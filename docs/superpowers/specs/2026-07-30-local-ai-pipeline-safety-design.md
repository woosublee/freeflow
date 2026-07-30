# Local AI Pipeline Safety — Design

## Context

Quill currently offers Local AI through Qwen2.5 7B Instruct for Post-processing, Context, and Meeting Summary. The model is capable of useful Korean cleanup and structured meeting summaries, but the product pipeline does not yet constrain untrusted input, token budgets, or accepted output tightly enough.

The investigation with Quill's bundled `llama-server` and the installed Qwen2.5 7B Q4_K_M model reproduced these failures:

- A transcript that closes the `RAW_TRANSCRIPTION` delimiter and includes a Chinese instruction makes Post-processing return Chinese text instead of cleaned dictation.
- A malicious window title makes text-only Local Context return an injected result; injecting that result into Post-processing makes a normal transcript return `EMPTY`.
- An 8,000-character Korean transcript can return `EMPTY` from Local Post-processing and is currently treated as a successful result.
- A 12,000-character Korean Summary chunk consumes 8,114 prompt tokens against the current 8,192-token Local server context. `llama-server` begins context shifting and can exceed the request timeout.
- Summary validates JSON shape but not output language, source quote presence, or owner/due-date grounding.

This design replaces the old Local Context decision from `docs/superpowers/specs/2026-07-21-local-ai-processing-engine-design.md` and `docs/superpowers/specs/2026-07-22-local-ai-processing-backends-design.md`: text-only Local models are no longer eligible for Context. Context requires a model that can actually analyze the screenshot.

## Goals

1. Make model availability feature-specific: every Cloud or Local model appears only in the Settings features it is declared to support.
2. Keep Qwen2.5 7B available for Local Post-processing and Meeting Summary, but remove it from Context because it cannot consume screenshots.
3. Make every Local AI pipeline non-destructive: an invalid, empty, wrong-language, injected, timed-out, or unavailable model result never replaces user source text or an existing meeting summary.
4. Replace character-count chunking with model-token budgets that reserve system, template, calendar, output, and safety capacity.
5. Preserve the existing screenshot Context pipeline while preventing text-only Local models from being selected for it.
6. Make Local model start, readiness, cancellation, output rejection, and history persistence failures visible and diagnosable without exposing source content or private paths.
7. Establish an architecture that allows a future vision-capable Local model to appear automatically in Context after its model metadata and runtime artifacts are declared.

## Non-goals

- Adding a vision-capable Local model in this change.
- Automatically changing a Local Context user to a Cloud model. A product update must not begin transmitting screenshots or metadata to a provider without an explicit new user choice.
- Removing Qwen2.5 1.5B in this change. Its removal, stored-selection migration, and downloaded-file policy are a follow-up after this safety work lands.
- Replacing the existing `llama-server` process isolation with an in-process inference binding.
- Turning Meeting Summary into automatic background generation.
- Sending Local requests to a Cloud fallback when the user selected Local AI.

## Product Decisions

### Feature-specific model support

A model is not globally "supported" or "unsupported." It has an explicit set of Quill features it supports.

```swift
enum AIModelFeature: Hashable, Sendable {
    case postProcessing
    case contextCapture
    case meetingSummary
}

enum AIModelModality: Hashable, Sendable {
    case text
    case image
}

struct AIModelCapabilities: Hashable, Sendable {
    let features: Set<AIModelFeature>
    let modalities: Set<AIModelModality>
    let recommendedContextWindow: Int?

    func supports(_ feature: AIModelFeature) -> Bool {
        features.contains(feature)
    }
}
```

`contextCapture` is valid only when the model has the `.image` modality. The catalog rejects descriptors that declare `.contextCapture` without `.image`.

The Qwen2.5 7B descriptor becomes:

```swift
features: [.postProcessing, .meetingSummary]
modalities: [.text]
recommendedContextWindow: 16_384
```

A future Local vision model can declare, for example:

```swift
features: [.postProcessing, .contextCapture]
modalities: [.text, .image]
recommendedContextWindow: 16_384
```

It does not appear in Meeting Summary unless that capability is explicitly added after quality validation.

### Local vision runtime contract

A Local model that declares `.image` must also declare the runtime requirements needed to receive image content.

```swift
enum LocalAIRuntime: Hashable, Sendable {
    case textChat
    case visionChat(projectorArtifact: LocalAIModelArtifact)
}
```

A vision Local model is selectable for Context only after the primary model artifact and projector artifact both validate. `LocalAIServerProcess` derives the appropriate vision launch arguments from this runtime declaration. `AIProcessingEndpoint.supportsImages` derives from the active model descriptor, not from whether the endpoint is Cloud or Local.

No model may claim Context support while running through the current text-only `--model <GGUF>` path.

### Settings behavior

Each Settings feature presents only models supporting that feature. Cloud and On This Mac remain visually separate sections, but both use the same capability predicate.

```text
Post-processing
  Cloud models supporting .postProcessing
  Local models supporting .postProcessing

Context
  Cloud models supporting .contextCapture and .image
  Local models supporting .contextCapture and .image

Meeting Summary
  Cloud models supporting .meetingSummary
  Local models supporting .meetingSummary
```

The Local model-management UI continues to show installed, downloadable, in-progress, and failed Local packages. A capability badge explains each model's available Quill features, for example `Post-processing · Meeting Summary` for Qwen2.5 7B.

When a previously stored feature selection no longer supports that feature, Quill does not silently substitute another model. It disables the feature and preserves a localized availability reason. Context capture does not start, and no screenshot is captured or uploaded. The user must explicitly select a capability-compatible model and re-enable the feature.

This rule applies to the existing stored Qwen2.5 7B Context selection. It does not automatically choose a Cloud vision model.

## Common Safety Boundary

### Untrusted input envelope

Transcript text, calendar values, and vocabulary are untrusted source data. They are never concatenated directly into prompt delimiters. This implementation preserves the existing Context prompt and Context-to-Post-processing flow for vision-capable models.

Every request creates a versioned, JSON-encoded envelope. JSON encoding escapes line breaks, quotes, delimiters, and role-like strings before model input.

```json
{
  "contract_version": "quill.ai.v2",
  "feature": "post_processing",
  "data": {
    "transcript": "Untrusted dictated text.",
    "context_summary": "Existing activity summary used only as a formatting reference."
  }
}
```

The feature system prompt defines the envelope's `data` values as quoted source material that must not add, override, or execute model instructions. JSON encoding does not make indirect prompt injection impossible for an LLM, so every output crosses a second safety boundary before use.

### Token budgets

`LocalAITokenBudgeter` computes input capacity from the selected model's context window. It counts the fully rendered chat request using the active Local tokenizer/template and reserves every non-source cost.

```text
model context window
- system prompt and chat-template tokens
- encoded envelope overhead
- feature output reservation
- fixed safety margin
= maximum source-data tokens
```

The safety margin is at least 512 tokens. Input is split before sending when the source data exceeds the remaining budget.

Qwen2.5 7B uses a 16,384-token Local server context. Feature reservations are:

| Feature operation | Completion reservation |
|---|---:|
| Post-processing chunk | source token count + 512, capped at 6,144 |
| Summary extraction | 1,024 |
| Summary intermediate merge | 1,024 |
| Summary final merge | 1,024 |

Post-processing input chunks are reduced until their expected output reservation, prompt overhead, and safety margin fit in the 16K context. Summary uses its smaller fixed output reservation to keep more space for grounded extraction. Context continues to use its existing compatible-vision request behavior and does not adopt this token-budgeting path in this work.

The request payload always sends the computed `max_completion_tokens`; Local requests no longer rely on the server's effectively unbounded completion default.

## Post-processing Pipeline

### Flow

```text
Raw transcript
  ↓
Sentence/paragraph chunking within token budget
  ↓
JSON envelope with the existing Context summary as a formatting reference
  ↓
Local or Cloud model request
  ↓
Chunk output validation
  ↓
Ordered concatenation and whole-output validation
  ├─ accepted → post-processed transcript
  └─ rejected → raw transcript retained
```

Chunk boundaries prefer paragraphs, then sentence endings, then the safe token boundary. Chunks are processed sequentially to preserve order and prevent multiple large Local requests from competing for the one active model slot.

### Output contract

`PostProcessingOutputValidator` accepts output only when all applicable checks pass:

1. The result is not empty for meaningful source input.
2. The result does not contain prompt wrappers, role tags, assistant boilerplate, or an apparent instruction response.
3. If Output Language is configured, generated prose has the requested dominant language. Preserved code, names, URLs, paths, flags, identifiers, and quoted source atoms are excluded from the language sample. An uncertain language classification rejects the transformed result rather than guessing.
4. URLs, email addresses, dates, numbers, filesystem paths, command flags, code-like identifiers, and custom vocabulary terms present in a source chunk remain present in its output.
5. The output is not a summary or answer in place of a cleanup. A normalized meaningful-token ratio and protected-atom comparison reject disproportionate collapse.
6. The merged output passes the same non-empty, protected-atom, language, and proportionality checks.

`EMPTY` is accepted only for input that a deterministic local filler classifier identifies as whitespace or known filler-only speech. If the classifier is uncertain, `EMPTY` is rejected and Quill retains raw text.

### Failure behavior

Output contract failures, transport errors, server errors, timeout, and cancellation do not create a blank final transcript.

```text
Model processing fails or output is rejected
  ↓
Use raw transcript as final transcript
  ↓
Record .rawFallback(reason)
  ↓
Show “Post-processing was not applied; the original transcript was kept.”
```

There is no blind automatic retry after language, injection, or semantic-preservation failure. A deterministic Local model retry with the same source is not expected to repair the problem. The user can retry after changing Settings or use the preserved raw transcript.

## Context Compatibility Policy

This implementation does not modify Context capture or propagation for a compatible model. The existing flow remains:

```text
active app metadata + active-window screenshot
  ↓
vision-capable Context model
  ↓
current activity summary
  ↓
existing Post-processing formatting reference
```

The only Context changes are model-selection safeguards:

- Context starts only when its selected model declares both `.contextCapture` and `.image`.
- Qwen2.5 7B and other text-only Local models are absent from the Context picker.
- An existing stored text-only Local Context selection disables Context with an explanation; it does not select a Cloud model or capture a screenshot.
- A future Local vision model appears in Context after its declared model/projector artifacts validate and its endpoint reports image support.

The existing Context prompt, screenshot-plus-metadata payload, activity-summary representation, Context fallback behavior, and Context-to-Post-processing flow remain unchanged in this work.

## Meeting Summary Pipeline

### Flow

```text
Transcript + calendar source data
  ↓
Token-budget extraction chunks
  ↓
Grounded partial summary JSON
  ↓
Bounded intermediate merges
  ↓
Final grounded summary JSON
  ↓
Validation before atomic replacement
```

Summary chunking uses the token budgeter rather than `12_000` characters. Calendar values are counted as source tokens for every extraction request.

Partial summaries are not all joined into a single final prompt. The merger groups validated partial documents into batches that fit the same merge budget, creates intermediate summaries, and repeats until a single final summary remains.

### Evidence-bearing schema

Summary schema version 2 stores evidence for every generated assertion. The Note Browser continues to display only readable text, while the persisted draft retains evidence for validation and inspection.

```json
{
  "overview": {
    "text": "...",
    "sourceQuotes": ["..."]
  },
  "keyPoints": [{"text": "...", "sourceQuote": "..."}],
  "decisions": [{"text": "...", "sourceQuote": "..."}],
  "actionItems": [{
    "task": "...",
    "owner": "... or null",
    "dueDate": "... or null",
    "sourceQuote": "..."
  }],
  "openQuestions": [{"text": "...", "sourceQuote": "..."}]
}
```

Legacy stored Summary JSON remains readable. A regenerated summary uses version 2; an existing legacy summary is never discarded merely because it lacks evidence fields.

### Summary validation

`MeetingSummaryOutputValidator` requires:

- strict version-specific JSON schema;
- generated field language matching the selected Summary language; source quotes are exempt because they preserve source language;
- every source quote to be an exact substring of the source transcript, calendar data, or a validated prior-stage partial record;
- every action item's owner and due date, when non-null, to occur in its source quote after normalized whitespace/date comparison;
- no source quote-less decision, action item, open question, or overview assertion;
- no unsupported owner or due date inferred from unrelated source text.

If validation fails, Quill leaves the existing Summary untouched and exposes a retryable Summary error. It does not save a structurally valid but ungrounded or wrong-language draft.

## Local Runtime

### Readiness

Local server startup becomes:

```text
Start process
  ↓
Loopback health check
  ↓
Fixed, source-free chat-completion readiness probe
  ↓
Ready for feature requests
```

The probe verifies the active model can accept the OpenAI-compatible chat request and return a non-empty response. It contains no transcript, screenshot, calendar, or user metadata.

### Diagnostics and lifecycle

`RealLocalAIServerProcess` retains a bounded stdout/stderr ring buffer. Only redacted diagnostic categories and a limited trailing server excerpt appear in a `QuillUserIssueRecord`; private source text, full filesystem paths, authorization values, and request bodies do not enter user-visible history.

Cancellation must cancel the HTTP transport and release the Local server lease. A cancelled or timed-out request is considered complete only after its lease is released; a subsequent request must be able to acquire a ready server slot. Process exit, readiness failure, transport timeout, output validation rejection, and model corruption remain distinct issue codes.

## Persistence and UI State

```swift
enum AIProcessingOutcome: Codable, Sendable {
    case succeeded
    case bypassed(reason: AIBypassReason)
    case rawFallback(reason: AIValidationFailure)
    case failed(reason: AIProcessingFailure)
}
```

History and UI distinguish model success from safe fallback:

```text
Post-processing applied
Post-processing was not applied; the original transcript was kept
Context was unavailable and was excluded
Summary could not be created; the existing summary was kept
Local model could not start
```

When history-store recovery fails, Quill first moves the existing SQLite store, WAL, and SHM files into a timestamped recovery backup. It then creates a fresh store. The UI presents a persistence warning for the session and does not imply that newly created summaries are durable while the app is using in-memory fallback.

## Testing

### Unit and service tests

- capability predicates filter every feature picker correctly;
- Qwen2.5 7B is available for Post-processing and Summary but unavailable for Context;
- a Local vision fixture appears in Context and produces an image-capable endpoint only when its projector artifact is ready;
- old Context Local Qwen selection disables Context without selecting or contacting Cloud;
- envelope encoding preserves arbitrary delimiters, quotes, newlines, role tags, and JSON-looking transcript data as data;
- token budgets reserve prompt, template, output, and safety capacity;
- Post-processing rejects non-filler `EMPTY`, wrong-language output, missing protected atoms, template echoes, and summary-like collapse;
- existing Context screenshot capture and Context-to-Post-processing propagation remain unchanged for a compatible vision model;
- Summary validates evidence, quote membership, owner/due-date grounding, language, and legacy schema compatibility;
- hierarchy merge never creates a request over its budget;
- persistence recovery backs up the failed store and exposes non-durable mode.

### Real Local integration suite

A separate opt-in target runs only when the bundled `llama-server` and Quality Qwen2.5 7B artifacts are installed:

```text
make test-local-ai-integration
```

It uses the real bundled binary and model through loopback. It verifies properties, not exact prose:

1. a Post-processing delimiter injection never becomes accepted Chinese output and preserves raw transcript;
2. Qwen2.5 7B is never selected for Context and a compatible vision endpoint retains the existing screenshot Context request shape;
3. a meaningful long Post-processing transcript never becomes accepted `EMPTY`;
4. a Korean 12,000-character Summary completes under the 16K budget with Korean, evidence-bearing JSON;
5. multi-batch Summary merge remains bounded and grounded;
6. cancellation, timeout, and forced server exit release the Local lease and permit a later request;
7. no request sends authorization to the loopback Local server.

The ordinary unit suite continues to use injected fake processes and transports, so CI does not require multi-gigabyte model artifacts.

## Delivery Boundaries

This implementation delivers the capability registry and pipeline safeguards for the models already offered by Quill. Qwen2.5 1.5B removal is intentionally deferred. Its follow-up must use the generic unavailable-selection behavior above, define retention or cleanup for its downloaded artifact, and add a migration test for every persisted feature selection that names the removed model.
