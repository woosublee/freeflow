import Foundation

@main
struct UpdateSnapshotStoreTests {
    static func main() {
        testSavesAndLoadsNewerSnapshot()
        testClearsInstalledSnapshot()
        testClearsSkippedSnapshot()
        testClearsSnapshotBelowSkippedMinorCeiling()
        testClearsSkippedMajorUpgradeSnapshot()
        testRestoresMajorUpgradeWhenCurrentBuildPassesSkippedMajorVersion()
        testRestoresMajorUpgradeWhenIgnoreThresholdExceedsSkippedSubrelease()
        testPreservesSnapshotWhenCurrentBuildIsUnavailable()
        testRemovesCorruptSnapshot()
        testRemovesSnapshotWithUnexpectedDefaultsType()
        print("UpdateSnapshotStoreTests passed")
    }

    private static func testSavesAndLoadsNewerSnapshot() {
        withStore { _, store in
            let snapshot = PersistedUpdateSnapshot(
                buildVersion: "32",
                displayVersion: "0.1.29",
                releaseDate: Date(timeIntervalSince1970: 1_700_000_000),
                releaseNotesURL: URL(string: "https://github.com/woosublee/quill/releases/tag/v0.1.29"),
                minimumAutoupdateVersion: nil,
                ignoreSkippedUpgradesBelowVersion: nil
            )

            store.save(snapshot)
            let restored = store.restorableSnapshot(
                currentBuildVersion: "31",
                skippedUpdate: .none,
                isNewer: numericIsNewer
            )

            precondition(restored == snapshot)
        }
    }

    private static func testClearsInstalledSnapshot() {
        withStore { defaults, store in
            store.save(snapshot(build: "31"))

            let restored = store.restorableSnapshot(
                currentBuildVersion: "31",
                skippedUpdate: .none,
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static func testClearsSkippedSnapshot() {
        withStore { defaults, store in
            store.save(snapshot(build: "32"))

            let restored = store.restorableSnapshot(
                currentBuildVersion: "31",
                skippedUpdate: PersistedSkippedUpdate(minorVersion: "32"),
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static func testClearsSnapshotBelowSkippedMinorCeiling() {
        withStore { defaults, store in
            store.save(snapshot(build: "31"))

            let restored = store.restorableSnapshot(
                currentBuildVersion: "30",
                skippedUpdate: PersistedSkippedUpdate(minorVersion: "32"),
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static func testClearsSkippedMajorUpgradeSnapshot() {
        withStore { defaults, store in
            store.save(
                snapshot(
                    build: "40",
                    minimumAutoupdateVersion: "35"
                )
            )

            let restored = store.restorableSnapshot(
                currentBuildVersion: "30",
                skippedUpdate: PersistedSkippedUpdate(
                    majorVersion: "35",
                    majorSubreleaseVersion: "40"
                ),
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static func testRestoresMajorUpgradeWhenCurrentBuildPassesSkippedMajorVersion() {
        withStore { _, store in
            let expected = snapshot(
                build: "40",
                minimumAutoupdateVersion: "35"
            )
            store.save(expected)

            let restored = store.restorableSnapshot(
                currentBuildVersion: "36",
                skippedUpdate: PersistedSkippedUpdate(
                    majorVersion: "35",
                    majorSubreleaseVersion: "40"
                ),
                isNewer: numericIsNewer
            )

            precondition(restored == expected)
        }
    }

    private static func testRestoresMajorUpgradeWhenIgnoreThresholdExceedsSkippedSubrelease() {
        withStore { _, store in
            let expected = snapshot(
                build: "42",
                minimumAutoupdateVersion: "35",
                ignoreSkippedUpgradesBelowVersion: "41"
            )
            store.save(expected)

            let restored = store.restorableSnapshot(
                currentBuildVersion: "30",
                skippedUpdate: PersistedSkippedUpdate(
                    majorVersion: "35",
                    majorSubreleaseVersion: "40"
                ),
                isNewer: numericIsNewer
            )

            precondition(restored == expected)
        }
    }

    private static func testPreservesSnapshotWhenCurrentBuildIsUnavailable() {
        withStore { defaults, store in
            store.save(snapshot(build: "32"))

            let restored = store.restorableSnapshot(
                currentBuildVersion: nil,
                skippedUpdate: .none,
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) != nil)
        }
    }

    private static func testRemovesCorruptSnapshot() {
        withStore { defaults, store in
            defaults.set(Data("not-json".utf8), forKey: UpdateSnapshotStore.defaultStorageKey)

            let restored = store.restorableSnapshot(
                currentBuildVersion: "31",
                skippedUpdate: .none,
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.data(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static func testRemovesSnapshotWithUnexpectedDefaultsType() {
        withStore { defaults, store in
            defaults.set("not-data", forKey: UpdateSnapshotStore.defaultStorageKey)

            let restored = store.restorableSnapshot(
                currentBuildVersion: "31",
                skippedUpdate: .none,
                isNewer: numericIsNewer
            )

            precondition(restored == nil)
            precondition(defaults.object(forKey: UpdateSnapshotStore.defaultStorageKey) == nil)
        }
    }

    private static let numericIsNewer: (String, String) -> Bool = {
        guard let candidate = Int($0), let current = Int($1) else { return false }
        return candidate > current
    }

    private static func snapshot(
        build: String,
        minimumAutoupdateVersion: String? = nil,
        ignoreSkippedUpgradesBelowVersion: String? = nil
    ) -> PersistedUpdateSnapshot {
        PersistedUpdateSnapshot(
            buildVersion: build,
            displayVersion: "0.1.29",
            releaseDate: nil,
            releaseNotesURL: nil,
            minimumAutoupdateVersion: minimumAutoupdateVersion,
            ignoreSkippedUpgradesBelowVersion: ignoreSkippedUpgradesBelowVersion
        )
    }

    private static func withStore(
        _ body: (UserDefaults, UpdateSnapshotStore) -> Void
    ) {
        let suiteName = "UpdateSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults, UpdateSnapshotStore(userDefaults: defaults))
    }
}
