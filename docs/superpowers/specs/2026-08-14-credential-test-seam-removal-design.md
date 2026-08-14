# Credential Test Seam Removal Design

## Summary

Issue #326 removes the last process-global credential-storage override from Quill. Production `AppState` already receives an instance-owned `CredentialStorageLayout`, but two large AppState test suites and the shared `AppStateTestStorage` helper still redirect `AppSettingsStorage.storageDirectoryOverride` so their default dependency values point at temporary `.settings` files.

The migration will replace that mutable override with immutable, suite-owned credential layouts that are copied into each `AppStateDependencies` value before `AppState` construction. Tests will write fixture credentials through `CredentialStore` using the same explicit layout. Once no caller depends on the bridge, `CredentialStorageLayout.live` will use `AppName.applicationSupportDirectory` directly and the legacy `AppSettingsStorage` type will be removed.

This is behavior-preserving internal work. Credential account names, `.settings` format and permissions, provider selection, and user-facing behavior do not change.

## Current State

`CredentialStore` owns all production credential file I/O. The remaining global seam is structural:

- `CredentialStorageLayout.live` checks `AppSettingsStorage.storageDirectoryOverride` before the production Application Support directory.
- `AppStateAIProcessingBackendTests` sets one override in `main()` and restores it after the suite.
- `AppStateTranscriptionConfigurationTests.resetDefaults()` creates a new override directory and deletes fixture accounts through the legacy static API.
- `AppStateTestStorage.withIsolatedStorage` sets and restores the override even though it already places an explicit `credentialStorageLayout` in `environment.dependencies`.
- Seven test fixture writes/deletes still call `AppSettingsStorage.save` or `AppSettingsStorage.delete`.
- Most of the roughly 161 `AppState` constructions in the two large suites already flow through `makeAppState`, `transcriptionTestDependencies`, `makeRefreshedAppState`, or `modelTestDependencies`; only a limited set constructs `AppState(dependencies:)` directly.

The issue description predates some dependency-helper consolidation. The implementation therefore does not need to mechanically add a credential argument to every AppState construction. It can migrate the common factories and audit the direct exceptions.

## Approaches Considered

### 1. Immutable suite-owned credential layouts through existing dependency factories — recommended

Each suite owns one unique temporary `CredentialStorageLayout` as an immutable static value. Its dependency factory copies that layout into `AppStateDependencies`. Reset helpers clear the suite directory, and credential fixtures use `CredentialStore(layout:)` directly.

This removes mutable process-global routing while reusing the suite helpers that already centralize most AppState construction. The suites execute serially in the grouped runner, and each receives a distinct UUID-named directory, so they remain isolated from one another.

### 2. Return a new credential layout from every reset and thread it through every test

This provides per-test path identity but requires modifying most of the 161 AppState construction paths and every test that stores credentials. The additional churn does not improve observable isolation because the suites already reset their credential directories between tests and execute serially.

### 3. Introduce a new mutable test-global “current credential layout”

This would minimize edits but reproduce the same hidden routing problem under a different name. It is rejected.

## Architecture

### Production layout

`CredentialStorageLayout.live` will become:

```swift
static var live: CredentialStorageLayout {
    CredentialStorageLayout(
        directory: AppName.applicationSupportDirectory
    )
}
```

This preserves the exact current production path: the user Application Support directory plus `AppName.displayName`.

`CredentialStore` remains the only credential filesystem boundary. No compatibility shim, service locator, environment override, or alternate settings format is introduced.

When all references are gone, `Sources/KeychainStorage.swift` and its `AppSettingsStorage` delegating type are deleted.

### Transcription configuration suite

`AppStateTranscriptionConfigurationTests` will define one immutable UUID-named suite layout and a matching store helper:

```swift
private static let credentialStorageLayout = CredentialStorageLayout(
    directory: FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "quill-app-state-transcription-credentials-\(UUID().uuidString)",
            isDirectory: true
        )
)

private static var credentialStore: CredentialStore {
    CredentialStore(layout: credentialStorageLayout)
}
```

`transcriptionTestDependencies(from:status:)` will always assign `dependencies.credentialStorageLayout = credentialStorageLayout`. The default `makeAppState()` path therefore remains concise while passing an explicit layout.

`resetDefaults()` will remove the suite credential directory and clear `UserDefaults`; it will no longer mutate a process-global override. Tests that save credentials will call the suite `CredentialStore`.

Direct `AppState(dependencies:)` constructions will be classified:

- dependencies created by `transcriptionTestDependencies` already carry the suite layout,
- dependencies supplied by `AppStateTestStorage` keep that environment’s explicit layout,
- dependencies created directly from `.live` will be normalized to the suite layout before construction.

### AI processing backend suite

`AppStateAIProcessingBackendTests` will use its own immutable UUID-named suite layout. `modelTestDependencies()` will assign it, and credential fixture calls will use the suite `CredentialStore`.

The suite-level mutable override setup and restoration in `main()` will be removed. `main()` will instead remove the suite credential directory on entry and exit.

`makeRefreshedAppState(dependencies:)` and direct AppState construction sites will be audited so every dependency value has an explicit layout. Tests that intentionally compare two AppState instances may share the immutable suite layout because credential isolation is not their subject; tests that already provide an isolated environment retain that environment’s layout.

### Shared AppState test storage

`AppStateTestStorage.withIsolatedStorage` already creates a settings directory and assigns it to `dependencies.credentialStorageLayout`. It will stop setting and restoring `AppSettingsStorage.storageDirectoryOverride`.

This leaves the helper fully instance-owned: the operation receives all storage roots through `AppStateTestEnvironment.dependencies`.

## Data Flow

### Test setup

```text
suite immutable CredentialStorageLayout
  → dependency factory copies layout into AppStateDependencies
  → AppState(dependencies:) constructs its CredentialStore from that layout
  → fixture credential writes use CredentialStore with the same layout
```

No later reset, another suite, or another AppState instance can redirect an already-created dependency value.

### Production setup

```text
AppStateDependencies.live
  → CredentialStorageLayout.live
  → AppName.applicationSupportDirectory
  → CredentialStore reads/writes the existing .settings file
```

The on-disk location and file content remain unchanged.

## Error Handling and Safety

- Fixture directory removal remains best-effort, matching current reset behavior.
- Credential writes continue to use the throwing `CredentialStore.save`; tests may use `try` or explicit failure handling rather than silently redirecting through a static wrapper.
- Production save/delete behavior and user issue handling do not change.
- API keys and credential values remain runtime-only and are not added to logs, diagnostics, history, cloud jobs, or test failure messages.
- No test may obtain credentials from `CredentialStorageLayout.live`; every test AppState receives an explicit temporary layout.
- Direct dependency construction is audited to prevent the mismatch previously found between fixture-write layout and AppState-read layout.

## Testing Strategy

### Characterization and regression coverage

- Keep existing `CredentialStoreTests` for round trips, permissions, deletion, and independent layouts.
- Add or retain a focused assertion that `CredentialStorageLayout.live.directory` equals `AppName.applicationSupportDirectory`.
- Extend dependency tests where useful to prove copied `AppStateDependencies` retain their explicit credential layout.
- Run both full-source AppState suites after each migration stage.

### Removal guard

After migration, repository searches must return no `AppSettingsStorage` or `storageDirectoryOverride` references:

```bash
rg -n "AppSettingsStorage|storageDirectoryOverride" Sources Tests
```

A narrow structural guard may be retained for this removed global seam because its absence, rather than a runtime output, is the requirement. Behavioral credential coverage remains authoritative for file operations and isolation.

### Required verification

```bash
make --no-print-directory _test-transcription
make check-test-wiring
make test
make all BUILD_DIR=/tmp/quill-issue326-build CODESIGN_IDENTITY=Quill
codesign --verify --deep --strict /tmp/quill-issue326-build/Quill.app
```

The local `/code-review` runs exactly once at medium effort after the branch is fully green.

## Migration Order

1. Add immutable credential layouts and explicit fixture stores to the two suites.
2. Update dependency factories and the limited direct AppState construction exceptions.
3. Replace legacy static fixture writes/deletes.
4. Remove override setup from `AppStateTestStorage`.
5. Change `CredentialStorageLayout.live` to the production Application Support path directly.
6. Delete `AppSettingsStorage` and `Sources/KeychainStorage.swift` after a repository-wide reference scan.
7. Run focused, full, build, signing, and review verification.

## Non-goals

- No credential account rename or provider-selection change.
- No `.settings` schema, location, permissions, or migration change.
- No unrelated `UserDefaults` reset cleanup.
- No per-test dependency container redesign.
- No Keychain migration despite the legacy source filename.
- No general AppState workflow extraction or file split.

## Acceptance Criteria

- Neither large AppState suite assigns or restores a process-global credential directory override.
- Every AppState created by those suites receives an explicit `credentialStorageLayout`.
- Fixture credential writes and reads use the same explicit layout.
- `AppStateTestStorage` relies only on its dependency value.
- `CredentialStorageLayout.live` uses the unchanged production Application Support directory directly.
- `AppSettingsStorage`, `storageDirectoryOverride`, and `Sources/KeychainStorage.swift` are removed with no remaining references.
- Existing credential behavior and all suite coverage remain passing.
- Full tests and the signed production build pass.
