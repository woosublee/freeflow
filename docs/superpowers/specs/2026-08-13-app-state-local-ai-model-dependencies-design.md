# AppState Local AI and Model Dependencies Design

**Date:** 2026-08-13
**Status:** Approved for implementation planning
**Issue:** #316
**Base:** `origin/main` at `06db4e6`

## Goal

Move Local AI and Native Whisper model-management dependencies from mutable `AppState` static properties to instance-owned values while preserving current model paths, installation behavior, server lifecycle, UI behavior, errors, and the source compatibility of `AppState()`.

This work extends the `AppStateDependencies` pattern established by #312 and refined by #314–#315. It changes dependency ownership, not the Local AI or Native Whisper product model.

## Scope

### Included

- focused Local AI and Native Whisper dependency values in `AppStateDependencies`
- instance-owned Local AI install status, installer start, progress scheduling, final and partial deletion, server-manager creation, idle-shutdown timing, and processing availability
- instance-owned Native Whisper install status, installer start, progress scheduling, and model deletion
- removal of the selected mutable `AppState` static seams
- initialization of Native Whisper state from the supplied instance dependencies
- explicit propagation of the originating instance’s Local AI availability into `AIProcessingBackendExecutor`
- preservation of asynchronous dependency snapshots for status refresh, installation, cancellation cleanup, deletion, idle shutdown, and termination cleanup
- migration of Local AI and Native Whisper `AppState` tests from static save/assign/restore setup to dependency copy-and-override setup
- behavior tests proving that two `AppState` instances retain independent model environments
- a narrow source scan preventing reintroduction of the removed static seams
- a follow-up issue for the Native Whisper transcription execution path

### Excluded

- Native Whisper’s actual transcription execution path in `TranscriptionService`
- model catalog, URLs, checksums, package formats, recommended models, and hardware requirements
- Local AI or Native Whisper installer internals
- the process-wide installer in-flight lock and key registry
- model-download quit-alert presentation and application termination reply seams
- Calendar, post-processing, cloud import, storage, credential, and unrelated `AppState` static seams
- Local AI or Native Whisper workflow extraction
- general `AppState.swift` splitting
- new UI, user-facing text, error types, or retry policy

## Current Problem

`AppState` currently owns mutable static closures for Local AI and Native Whisper status, installation, progress scheduling, deletion, server creation, idle timing, and availability. Tests replace and restore these closures globally.

This causes several problems:

- model tests are order-dependent if restoration is delayed or missed,
- tests that use the same seams cannot safely run concurrently,
- multiple `AppState` instances cannot express different model environments,
- asynchronous work can observe a dependency installed by a later test,
- status, installation, deletion, server validation, and execution availability can resolve from different live environments,
- the static registry obscures which instance owns active installer and server behavior.

Two related correctness inconsistencies also need correction within this boundary:

1. Native Whisper deletion constructs a live `NativeWhisperModelStore` directly instead of using the same environment as status and installation.
2. `AppState` selection logic can use an overridden Local AI availability, while the actual `AIProcessingBackendExecutor` independently falls back to `LocalAIProcessingAvailability.live()`.

## Architecture

### Focused dependency values

Extend `AppStateDependencies` with two focused value bundles rather than introducing a generic registry or service container.

```swift
struct AppStateLocalAIDependencies {
    var makeServerManager: @MainActor () -> LocalAIServerManager
    var idleShutdownSleep: @Sendable (Duration) async throws -> Void
    var installStatus: @Sendable (LocalAIModel) -> LocalAIModelInstallStatus
    var startInstall: @MainActor (
        LocalAIModel,
        @escaping @Sendable (Double) -> Void,
        @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> any ModelInstallation
    var progressSchedule: @MainActor (
        @escaping @MainActor () -> Void
    ) -> LocalAIProgressScheduling
    var deleteModel: @Sendable (LocalAIModel) throws -> Void
    var deletePartialModel: @Sendable (LocalAIModel) throws -> Void
    var processingAvailability: @Sendable () -> LocalAIProcessingAvailability
}
```

```swift
struct AppStateNativeWhisperDependencies {
    var installStatus: @Sendable (
        NativeWhisperModel
    ) -> NativeWhisperModelInstallStatus
    var startInstall: @MainActor (
        NativeWhisperModel,
        @escaping @Sendable (Double) -> Void,
        @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> any ModelInstallation
    var progressSchedule: @MainActor (
        @escaping @MainActor () -> Void
    ) -> LocalAIProgressScheduling
    var deleteModel: @Sendable (NativeWhisperModel) throws -> Void
}
```

The exact type aliases and closure formatting may follow existing source conventions, but the ownership and included responsibilities are fixed by this design.

`AppStateDependencies` gains two properties:

```swift
var localAI: AppStateLocalAIDependencies
var nativeWhisper: AppStateNativeWhisperDependencies
```

These properties remain variables so tests can copy `.live` and override only the seam they need. The `AppState` retains the resulting dependency value after initialization.

### Live dependency construction

Each `.live` bundle creates one explicit model store and captures it across the whole model lifecycle.

Local AI live construction:

1. create one `LocalAIModelStore`,
2. use it for install-status lookup,
3. construct `LocalAIInstaller(store:)` for installation,
4. construct `LocalAIServerManager(store:)` for server validation,
5. use it for final and partial deletion,
6. preserve the current progress scheduler, sleep implementation, and hardware availability provider.

Native Whisper live construction:

1. create one `NativeWhisperModelStore`,
2. use it for install-status lookup,
3. construct `NativeWhisperInstaller(store:)` for installation,
4. use it for model deletion,
5. preserve the current progress scheduler.

The store is an implementation detail of the bundle. It is not exposed as a new public `AppState` API.

### Removed mutable static seams

Remove these model-related mutable static properties from `AppState`:

- `nativeWhisperInstallStatusProvider`
- `nativeWhisperInstallStarter`
- `nativeWhisperProgressSchedule`
- `localAIServerManagerFactory`
- `localAIIdleShutdownSleep`
- `localAIInstallStatusProvider`
- `localAIInstallStarter`
- `localAIProgressSchedule`
- `localAIModelDelete`
- `localAIPartialModelDelete`
- `localAIProcessingAvailabilityProvider`

Do not leave compatibility properties that forward to mutable global state. Tests and production code must use the originating `AppState` dependency value.

The following adjacent seams remain unchanged because they are external effects outside model ownership:

- `modelDownloadQuitAlertPresenter`
- `applicationTerminationReply`

## AppState Ownership and Initialization

`AppState` continues to retain a single `AppStateDependencies` value supplied through:

```swift
init(dependencies: AppStateDependencies = .live)
```

Production construction remains source-compatible:

```swift
let appState = AppState()
```

### Native Whisper initial state

The current stored-property initializer reads a mutable static provider before initializer dependencies are available. Replace it with explicit initialization inside `AppState.init(dependencies:)` using the supplied Native Whisper dependency value.

The initial status must continue to represent `.recommended`, and all downstream initial selection and readiness behavior must remain unchanged.

### Local AI server manager

Create the manager with the supplied instance dependency during initialization and retain it as the existing `AppState` instance property. The manager itself is already an actor with instance state; only its factory ownership changes.

## Runtime Data Flow

### Status refresh

Status refreshes read `dependencies.localAI.installStatus` or `dependencies.nativeWhisper.installStatus` from the originating instance.

Before starting detached or asynchronous work, copy the closure into a local constant. This preserves the existing snapshot behavior and prevents active work from observing another instance or test environment.

Generation checks, stale refresh suppression, state normalization, and UI publication remain unchanged.

### Installation and progress

Installation keeps the current lifecycle:

1. reject duplicate or invalid starts as today,
2. establish the existing generation and in-flight state,
3. create the progress coalescer from the instance dependency,
4. capture install status, install starter, and partial cleanup closures from the instance dependency,
5. start the existing installer,
6. publish progress and completion through the existing callbacks,
7. reconcile final status before marking success,
8. preserve cancellation, retry, and error behavior.

The dependency change must not reorder completion relative to the final coalesced progress update.

### Cancellation cleanup

When installation cancellation triggers partial-model cleanup, capture the originating instance’s partial-delete and status closures before starting detached cleanup work.

A later change to another test dependency must not alter cleanup or final status reconciliation for the active install.

### Deletion

Local AI deletion continues to run through `LocalAIServerManager.withExclusiveMaintenance`, ensuring that active inference is excluded and the resident server is stopped before model files are deleted. The delete and status closures come from the same Local AI dependency bundle as the manager.

Native Whisper deletion uses the Native Whisper bundle’s delete closure instead of constructing `NativeWhisperModelStore()` directly.

Current success, failure, state-transition, and user-message behavior remains unchanged.

### Idle shutdown and termination

Idle shutdown captures the originating instance’s manager and sleep closure before creating its task. Existing idempotence and cancellation behavior remain intact.

Unified termination cleanup continues to:

1. cancel Native Whisper and Local AI installations,
2. wait for both installer families to become quiescent,
3. stop the originating instance’s Local AI server manager,
4. invoke the existing external alert and termination-reply seams.

No public method names or source-contract markers for this flow are intentionally changed.

### Local AI availability consistency

All Local AI selection and UI choice logic reads the originating instance’s availability dependency.

When `AppState` constructs `AIProcessingBackendExecutor`, it explicitly supplies the same availability value rather than allowing the executor to fall back to `.live()`. The UI decision and actual execution gate must therefore agree for a given `AppState` instance.

This does not change the executor’s availability model or hardware rules; it only supplies the correct instance snapshot.

## Native Whisper Execution Boundary

`TranscriptionService` currently constructs a live `NativeWhisperModelStore` and `NativeWhisperRuntime` when performing actual Native Whisper transcription.

This design intentionally does not migrate that execution path. Doing so would require a separate transcription execution dependency or immutable execution snapshot, propagation through service construction, and replacement of an exact-source contract that protects preflight ordering.

No compatibility shim is added in #316. A follow-up issue will track:

- an originating-instance Native Whisper model path/runtime snapshot,
- propagation into actual transcription execution,
- preservation of preflight-before-audio-conversion behavior,
- behavior-based replacement or adjustment of the relevant source contract.

## Installer Process-Wide Coordination

`LocalAIInstaller` and `NativeWhisperInstaller` maintain process-wide lock-protected in-flight key sets. These are not `AppState` service locators; they prevent concurrent modification of the same filesystem model artifact.

They remain process-wide in this work. Moving them into `AppStateDependencies` would allow two instances targeting the same model path to download or replace the file concurrently and would weaken safety.

Any future effort to make this coordination explicit must preserve its process-wide filesystem semantics and belongs to a separate design.

## Error Handling

This refactoring introduces no new error model or user-facing copy.

Preserve:

- current installer errors,
- current cancellation behavior,
- current partial cleanup error handling,
- current success verification through final install status,
- current delete errors and state transitions,
- current Local AI availability reasons,
- current server stop and maintenance behavior,
- current Native Whisper and Local AI user messages.

A dependency closure failure follows the same `AppState` completion and error path as the corresponding live implementation today. The refactoring changes where the operation comes from, not how its result is interpreted.

## Concurrency and Lifetime

- Each `AppState` retains its own dependency value.
- Closures used by `Task` or `Task.detached` are captured from that value before the work starts.
- Relevant closures are `@Sendable` where they cross concurrency boundaries.
- Main Actor-only manager construction, progress scheduling, and callback publication remain Main Actor-isolated.
- Test harnesses synchronize mutable state captured by `@Sendable` closures.
- Tests configure dependencies before `AppState` creation instead of mutating model globals afterward.
- The live bundles may capture reference-type stores because those stores are immutable path environments for these operations.
- No process-global dependency reset is introduced.

## Test Migration

### Copy-and-override setup

Tests use the existing pattern:

```swift
var dependencies = AppStateDependencies.live
dependencies.localAI.installStatus = { model in
    harness.status(for: model)
}
dependencies.nativeWhisper.installStatus = { model in
    harness.status(for: model)
}

let appState = AppState(dependencies: dependencies)
```

A test that needs a controlled installer, scheduler, deletion, availability, or server manager overrides that field on its dependency copy.

### `AppStateAIProcessingBackendTests`

Remove model-related static setup and `LocalAISeamSnapshot` save/restore behavior. Migrate status, installation, progress, deletion, availability, idle-shutdown, and server-manager tests to explicit dependencies.

Quit-alert and termination-reply seams may retain a small, separate restoration helper because they are outside #316 and still process-global.

Retain behavior coverage for:

- duplicate install coalescing,
- progress coalescing and completion precedence,
- install cancellation and retry,
- cancellation partial cleanup,
- final ready-status verification,
- status-refresh generation handling,
- unsupported and low-memory availability,
- Local AI deletion during server lifecycle,
- delete success and failure,
- server reuse and idle shutdown,
- unified termination quiescence.

### `AppStateTranscriptionConfigurationTests`

Remove Native Whisper model static setup and migrate status/install/progress tests to dependencies supplied during `AppState` construction.

Retain behavior coverage for:

- keeping a ready Native Whisper choice,
- maintaining Apple Live while installation is active,
- automatic Native Whisper selection after success,
- explicit user selection canceling pending auto-selection,
- cancellation clearing pending selection,
- combined-source fallback and legacy/native transition stability.

The exact-source test for Native Whisper runtime preflight remains unchanged in this issue because the execution path is deferred.

### Instance-isolation tests

Add focused behavior tests proving that two `AppState` instances can retain different:

- Local AI and Native Whisper initial statuses,
- Local AI processing availability,
- installer callbacks and progress environments,
- Local AI server managers,
- deletion results.

At minimum, mutate or exercise one instance and verify the other instance’s observed status and harness state remain unchanged.

Also verify that changing a local dependency value after creating the first `AppState` affects only a later instance and not the existing one.

### Asynchronous snapshot tests

Add or strengthen tests proving that:

- a detached status refresh uses the originating instance provider,
- cancellation cleanup uses the installer’s originating partial-delete and status closures,
- idle shutdown uses the originating manager and sleep implementation,
- executor availability matches the originating `AppState` availability.

### Static seam removal scan

Extend the narrow source audit used for removed process-global seams. The selected identifiers must no longer appear as mutable `AppState` properties, and tests must not save, assign, or restore them.

The scan is a structural guard only. Lifecycle behavior remains protected by behavior tests rather than exact implementation text.

## Expected Files

Required source changes:

- `Sources/AppStateDependencies.swift`
- `Sources/AppState.swift`

Required test migrations:

- `Tests/AppStateDependenciesTests.swift`
- `Tests/AppStateAIProcessingBackendTests.swift`
- `Tests/AppStateTranscriptionConfigurationTests.swift`
- `Tests/AppStateHistoryProtectionSourceTests.swift`

Possible targeted additions depending on the most coherent test location:

- `Tests/AppStateStorageSafetyTests.swift`

No new production source file is required unless the focused dependency value definitions become clearer outside `AppStateDependencies.swift`. If a new test file is introduced, update the Makefile test list and the grouped full-source AppState runner.

## Verification

Run focused tests covering:

- `AppStateDependenciesTests`
- `AppStateAIProcessingBackendTests`
- `AppStateTranscriptionConfigurationTests`
- `AppStateHistoryProtectionSourceTests`
- Local AI installer/model store/server manager tests
- Native Whisper installer/model/runtime tests
- AI processing backend tests

Then run:

- `make check-test-wiring`
- `make test`
- `make all CODESIGN_IDENTITY=Quill`

If the known iCloud-synchronized build-directory codesign detritus causes `errSecInternalComponent`, clear extended attributes with `xattr -cr build` and rerun the same production build command.

Before opening or merging the PR:

- run `/code-review medium`,
- resolve verified findings,
- rerun affected tests and full verification,
- confirm CI and CodeRabbit findings are resolved.

## Completion Criteria

The work is complete when:

1. the selected eleven mutable model-related `AppState` static seams are removed,
2. Local AI and Native Whisper model-management operations use originating-instance dependencies,
3. Local AI status, install, delete, manager, and availability share one live store environment per dependency value,
4. Native Whisper status, install, and delete share one live store environment per dependency value,
5. actual Local AI executor availability agrees with the originating `AppState`,
6. two `AppState` instances can use different model environments without cross-contamination,
7. asynchronous work cannot observe a later test’s replacement model dependency,
8. related tests no longer save, assign, or restore the removed static seams,
9. installer process-wide filesystem coordination remains intact,
10. existing model paths, UI, lifecycle, errors, and `AppState()` construction remain unchanged,
11. focused tests, `make check-test-wiring`, `make test`, and the production build pass,
12. Native Whisper actual transcription execution migration is tracked separately rather than silently omitted.

## Follow-Up

Create a separate issue for making Native Whisper actual transcription execution use an originating-instance immutable model path/runtime snapshot. Link it from #316 and roadmap #321 without blocking the model-management dependency migration described here.
