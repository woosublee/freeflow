import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct CredentialStoreTests {
    static func main() throws {
        try testSaveAndLoadRoundTrips()
        try testLoadReturnsNilForMissingAccount()
        try testDeleteIsIdempotentForMissingAccount()
        try testDeleteRemovesAnExistingValue()
        try testSaveOverwritesAnExistingValue()
        try testTwoStoresWithIndependentLayoutsDoNotShareValues()
        try testSaveThrowsWhenDirectoryIsUnavailable()
        try testDeleteThrowsWhenDirectoryIsUnavailable()
        try testSettingsFileHasOwnerOnlyPermissions()
        print("CredentialStoreTests passed")
    }

    private static func testSaveAndLoadRoundTrips() throws {
        try withTemporaryStore { store in
            try store.save("secret-value", account: "test_account")
            let loaded = store.load(account: "test_account")
            try expect(loaded == "secret-value", "loaded value matches the saved value")
        }
    }

    private static func testLoadReturnsNilForMissingAccount() throws {
        try withTemporaryStore { store in
            try expect(
                store.load(account: "missing-\(UUID().uuidString)") == nil,
                "loading an account that was never saved returns nil"
            )
        }
    }

    private static func testDeleteIsIdempotentForMissingAccount() throws {
        try withTemporaryStore { store in
            try store.delete(account: "missing-\(UUID().uuidString)")
        }
    }

    private static func testDeleteRemovesAnExistingValue() throws {
        try withTemporaryStore { store in
            try store.save("to-delete", account: "deletable_account")
            try store.delete(account: "deletable_account")
            try expect(
                store.load(account: "deletable_account") == nil,
                "a deleted account is no longer readable"
            )
        }
    }

    private static func testSaveOverwritesAnExistingValue() throws {
        try withTemporaryStore { store in
            try store.save("first-value", account: "overwritable_account")
            try store.save("second-value", account: "overwritable_account")
            try expect(
                store.load(account: "overwritable_account") == "second-value",
                "saving again overwrites the previous value"
            )
        }
    }

    private static func testTwoStoresWithIndependentLayoutsDoNotShareValues() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-independent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStore = CredentialStore(
            layout: CredentialStorageLayout(
                directory: parent.appendingPathComponent("first", isDirectory: true)
            )
        )
        let secondStore = CredentialStore(
            layout: CredentialStorageLayout(
                directory: parent.appendingPathComponent("second", isDirectory: true)
            )
        )

        try firstStore.save("first-store-value", account: "shared_account_name")
        try secondStore.save("second-store-value", account: "shared_account_name")

        try expect(
            firstStore.load(account: "shared_account_name") == "first-store-value",
            "the first store keeps its own value"
        )
        try expect(
            secondStore.load(account: "shared_account_name") == "second-store-value",
            "the second store keeps its own value independent of the first"
        )
    }

    private static func testSaveThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings-dir", isDirectory: true)
        // Create a plain file where the settings directory should be, so
        // FileManager cannot create it and any write into it fails.
        try Data().write(to: directory)
        let store = CredentialStore(layout: CredentialStorageLayout(directory: directory))

        do {
            try store.save("unwritable", account: "blocked_account")
            throw TestFailure("expected save to throw when its directory cannot be created")
        } catch is CredentialStoreError {
            // expected
        }
    }

    private static func testDeleteThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-blocked-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("settings-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CredentialStore(layout: CredentialStorageLayout(directory: directory))
        try store.save("value", account: "account_to_block")

        // Replace the writable directory with a read-only one so the
        // subsequent rewrite (delete is implemented as a rewrite of the
        // settings dictionary) fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try store.delete(account: "account_to_block")
            throw TestFailure("expected delete to throw when its directory cannot be written")
        } catch is CredentialStoreError {
            // expected
        }
    }

    private static func testSettingsFileHasOwnerOnlyPermissions() throws {
        try withTemporaryStore { store in
            try store.save("permission-checked-value", account: "permission_account")
            let url = store.layout.directory.appendingPathComponent(".settings")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try expect(
                permissions == 0o600,
                "the settings file is restricted to owner-only read/write"
            )
        }
    }

    private static func withTemporaryStore(
        _ operation: (CredentialStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialStore(layout: CredentialStorageLayout(directory: root))
        try operation(store)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
