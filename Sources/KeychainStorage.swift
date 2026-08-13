import Foundation

/// Legacy static entry point, kept only so the ~150 existing call sites in
/// `AppStateTranscriptionConfigurationTests` and `AppStateAIProcessingBackendTests`
/// that redirect `storageDirectoryOverride` before constructing a bare
/// `AppState()` keep working unchanged (see `CredentialStorageLayout.live`'s
/// doc comment in `CredentialStore.swift`). All file I/O now lives in
/// `CredentialStore`; this type only owns the override and delegates to it.
enum AppSettingsStorage {
    static var storageDirectoryOverride: URL?

    static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppName.displayName, isDirectory: true)
    }

    static func load(account: String) -> String? {
        CredentialStore(layout: .live).load(account: account)
    }

    static func save(_ value: String, account: String) {
        try? CredentialStore(layout: .live).save(value, account: account)
    }

    static func delete(account: String) {
        try? CredentialStore(layout: .live).delete(account: account)
    }
}
