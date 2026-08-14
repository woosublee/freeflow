# History Archive and Recovery Workflow Design

## Summary

Issue #317 extracts Quill's history archive and recovery orchestration from `AppState.swift` into a focused `HistoryArchiveRecoveryWorkflow`.

The low-level storage boundaries already exist:

- `PipelineHistoryStore` owns active Core Data persistence,
- `HistoryArchiveTransition` owns crash-safe archive publication and rollback,
- `HistoryRecoveryService` owns snapshot cataloging, inspection, import, retention, and deletion,
- `NoteAssetStore` owns active audio and transcript files.

The remaining problem is orchestration. `AppState` currently owns startup rollback and safety inspection, recovery catalog state, inspection queues and revisions, detached archive/import/snapshot tasks, active-store verification and replacement, reentrancy guards, persistence-warning derivation, and completion ordering. This design moves that state machine outside `AppState` without changing file formats, user-visible behavior, or ordinary history CRUD ownership.

## Current State

`AppState` currently coordinates three connected phases.

### Startup

During initialization it:

1. prepares the storage directories,
2. rolls back interrupted archive transactions,
3. conditionally removes expired completed snapshots,
4. inspects archive safety,
5. constructs the active `PipelineHistoryStore`,
6. derives history availability and persistence warnings,
7. branches between normal and unresolved-archive startup,
8. and initializes the recovery snapshot catalog.

The later startup work for recording-journal recovery, history loading, asset-reference validation, orphan sweeping, title migration, and cloud reconciliation is already backed by focused collaborators, but its admission still depends on history safety decisions made inline in `AppState.init`.

### Archive and runtime replacement

`archiveOldHistoryAndStartFresh` checks workflow state plus a long list of unrelated active-work guards, detaches the current store, starts a detached archive transition, verifies the new store, replaces active runtime stores, clears generation-specific UI state, refreshes recovery state, and optionally opens recovery Settings.

### Recovery

`AppState` stores nine pieces of recovery orchestration state directly:

- snapshot catalog,
- inspection results,
- current inspection ID,
- inspection queue,
- attempted inspection IDs,
- inspection revision,
- recovery-operation activity,
- operation message,
- and partial import result.

It also starts and completes detached inspection, import, retention-cancellation, and snapshot-deletion operations. These paths repeatedly reconstruct `HistoryRecoveryService`, re-inspect archive safety, refresh the catalog, synchronize persistence state, and resume inspection scheduling.

The low-level types are independently tested, and `AppStateStorageSafetyTests` covers end-to-end safety. The extraction can therefore preserve behavior by moving orchestration rather than redesigning persistence.

## Approaches Considered

### 1. Stateful workflow with typed state and events — recommended

A dedicated workflow owns archive/recovery state, admission decisions, detached task sequencing, revision checks, and verified runtime replacement. It emits complete state snapshots and typed events for `AppState` to publish or apply.

This satisfies the issue's ownership goal while retaining the existing public `AppState` API and normal history CRUD path.

### 2. Stateless disk-operation worker

A worker would perform archive, inspection, import, and snapshot operations, but `AppState` would retain the queue, revisions, activity flags, admission guards, and completion ordering.

This reduces a few detached closures but leaves the central orchestration problem in `AppState`, so it is rejected.

### 3. Move all history persistence behind the workflow

The workflow would own the active store and every history CRUD operation.

This creates a stronger domain boundary but overlaps the broader AppState-store roadmap in #192 and greatly expands the migration surface. It is rejected for #317.

## Architecture

### `HistoryArchiveRecoveryWorkflow`

Create `Sources/HistoryArchiveRecoveryWorkflow.swift` containing the workflow and its focused value types.

The workflow is initialized with instance-owned values captured from the originating `AppStateDependencies`:

```swift
HistoryArchiveRecoveryWorkflow(
    storageLayout: dependencies.storageLayout,
    makeHistoryStore: dependencies.makePipelineHistoryStore
)
```

Its instance-owned `HistoryArchiveRecoveryWorkflowDependencies` bundle supplies closure-based archive, recovery, catalog, retention, and store collaborators. Production defaults delegate those closures to the existing `HistoryArchiveTransition` and `HistoryRecoveryService` concrete types, while workflow tests inject deterministic closures without adding process-global seams.

The workflow owns:

- archive safety,
- archive-transition activity,
- recovery-operation activity,
- recovery snapshot catalog,
- recovery inspection results,
- inspection queue and attempted IDs,
- inspection revision and current inspection ID,
- partial recovery import results,
- and derivation of history mutation availability and persistence warning state.

The workflow does not own ordinary history CRUD. `AppState` continues to use its current `PipelineHistoryStore` for recording, editing, retry, Meeting Summary, delete, and clear operations.

### `HistoryWorkflowState`

`HistoryWorkflowState` is the complete workflow snapshot delivered to `AppState`. It contains:

- `archiveSafety: HistoryArchiveSafety`,
- archive transition activity,
- recovery operation activity,
- `snapshots: [HistoryRecoverySnapshotDescriptor]`,
- `inspections: [UUID: HistoryRecoveryInspection]`,
- `inspectionSnapshotID: UUID?`,
- `importResult: HistoryRecoveryImportResult?`,
- history availability,
- and persistence-warning visibility.

Inspection scheduling remains a separate internal lane from mutating recovery operations. This preserves the current concurrency contract: snapshot deletion and retention cancellation wait for inspection to finish, while import admission is not silently changed to add a new inspection guard.

`AppState` keeps its existing `@Published` properties for source compatibility. A single adapter method applies each complete workflow state snapshot; no other `AppState` path writes those workflow-owned fields.

### `HistoryWorkflowAdmissionContext`

`AppState` supplies current non-history activity as an immutable value:

```swift
struct HistoryWorkflowAdmissionContext: Sendable {
    let isRecording: Bool
    let isTranscribing: Bool
    let hasRetryWork: Bool
    let hasActiveTranscriptionJobs: Bool
    let hasPendingAudioImports: Bool
    let hasCloudHistoryWork: Bool
    let hasMeetingSummaryWork: Bool
    let hasActiveRecordingJournal: Bool
    let hasPendingRecordingFinalization: Bool
    let hasPendingRecordingStart: Bool
    let hasPendingAudioOnlyStops: Bool
}
```

The workflow combines this value with its own state and snapshot catalog to accept or reject archive, import, retention-cancellation, and snapshot-deletion commands.

Typed rejection reasons replace the long inline guard branches. `AppState` maps them onto the same current user messages.

### `HistoryStartupResult`

Startup preparation remains synchronous because `AppState.init` is synchronous and these operations already run synchronously today.

The workflow performs:

1. interrupted transaction rollback,
2. best-effort expired completed snapshot cleanup when rollback is not unresolved,
3. archive safety inspection,
4. active-store construction and readability verification,
5. recovery catalog loading,
6. and initial availability/warning derivation.

It returns:

- the originating active store,
- initial `HistoryWorkflowState`,
- whether normal history startup work is permitted,
- and whether unresolved-archive startup work is permitted.

`AppState` uses those decisions to run the existing recording-journal recovery, history load, asset-reference validation, orphan sweep, migration, and cloud reconciliation code. Those already-focused paths do not move in #317.

### `HistoryWorkflowEvent`

The workflow emits typed Main Actor events:

```swift
enum HistoryWorkflowEvent {
    case stateChanged(HistoryWorkflowState)
    case installRuntime(HistoryRuntimeReplacement)
    case failed(HistoryWorkflowFailure)
    case performPostAction(HistoryArchivePostAction)
}
```

`AppState` installs the event handler after its stored properties have been initialized. Detached work captures only immutable workflow dependencies and input values. Completion returns to the Main Actor before state or runtime events are emitted.

### `HistoryRuntimeReplacement`

Only a verified store may become active.

Runtime replacement has two forms:

- a fresh archive generation, containing the verified active history store plus newly constructed `RecordingJournalStore` and `CloudTranscriptionJobStore`,
- a recovery import result, containing the verified reopened active history store and reloaded history.

The fresh-generation replacement also ensures active root, audio, transcript, and cloud-job directories are recreated before the workflow reports history as available.

`AppState` applies the replacement synchronously when it receives the event. It then clears only generation-specific UI/runtime collections that it already clears today: pipeline history, retry and import IDs, cloud progress, Meeting Summary generation/reveal state, and warning-banner state.

Event ordering is fixed:

1. prepare and verify the replacement,
2. emit `installRuntime`,
3. update and emit idle workflow state,
4. emit an optional post-action.

This prevents the UI from observing available history before the verified replacement has been installed.

## Data Flow

### Startup

```text
AppStateDependencies
  → HistoryArchiveRecoveryWorkflow.prepareStartup()
      → rollback interrupted archive transactions
      → retain snapshots on ambiguous rollback failure
      → remove only expired completed snapshots when safe
      → inspect archive safety
      → construct and verify originating active store
      → list recovery snapshots
      → return HistoryStartupResult
  → AppState runs existing allowed startup history/asset/cloud work
  → AppState initializes published workflow mirrors
```

An unresolved interrupted transaction prevents normal history loading and mutation even when the SQLite file itself opens successfully. A published unresolved archive may still use the verified fresh active store, but automatic archive cleanup remains suppressed as it is today.

### Archive

```text
AppState activity snapshot + current store + post-action
  → workflow admission
  → detach current store
  → publish archiving state
  → detached HistoryArchiveTransition
  → reopen and verify fresh store
  → construct fresh runtime replacement
  → Main Actor installRuntime event
  → idle state event
  → optional open-recovery post-action event
```

The workflow always uses the store factory captured from the originating `AppState`. Later mutation of a test dependency value cannot redirect an active transition.

### Inspection

```text
catalog refresh
  → queue ready snapshots not already attempted
  → capture snapshot ID + active history + inspection revision
  → detached HistoryRecoveryService.inspectSnapshot
  → Main Actor completion
  → ignore stale revision results
  → refresh catalog and schedule next inspection
```

Invalidation increments the revision and clears results, queue, and attempted IDs before any conditional rescheduling. Retry moves one eligible snapshot to the front without allowing duplicate concurrent inspection.

### Recovery import

```text
AppState activity snapshot + snapshot ID + current store
  → workflow admission
  → clear prior import feedback
  → detach current store
  → publish importing state
  → detached active-store verification
  → HistoryRecoveryService.importSnapshot
  → detach and reopen active store
  → verify reopened store and reload history
  → Main Actor installRuntime event
  → publish partial result only for conflicts/failures
  → invalidate and reschedule inspection
```

A missing or changed history row cannot be resurrected by workflow state: import behavior remains delegated to `HistoryRecoveryService`, which preserves UUID conflict and logical-equivalence rules.

### Snapshot operations

Retention cancellation and explicit snapshot deletion run through one typed snapshot-operation path. They do not detach, replace, or reload the active store. Success and failure both refresh archive safety and the catalog; failure preserves the active store and emits the existing snapshot-operation error through `AppState`.

## Admission and Mutation Guards

Archive admission preserves all current blockers:

- history must already require recovery,
- archive safety must be normal or a published unresolved archive,
- no archive or mutating recovery operation may already be active,
- no recording or transcription may be active,
- no retry, transcription job, audio import, cloud history work, or Meeting Summary generation may be active,
- no active recording journal may exist,
- and no recording finalization, recording start, or audio-only stop may be pending.

Recovery import uses the same active-work blockers but requires available durable history and an eligible ready snapshot.

Ordinary history mutations ask the workflow for mutation availability. Archive transition and mutating recovery activity retain their distinct existing messages; unavailable history retains `historyUnavailableMessage`.

Snapshot deletion and retention cancellation continue to require no mutating recovery operation and no current inspection. The extraction does not add new guards that change existing behavior.

## Error Handling and Safety

### Typed failures

`HistoryWorkflowFailure` distinguishes:

- history unavailable,
- archive transition failure,
- fresh-store verification failure,
- recovery inspection failure,
- recovery import failure,
- active-store reopen failure,
- and snapshot operation failure.

Command admission failures remain separate in `HistoryWorkflowRejection`, including `archiveTransitionInProgress`, `recoveryOperationInProgress`, and `applicationBusy`.

Failures and rejections carry no API key, transcript content, note content, absolute user path, or durable secret. `AppState` maps each category to the same existing localized user message.

### Store replacement

- A new store is never exposed before availability, durability, and readability verification succeed.
- Recovery failure installs a reopened store only when that store independently passes the same verification.
- Snapshot-only failures never replace the active store.
- Archive rollback ambiguity remains protected as `unresolvedInterruptedTransaction`.

### Data preservation

- Existing archive and recovery schemas remain unchanged.
- The seven-day completed-snapshot retention policy remains unchanged.
- Original stores, snapshots, and assets are never deleted on ambiguous failure.
- Asset copying and conflict handling remain in `HistoryRecoveryService`.
- Note-asset cleanup remains in `NoteAssetStore` and is not redesigned.

### Concurrency

- Workflow dependencies and command inputs are copied before detached work begins.
- Every completion returns to the Main Actor.
- Activity state blocks duplicate mutating operations.
- Inspection revision tokens discard stale completion.
- Weak event delivery prevents a detached task from retaining a discarded `AppState` through its adapter.

## AppState Integration

`AppState` gains one instance-owned workflow property. It continues to expose the existing public and `@Published` API used by views and tests.

The following responsibilities leave `AppState`:

- startup rollback, retention, safety inspection, and initial history-state derivation,
- archive/recovery admission decisions,
- inspection queue and revision management,
- detached archive, inspection, import, and snapshot operations,
- active-store verification and runtime replacement preparation,
- recovery catalog refresh sequencing,
- and persistence-state derivation.

The following remain in `AppState`:

- UI-facing command methods with their existing signatures,
- published state mirrors,
- current unrelated activity snapshot construction,
- applying runtime replacement to AppState-owned fields,
- generation-specific UI collection resets,
- user-message and Settings-navigation mapping,
- ordinary history CRUD,
- recording-journal recovery and note-asset/cloud startup work,
- and all non-history workflows.

No process-global workflow factory, mutable current workflow, or static dependency override is introduced.

## Testing Strategy

### New workflow tests

Create `Tests/HistoryArchiveRecoveryWorkflowTests.swift` with direct workflow coverage that does not construct the full UI-facing `AppState`.

#### Startup

- normal durable store,
- unavailable store,
- interrupted transaction rollback,
- unresolved interrupted transaction protection,
- published unresolved archive handling,
- safe retention cleanup,
- and retention failure preservation.

#### Archive

- table-driven coverage for every admission blocker,
- duplicate/reentrant command rejection,
- originating store-factory capture,
- successful verified replacement,
- fresh-store verification failure,
- archive transition failure,
- and post-action ordering after runtime installation.

#### Inspection

- ready-snapshot queue ordering,
- retry prioritization,
- duplicate prevention,
- revision invalidation before rescheduling,
- stale completion rejection,
- unreadable inspection failure,
- and continuation to the next snapshot.

#### Recovery import

- success,
- partial/conflict result publication,
- missing or invalid snapshot,
- duplicate/reentrant rejection,
- reopened active-store verification failure,
- active-store restoration after operation failure,
- and snapshot-only failure isolation.

#### Snapshot management

- retention-cancellation success and failure,
- explicit deletion success and failure,
- catalog refresh,
- and inspection resumption.

### Existing low-level tests

`HistoryArchiveTransitionTests` and `HistoryRecoveryServiceTests` remain the authoritative tests for archive durability, rollback, manifest validation, recovery state, asset copying, conflict handling, and retention. The workflow tests do not duplicate their low-level byte and filesystem assertions.

### AppState adapter tests

Keep narrow end-to-end coverage in `AppStateStorageSafetyTests` for:

- workflow state mirrored into existing published properties,
- explicit archive creating a fresh separated history,
- archived note import into fresh history,
- verified replacement applied before availability,
- archive completion allowing immediate asset saves,
- recovery operation blocking ordinary mutation,
- snapshot-only failure preserving the active store,
- existing user messages,
- and recovery Settings post-action.

### Source-test reduction

Move the remaining archive guard, inspection invalidation ordering, and import-result clearing assertions from `AppStateHistoryProtectionSourceTests` into workflow behavior tests. Retain only the defense-in-depth source checks whose races or system-call failures cannot be triggered deterministically through the public boundary.

### Required verification

```bash
make --no-print-directory _test-transcription
make check-test-wiring
make test
make all BUILD_DIR=/tmp/quill-issue317-build CODESIGN_IDENTITY=Quill
codesign --verify --deep --strict /tmp/quill-issue317-build/Quill.app
```

The local `/code-review` runs exactly once at medium effort after focused tests, full tests, and the production build are green.

## Migration Order

1. Add workflow state, admission, failure, startup-result, event, and runtime-replacement value types with direct failing tests.
2. Implement startup preparation and migrate `AppState.init` safety/store decisions.
3. Implement workflow archive admission, detached transition, verified replacement, and post-action ordering.
4. Add the AppState event adapter and migrate archive completion/runtime reset.
5. Move recovery catalog and inspection scheduling into the workflow.
6. Move import and snapshot operations into the workflow.
7. Replace obsolete source assertions with behavior coverage.
8. Run focused, full, build, signing, and one-time review verification.

Each migration stage keeps existing behavior green and lands as an independently reviewable commit.

## Non-goals

- No Core Data schema change.
- No archive or recovery manifest/state schema change.
- No snapshot retention-policy change.
- No note-asset storage redesign.
- No cloud transcription, retry, or Meeting Summary workflow extraction.
- No ordinary history CRUD extraction.
- No recovery UI or user-copy redesign.
- No general AppState file split.
- No change to #192's broader domain-store roadmap.

## Acceptance Criteria

- `HistoryArchiveRecoveryWorkflow` is the single owner of archive/recovery orchestration state outside `AppState.swift`.
- Startup rollback, retention, archive safety, active-store verification, and initial workflow-state derivation use the workflow.
- Detached archive, inspection, import, and snapshot operations capture immutable originating dependencies.
- AppState does not directly schedule or complete history archive/recovery disk transitions.
- Only verified active stores are installed.
- Snapshot-only failures never replace active history.
- All current recording/transcription/retry/import/cloud/summary/journal guards remain behavior-tested.
- Existing published properties, user messages, Settings navigation, schemas, retention, and stored data remain compatible.
- Source-shape assertions replaced by the workflow are removed.
- No process-global dependency seam is introduced.
- Focused tests, full tests, and the signed production build pass.
