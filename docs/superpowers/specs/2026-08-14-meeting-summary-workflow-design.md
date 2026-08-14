# Meeting Summary Workflow Design

## Summary

Issue #319 extracts Meeting Summary generation orchestration from `AppState.swift` into an instance-owned `MeetingSummaryWorkflow`.

The existing low-level boundaries remain authoritative:

- `MeetingSummaryService` generates and validates Summary drafts,
- `MeetingSummarySource` defines source normalization and fingerprints,
- `MeetingSummaryEnvelope` and `MeetingSummaryAttempt` define durable records,
- `PipelineHistoryStore` persists active note history,
- and `AppState` remains the UI-facing owner of settings, public actions, and published mirrors.

The remaining problem is orchestration. `AppState` currently owns generation revisions, in-progress and pending-reveal state, language resolution, source construction, generator invocation, stale-completion checks, successful and failed attempt persistence, existing-summary preservation, and completion ordering. This design moves those responsibilities into a focused workflow without changing prompts, models, schemas, user-facing copy, or Summary output.

## Why #319 Precedes #318

The remaining Phase 2 issues are #318, transcription retry/resume extraction, and #319, Meeting Summary extraction.

#319 should proceed first because:

- #317 now provides a stable history-runtime boundary and makes the current history store replacement rules explicit,
- successful transcription retry must invalidate in-flight Summary generation,
- a focused Summary invalidation API gives #318 a stable collaborator instead of a temporary callback into `AppState`,
- and the current Meeting Summary path already has extensive behavioral coverage in `MeetingSummaryAppStateTests`.

#318 spans cloud checkpoints, durable sidecars, transcript assets, Post-processing, startup reconciliation, and several source-shape test suites. Stabilizing Summary invalidation first avoids changing that broader workflow twice.

## Current State

### Availability and source preparation

`AppState` currently decides whether Summary generation is available by reading:

- the note intent and transcription status,
- the current transcript,
- feature enablement,
- backend readiness,
- and `meetingSummaryGeneratingNoteIDs`.

It also builds `MeetingSummarySource`, maps calendar attendees, chooses processed or raw transcript text, resolves the output language, and may durably update inferred spoken-language metadata before generation.

### Generation and persistence

`generateMeetingSummary(id:)` currently:

1. finds the starting history item,
2. verifies availability and durable history,
3. captures backend and model metadata,
4. captures a per-note generation revision,
5. marks the note as generating,
6. resolves and, when needed, persists spoken-language metadata,
7. builds and fingerprints the source,
8. constructs a generator through `AppStateDependencies`,
9. awaits generation,
10. rejects stale revisions, changed transcripts, and deleted notes,
11. persists either a success envelope and attempt or a failed attempt,
12. preserves the previous Summary and action completion on failure,
13. records pending reveal only after durable success,
14. and clears in-progress state when the same generation revision completes.

### External invalidation

Other `AppState` paths directly mutate generation state:

- transcript edit invalidates generation after a successful durable edit,
- successful transcription retry invalidates generation after durable history replacement,
- Summary deletion invalidates generation after durable deletion,
- note deletion forgets note-scoped generation state after durable note deletion,
- history clear forgets all generation state after durable clear,
- and archive runtime replacement clears all generation-specific state.

The distinction between invalidate and forget is behaviorally important. Failed or missing note mutations must not silently clear a still-running generation.

## Approaches Considered

### 1. Stateful instance-owned workflow — recommended

A `MeetingSummaryWorkflow` owns revisions, generation activity, pending reveal, source preparation, generator execution, stale-result rejection, attempt persistence ordering, and invalidation. `AppState` supplies immutable request values and a narrow history collaborator, then mirrors workflow events.

This satisfies #319 and provides #318 with a stable Summary invalidation boundary.

### 2. Stateless generation executor

A stateless executor would move generator invocation and envelope construction but leave revisions, pending reveal, persistence, and completion ordering in `AppState`.

This reduces method size but leaves the central race and ownership problem unsolved, so it is rejected.

### 3. Summary domain store

A larger extraction would move generation plus action completion, Summary deletion, and all Summary-related history CRUD behind a dedicated domain store.

That overlaps #192 and expands the migration beyond #319. It is rejected.

## Architecture

### `MeetingSummaryWorkflow`

Create `Sources/MeetingSummaryWorkflow.swift` containing the workflow and its focused value types.

Each `AppState` owns one workflow instance. No static current workflow, mutable process-global factory, or compatibility shim is introduced.

The workflow owns:

- per-note generation revisions,
- generating note IDs,
- pending-reveal note IDs,
- language resolution for a generation attempt,
- source construction and fingerprint capture,
- generator construction and execution,
- stale completion validation,
- durable success and failed-attempt ordering,
- and invalidate, forget, and forget-all semantics.

The workflow does not own general history CRUD, Summary UI, action-item editing, Summary deletion, transcript editing, transcription retry, backend settings, or model installation.

### `MeetingSummaryWorkflowState`

```swift
struct MeetingSummaryWorkflowState: Equatable, Sendable {
    var generatingNoteIDs: Set<UUID>
    var pendingRevealNoteIDs: Set<UUID>
}
```

Generation revisions remain private implementation state. `AppState` retains its existing `@Published private(set) var meetingSummaryGeneratingNoteIDs` as a compatibility mirror and updates it only from complete workflow state events.

Pending reveal moves fully into the workflow. `AppState.consumeMeetingSummaryPendingReveal(id:)` remains public and delegates to the workflow.

### `MeetingSummaryGeneratorConfiguration`

The current generator dependency takes the entire `AppState`:

```swift
@MainActor (AppState) -> any MeetingSummaryGenerating
```

Replace it with a small attempt-scoped value:

```swift
struct MeetingSummaryGeneratorConfiguration: Sendable {
    let backendExecutor: AIProcessingBackendExecutor
    let cloudFallbackModelID: String?
}
```

`AppState` builds this configuration from the current backend choice, API settings, Local AI manager, and instance-owned Local AI availability before starting the workflow request. API credentials remain runtime-only inside the backend executor. The configuration is never stored in workflow state, history, attempts, diagnostics, or durable metadata.

`AppStateDependencies.makeMeetingSummaryGenerator` becomes:

```swift
@MainActor
(MeetingSummaryGeneratorConfiguration) -> any MeetingSummaryGenerating
```

The production closure constructs `MeetingSummaryService`. Tests continue to inject deterministic generators without a global replacement seam.

### `MeetingSummaryWorkflowDependencies`

```swift
struct MeetingSummaryWorkflowDependencies {
    var makeGenerator:
        @MainActor (MeetingSummaryGeneratorConfiguration)
            -> any MeetingSummaryGenerating
    var now: @Sendable () -> Date
}
```

The dependencies are copied into the originating workflow instance. Generator construction remains per attempt and Main Actor isolated. The injectable clock makes attempt and envelope timestamps deterministic in direct workflow tests.

### `MeetingSummaryWorkflowRequest`

A request captures all execution decisions before the first asynchronous boundary:

```swift
struct MeetingSummaryWorkflowRequest {
    let noteID: UUID
    let initialItem: PipelineHistoryItem
    let requestedOutputLanguage: String
    let configuredBackendKind: MeetingSummaryBackendKind
    let configuredModelID: String
    let providerHost: String?
    let generatorConfiguration: MeetingSummaryGeneratorConfiguration
}
```

The request does not retain `AppState`. Later changes to settings or test dependency variables cannot redirect an active generation.

### `MeetingSummaryHistoryAccess`

The workflow receives a narrow, request-scoped history collaborator:

```swift
struct MeetingSummaryHistoryAccess {
    var durability: @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) throws -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}
```

`AppState` constructs it from the current `PipelineHistoryStore` for each generation request. It is not retained as workflow runtime state. The item lookup throws when the originating store becomes unreadable, allowing the workflow to distinguish a persistence outage from a genuinely missing or changed note.

This request-scoped design coordinates with #317: an archive runtime replacement cannot leave the workflow permanently attached to an old store. Archive admission already blocks while Meeting Summary work is active, so the originating store remains valid for the duration of an accepted attempt.

The collaborator exposes only the operations needed for Summary generation. It does not become a competing general history store.

### `MeetingSummaryWorkflowEvent`

```swift
enum MeetingSummaryWorkflowEvent {
    case stateChanged(MeetingSummaryWorkflowState)
    case itemPersisted(PipelineHistoryItem)
}
```

Events are delivered on the Main Actor. `itemPersisted` is emitted only after the history collaborator confirms a durable update. `AppState` applies the item to its `pipelineHistory` mirror if the row still exists.

No event contains API credentials, transcript contents beyond the already-existing updated history item, absolute user paths, or raw provider errors.

### `MeetingSummaryWorkflowOutcome`

The workflow returns a typed immediate outcome instead of changing `AppState` error semantics:

```swift
enum MeetingSummaryWorkflowOutcome {
    case verifiedSuccess
    case unverifiedSuccess
    case invalidInput
    case sourceChanged
    case generationFailed(Error)
    case persistenceFailed
}
```

This type is consumed on the Main Actor and is not durable state. `AppState.generateMeetingSummary(id:)` maps outcomes back to the existing public behavior:

- `verifiedSuccess` and `unverifiedSuccess` return normally,
- `invalidInput` throws `MeetingSummaryError.invalidInput`,
- `sourceChanged` throws `MeetingSummaryError.sourceChanged`,
- `generationFailed(error)` rethrows the original error,
- and `persistenceFailed` throws `QuillUserIssueError.historyPersistenceUnavailable()`.

This preserves existing callers and user-issue mapping while giving direct workflow tests explicit categories.

## Data Flow

### Admission

```text
AppState.generateMeetingSummary(id:)
  → find current UI-facing item
  → existing availability checks
  → capture backend/model/output-language configuration
  → create current-store MeetingSummaryHistoryAccess
  → workflow.generate(request, historyAccess)
```

The workflow rejects a non-durable store before mutating generation state.

### Language and source preparation

```text
workflow captures revision and marks note generating
  → choose processed transcript, falling back to raw transcript
  → resolve explicit or spoken-language-derived output language
  → if spoken-language metadata must change:
      reload current item
      verify note and revision
      durable persist updated language metadata
      emit itemPersisted
  → build MeetingSummarySource with calendar context
  → capture source fingerprint
  → construct generator from captured configuration
```

Language resolution preserves the current rules:

- explicitly configured Summary output language wins,
- engine-detected or configured spoken language is retained,
- transcript-inferred and unavailable language may be recomputed,
- and missing language produces the existing `meetingSummaryLanguageUnavailable` issue.

### Generator completion validation

After generator success or failure, the workflow reloads the current item through `MeetingSummaryHistoryAccess` and verifies:

1. the note still exists,
2. the current revision matches the captured revision,
3. and the current source fingerprint matches the attempt fingerprint.

Any mismatch yields `sourceChanged`. A history lookup failure yields `persistenceFailed` instead, so the caller surfaces the existing history-persistence warning. The workflow writes neither a success result nor a failed attempt for stale or unreadable history.

### Success

```text
verified current item + generation result
  → materialize MeetingSummaryEnvelope
  → preserve action completion from the current existing Summary
  → create succeeded MeetingSummaryAttempt
  → durable persist updated item
  → emit itemPersisted
  → add pending reveal
  → clear generating state for matching revision
  → return verifiedSuccess or unverifiedSuccess
```

An unverified generation remains a successful durable Summary with the existing evidence warning state.

### Generation failure

```text
generator/language/grounding/model error
  → verify current item, revision, and source fingerprint
  → map the existing QuillUserIssueRecord
  → create failed MeetingSummaryAttempt
  → preserve existing Summary and action completion
  → durable persist updated item
  → emit itemPersisted
  → clear generating state for matching revision
  → return generationFailed(originalError)
```

`MeetingSummaryError.sourceChanged` bypasses failed-attempt persistence and returns `sourceChanged`.

### Persistence failure

If spoken-language metadata, failed attempt, or successful Summary persistence fails:

- no `itemPersisted` event is emitted,
- the UI mirror remains unchanged,
- pending reveal is not added,
- generating state is cleared only when the captured revision is still current,
- and the workflow returns `persistenceFailed`.

A failed persistence is never reported as durable success.

## Invalidation Semantics

The workflow exposes three distinct commands.

### `invalidate(noteID:)`

- increments the note revision,
- removes the note from generating state,
- clears pending reveal.

Called only after successful durable transcript edit, successful transcription retry, or successful Summary deletion.

### `forget(noteID:)`

- removes the note revision entry entirely,
- removes generating and pending-reveal state.

Called only after successful durable note deletion.

### `forgetAll()`

- clears all revisions, generating state, and pending reveal.

Called only after successful durable history clear or verified archive runtime replacement.

Missing notes and failed delete or clear operations do not invoke these commands. This preserves the current race semantics covered by `MeetingSummaryAppStateTests`.

## `AppState` Responsibilities After Extraction

`AppState` retains:

- Summary settings and backend readiness,
- `meetingSummaryAvailability(for:)`,
- public `meetingSummarySource(for:)` as a thin workflow-source adapter,
- public `generateMeetingSummary(id:)` and outcome-to-error mapping,
- the published generating-ID mirror,
- action-item completion,
- Summary deletion and its durable mutation guard,
- transcript editing, retry, note deletion, and history clear,
- application of `itemPersisted` events to `pipelineHistory`,
- and UI navigation and user-facing error presentation.

`AppState` no longer owns:

- generation revisions,
- pending reveal storage,
- generator execution,
- language/source preparation for generation,
- stale completion checks,
- successful or failed attempt construction,
- attempt persistence ordering,
- or generation completion cleanup.

## Error and Safety Rules

- API keys remain runtime-only and never enter durable Summary metadata or diagnostics.
- Deleted notes cannot be recreated by a late generation.
- Changed transcripts cannot receive stale Summary or failed-attempt state.
- Existing Summary and action completion survive generation failure.
- Failed persistence never updates the `AppState` mirror or pending reveal.
- Summary JSON schema, source fingerprint version, prompt version, backend/model metadata, evidence verification, and user issues remain compatible.
- Generator construction remains per attempt and Main Actor isolated.
- No provider, retry, fallback, prompt, model-selection, or user-copy policy changes are introduced.

## Testing Strategy

### New direct workflow suite

Create `Tests/MeetingSummaryWorkflowTests.swift` covering:

- independent workflow instances and generator factories,
- originating dependency and configuration capture,
- verified and unverified success,
- action completion preservation,
- configured, engine-detected, and transcript-inferred language,
- language metadata persistence before generator invocation,
- failed-attempt persistence and existing Summary preservation,
- effective fallback model and provider metadata,
- language, failed-attempt, and success persistence failures,
- transcript change, note deletion, and revision invalidation races,
- stale success and stale failure rejection,
- missing-note non-resurrection,
- one-shot pending reveal,
- and invalidate, forget, and forget-all semantics.

The direct suite uses deterministic history closures, generator stubs, and a clock. It does not construct the UI-facing `AppState`.

### Existing AppState suite

Retain `MeetingSummaryAppStateTests` for adapter and integration behavior:

- independent `AppState` instances,
- public generation API and error mapping,
- published generating state,
- UI availability,
- action completion and Summary deletion,
- transcript-edit, retry, delete, clear, and archive invalidation routing,
- history mirror updates,
- and dependency snapshot ownership.

Workflow-internal tests should migrate to the direct suite rather than being duplicated. Existing AppState tests remain until their replacement behavior is green.

### Existing low-level suites

`MeetingSummaryServiceTests`, `MeetingSummaryOutputValidatorTests`, prompt tests, model tests, and durable decoding tests remain authoritative for generation algorithms, transport behavior, validation, schema compatibility, and rendering. The workflow suite does not duplicate those assertions.

### Source-shape policy

No new exact-source-string assertions are added for workflow internals. Existing source assertions that become invalid solely because ownership moved are removed only after direct behavioral coverage is present. The Summary UI contract may continue checking that it calls the existing public `AppState` route.

### Test wiring and verification

Add the direct workflow suite to the grouped full-source AppState runner and the corresponding Makefile source list.

Verification order:

1. focused direct workflow tests,
2. existing Meeting Summary AppState tests,
3. `make check-test-wiring`,
4. `make test`,
5. production build with `CODESIGN_IDENTITY=Quill`,
6. `codesign --verify --deep --strict`,
7. and `/code-review medium` exactly once after the full tree is green.

## Files

Create:

- `Sources/MeetingSummaryWorkflow.swift`
- `Tests/MeetingSummaryWorkflowTests.swift`
- `docs/superpowers/specs/2026-08-14-meeting-summary-workflow-design.md`

Modify:

- `Sources/AppState.swift`
- `Sources/AppStateDependencies.swift`
- `Tests/MeetingSummaryAppStateTests.swift`
- `Tests/FullSourceAppStateTestRunner.swift`
- `Makefile`

Other tests are changed only when an existing ownership-specific source assertion must be replaced by direct workflow behavior.

## Non-Goals

- No prompt, model, backend, output-schema, Summary UI, or action-item behavior change.
- No transcription retry/resume extraction; that remains #318.
- No transcript editing redesign.
- No general Summary domain store.
- No `PipelineHistoryStore` format or API redesign.
- No broader `AppState` split from #192.
- No compatibility shim that recreates process-global mutable dependency replacement.

## Acceptance Criteria

- Meeting Summary generation has one focused owner outside `AppState.swift`.
- The workflow is independently testable without constructing `AppState` or replacing a global generator.
- Active attempts use only captured configuration and the originating request-scoped history collaborator.
- Success, unverified success, generation failure, source change, deletion, revision invalidation, language handling, persistence failure, and pending reveal are behavior-tested.
- Existing Summary and action completion survive failed attempts.
- Deleted or changed notes never receive stale Summary state.
- Existing durable Summary records decode unchanged.
- AppState public APIs, published mirrors, settings, UI routes, and user messages remain compatible.
- No process-global Summary workflow or generator seam is introduced.
- Focused tests, `make check-test-wiring`, `make test`, signed production build, and code-sign verification pass.
