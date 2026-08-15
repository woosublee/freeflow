# Local AI / Native Whisper Model Management Workflow Extraction — Design

## Context

This is issue **#320** in the internal-refactoring roadmap (#321): "split AppState by the stabilized internal boundaries." #320's own issue body explicitly disclaims being the broader AppState domain-store split tracked by **#192** (still blocked by #217) — it is scoped to finishing the relocation of internals for boundaries the refactoring track has already stabilized: history archive/recovery (#317), transcription retry/resume (#318), meeting summary generation (#319), note assets (#314/#324), credentials (#315), and Local AI/model management (#316).

Research into the current codebase (main @ `822d720`, `Sources/AppState.swift` at 12,000 lines) found that five of those six boundaries are already clean thin adapters — `HistoryArchiveRecoveryWorkflow`, `TranscriptionRetryWorkflow`, `MeetingSummaryWorkflow` are each in dedicated files and AppState only holds event-adaptation code and `@Published` mirrors for them; `NoteAssetStore` and `CredentialStore` are computed properties wrapping dedicated files. There is no leftover work there.

**Local AI/model management is the one exception.** #316 ("move Local AI and model installer dependencies to AppState instances") made the raw dependency closures instance-owned (`AppStateLocalAIDependencies`, `AppStateNativeWhisperDependencies` in `Sources/AppStateDependencies.swift`) but did not extract a workflow type. All of the stateful orchestration — per-model install tokens, cancellation, deletion, progress coalescing, status-refresh generations — is still written directly inside `AppState.swift`. This spec scopes #320 down to exactly that: extracting this orchestration into two dedicated workflow files, following the same instance-owned, event-driven pattern already established by `TranscriptionRetryWorkflow.swift`.

## Goals

- Extract the Native Whisper model install/cancel/delete lifecycle into `Sources/NativeWhisperModelWorkflow.swift`.
- Extract the Local AI (llama.cpp-backed) model install/cancel/delete/status-refresh lifecycle into `Sources/LocalAIModelWorkflow.swift`.
- Preserve every existing external call site's method name and signature on `AppState` (see "API Surface to Preserve" below) — no UI-visible behavior change.
- Preserve all existing safety properties: active-token/generation guards against stale completions, deletion-before-reinstall ordering, app-termination quiescence waiting, idle server shutdown monitoring.
- Replace the tangled current test file with direct workflow behavior tests plus narrower AppState integration tests, matching the pattern from #317–#319.

## Non-Goals

- No work on Settings/UserDefaults persistence, Calendar, Permissions, or Recording — those remain #192's scope (blocked by #217).
- No change to `AIProcessingBackendChoice` normalization/persistence logic itself (`normalizeAIProcessingChoices`, `initializeMeetingSummarySettingsIfNeeded`, the `postProcessingBackendChoice`/`contextBackendChoice`/`meetingSummaryBackendChoice` `@Published` properties and their `didSet` persistence) — this is Settings-domain logic that happens to consume Local AI install state, not part of the Local AI model-management boundary itself. It stays in `AppState.swift`.
- No change to `LocalAIServerManager`, `LocalAIInstaller`, `NativeWhisperInstaller`, `LocalAIModelStore`, `NativeWhisperModelStore`, or the model catalogs (`LocalAIModelCatalog`, `NativeWhisperModelCatalog`) — these low-level files are already correctly scoped and stay as-is.
- No new feature, no new UI, no change to persisted state format, retry policy, or user-facing copy.
- No growth of the public API surface — the goal is relocation, not redesign.

## Current State Inventory

### Native Whisper lifecycle (`Sources/AppState.swift:1011–1392`, ~150 lines of actual lifecycle code interleaved with ~230 lines of unrelated display/label helpers in the same range)

State:
- `@Published private(set) var nativeWhisperInstallStatus: NativeWhisperInstallStatus`
- `@Published private(set) var nativeWhisperInstallProgress: NativeWhisperDownloadProgress`
- `@Published private(set) var isInstallingNativeWhisper: Bool`
- `@Published private(set) var nativeWhisperInstallError: String?`
- `@Published private(set) var nativeWhisperInstallIssue: QuillUserIssueRecord?`
- `@Published private(set) var pendingNativeWhisperAutoSelectionModelID: String?` — **feature-selection glue, stays in AppState** (see Entanglement Points)
- `private var nativeWhisperInstallTask: NativeWhisperInstallTask?`
- `private var nativeWhisperProgressCoalescer: LatestValueProgressCoalescer<NativeWhisperDownloadProgress>?`
- `private var nativeWhisperInstallQuiescenceWaiters: [CheckedContinuation<Void, Never>]`
- `private var nativeWhisperInstallCancellationMessage: String?` — dead code today (only ever set to `nil`, read back as `nil`); preserve verbatim, do not "fix."

Functions (pure lifecycle, all move):
- `refreshNativeWhisperInstallStatus()`
- `installNativeWhisperModel(autoSelectWhenReady:)` — **entangled**, see below
- `finishNativeWhisperInstall(model:result:)` — **entangled**, see below
- `waitForNativeWhisperInstallToQuiesce() async`
- `resumeNativeWhisperInstallQuiescenceWaitersIfNeeded()`
- `cancelNativeWhisperInstall()`
- `deleteNativeWhisperModel()`

Functions that stay (feature-selection glue / UI display, not lifecycle):
- `cancelNativeWhisperAutoSelection()`
- `willAutoSelectNativeWhisperWhenReady` (computed; used externally by `SetupView.swift:755`, `SettingsView.swift:4858`)
- All of `noteBrowserTranscriptionDisplay(for:)`, `nativeWhisperChoice`, `nativeWhisperDisplayName`, `hasNativeLocalWhisperModel`, and the surrounding transcription-choice display helpers (lines ~1023–1260) — these read `nativeWhisperInstallStatus` but are Settings/Note-Browser display logic, not install lifecycle.

### Local AI lifecycle (`Sources/AppState.swift:2245–4260`, ~2,000 lines total; roughly 1,400 lines pure lifecycle, ~600 lines feature-selection glue tightly interleaved)

State (all move to the workflow):
- `let localAIServerManager: LocalAIServerManager` — **stays instance-owned by AppState** (it's also referenced elsewhere for transcription execution), but the workflow receives it as a runtime dependency for the exclusive-maintenance-before-delete step.
- `@Published private(set) var localAIInstallStates: [String: LocalAIModelInstallViewState]`
- `private var localAIInstallTasks: [String: LocalAIInstallTask]`
- `private var localAIProgressCoalescers: [String: LatestValueProgressCoalescer<LocalAIDownloadProgress>]`
- `private var localAIInstallTokens: [String: UUID]`
- `private var localAICancellingModelIDs: Set<String>`
- `private var localAIRestartAfterCancellationModelIDs: Set<String>`
- `private var localAIDeletionRequestedModelIDs: Set<String>`
- `private var localAIStatusRefreshGenerations: [String: Int]`
- `private var localAIStatusRefreshPendingModelIDs: Set<String>`
- `private var localAIStatusRefreshWaiters: [CheckedContinuation<Void, Never>]`
- `private var localAIInstallQuiescenceWaiters: [CheckedContinuation<Void, Never>]`
- `private var localAIIdleShutdownTask: Task<Void, Never>?`
- `private var hasCompletedLocalAIStatusRefresh: Bool`
- `private struct LocalAIModelDeletionOutcome: Sendable` (currently at line 365, physically separated from its usage) — moves to the workflow file.

State that stays on AppState (feature-selection glue):
- `@Published private var pendingLocalAISelections: [AIProcessingFeature: String]`
- `@Published private(set) var contextModelCapabilityWarning: String?`

Functions (pure lifecycle, all move, signatures preserved where public):
- `startLocalAIIdleShutdownMonitoring()`
- `stopLocalAIIdleShutdownMonitoring()`
- `localAIInstallState(for:) -> LocalAIModelInstallViewState`
- `refreshAllLocalAIInstallStates()`
- `waitForLocalAIInstallStateRefresh() async`
- `waitForLocalAIInstallsToQuiesce() async`
- `resumeLocalAIInstallQuiescenceWaitersIfNeeded()`
- `nextLocalAIStatusRefreshGeneration(for:)`
- `applyLocalAIStatusRefresh(_:for:generation:)`
- `completeLocalAIStatusOperation(_:for:)`
- `startLocalAIInstallIfPossible(_:)` — **entangled**, see below
- `finishLocalAIInstall(model:token:result:status:cleanupErrorDescription:)` — **entangled**, see below
- `canonicalLocalAIModel(_:) -> LocalAIModel?`
- `localAIModelUnavailableIssue(for:) -> QuillUserIssueRecord`
- `cancelLocalAIInstall(_:)`
- `deleteLocalAIModel(_:)`
- `beginLocalAIModelDeletion(_:)`
- `finishLocalAIModelDeletion(_:outcome:)`
- `isLocalAIModelAvailable(_:) -> Bool` (reads `dependencies.localAI.processingAvailability()`) — moves; becomes a public query on the workflow since it's a hardware/model-capability predicate independent of AppState's own UI state, and it's already consumed both by lifecycle functions and by glue functions (see below).

Functions that stay (feature-selection glue, settings interaction — not lifecycle):
- `installLocalAIModel(_:autoSelectFor:)` — **entangled**, see below; stays as the public adapter, but delegates its lifecycle decision to the workflow.
- `setPendingLocalAIModelID(_:for:)`
- `clearPendingLocalAISelections(forModelID:)`
- `waitingFeatures(for:) -> [AIProcessingFeature]`
- `selectedOrPendingLocalAIModel(for:) -> LocalAIModel?`
- `pendingLocalAIModelID(for:) -> String?`
- `discardPendingLocalAISelection(for:)`
- `discardUndownloadedLocalAISelections()`
- `applyReadyLocalAIModelToWaitingFeatures(_:)` — **entangled**, see below
- `resumeDeferredLocalAIRequests()` — **entangled**, see below
- `unavailableLocalAIChoiceDisplay(...)`
- `normalizeAIProcessingChoices()`, `normalizedAIProcessingChoice(_:for:)`, `initializeMeetingSummarySettingsIfNeeded()` — Settings-domain, out of scope entirely.

### App-termination fan-out (`Sources/AppState.swift:~8200–8260`)

`requestTerminationAfterModelCleanup(replyIsAlreadyPending:)` cancels both lifecycles, then awaits both quiescence signals, then stops the shared server, then replies to termination. This orchestration **stays on AppState** as a thin fan-out over both workflows' public `cancel...()`/`waitFor...Quiesce()` methods — it is legitimately AppState-level because it also coordinates the shared `localAIServerManager.stop()` and the app-level "quit alert" UI flow (`isModelDownloadQuitAlertPresented`, `modelDownloadQuitAlertPresenter`).

`AppState.deinit` currently does `localAIIdleShutdownTask?.cancel()` directly. Once `localAIIdleShutdownTask` moves into `LocalAIModelWorkflow`, `LocalAIModelWorkflow` gets its own `deinit { idleShutdownTask?.cancel() }` and the line is removed from `AppState.deinit` (it fires automatically when AppState releases the workflow instance).

### External call sites that must keep their exact name/signature on `AppState`

```text
Sources/SetupView.swift:106      appState.refreshNativeWhisperInstallStatus()
Sources/SettingsView.swift:4933  appState.installNativeWhisperModel()
Sources/SettingsView.swift:4960  appState.cancelNativeWhisperInstall()
Sources/SettingsView.swift:4988  appState.installNativeWhisperModel()
Sources/SettingsView.swift:4997  appState.deleteNativeWhisperModel()
Sources/SetupView.swift:755      appState.willAutoSelectNativeWhisperWhenReady
Sources/SettingsView.swift:4858  appState.willAutoSelectNativeWhisperWhenReady
Sources/NoteBrowserView.swift:870 appState.installedLegacyLocalWhisperModels
Sources/LocalAIModelRowView.swift:144  appState.deleteLocalAIModel(model)
Sources/LocalAIModelRowView.swift:239  appState.installLocalAIModel(model, autoSelectFor: feature)
Sources/LocalAIModelRowView.swift:273  appState.cancelLocalAIInstall(model)
Sources/AppDelegate.swift:92     appState.startLocalAIIdleShutdownMonitoring()
```

Plus, called from within `AppState.init`: `refreshAllLocalAIInstallStates()` (tail of `init`, wrapped in a main-thread dispatch — this becomes `localAIWorkflow.refreshAllInstallStates()`).

### Test coverage (`Tests/AppStateAIProcessingBackendTests.swift`, 3,194 lines, 65 test functions)

This file mixes three concerns in the same test functions:
1. **Pure Local AI/Native Whisper lifecycle** (install/cancel/delete, progress coalescing, quiescence, status-refresh generation guards, termination fan-out) — candidates to move to direct workflow tests.
2. **Feature-selection glue** (`pendingLocalAISelections`, auto-select-when-ready, `discardUndownloadedLocalAISelections`) — stays as AppState integration tests, now exercised against the workflow's public API instead of internal dictionaries.
3. **`AIProcessingBackendChoice` normalization/persistence** (legacy migration, cloud/local independence per feature, remembered-cloud-model fallback) — entirely out of scope for #320; stays untouched in this file.

Concretely, at least these already look like clean pure-lifecycle candidates for extraction into direct workflow tests: `testNativeWhisperProgressCoalescesAndCancellationWins`, `testLocalAIProgressCoalescesAndCompletionWins`, `testIdleShutdownMonitoringIsIdempotentAndStops`, `testLocalAIInstallQuiescenceWaitsForActiveWorker`, `testBackgroundStatusRefreshIgnoresStaleGeneration`, `testCanonicalModelValidationRejectsForgedModels`, `testInstallerSuccessRequiresReadyStatus`, `testInstallerSuccessRechecksHardwareAvailability`, `testPartialCleanupFailureSetsModelIssue`, `testDeleteFailureAndSuccessStateReset`, `testAppStateInstancesKeepIndependentLocalAIEnvironments`. Others mix concerns (e.g. `testDiscardUndownloadedSelectionsPreservesStartedDownloads`, `testCancellationWaitsForCompletionAndRetriesAfterQuiescence`, `testDeleteDuringInstallWaitsAndCannotAutoSelect`) and need a per-test judgment call during implementation about whether to split the assertions across a workflow test and an AppState test, or keep as a single AppState integration test if the feature-selection reaction is the actual point of the test. The termination fan-out tests (`testCombinedNativeAndLocalTerminationWaitsForBothWorkers`, `testTerminationRoutesThroughUnifiedModelCleanup`) stay as AppState integration tests since the fan-out itself stays on AppState.

## Entanglement Points (the reason this isn't a mechanical move)

Six places in the current code interleave pure lifecycle control-flow with feature-selection glue or Settings-domain logic in the same function body. Each needs to be split at the call boundary, not just relocated:

1. **`installNativeWhisperModel(autoSelectWhenReady:)`** — records `pendingNativeWhisperAutoSelectionModelID` (glue) *before* checking `isInstallingNativeWhisper` and starting the workflow (lifecycle). Split: AppState's adapter records the pending selection, then unconditionally calls `nativeWhisperWorkflow.startInstall()` (workflow no-ops if already installing, exactly as today).

2. **`finishNativeWhisperInstall(model:result:)`** — on success, reads `pendingNativeWhisperAutoSelectionModelID` and calls `setNoteBrowserTranscriptionChoice(...)` (glue) inline. Split: workflow emits an `.installCompleted(outcome)` event; AppState's event handler performs the auto-select reaction exactly as today.

3. **`installLocalAIModel(_:autoSelectFor:)`** — the guard chain (`canonicalLocalAIModel`, `isLocalAIModelAvailable`, deletion-requested check) gates *both* whether to record the pending feature selection *and* whether to attempt the install. Split: the workflow exposes a query (`canonicalModel(for:) -> LocalAIModel?` or equivalent "is this startable" check) that AppState calls first to decide whether to record the pending selection, then AppState calls `localAIWorkflow.startInstall(model)` unconditionally (workflow re-validates and no-ops internally, same as today's early returns inside `startLocalAIInstallIfPossible`).

4. **`finishLocalAIInstall(...)`** — the result switch directly calls `applyReadyLocalAIModelToWaitingFeatures(model)` (glue) on success-and-ready, or `clearPendingLocalAISelections(forModelID:)` (glue) on the other branches. Split: workflow emits `.installOutcome(model, outcome)` where `outcome` mirrors today's four-way classification (ready-and-available / succeeded-but-unavailable / cancelled / failed); AppState's event handler performs the same reactions it does today, now via the workflow's public query API instead of internal dictionaries.

5. **`resumeDeferredLocalAIRequests()`** (called from `finishLocalAIStatusRefreshIfReady`) — iterates `pendingLocalAISelections` and `localAIDeferredInstallModelIDs` (glue state) but calls `applyReadyLocalAIModelToWaitingFeatures` / `startLocalAIInstallIfPossible` (lifecycle) depending on each model's current status. Split: stays in AppState as glue, but reads model status via `localAIWorkflow.installState(for:)` and starts installs via `localAIWorkflow.startInstall(model)` instead of manipulating lifecycle dictionaries directly. `localAIDeferredInstallModelIDs` itself — currently lifecycle-side state used only to remember "an install was requested before the initial status refresh finished" — moves into the workflow (it's install-attempt bookkeeping, not feature selection), and the workflow replays it internally once its own initial refresh completes, **removing the need for AppState to iterate it at all**. This shrinks `resumeDeferredLocalAIRequests()` to only the `pendingLocalAISelections` iteration.

6. **`finishLocalAIStatusRefreshIfReady()`** — signals "initial catalog refresh done" and directly calls `normalizeAIProcessingChoices()` / `initializeMeetingSummarySettingsIfNeeded()` (Settings-domain) and `resumeDeferredLocalAIRequests()` (glue) inline. Split: workflow emits `.initialStatusRefreshCompleted` once (after internally replaying any deferred installs per point 5); AppState's event handler calls `normalizeAIProcessingChoices()`, `initializeMeetingSummarySettingsIfNeeded()`, and the shrunk `resumeDeferredLocalAIRequests()`, exactly as today, just from an event handler instead of an inline call.

## Architecture

Two new instance-owned workflow types, constructed with `.live`-backed dependency closures exactly like `TranscriptionRetryWorkflow`, each exposing an `onEvent` closure and a `state` property that `AppState` mirrors into its own `@Published` properties.

### `Sources/NativeWhisperModelWorkflow.swift`

```swift
struct NativeWhisperModelWorkflowState: Equatable, Sendable {
    var installStatus: NativeWhisperInstallStatus
    var installProgress: NativeWhisperDownloadProgress
    var isInstalling: Bool
    var installError: String?
    var installIssue: QuillUserIssueRecord?
}

enum NativeWhisperModelWorkflowOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(QuillUserIssueRecord)
}

enum NativeWhisperModelWorkflowEvent {
    case stateChanged(NativeWhisperModelWorkflowState)
    case installCompleted(NativeWhisperModelWorkflowOutcome)
}

@MainActor
final class NativeWhisperModelWorkflow {
    var onEvent: ((NativeWhisperModelWorkflowEvent) -> Void)?
    private(set) var state: NativeWhisperModelWorkflowState

    func refreshInstallStatus()
    func startInstall()
    func cancelInstall()
    func deleteModel()
    func waitUntilQuiesced() async
}
```

Issue construction (`QuillUserIssueRecord(code: .localModelMissing, ...)`) for both install failure and delete failure moves into the workflow — it depends only on the model catalog, not on AppState's own state, matching the "leftover internals" classification from the initial audit.

### `Sources/LocalAIModelWorkflow.swift`

```swift
struct LocalAIModelWorkflowState: Equatable, Sendable {
    var installStates: [String: LocalAIModelInstallViewState]
    var hasCompletedInitialStatusRefresh: Bool
}

enum LocalAIModelWorkflowInstallOutcome: Equatable, Sendable {
    case readyAndAvailable
    case succeededButUnavailable(QuillUserIssueRecord)
    case cancelled
    case failed(QuillUserIssueRecord)
}

enum LocalAIModelWorkflowEvent {
    case stateChanged(LocalAIModelWorkflowState)
    case installOutcome(LocalAIModel, LocalAIModelWorkflowInstallOutcome)
    case deletionOutcome(LocalAIModel, errorDescription: String?)
    case initialStatusRefreshCompleted(deferredModelIDs: Set<String>)
}

@MainActor
final class LocalAIModelWorkflow: @unchecked Sendable {
    nonisolated(unsafe) var onEvent:
        (@MainActor (LocalAIModelWorkflowEvent) -> Void)?
    private(set) var state: LocalAIModelWorkflowState
    var hasActiveInstalls: Bool

    func beginTerminationCleanup()
    func installState(for model: LocalAIModel) -> LocalAIModelInstallViewState
    func isModelAvailable(_ model: LocalAIModel) -> Bool
    func canonicalModel(for model: LocalAIModel) -> LocalAIModel?
    func isDeletionRequested(_ modelID: String) -> Bool
    @discardableResult
    func markUnavailable(_ model: LocalAIModel) -> QuillUserIssueRecord
    func refreshAllInstallStates()
    func waitForInitialStatusRefresh() async
    func startInstall(_ model: LocalAIModel)
    @discardableResult
    func cancelInstall(_ model: LocalAIModel) -> Bool
    @discardableResult
    func deleteModel(_ model: LocalAIModel) -> Bool
    func waitForInstallsToQuiesce() async
    func startIdleShutdownMonitoring()
    func stopIdleShutdownMonitoring()

    deinit // cancels idleShutdownTask
}
```

`startInstall(_:)` internally reproduces today's full guard chain from `installLocalAIModel` + `startLocalAIInstallIfPossible` (canonical-model validation, deletion-requested check, availability check, deferred-until-status-refresh queuing, already-ready short-circuit via `.installOutcome(.readyAndAvailable)`, cancelling-then-restart handling) — it is safe to call unconditionally; it no-ops or defers exactly as the current code does.

### AppState adapter shape

`AppState` gains:
```swift
private let nativeWhisperWorkflow: NativeWhisperModelWorkflow
private let localAIWorkflow: LocalAIModelWorkflow
```

wired with `onEvent` closures in `init` (before any code path that could fire an event, matching the ordering fix already applied for `TranscriptionRetryWorkflow` in #318 — event handler wiring precedes any workflow call, including the tail-of-`init` `refreshAllLocalAIInstallStates()` call).

`AppState`'s existing `@Published` properties for both lifecycles (`nativeWhisperInstallStatus`, `nativeWhisperInstallProgress`, `isInstallingNativeWhisper`, `nativeWhisperInstallError`, `nativeWhisperInstallIssue`, `localAIInstallStates`) become mirrors updated from `.stateChanged` events, exactly matching the pattern `applyTranscriptionRetryWorkflowState` already uses. All external call sites keep their exact name (see list above) as thin methods that delegate to the workflow and, where an entanglement point requires it, perform the feature-selection reaction described above.

## Data Flow (representative sequences)

**Native Whisper install, auto-select requested:**
`SettingsView` → `appState.installNativeWhisperModel()` → AppState records `pendingNativeWhisperAutoSelectionModelID` → `nativeWhisperWorkflow.startInstall()` → workflow manages `Task`, emits `.stateChanged` during progress → on completion, workflow emits `.installCompleted(.succeeded)` → AppState's handler checks `pendingNativeWhisperAutoSelectionModelID`, calls `setNoteBrowserTranscriptionChoice(...)`, clears the pending ID.

**Local AI install requested for a feature, status refresh not yet complete:**
`LocalAIModelRowView` → `appState.installLocalAIModel(model, autoSelectFor: .postProcessing)` → AppState checks `localAIWorkflow.canonicalModel(for:)`/`isModelAvailable(for:)`, records `pendingLocalAISelections[.postProcessing] = model.id` → calls `localAIWorkflow.startInstall(model)` → workflow internally queues the model (deferred, since its own initial refresh isn't done) and no-ops for now → later, workflow's own initial catalog refresh completes → workflow emits `.initialStatusRefreshCompleted(deferredModelIDs:)` → AppState's handler calls `normalizeAIProcessingChoices()`, `initializeMeetingSummarySettingsIfNeeded()`, and `resumeDeferredLocalAIRequests(deferredModelIDs:)` → AppState reapplies ready pending choices and explicitly restarts each deferred non-ready model through `localAIWorkflow.startInstall(_:)` → on success, workflow emits `.installOutcome(model, .readyAndAvailable)` → AppState's handler calls its retained `applyReadyLocalAIModelToWaitingFeatures(model)`, which queries `localAIWorkflow.installState(for:)`/`isModelAvailable(_:)` and applies the choice for each waiting feature.

**App termination:**
`requestTerminationAfterModelCleanup` → `nativeWhisperWorkflow.cancelInstall()` (if installing) → `localAIWorkflow.cancelInstall(model)` for each active model → `localAIWorkflow.stopIdleShutdownMonitoring()` → `await nativeWhisperWorkflow.waitUntilQuiesced()` → `await localAIWorkflow.waitForInstallsToQuiesce()` → `await localAIServerManager.stop()` → reply to termination. Unchanged in shape from today; only the receiver of each call changes.

## Testing Strategy

- New `Tests/NativeWhisperModelWorkflowTests.swift` and `Tests/LocalAIModelWorkflowTests.swift`: direct workflow instance tests (no `AppState`), covering install/cancel/delete, progress coalescing, status-refresh generation guards, quiescence waiting, canonical-model validation, and the deferred-install-replay-on-initial-refresh behavior — migrated from the pure-lifecycle tests identified in `AppStateAIProcessingBackendTests.swift`.
- `Tests/AppStateAIProcessingBackendTests.swift` keeps: `AIProcessingBackendChoice` normalization/persistence tests (untouched, out of scope), plus narrowed AppState integration tests for feature-selection glue (auto-select-when-ready, pending-selection lifecycle, `discardUndownloadedLocalAISelections`) and the termination fan-out.
- Each test currently mixing both concerns gets a judgment call during implementation: split into a workflow test plus a narrower AppState test if both halves are independently meaningful, or keep as a single AppState integration test if the point of the test is specifically the AppState-level reaction.
- `make check-test-wiring` must continue to pass with the new test files registered.

## Safety Invariants Preserved (no behavior change)

- Active-token-per-model-ID guards on Local AI install completion and progress application (`localAIInstallTokens`).
- Status-refresh generation guards (`localAIStatusRefreshGenerations`) preventing stale background status checks from overwriting newer state.
- Deletion re-entrancy guard (`localAIDeletionRequestedModelIDs`) and deletion-before-reinstall ordering via `withExclusiveMaintenance` on the shared `localAIServerManager`.
- Single-instance guard on Native Whisper installs (`isInstallingNativeWhisper`), no token needed since only one install can exist at a time by construction.
- App-termination quiescence waiting for both lifecycles before stopping the shared server.
- Vestigial `nativeWhisperInstallCancellationMessage` (currently dead code, always `nil`) is preserved as-is — not "fixed," since this is a pure relocation, not a behavior change.

## Out of Scope / Deferred

- `AIProcessingBackendChoice` normalization/persistence logic and its own extensive test coverage in `AppStateAIProcessingBackendTests.swift`.
- Any further #192 domain-store work (Settings/Calendar/Permissions/Recording) — remains blocked by #217.
- `LocalAIServerManager`'s own internal state machine (`idle/starting/running/stopping`) — already a separate, correctly-scoped file; the new `LocalAIModelWorkflow` only calls its existing public `withExclusiveMaintenance`/`stop`/`shutdownIfIdle` methods.
