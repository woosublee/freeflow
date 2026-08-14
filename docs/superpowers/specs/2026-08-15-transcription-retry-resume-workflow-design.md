# Transcription Retry and Resume Workflow Design

## Summary

Issue #318 extracts manual transcription Retry and durable startup Resume orchestration from `AppState.swift` into an instance-owned `TranscriptionRetryWorkflow`.

The extraction is behavior-preserving at the user and durable-data boundaries. It keeps:

- the existing `TranscriptionExecutionSnapshot` model from #217,
- provider, model, language, chunking, retry, and fallback policy,
- `CloudTranscriptionJobRecord` and checkpoint schemas,
- `PipelineHistoryItem` persisted fields and user-issue encoding,
- `NoteAssetStore` paths and best-effort transcript-file behavior,
- manual Retry’s current-settings and interactive-delivery behavior,
- startup Resume’s persisted-policy and history-only behavior,
- raw-transcript fallback, AI outcome, spoken-language, audio-only metadata, and cloud sidecar semantics,
- and the public `AppState.retryTranscription(item:)` API.

The new workflow owns active Retry/Resume attempts, immutable execution input, progress, stale-completion rejection, history and transcript persistence ordering, and sidecar cleanup. `AppState` remains the UI-facing adapter that decides whether Retry is available, captures current settings, mirrors workflow state, advances warning generations, delegates Meeting Summary invalidation, and performs pasteboard delivery.

Initial audio Import and stopped-recording transcription remain in `AppState`. This issue does not create a general transcription pipeline or overlap #192’s broader AppState decomposition.

## Why This Is an Architectural Extraction

Manual Retry and startup Resume currently duplicate a large asynchronous sequence inside `AppState.swift`:

1. resolve the history item and stored audio,
2. build an execution snapshot,
3. prepare or resume a cloud job session,
4. create and run `TranscriptionService`,
5. parse transcript commands,
6. run Post-processing or a raw fallback,
7. persist a transcript file when needed,
8. reconstruct a history item,
9. reject stale cloud callbacks,
10. persist history,
11. advance warning-generation state,
12. invalidate in-flight Meeting Summary generation where required,
13. delete a completed cloud sidecar,
14. update progress and retry state,
15. and optionally copy the result to the pasteboard.

The dangerous behavior is not service construction alone. Correctness depends on the ordering between the active attempt, current history row, permanent transcript asset, durable history, Meeting Summary revision, cloud sidecar, and UI delivery. A stateless executor would leave those races and ownership rules in `AppState`, so the extraction must be stateful.

## Confirmed Scope

### Included

- Manual Retry orchestration for cloud and local transcription.
- Startup Resume orchestration for compatible durable cloud jobs.
- Per-note active attempt tokens and owned tasks.
- Retry/Resume progress state.
- Immutable Retry/Resume request values.
- Same-cloud checkpoint reuse and incompatible-cloud restart.
- Local Retry behavior in the presence of an existing cloud sidecar.
- Transcript command parsing and Post-processing through a captured behavior boundary.
- Focused history-item transcription replacement.
- Current-item and source validation before persistence.
- Success, fallback, provider failure, cancellation, stale completion, history-persistence failure, transcript-asset failure, and sidecar-cleanup failure outcomes.
- Warning-generation, Meeting Summary invalidation, and interactive-delivery events after durable persistence.
- Retry/Resume source-shape assertions replaced by direct behavior tests.

### Excluded

- Initial audio Import orchestration.
- Stopped-recording transcription orchestration.
- Realtime transcription and file fallback.
- Recording startup recovery.
- Provider, model, language, chunking, retry-count, timeout, or fallback-policy changes.
- A new transcription snapshot model.
- A new durable job or history schema.
- General history CRUD or note-asset ownership.
- UI redesign or user-copy changes.
- A full transcription domain store or broader AppState split from #192.

## Existing Boundaries Reused

The extraction builds on existing focused primitives rather than duplicating them.

### `TranscriptionExecutionSnapshot`

`TranscriptionExecutionSnapshot` remains the authoritative backend execution input. It contains either:

- `CloudTranscriptionExecutionSnapshot` plus `TranscriptionCompletionSnapshot`, or
- `LocalTranscriptionExecutionSnapshot` plus `TranscriptionCompletionSnapshot`.

The workflow does not introduce a second provider/model/language snapshot. API keys stay runtime-only in the cloud snapshot and are never copied into workflow state, events, durable jobs, history metadata, or diagnostics.

### `CloudTranscriptionJobStore`

`CloudTranscriptionJobStore` remains authoritative for:

- active cloud job sessions,
- checkpoint creation and loading,
- contiguous completed chunk prefixes,
- compatible retry reuse,
- incompatible retry replacement,
- failure recording,
- completed-job deletion,
- and stale-session rejection.

The workflow receives the originating store for each accepted attempt. It does not hold one process-global current store.

### `CloudTranscriptionHistoryCoordinator`

Initial Import and stopped-recording cloud tasks continue to use the existing `CloudTranscriptionHistoryCoordinator` owned by `AppState`.

Before a manual Retry takes ownership of the same history ID, the workflow invokes a narrow cancellation boundary backed by this coordinator. The Retry/Resume workflow then owns its own attempt task and revision while `CloudTranscriptionJobSession` protects checkpoint and sidecar writes. This keeps initial flows unchanged without allowing an old initial task to race a Retry.

### `NoteAssetStore`

`NoteAssetStore` remains the filesystem boundary for stored audio and transcript files. The workflow receives narrow save/delete closures bound to the originating `AppStateStorageLayout`.

### `MeetingSummaryWorkflow`

Successful manual Retry continues to invalidate in-flight Meeting Summary generation only after durable replacement history has been saved. Startup Resume does not invalidate Summary state because a new `AppState` has no previous process’s in-flight Summary workflow state. Both paths preserve existing durable Summary metadata while replacing transcription fields.

## Approaches Considered

### 1. Stateful instance-owned workflow — selected

A `TranscriptionRetryWorkflow` owns active attempt tokens, tasks, Retry/Resume state, progress, execution, stale validation, persistence order, and cleanup. `AppState` supplies immutable request values and request-scoped storage collaborators, then applies typed events.

This solves the ownership and race problem while keeping initial Import and stopped-recording paths unchanged.

### 2. Stateless Retry executor — rejected

A stateless executor would move `TranscriptionService` invocation and perhaps Post-processing, but leave task ownership, `retryingItemIDs`, history reconstruction, sidecar deletion, stale checks, Summary invalidation, and pasteboard order in `AppState`.

This would reduce method size without satisfying #318’s acceptance criteria.

### 3. Whole-cloud transcription workflow — rejected

A broader owner for Import, stopped recording, Retry, and Resume would remove more duplication, but it would rewrite unrelated production paths, conflict with #192, and make the PR substantially harder to review and reverse.

## Architecture

### `TranscriptionRetryWorkflow`

Create `Sources/TranscriptionRetryWorkflow.swift` with one stateful workflow per `AppState` instance.

The workflow owns:

- per-note attempt tokens,
- active Retry/Resume tasks,
- Retry/Resume note IDs,
- Retry/Resume progress,
- service construction and invocation through injected dependencies,
- current-attempt and current-history validation,
- transcript-file creation and stale cleanup,
- history persistence,
- manual failure persistence,
- startup failure preservation,
- cloud sidecar reuse, replacement, preservation, and completion cleanup,
- and `invalidate`, `cancel`, `forget`, and `forgetAll` semantics.

The workflow does not own:

- Retry availability or provider setup UI,
- current Settings,
- general history loading and CRUD,
- global note-asset cleanup,
- warning-banner storage,
- Meeting Summary internals,
- pasteboard APIs,
- initial Import tasks,
- stopped-recording tasks,
- or history archive/recovery.

### Workflow isolation

The mutable attempt registry and state are Main Actor isolated. Provider work runs asynchronously, but every state transition and terminal validation returns to the Main Actor. Each active attempt stores its originating request-scoped runtime until completion or cancellation.

A request never retains `AppState`. Event delivery is a Main Actor closure.

### `TranscriptionRetryWorkflowState`

```swift
struct TranscriptionRetryWorkflowState: Equatable, Sendable {
    var retryingNoteIDs: Set<UUID>
    var progressByNoteID: [UUID: CloudTranscriptionDisplayProgress]

    static let initial = TranscriptionRetryWorkflowState(
        retryingNoteIDs: [],
        progressByNoteID: [:]
    )
}
```

The progress dictionary contains only Retry/Resume progress owned by this workflow. `AppState` overlays it onto the existing `cloudTranscriptionProgressByHistoryID` map without deleting progress owned by initial Import or stopped-recording tasks.

### Retry origin and delivery policy

```swift
enum TranscriptionRetryOrigin: Equatable, Sendable {
    case manual
    case startupResume
}

enum TranscriptionRetryDeliveryPolicy: Equatable, Sendable {
    case interactive
    case historyOnly
}
```

Manual Retry always uses `.interactive`. Startup Resume always uses `.historyOnly`.

### `TranscriptionRetrySourceIdentity`

```swift
struct TranscriptionRetrySourceIdentity: Equatable, Sendable {
    let noteID: UUID
    let noteTimestamp: Date
    let audioFileName: String
}
```

The workflow validates this identity against the current history item before writing. Transcript text is deliberately excluded because Retry is intended to replace it. Custom title, Meeting Summary metadata, warning state, and other unrelated fields are also excluded so concurrent unrelated metadata changes can be preserved.

### Processing behavior

The Retry workflow must not read `AppState` after request preparation, but Post-processing behavior is shared with existing paths. Represent it as a captured runtime-only behavior:

```swift
struct TranscriptionRetryProcessingBehavior {
    var process:
        @MainActor (TranscriptionResult) async
            -> TranscriptionRetryProcessingResult
}
```

`AppState` builds this behavior before starting an attempt. It captures only:

- restored `SessionIntent`,
- restored `AppContext`,
- completion policy,
- custom vocabulary and system prompt,
- a value snapshot of voice macros,
- and the originating `PostProcessingService`.

It does not capture `AppState` itself. Existing command parsing and Post-processing helpers are adjusted to accept the captured macro values explicitly rather than reading `precomputedMacros` from the live `AppState` after an asynchronous boundary.

The result contains all history-facing values the workflow needs:

```swift
struct TranscriptionRetryProcessingResult: Sendable {
    let rawTranscript: String
    let finalTranscript: String
    let prompt: String?
    let postProcessingStatus: String
    let aiProcessingOutcome: AIProcessingOutcome
    let spokenLanguage: SpokenLanguageResolution
    let disposition: TranscriptionRetryProcessingDisposition
}

enum TranscriptionRetryProcessingDisposition: Equatable, Sendable {
    case succeeded
    case fallback
}
```

`fallback` includes raw-transcript fallback and command-mode fallback. The persisted `AIProcessingOutcome` remains authoritative for the exact machine reason.

### History metadata

```swift
struct TranscriptionRetryHistoryMetadata: Sendable {
    let customVocabulary: String
    let customSystemPrompt: String
    let usedLocalTranscription: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let localTranscriptionModelID: String
    let successDebugStatus: String
}
```

Manual Retry uses `"Retried"`; startup Resume uses `"Resumed after relaunch"`.

### `TranscriptionRetryWorkflowRequest`

```swift
struct TranscriptionRetryWorkflowRequest {
    let origin: TranscriptionRetryOrigin
    let deliveryPolicy: TranscriptionRetryDeliveryPolicy
    let initialItem: PipelineHistoryItem
    let sourceIdentity: TranscriptionRetrySourceIdentity
    let audioURL: URL
    let execution: TranscriptionExecutionSnapshot
    let cloudDependencies: CloudTranscriptionDependencies
    let processing: TranscriptionRetryProcessingBehavior
    let historyMetadata: TranscriptionRetryHistoryMetadata
    let failureContext: TranscriptionRetryFailureContext
}
```

The request is fully prepared before the attempt task is created. Later changes to backend selection, credentials, context capture, Post-processing, output language, voice macros, model installation, or test dependencies cannot redirect the active attempt.

The request is Main Actor-bound and does not declare `Sendable` because it contains `PipelineHistoryItem` and Main Actor processing behavior. `start` stores and validates the request under Main Actor isolation. Provider execution receives only the captured Sendable execution snapshot, URL, cloud dependency value, and cloud context; processing resumes through the captured Main Actor behavior. No unsafe Sendable conformance or process-global transport is added.

### Startup input

Startup Resume has one batch entry point so `AppState` does not loop and orchestrate individual jobs:

```swift
struct TranscriptionRetryStartupInput {
    let reconciliation: CloudTranscriptionReconciliation
    let runtime: CloudTranscriptionExecutionSnapshot
    let history: [PipelineHistoryItem]
    let audioDirectory: URL
    let cloudDependenciesFactory:
        @Sendable () -> CloudTranscriptionDependencies
    let makeProcessingBehavior:
        @MainActor (
            PipelineHistoryItem,
            TranscriptionCompletionSnapshot
        ) -> TranscriptionRetryProcessingBehavior
}
```

The workflow filters the already validated startup reconciliation against the runtime provider identity and builds one immutable history-only request per exact-compatible resumable record. It resolves each validated record’s safe audio basename under the captured originating `audioDirectory`, then restores the record’s persisted completion policy and the item’s stored context. `AppState` constructs `makeProcessingBehavior` after initialization as a value closure that captures the originating Post-processing service and a voice-macro snapshot without retaining `AppState`; the workflow invokes that factory once per resumed item.

Add a pure `CloudTranscriptionStartupReconciler` overload that filters an existing `CloudTranscriptionReconciliation` by runtime compatibility. Startup handoff uses this overload and does not perform a second disk scan after AppState initialization when the validated base reconciliation is already available.

### Request-scoped history access

```swift
struct TranscriptionRetryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) throws -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}
```

The item lookup throws when the originating store becomes unreadable, distinguishing a persistence outage from a deleted or stale note. A missing item is stale; a throwing lookup is persistence failure.

### Request-scoped asset access

```swift
struct TranscriptionRetryAssetAccess: Sendable {
    var saveTranscript:
        @Sendable (String, String) throws -> String
    var deleteTranscript:
        @Sendable (String) throws -> Void
}
```

The closures are bound to the originating `NoteAssetStore` and therefore the originating `AppStateStorageLayout`.

### Request-scoped cloud access

```swift
struct TranscriptionRetryCloudAccess {
    let jobStore: CloudTranscriptionJobStore
    var cancelExistingExecution:
        @MainActor @Sendable (UUID) -> Void
}
```

The workflow creates and invalidates `CloudTranscriptionJobSession` values through the originating store. `cancelExistingExecution` is backed by the existing AppState-owned coordinator and captures only that coordinator and store, not `AppState`.

### Runtime bundle

```swift
struct TranscriptionRetryWorkflowRuntime {
    let history: TranscriptionRetryHistoryAccess
    let assets: TranscriptionRetryAssetAccess
    let cloud: TranscriptionRetryCloudAccess
}
```

A runtime bundle is captured per accepted manual attempt or startup batch. It is not replaceable under an active attempt. The existing history archive admission blocks while workflow state reports Retry/Resume work.

### Workflow dependencies

```swift
struct TranscriptionRetryWorkflowDependencies {
    var transcribe:
        @Sendable (
            TranscriptionExecutionSnapshot,
            URL,
            CloudTranscriptionDependencies,
            CloudTranscriptionExecutionContext?
        ) async throws -> TranscriptionResult
    var makeAttemptToken: @Sendable () -> UUID
}
```

The live transcriber creates `TranscriptionService` from the captured execution snapshot, dependencies, and optional cloud context, then calls `transcribe(fileURL:)`. Direct workflow tests replace this dependency without constructing `AppState` or mutating a process-global service factory.

### Persisted effects

```swift
struct TranscriptionRetryPersistedEffects: Equatable, Sendable {
    let advancesWarningGeneration: Bool
    let invalidatesMeetingSummary: Bool
}
```

Every successful manual replacement and persisted manual failure advances the warning generation after durable save. Startup success or fallback also advances it, preserving current behavior. Only a successful or fallback manual transcription replacement invalidates Meeting Summary generation.

### Workflow events

```swift
enum TranscriptionRetryWorkflowEvent {
    case stateChanged(TranscriptionRetryWorkflowState)
    case itemPersisted(
        PipelineHistoryItem,
        TranscriptionRetryPersistedEffects
    )
    case completed(UUID, TranscriptionRetryWorkflowOutcome)
}
```

Events are Main Actor delivered. `itemPersisted` is emitted only after the history collaborator confirms durable update. `completed` may request interactive delivery or present an existing user issue, but it never contains credentials or raw provider diagnostics.

### Typed outcome

```swift
enum TranscriptionRetryWorkflowOutcome {
    case succeeded(TranscriptionRetryCompletion)
    case fallback(TranscriptionRetryCompletion)
    case failed(TranscriptionRetryFailure)
    case cancelled
    case stale
    case persistenceFailed(QuillUserIssueRecord)
}
```

A completion records runtime-only delivery information, whether transcript-file creation succeeded, and an optional sidecar-cleanup warning. A failure records the classified issue and whether manual failure history was durably persisted. These values are not new durable schema.

## Manual Retry Data Flow

### Admission and request capture

`AppState.retryTranscription(item:)` retains the existing public admission checks:

1. persistent history mutations are available,
2. the note is not already retrying through the public adapter,
3. stored audio exists,
4. the explicitly selected backend is ready,
5. and `makeRetryWorkflowRequest(for:)` succeeds.

The request builder preserves current Manual Retry rules:

- explicit Retry choice only; no silent fallback to another backend,
- current Post-processing setting,
- current output language,
- current press-enter-command setting,
- current context-capture toggle applied to stored context,
- placeholder context treated as unavailable,
- current vocabulary/system prompt for audio-only notes,
- stored vocabulary/system prompt for normal notes,
- stored transcription language,
- captured Local or Cloud execution snapshot,
- captured Native Whisper execution,
- captured voice macros,
- captured Post-processing service,
- and captured provider/model issue context.

Preparation errors continue to surface through the existing compact user issue and do not start workflow state.

### Attempt start

The workflow:

1. cancels and invalidates an older workflow attempt for the same note,
2. cancels pre-existing cloud execution for the history ID through the narrow coordinator boundary,
3. creates a new workflow attempt token,
4. inserts the note into Retry state,
5. and prepares backend-specific cloud job access.

The public AppState guard preserves the existing duplicate-click no-op behavior. Replacement behavior remains available internally for stale-race tests and startup coordination.

### Cloud Retry context

For a cloud Retry, the workflow loads any existing sidecar and compares:

- provider ID,
- model,
- language,
- response format,
- encoded upload ceiling,
- and completion policy.

If all fields match, the attempt reuses the durable completed chunk prefix. If any field differs, the old active execution is invalidated, the old sidecar is removed through `replaceForIncompatibleRetry`, and the new attempt starts at the first chunk.

The new `CloudTranscriptionExecutionContext` publishes progress only when the workflow attempt token is still current.

### Local Retry context

A Local Retry never feeds cloud completed text into the local engine. If a cloud sidecar exists, it is retained through local failure and deleted only after local success has been durably saved to history.

The workflow still records a per-attempt session/token so cancellation, deletion, and newer attempts reject late local completion.

### Transcription and processing

The workflow invokes the captured transcriber, then the captured processing behavior. Processing performs the existing command parsing, voice macro, command mode, Post-processing, cooldown, validation, timeout, and raw-fallback rules.

The processing behavior returns history-ready values and a success/fallback disposition. No workflow code reads live AppState settings.

### Transcript file

If the current note already has a transcript file, the workflow keeps that filename. If it does not, the workflow attempts to save one through the originating asset access.

Transcript-file creation remains best-effort, matching the current `try?` behavior:

- failure does not prevent durable history replacement,
- the filename remains the current value or `nil`,
- and no new user-facing error is introduced.

If the workflow created a transcript file but later rejects or fails the history update, it attempts to delete only that newly created file.

### Current-item validation

Before history mutation, the workflow verifies:

1. the workflow attempt token still matches,
2. the originating history lookup remains readable,
3. the note still exists,
4. the note timestamp matches,
5. and the stored audio filename matches.

The current history item, not the starting item, becomes the base for replacement. This preserves unrelated fields changed while the provider request was running.

### History replacement

Add a focused history transformation instead of reconstructing every field at each call site:

```swift
struct PipelineHistoryTranscriptionReplacement {
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let postProcessingStatus: String
    let aiProcessingOutcome: String
    let debugStatus: String
    let customVocabulary: String
    let customSystemPrompt: String
    let usedLocalTranscription: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let spokenLanguage: SpokenLanguageResolution?
    let localTranscriptionModelID: String
    let transcriptFileName: String?
}

extension PipelineHistoryItem {
    func replacingTranscription(
        with replacement: PipelineHistoryTranscriptionReplacement
    ) -> PipelineHistoryItem
}
```

The helper preserves identity, timestamps, calendar metadata, selection/context metadata, custom title, Meeting Summary JSON, Meeting Summary attempt, and all fields not explicitly replaced.

### Success and fallback commit order

For successful or fallback Manual Retry:

```text
current attempt and source verified
  → transcript replacement built from current item
  → durable history update
  → itemPersisted event
      → AppState mirror update
      → warning generation increment
      → MeetingSummaryWorkflow.invalidate(noteID:)
  → completed cloud sidecar deletion when present
  → workflow state cleared
  → succeeded/fallback outcome
      → interactive pasteboard delivery
```

No Summary invalidation, sidecar deletion, or pasteboard delivery occurs before durable history success.

### Manual provider or local failure

A transcription failure is classified using only the captured provider/model/local-backend context. Wrapped `URLError` values keep the existing root-cause classification.

If the attempt and source are still current, Manual Retry builds a failure replacement from the current item:

- existing raw and processed transcript preserved,
- existing Post-processing prompt preserved,
- existing AI outcome preserved,
- existing transcript filename preserved,
- existing Summary metadata and action completion preserved,
- versioned failure issue persisted in `postProcessingStatus`,
- selected Retry backend metadata recorded,
- debug status set to `"Retry failed"`.

After durable failure save, the workflow emits an item event that advances warning generation but does not invalidate Summary generation. Cloud sidecar/checkpoint state remains available for the next explicit Retry.

## Startup Resume Data Flow

### Startup ordering

`AppState.init` retains this safety order:

1. recording journal recovery,
2. persistent history load and trim,
3. invalidated trimmed cloud sessions and asset cleanup,
4. interrupted history normalization,
5. stale cloud temporary artifact cleanup,
6. base cloud sidecar reconciliation against surviving history and permanent audio,
7. orphan sweep scheduling,
8. remaining AppState initialization,
9. deferred startup Resume handoff to the workflow.

Recording startup recovery remains network-free.

### Compatibility filtering

Startup Resume proceeds only when a runtime cloud snapshot can be created with a non-empty API key. Exact compatibility requires:

- provider ID,
- model,
- language,
- response format,
- current chunk-plan algorithm version,
- and encoded upload ceiling.

Only `.transcribing` and `.interrupted` jobs from the validated base reconciliation are candidates. Prepared, failed, assembled, terminal, incompatible, keyless, and invalid jobs remain waiting for explicit Retry or cleanup under existing semantics.

### Request construction

For each exact-compatible job, the workflow builds a cloud-only request using:

- the record’s persisted completion policy,
- the current surviving history item,
- stored intent and selection,
- stored context without applying the current context-capture toggle,
- stored vocabulary and system prompt,
- stored transcription language metadata,
- captured startup voice macros,
- the startup Post-processing service,
- a fresh instance-owned cloud dependency value,
- `"Resumed after relaunch"` debug status,
- and `.historyOnly` delivery.

Current Settings do not replace the persisted completion policy.

### Startup completion

Startup success or fallback uses the same current-item validation, focused history replacement, durable save, warning-generation event, and sidecar deletion ordering as Manual Retry.

Intentional differences remain:

- no Meeting Summary invalidation event,
- no pasteboard delivery,
- and no interactive UI action.

### Startup failure

Provider failure or cancellation during startup Resume:

- does not write a failed replacement history row,
- does not advance warning generation,
- does not invalidate Summary,
- does not perform pasteboard delivery,
- retains the history placeholder,
- retains the sidecar and completed chunk prefix,
- and clears only active workflow state and progress.

This preserves manual recovery after an unsuccessful automatic Resume.

## Error and Outcome Rules

### Success

A success outcome means durable history replacement succeeded. If a cloud sidecar existed, its deletion has been attempted after history save. Interactive delivery is requested only for Manual Retry.

### Fallback

A fallback outcome means transcription succeeded but processing selected a safe fallback, including timeout, rejected output, Post-processing failure, or command-mode fallback. The final fallback text, versioned issue where applicable, and existing `AIProcessingOutcome` encoding are preserved.

Fallback is still a durable transcription replacement, so Manual Retry invalidates in-flight Summary generation and may deliver to the pasteboard.

### Transcription failure

Manual failure is persisted as described above. Startup failure preserves the placeholder and sidecar. Both use captured issue context rather than live Settings.

### Cancellation

Cancellation invalidates the workflow attempt token and any active cloud job session. Late provider, checkpoint, processing, asset, and history callbacks are rejected. Existing durable sidecar state is retained unless an external successful note deletion/clear removes it.

### Stale completion

A stale outcome writes no history, emits no item event, invalidates no Summary, performs no pasteboard delivery, and deletes only a transcript file created by that stale attempt.

### History lookup failure

An unreadable originating store is `persistenceFailed`, not stale. The existing history-persistence user issue is emitted. No sidecar is deleted and no durable-success event is emitted.

### History save failure

A history save failure:

- leaves the current mirror unchanged,
- leaves warning generation unchanged,
- does not invalidate Summary,
- does not delete the cloud sidecar,
- does not request pasteboard delivery,
- attempts to delete a newly created transcript file,
- and returns `persistenceFailed` with the existing structured issue.

### Transcript-file creation failure

Transcript-file creation is best-effort and does not fail the history replacement. The terminal completion records whether the transcript asset was persisted for direct tests, but AppState presents no new error.

### Transcript-file cleanup failure

Cleanup remains best-effort. It does not convert a stale or persistence outcome into a durable success and does not overwrite the primary user issue.

### Sidecar deletion failure

If durable history succeeded but completed sidecar deletion fails:

- the history success remains committed,
- mirror, warning generation, and Manual Summary invalidation remain applied,
- the workflow emits the existing `Unable to finish cloud transcription` warning,
- the sidecar may remain for later reconciliation,
- and the terminal success/fallback records the cleanup warning.

A cleanup failure never rolls history back.

## Invalidation and External Mutation Semantics

### `invalidate(noteID:)`

- increments or replaces the note attempt token,
- cancels active Retry/Resume work for the note,
- invalidates its cloud session,
- removes Retry/Resume progress,
- and keeps note-scoped revision state.

Called after a successful durable manual transcript edit or another successful external transcription replacement.

### `cancel(noteID:)`

- cancels active work before destructive history mutation,
- invalidates the active cloud session,
- removes Retry/Resume state and progress,
- and keeps enough revision state to reject late callbacks.

Called from note-delete and history-clear pre-deletion cleanup. If the durable mutation later fails, the old attempt remains cancelled, matching the existing pre-delete cloud cancellation safety boundary.

### `forget(noteID:)`

- performs cancellation if needed,
- removes note-scoped revision and active state entirely.

Called after successful durable note deletion and for history items removed by successful trim.

### `forgetAll()`

- cancels every active Retry/Resume task,
- invalidates every retained attempt session,
- clears revision, Retry state, and progress.

Called after successful durable history clear or verified fresh archive runtime replacement.

### Newer Retry

The public AppState API continues to ignore duplicate Retry clicks while the note is active. Internally, starting a replacement attempt invalidates the prior token and session so direct tests can prove late completion cannot overwrite a newer attempt.

## AppState Responsibilities After Extraction

`AppState` retains:

- `noteBrowserStoredAudioURL(for:)`,
- `noteBrowserRetryAvailability(for:)`,
- Retry option construction and selected-backend readiness,
- current Settings and credential access,
- `retryTranscription(item:)` public API,
- immutable manual request construction,
- startup input construction after initialization,
- `retryingItemIDs` compatibility mirror,
- shared cloud progress map for initial and Retry/Resume flows,
- warning-generation side storage,
- Meeting Summary workflow ownership,
- pasteboard APIs,
- user-facing compact error presentation,
- history delete/clear/trim/archive routes,
- and initial Import and stopped-recording orchestration.

`AppState` no longer owns:

- `RetrySnapshot`,
- manual Retry task body,
- startup Resume loop and task body,
- Retry/Resume active attempt tokens,
- Retry/Resume progress validation,
- Retry/Resume history reconstruction,
- Retry/Resume current-item validation,
- Retry/Resume sidecar compatibility and completion cleanup,
- Retry/Resume failure persistence policy,
- or Retry/Resume terminal cleanup.

### AppState event adapter

On `stateChanged`, AppState:

- mirrors `retryingNoteIDs` into `retryingItemIDs`,
- removes only progress previously owned by the workflow,
- overlays current workflow progress without disturbing initial Import or stopped-recording progress,
- and keeps archive admission and transcription-settings locking behavior unchanged.

On `itemPersisted`, AppState:

- replaces the matching item in `pipelineHistory` if it still exists,
- increments warning generation when requested,
- and calls `meetingSummaryWorkflow.invalidate(noteID:)` only when requested.

On terminal completion, AppState:

- copies a non-empty interactive transcript to `lastTranscript` and the pasteboard,
- presents persistence or sidecar-cleanup issues using existing localized copy,
- and performs no action for history-only success, cancellation, or stale completion.

## Runtime Replacement and Archive Coordination

History archive admission continues to reject while Retry/Resume state is active. The workflow’s `retryingNoteIDs` mirror supplies `hasRetryWork`; initial cloud tasks continue to supply `hasCloudHistoryWork` through `CloudTranscriptionHistoryCoordinator`.

A fresh archive runtime replacement installs a new history store, recording journal store, and cloud job store in AppState only after active work is quiescent. AppState then calls `transcriptionRetryWorkflow.forgetAll()` before accepting new Retry requests. No active attempt is rebound to the new store.

Recovered history runtime replacement also occurs only while active Retry/Resume work is absent. Subsequent requests capture the recovered current store.

## Test Strategy

### New direct workflow suite

Create `Tests/TranscriptionRetryWorkflowTests.swift`. It constructs workflow requests and storage collaborators directly without creating `AppState`.

Cover:

- independent workflow instances and transcriber dependencies,
- immutable execution, cloud dependency, processing, and issue context capture,
- manual cloud success,
- same-cloud checkpoint-prefix reuse,
- incompatible provider/model/language/format/upload-ceiling/completion-policy restart,
- local Retry ignoring cloud transcript prefixes,
- local failure preserving a prior cloud sidecar,
- local success deleting a prior cloud sidecar only after durable history save,
- progress publication and stale progress rejection,
- success event ordering,
- raw fallback and timeout fallback,
- command fallback,
- versioned manual failure persistence,
- existing raw/final transcript and AI outcome preservation on failure,
- current custom title and Summary metadata preservation,
- startup exact compatibility filtering,
- startup persisted completion policy,
- startup stored context,
- startup history-only completion,
- startup provider failure preserving placeholder and sidecar,
- startup cancellation preserving sidecar,
- missing current history item,
- unreadable history lookup,
- stale source identity,
- transcript edit invalidation,
- newer attempt rejection of older success and older failure,
- note cancel, forget, and forget-all,
- transcript-file creation failure as best-effort success,
- newly created transcript cleanup after stale or history-save failure,
- history save failure preserving sidecar and suppressing events,
- sidecar deletion failure preserving durable success,
- warning-generation event after persistence,
- Manual Summary invalidation after persistence,
- no Summary invalidation on manual provider failure,
- no Summary invalidation on startup completion,
- interactive delivery only after durable Manual completion,
- and no credential value in state, events, durable records, or diagnostics.

Use deterministic transcriber closures, controlled continuations, in-memory history closures, temporary `NoteAssetStore` layouts, real `CloudTranscriptionJobStore` fixtures where session semantics matter, and an injectable attempt-token factory.

### AppState integration suite

Retain AppState behavior tests for:

- public Retry availability and explicit backend choice,
- protected/non-durable history admission,
- current context toggle and placeholder-context handling,
- audio-only current vocabulary and system prompt,
- current completion policy for Manual Retry,
- persisted completion policy for startup Resume,
- Native Whisper snapshot capture,
- originating instance cloud dependency ownership,
- workflow Retry-state mirror,
- workflow progress overlay,
- durable item mirror update,
- warning-generation advancement,
- successful Manual Summary invalidation,
- failed or missing durable mutation not applying Summary invalidation,
- pasteboard adapter,
- startup deferred scheduling,
- delete, clear, transcript edit, trim, and archive workflow invalidation routes,
- and history reload compatibility.

Workflow-internal success/failure/cleanup tests migrate to the direct suite instead of remaining duplicated in `MeetingSummaryAppStateTests` or `AppStateTranscriptionConfigurationTests`.

### Source-shape test migration

Existing source-shape suites mix Retry/Resume ownership assertions with still-relevant initial Import and stopped-recording contracts.

Update them proportionately:

- `AppStateCloudTranscriptionIntegrationSourceTests` keeps Import, recording, and public adapter contracts; remove Retry/Resume implementation-block assertions after direct behavior coverage exists.
- `AppStateCloudTranscriptionCleanupSourceTests` keeps initial Import/recording installation and common asset cleanup contracts; replace Retry task/session source assertions with workflow behavior tests.
- `AppStateUserIssueLifecycleSourceTests` keeps unrelated issue lifecycle contracts; replace Retry/Resume ordering strings with behavior tests.
- `QuillUserIssueUIContractTests` keeps public user-issue and UI routing contracts; do not pin the workflow implementation source.
- `UpstreamMergeBehaviorTests` keeps a public behavior contract that Retry success reaches the existing pasteboard adapter, but removes any requirement for a specific internal function body.
- `MeetingSummaryAppStateTests` keeps the successful public Retry-to-Summary invalidation adapter test; workflow stale/race internals move to the direct suite.

Do not add new exact source-string assertions for workflow internals.

### Existing low-level suites

Keep these authoritative and unchanged except for wiring or narrowly required API adjustments:

- `TranscriptionExecutionSnapshot` tests for immutable service configuration,
- `CloudTranscriptionCoreTests` for chunking and provider behavior,
- `CloudTranscriptionJobStoreTests` for durable sidecars and sessions,
- `CloudTranscriptionHistoryLifecycleTests` for checkpoint-prefix and relaunch semantics,
- `CloudTranscriptionHistoryCoordinatorTests` for initial shared cloud task coordination,
- `NoteAssetStoreTests` for storage paths and filesystem errors,
- Post-processing and user-issue tests for fallback classification,
- and Meeting Summary workflow tests for Summary revision semantics.

## Test Wiring and Verification

Add the direct workflow suite to the grouped full-source AppState runner and the matching Makefile source list.

Verification order:

1. focused `TranscriptionRetryWorkflowTests`,
2. focused AppState Retry/Resume and Meeting Summary adapter tests,
3. cloud history lifecycle/coordinator tests,
4. affected source-contract tests,
5. `make check-test-wiring`,
6. `make test`,
7. production build with `CODESIGN_IDENTITY=Quill`,
8. `codesign --verify --deep --strict`,
9. and `/code-review medium` exactly once after the entire tree is green.

If the one local review finds a confirmed defect, fix it with regression coverage and repeat the focused/full/build verification. Do not run `/code-review` a second time.

After local verification:

- push only to `woosublee/quill`,
- create a PR that closes #318,
- verify CI and CodeRabbit,
- technically validate review feedback before applying it,
- mention the reviewer when declining a suggestion,
- choose the merge strategy appropriate to the PR,
- update #321 after merge,
- inventory worktree and local/remote branches,
- and obtain explicit approval before deleting the worktree or branches.

## Files

### Create

- `Sources/TranscriptionRetryWorkflow.swift`
- `Tests/TranscriptionRetryWorkflowTests.swift`
- `docs/superpowers/specs/2026-08-15-transcription-retry-resume-workflow-design.md`

### Modify

- `Sources/AppState.swift`
- `Sources/AppStateDependencies.swift`
- `Sources/PipelineHistoryItem.swift`
- `Sources/CloudTranscriptionHistoryCoordinator.swift`
- `Tests/AppStateTranscriptionConfigurationTests.swift`
- `Tests/MeetingSummaryAppStateTests.swift`
- `Tests/AppStateCloudTranscriptionIntegrationSourceTests.swift`
- `Tests/AppStateCloudTranscriptionCleanupSourceTests.swift`
- `Tests/AppStateUserIssueLifecycleSourceTests.swift`
- `Tests/QuillUserIssueUIContractTests.swift` only for ownership-specific assertions
- `Tests/UpstreamMergeBehaviorTests.swift` only for ownership-specific assertions
- `Tests/FullSourceAppStateTestRunner.swift`
- `Makefile`

Other files change only when a direct behavior replacement makes an existing Retry/Resume ownership assertion obsolete.

## Safety Rules

- API keys remain runtime-only.
- No credential appears in workflow state, event descriptions, persisted jobs, history metadata, logs, or diagnostics.
- Active attempts use only captured execution and processing input.
- The originating storage layout, history store, note-asset boundary, cloud job store, and dependency values remain fixed for the attempt.
- A deleted or replaced note cannot be recreated by late completion.
- A stale attempt cannot update history, delete a newer sidecar, invalidate a newer Summary generation, or write to the pasteboard.
- Partial cloud chunk text remains outside history until full transcription completion.
- A cloud sidecar is deleted only after durable history replacement.
- History failure preserves the sidecar.
- Manual failure preserves existing transcript, AI outcome, Summary metadata, and action completion.
- Startup failure preserves the placeholder and sidecar.
- Transcript-file creation remains best-effort.
- No process-global Retry workflow or transcriber replacement seam is introduced.
- Initial Import and stopped-recording behavior remains unchanged.

## Non-Goals

- No provider or model behavior change.
- No new retry, timeout, chunking, fallback, or Post-processing policy.
- No durable schema migration.
- No recording recovery redesign.
- No audio Import workflow extraction.
- No stopped-recording workflow extraction.
- No Realtime transcription redesign.
- No UI or localized copy redesign.
- No general transcription service locator.
- No broad domain store from #192.
- No source-file split solely to reduce line count.

## Acceptance Criteria

- Manual Retry and startup Resume have one focused owner outside `AppState.swift`.
- The workflow is independently testable without constructing `AppState` or replacing process-global dependencies.
- Manual and startup attempts use immutable execution, completion, context, dependency, and storage input.
- Initial Import and stopped-recording orchestration remain in `AppState`.
- Same-cloud Retry and exact-compatible startup Resume reuse the existing checkpoint prefix.
- Incompatible Retry starts from the first chunk without an old callback corrupting the new job.
- Local Retry never consumes cloud partial text and deletes a prior sidecar only after durable local success.
- Manual success/fallback, manual failure, startup success/fallback, startup failure, cancellation, stale revision, missing history, unreadable history, transcript-file failure, history failure, and sidecar-cleanup failure are behavior-tested.
- Durable history update precedes warning-generation changes, Summary invalidation, sidecar deletion, and pasteboard delivery.
- Manual success invalidates in-flight Summary generation; manual failure and startup Resume do not.
- Existing history metadata, raw fallback, AI outcome, spoken language, audio-only behavior, user issues, and durable schemas remain compatible.
- Deleted or replaced notes are not resurrected by late completion.
- Workflow-internal Retry/Resume source-shape assertions have direct behavioral replacements.
- `make check-test-wiring`, `make test`, signed production build, strict code-sign verification, and one `/code-review medium` pass succeed.
