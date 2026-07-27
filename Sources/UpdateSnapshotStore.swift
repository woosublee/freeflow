import Foundation

struct PersistedUpdateSnapshot: Codable, Equatable {
    let buildVersion: String
    let displayVersion: String
    let releaseDate: Date?
    let releaseNotesURL: URL?
    let minimumAutoupdateVersion: String?
    let ignoreSkippedUpgradesBelowVersion: String?
}

struct PersistedSkippedUpdate {
    static let none = PersistedSkippedUpdate()

    let minorVersion: String?
    let majorVersion: String?
    let majorSubreleaseVersion: String?

    init(
        minorVersion: String? = nil,
        majorVersion: String? = nil,
        majorSubreleaseVersion: String? = nil
    ) {
        self.minorVersion = minorVersion
        self.majorVersion = majorVersion
        self.majorSubreleaseVersion = majorSubreleaseVersion
    }
}

struct UpdateSnapshotStore {
    static let defaultStorageKey = "updateAvailableSnapshot"

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func save(_ snapshot: PersistedUpdateSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func clear() {
        userDefaults.removeObject(forKey: storageKey)
    }

    func restorableSnapshot(
        currentBuildVersion: String?,
        skippedUpdate: PersistedSkippedUpdate,
        isNewer: (String, String) -> Bool
    ) -> PersistedUpdateSnapshot? {
        guard userDefaults.object(forKey: storageKey) != nil else { return nil }
        guard let data = userDefaults.data(forKey: storageKey) else {
            clear()
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(PersistedUpdateSnapshot.self, from: data) else {
            clear()
            return nil
        }
        guard let currentBuildVersion else { return nil }
        guard isNewer(snapshot.buildVersion, currentBuildVersion),
              !isSkipped(
                  snapshot,
                  currentBuildVersion: currentBuildVersion,
                  skippedUpdate: skippedUpdate,
                  isNewer: isNewer
              ) else {
            clear()
            return nil
        }
        return snapshot
    }

    private func isSkipped(
        _ snapshot: PersistedUpdateSnapshot,
        currentBuildVersion: String,
        skippedUpdate: PersistedSkippedUpdate,
        isNewer: (String, String) -> Bool
    ) -> Bool {
        if let skippedMinorVersion = skippedUpdate.minorVersion,
           !isNewer(snapshot.buildVersion, skippedMinorVersion) {
            return true
        }

        guard let skippedMajorVersion = skippedUpdate.majorVersion,
              let minimumAutoupdateVersion = snapshot.minimumAutoupdateVersion,
              isNewer(skippedMajorVersion, currentBuildVersion),
              !isNewer(minimumAutoupdateVersion, skippedMajorVersion) else {
            return false
        }

        guard let ignoreThreshold = snapshot.ignoreSkippedUpgradesBelowVersion else {
            return true
        }
        guard let skippedSubreleaseVersion = skippedUpdate.majorSubreleaseVersion else {
            return false
        }
        return !isNewer(ignoreThreshold, skippedSubreleaseVersion)
    }
}
