# AppState History and Summary Dependencies Design

**Date:** 2026-08-12
**Status:** Approved for implementation planning
**Stacked base:** `worktree-internal-logic-small-refactors` at `709bfa3`

## Goal

Replace the first high-value group of `AppState` global mutable test seams with instance-owned dependencies while preserving Quill’s storage layout, history recovery behavior, meeting-summary behavior, cloud retry behavior, and existing user-facing errors.

This is the first large internal refactoring step, not a full decomposition of `AppState`. It establishes a stable instance dependency boundary that later workflow and storage refactors can build on.

## Delivery Strategy

This work uses two sequential pull requests.

### PR A: Small internal refactors

Branch: `worktree-internal-logic-small-refactors`

PR A contains only:

- linear oversized-token splitting,
- centralized post-processing prompt-leak policy,
- safe timestamp formatter reuse.

It targets `main` and must merge first.

### PR B: AppState history and summary dependencies

Branch: `worktree-app-state-history-summary-dependencies`

PR B is based on PR A’s current head while implementation proceeds. It is not opened until PR A is merged. After PR A merges, PR B’s own commits are rebased onto the latest `main` so its final diff contains only this dependency refactoring.

If PR A is squash-merged, PR B must transplant only the commits after `709bfa3` onto the new `main`, rather than rebasing the entire stacked history naively.

## Scope

### Included

- `AppStateStorageLayout`
- `AppStateDependencies`
- instance-owned storage layout and history-store construction
- instance-owned meeting-summary generator construction
- instance-owned cloud retry dependencies
- archive and recovery store replacement through the instance factory
- recording-journal and cloud-job paths derived from the instance layout
- migration of History + Summary tests away from the selected global seams
- minimum source-contract updates needed for the new instance path
- full regression verification

### Excluded

- Local AI and Native Whisper installation dependencies
- post-processing transport and audio-import cloud dependencies
- Google Calendar dependencies
- app termination and alert presentation dependencies
- all remaining `AppState` static seams
- general `AppState` file splitting
- recording, import, retry, or summary workflow extraction
- replacement of all source-string tests
- credential storage changes
- throwing storage APIs or new storage error types
- file-format, path-name, retry-policy, or user-copy changes

## Current Problem

`AppState` currently owns mutable static closures for storage roots, history-store creation, meeting-summary generation, and cloud retry dependencies. Tests replace these values globally and restore them with `defer`.

This creates several structural problems:

- tests are order-dependent when restoration is missed or delayed,
- tests that mutate the same seam cannot safely run in parallel,
- multiple `AppState` instances cannot use different environments,
- asynchronous work can observe a later test’s replacement closure,
- future workflow extraction remains coupled to class-level service location,
- tests contain extensive setup and restoration boilerplate.

The production application creates one `AppState`, but the dependency model should not require global process state to express that fact.

## Architecture

### AppStateStorageLayout

Create a focused value type:

```swift
struct AppStateStorageLayout: Sendable {
    let rootDirectory: URL

    var audioDirectory: URL { ... }
    var transcriptDirectory: URL { ... }
    var historyStoreURL: URL { ... }
    var cloudTranscriptionJobsDirectory: URL { ... }
    var cloudTranscriptionTemporaryDirectory: URL { ... }

    static var live: AppStateStorageLayout { ... }
}
```

The layout owns path relationships only. It does not become a general file service and does not change current directory-creation or error behavior.

Required path compatibility:

- root: `AppName.applicationSupportDirectory`
- audio: `<root>/audio`
- transcripts: `<root>/transcripts`
- history: `<root>/PipelineHistory.sqlite`
- cloud jobs: `<root>/cloud-transcription/jobs`
- cloud temporary root: `<FileManager.default.temporaryDirectory>/<bundle-id>/cloud-transcription`

The cloud temporary directory is included because the current cloud job store derives it alongside persistent job storage. The bundle identifier fallback remains `com.woosublee.quill`.

The value is `Sendable` because immutable URLs are captured by detached storage work.

### AppStateDependencies

Create a value type:

```swift
struct AppStateDependencies {
    var storageLayout: AppStateStorageLayout
    var makePipelineHistoryStore: @Sendable (URL) -> PipelineHistoryStore
    var makeMeetingSummaryGenerator:
        @MainActor (AppState) -> any MeetingSummaryGenerating
    var makeRetryCloudTranscriptionDependencies:
        @Sendable () -> CloudTranscriptionDependencies

    static var live: AppStateDependencies { ... }
}
```

The properties are variables so tests can copy `.live` and replace only the seam they need. `AppStateDependencies.live` returns a fresh value and is not itself mutable global state.

The live implementations preserve current behavior:

- `makePipelineHistoryStore` calls `PipelineHistoryStore(storeURL:)`,
- `makeMeetingSummaryGenerator` calls `appState.makeMeetingSummaryService()`,
- retry cloud dependencies use `.live`,
- storage uses `AppStateStorageLayout.live`.

No generic dependency container, registry, protocol framework, or test-only reset mechanism is introduced.

### AppState ownership

`AppState` receives and retains dependencies:

```swift
private let dependencies: AppStateDependencies

init(dependencies: AppStateDependencies = .live) {
    self.dependencies = dependencies
    ...
}
```

The default keeps `AppDelegate` and all production call sites source-compatible:

```swift
let appState = AppState()
```

After initialization, an `AppState` never reads a selected class-level dependency seam. Its behavior is determined by the value supplied to that instance.

## Removed Static Seams

Remove these mutable static properties from `AppState`:

- `meetingSummaryGeneratorFactory`
- `storageRootProvider`
- `pipelineHistoryStoreFactory`
- `pipelineHistoryStoreAtURLFactory`
- `retryCloudTranscriptionDependenciesFactory`

Remove or replace `makeDefaultPipelineHistoryStore()` once no production or test caller needs the static helper.

Do not add compatibility shims with the same mutable global behavior. A temporary static bridge would leave the concurrency and test-isolation problem intact.

## Storage Data Flow

### Initialization

1. `AppState` stores the supplied dependencies.
2. It obtains `storageLayout` from that value.
3. Existing directory-creation behavior prepares the root, audio, and transcript paths.
4. It creates the initial history store with:

```swift
let pipelineHistoryStore = dependencies.makePipelineHistoryStore(
    storageLayout.historyStoreURL
)
```

5. Recording journal and cloud transcription job stores use paths from the same layout.
6. Startup history verification, recording-journal recovery, trim, sidecar reconciliation, and orphan cleanup continue in the existing order.

No persistence operation is reordered merely to introduce dependencies.

### Runtime file access

All instance operations that save, load, inspect, or delete note assets derive their URLs from the retained layout. This includes:

- transcript save/load/delete,
- audio save/delete and size lookup,
- Note Browser stored-audio lookup,
- retry snapshot construction,
- recording and cloud recovery paths,
- MCP meeting-source access,
- archive/recovery settings paths.

Static helper functions that execute off the main actor accept the layout or an already-derived directory explicitly. They must not fall back to a process-wide root provider.

### Archive and recovery

Archive and recovery are the most sensitive history-store replacement paths.

Before detached archive work begins, capture the instance factory and storage root:

```swift
let storageRoot = dependencies.storageLayout.rootDirectory
let makeStore = dependencies.makePipelineHistoryStore
```

`HistoryArchiveTransition` receives that captured factory as today. Completion and recovery paths create the new active store through the same instance dependency:

```swift
let activeStore = dependencies.makePipelineHistoryStore(
    dependencies.storageLayout.historyStoreURL
)
```

After a verified fresh history store is installed, recording journal and cloud job stores are recreated from the same retained storage layout. Existing availability, durability, readability, transition guards, and UI state resets remain unchanged.

## Meeting Summary Data Flow

Meeting-summary generation uses the retained dependency:

```swift
let generator = dependencies.makeMeetingSummaryGenerator(self)
let result = try await generator.generate(...)
```

The existing Main Actor isolation is preserved. Generator construction remains scoped to a generation attempt, matching current behavior.

Different `AppState` instances may therefore use different summary generators without modifying global state. Existing source fingerprinting, in-flight invalidation, persistence, warning records, pending reveal state, and error propagation remain unchanged.

## Cloud Retry Data Flow

Manual and resumed cloud retry execution use:

```swift
let cloudDependencies =
    dependencies.makeRetryCloudTranscriptionDependencies()
```

The factory is called when a retry execution is prepared, as in the current behavior. The difference is that the selected factory belongs to the `AppState` instance and cannot be changed by another test after construction.

Audio-import cloud dependencies remain on their existing static seam in this PR because import behavior is outside the selected History + Summary boundary.

## Test Migration

### Test dependency construction

Tests use copy-and-override setup:

```swift
var dependencies = AppStateDependencies.live
dependencies.storageLayout = AppStateStorageLayout(
    rootDirectory: temporaryRoot
)
dependencies.makePipelineHistoryStore = { _ in store }
dependencies.makeMeetingSummaryGenerator = { _ in generator }

let appState = AppState(dependencies: dependencies)
```

No test mutates the selected `AppState` static seams after this migration.

### AppStateTestStorage

Replace the current global storage overrides with an environment passed to the operation:

```swift
struct AppStateTestEnvironment {
    let rootDirectory: URL
    let storageLayout: AppStateStorageLayout
    let dependencies: AppStateDependencies
}
```

```swift
@MainActor
static func withIsolatedStorage<T>(
    _ operation: (AppStateTestEnvironment) async throws -> T
) async throws -> T
```

The helper:

1. creates a unique temporary root,
2. builds an `AppStateStorageLayout`,
3. builds dependencies using that layout,
4. temporarily redirects `AppSettingsStorage.storageDirectoryOverride`,
5. passes the environment to the test,
6. restores the settings override and deletes the temporary root.

`AppSettingsStorage.storageDirectoryOverride` remains temporarily global because credential storage is explicitly outside this PR. It is the only storage test global retained by this helper.

### MeetingSummaryAppStateTests

Migrate generator and history-store setup to dependencies supplied during `AppState` creation.

Tests that need a controlled generator create the generator before the `AppState`, then pass it through `makeMeetingSummaryGenerator`. Helpers such as `configuredAppState` and `configuredPersistedAppState` accept or construct dependencies rather than assigning class properties.

The suite’s outer save/restore block for the selected static seams is removed.

### AppStateStorageSafetyTests

Pass unavailable, fallback, archived, and replacement stores through the dependencies for each `AppState` instance. Use environment storage-layout paths rather than `AppState.audioStorageDirectory()` and related class helpers.

Archive tests verify that the instance factory creates and installs the replacement store.

### AppStateTranscriptionConfigurationTests

Only history/retry cases using the selected seams migrate in this PR. Tests using audio-import cloud dependencies or post-processing transport continue to use their existing seams.

For migrated retry cases:

- history store comes from instance dependencies,
- retry cloud dependencies come from instance dependencies,
- audio paths come from the test environment’s layout.

### Source-contract tests

Do not broadly replace source-string tests in this PR.

Update `AppStateHistoryProtectionSourceTests` only where it asserts the removed store factory name. Its order and guard assertions continue to require that:

- archive work captures the instance store factory,
- replacement stores are created through `dependencies.makePipelineHistoryStore`,
- snapshot-only recovery failure does not replace the active store.

Behavior-test conversion of these source contracts remains a separate follow-up project.

## Error Handling

This refactoring does not create a new error model.

Preserve:

- directory preparation using existing `try?` behavior,
- `PipelineHistoryStore` availability and durability states,
- archive/recovery verification and fallback behavior,
- current history-unavailable messages,
- meeting-summary issue classification and persistence,
- cloud retry issue classification and fallback,
- current file cleanup semantics.

The refactoring changes dependency ownership, not error interpretation.

Throwing storage-layout preparation, typed credential failures, and `NoteAssetStore` belong to later PRs.

## Concurrency and Lifetime

- Each `AppState` stores an immutable dependency value.
- Dependency factories captured by `Task.detached` must be `@Sendable`.
- Tests configure dependencies before creating the `AppState`; they do not mutate captured shared variables unless their existing harness explicitly synchronizes access.
- Meeting-summary generator creation remains Main Actor-isolated.
- A factory must not capture an `AppState` strongly unless the current call path already requires it; the live summary factory receives the instance as an argument instead.
- No process-global dependency reset is needed.

## Verification

### New behavior tests

Add focused tests proving:

1. two `AppState` instances with different layouts load different history stores,
2. two instances use their own meeting-summary generators,
3. retry dependencies are isolated per instance,
4. archive replacement uses the originating instance’s history-store factory,
5. default `AppState()` resolves the existing live storage layout,
6. changing a test dependency value after one instance is created does not alter that instance.

### Static seam removal checks

The selected identifiers must no longer appear as mutable `AppState` properties:

- `meetingSummaryGeneratorFactory`
- `storageRootProvider`
- `pipelineHistoryStoreFactory`
- `pipelineHistoryStoreAtURLFactory`
- `retryCloudTranscriptionDependenciesFactory`

Tests must not save, assign, or restore those class properties.

### Test suites

Run at minimum:

- `MeetingSummaryAppStateTests`
- `AppStateStorageSafetyTests`
- `AppStateTranscriptionConfigurationTests`
- `AppStateHistoryProtectionSourceTests`
- grouped app-state runner
- `make check-test-wiring`
- `make test`

### Completion criteria

The work is complete when:

- all listed tests pass,
- full `make test` passes,
- production `AppState()` remains source-compatible,
- persisted paths and file names remain identical,
- archive/recovery ordering and guards remain intact,
- the five selected static mutable seams are gone,
- History + Summary tests no longer mutate those seams,
- no unrelated static seam or workflow is refactored,
- PR B contains only commits after the PR A base when finally opened.

## Follow-up Sequence

After PR B, proceed with separate projects rather than expanding this PR:

1. convert source-string history tests to behavioral collaborators,
2. introduce throwing storage and credential boundaries,
3. migrate Local AI and model installer dependencies,
4. extract history, retry, and summary workflows from `AppState`,
5. split the remaining `AppState` file by stable responsibility.
