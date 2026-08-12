# Internal Logic Small Refactors Design

**Date:** 2026-08-12
**Status:** Approved for implementation planning

## Goal

Improve three internal hot spots without changing Quill’s user-facing behavior:

1. make oversized-token transcript splitting linear in input size,
2. make post-processing prompt-leak validation a single, shared policy,
3. reuse timestamp formatters without changing localized output.

This is intentionally a small first refactoring step. It does not introduce new features, redesign `AppState`, change storage formats, parallelize post-processing requests, or alter retry behavior.

## Scope

### Included

- `PostProcessingTranscriptSplitter` byte-boundary fallback
- post-processing prompt instruction/signature ownership
- removal of duplicate post-processing prompt-leak validation
- replacement of a source-string contract test with behavior tests
- locale/calendar/time-zone-aware reuse of `DateFormatter` and `DateIntervalFormatter`
- focused regression tests and the full `make test` suite

### Excluded

- concurrent cloud chunk processing
- `AppStateDependencies`
- source-string tests outside the prompt-leak case
- credential or asset storage refactoring
- Calendar diagnostics
- general-purpose utility modules
- changes to timestamp wording or punctuation

## Design

### 1. Linear safe-byte splitting

`PostProcessingTranscriptSplitter.splitAtSafeByteBoundaries` keeps its existing contract:

- preserve source character order,
- never split a Swift `Character`,
- emit chunks in source order,
- keep each chunk within `maximumSourceBytes` whenever a single character itself fits the limit,
- preserve the current behavior when a single character exceeds the limit.

The implementation will stop constructing `current + character` and recounting the entire candidate’s UTF-8 bytes on every iteration. It will instead maintain the current chunk’s byte count, compute each incoming character’s UTF-8 byte count once, flush when necessary, and append incrementally. This changes the oversized unbroken-token path from quadratic repeated copying/counting to linear traversal.

No public API changes are required.

### 2. One post-processing prompt-leak policy

The cleanup data-envelope instruction and the signatures used to detect an echoed instruction must have one owner. A small policy type in the post-processing domain will provide:

- the full app-owned cleanup instruction used to construct the user message,
- the stable signature fragments that identify an echoed instruction.

`PostProcessingService` and `PostProcessingOutputValidator` will both consume this policy instead of maintaining separate literals.

`PostProcessingOutputValidator.validate` remains the single acceptance gate for cleanup output. `processChunk` will remove the immediate second call to `containsPostProcessingPromptLeak` after successful validation. Rejection behavior remains unchanged: a detected leak becomes `PostProcessingError.outputRejected(.promptLeak)`.

The detector remains source-aware. A signature found in output is rejected only when that normalized signature was not already present in the source transcript. This preserves legitimate dictation that quotes Quill’s instruction text. Ordinary references such as `data.transcript` remain valid.

The source-string test that requires a particular guard statement in `PostProcessingService.swift` will be removed. Service-level behavior tests will verify the rejection path instead, allowing the internal validation structure to change without weakening protection.

### 3. Timestamp formatter reuse

`NoteTimestampFormatter` keeps its current API and localized output. Formatter reuse will be internal.

A private cache will key formatter instances by all inputs that affect output:

- locale identifier,
- calendar identifier,
- time-zone identifier,
- formatter role: row timestamp, detail timestamp, or detail interval.

The cache will configure formatters exactly as today:

- row template: `MMMMdEEEjm`,
- detail template: `yMMMdEEEjm`,
- `Calendar.current` semantics,
- the effective current time zone.

`DateFormatter` and `DateIntervalFormatter` are mutable reference types. Cache lookup and formatting will therefore occur through a synchronized cache operation rather than returning a shared formatter for unsynchronized use. The cache stays private; production code will not expose formatter identities, cache size, or reset hooks solely for tests.

The existing localized-space normalization remains unchanged in this work. Moving that helper into a broad utility would add unrelated scope.

## Data Flow

### Transcript splitting

1. paragraph/sentence/word splitting reaches an oversized unbroken token,
2. the safe-byte splitter visits each character once,
3. it updates an accumulated byte count,
4. it flushes the current chunk before adding a character that would exceed the limit,
5. it returns ordered chunks to the existing post-processing pipeline.

### Prompt-leak validation

1. `PostProcessingService` builds its user message from the shared policy instruction,
2. model output is sanitized as today,
3. `PostProcessingOutputValidator.validate` normalizes the source, output, and policy signatures,
4. any app-owned signature appearing only in output yields `.promptLeak`,
5. `processChunk` maps validation failure to the existing `PostProcessingError.outputRejected` path.

### Timestamp formatting

1. a caller requests a row or detail timestamp,
2. `NoteTimestampFormatter` builds a cache key from the effective locale, current calendar, time zone, and role,
3. the synchronized cache finds or creates the formatter,
4. formatting occurs while access to that mutable formatter is protected,
5. localized spaces are normalized and the existing string is returned.

## Error Handling

This refactoring introduces no new user-facing errors.

- Transcript splitting remains non-throwing.
- Prompt leaks continue to use `.promptLeak` and the current fallback/user-issue path.
- Formatter creation uses Foundation objects that do not require fallible external resources.
- No error is silently converted into a new success state.

If a regression causes prompt policy and detection to diverge, behavior tests must fail on the actual service result rather than on source layout.

## Testing

### Transcript splitter tests

Extend `PostProcessingChunkingTests` to cover:

- a long ASCII token,
- multibyte Korean characters,
- emoji or another multi-scalar `Character`,
- byte-budget compliance for every emitted chunk,
- preservation of character order when chunks are concatenated.

Do not add wall-clock performance assertions. The structural implementation and large-input regression case provide stable evidence without timing flakiness.

### Prompt-leak tests

Retain validator coverage and add or strengthen service-level cases for:

- full instruction echo,
- first signature only,
- second signature only,
- punctuation/case-reformatted echo,
- signature already present in source,
- ordinary `data.transcript` wording.

Remove `testFinalPromptLeakGuardUsesValidatorDetector`, which asserts a literal implementation statement rather than behavior.

### Timestamp tests

Keep all existing exact localized outputs. Add behavioral coverage for:

- repeated calls with the same locale,
- alternating locales without cross-contamination,
- distinct time-zone/calendar cache keys where practical through explicit internal inputs rather than global mutation,
- concurrent formatting calls producing valid deterministic results.

Tests must not depend on cache count or formatter object identity.

## Verification

Implementation is complete only when:

1. focused post-processing and timestamp tests pass,
2. `make test` passes,
3. existing timestamp strings are unchanged,
4. prompt-leak rejection is not weakened,
5. no test-only production API is added,
6. the pre-existing untracked design documents in the primary worktree remain untouched.

## Implementation Sequence

1. Add splitter regression tests and implement accumulated byte counting.
2. Add behavior coverage for the final prompt-leak path, introduce the shared policy, and remove duplicate validation plus the source-string test.
3. Add formatter reuse tests and implement the synchronized formatter cache.
4. Run focused tests after each step and the full suite at the end.

Each step should remain independently reviewable and reversible even if delivered in one branch.
