import Foundation

enum CredentialStoreError: LocalizedError {
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            underlying.localizedDescription
        }
    }
}

/// A focused, instance-owned boundary over the on-disk credential/settings
/// file `AppSettingsStorage` also reads and writes.
///
/// `AppSettingsStorage.storageDirectoryOverride` remains in place as a
/// transitional bridge: `CredentialStorageLayout.live` still consults it so
/// the many existing tests in `AppStateTranscriptionConfigurationTests` and
/// `AppStateAIProcessingBackendTests` that redirect it before constructing a
/// bare `AppState()` keep working unchanged. Those two suites construct
/// `AppState()` at roughly 150 call sites relying on that global today;
/// migrating all of them to inject `credentialStorageLayout` explicitly is a
/// materially larger, separate effort tracked as a follow-up rather than
/// folded into this PR. Production code (`AppState`) no longer reads
/// `AppSettingsStorage` directly — it goes through this type.
struct CredentialStorageLayout: Sendable {
    let directory: URL

    static var live: CredentialStorageLayout {
        CredentialStorageLayout(
            directory: AppSettingsStorage.storageDirectoryOverride
                ?? AppSettingsStorage.defaultStorageDirectory
        )
    }
}

struct CredentialStore: Sendable {
    let layout: CredentialStorageLayout

    private var settingsFileURL: URL {
        layout.directory.appendingPathComponent(".settings")
    }

    func load(account: String) -> String? {
        loadSettings()[account]
    }

    func save(_ value: String, account: String) throws {
        var dict = loadSettings()
        dict[account] = value
        try writeSettings(dict)
    }

    func delete(account: String) throws {
        var dict = loadSettings()
        dict.removeValue(forKey: account)
        try writeSettings(dict)
    }

    private func prepareDirectory() {
        let directory = layout.directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func loadSettings() -> [String: String] {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeSettings(_ dict: [String: String]) throws {
        prepareDirectory()
        let url = settingsFileURL
        do {
            let data = try JSONEncoder().encode(dict)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CredentialStoreError.writeFailed(underlying: error)
        }
        // Restrict to owner-only read/write (0600). Best-effort: the value
        // is already durably written above, so a permission-hardening
        // failure here must not be reported as a write failure.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
