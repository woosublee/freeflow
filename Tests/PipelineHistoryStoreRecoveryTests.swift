import CoreData
import Foundation

@main
struct PipelineHistoryStoreRecoveryTests {
    static func main() throws {
        try testRecoveryMovesAllSQLiteComponentsBeforeLoadingReplacementStore()
        try testFailedBackupKeepsRemainingOriginalFilesAndUsesInMemoryStore()
        print("PipelineHistoryStoreRecoveryTests passed")
    }

    private static func testRecoveryMovesAllSQLiteComponentsBeforeLoadingReplacementStore() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        var loadAttempts = 0
        var sourceFilesAtBackupStart: Set<String> = []

        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            persistentStoreLoader: { container in
                loadAttempts += 1
                if loadAttempts == 1 {
                    return RecoveryTestFailure("Injected persistent-store load failure")
                }
                return PipelineHistoryStore.loadPersistentStoresSynchronously(
                    container: container
                )
            },
            moveItem: { sourceURL, destinationURL in
                if sourceFilesAtBackupStart.isEmpty {
                    sourceFilesAtBackupStart = Set(
                        fixture.componentURLs.filter {
                            FileManager.default.fileExists(atPath: $0.path)
                        }.map(\.lastPathComponent)
                    )
                }
                try FileManager.default.moveItem(
                    at: sourceURL,
                    to: destinationURL
                )
            }
        )

        guard case let .recovered(backupName) = store.durability else {
            throw RecoveryTestFailure("Persistent recovery exposes its backup state")
        }
        let backupURL = fixture.recoveryRootURL.appendingPathComponent(
            backupName,
            isDirectory: true
        )

        let backupContents = Set(try FileManager.default.contentsOfDirectory(
            atPath: backupURL.path
        ))
        try expect(
            backupContents == Set(fixture.componentURLs.map(\.lastPathComponent)),
            "failed store is backed up together"
        )
        try expect(
            sourceFilesAtBackupStart == Set(fixture.componentURLs.map(\.lastPathComponent)),
            "recovery never destroys originals first"
        )
        try expect(store.durability != .durable, "fallback state is observable")
    }

    private static func testFailedBackupKeepsRemainingOriginalFilesAndUsesInMemoryStore() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        var loadAttempts = 0

        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            persistentStoreLoader: { container in
                loadAttempts += 1
                if loadAttempts == 1 {
                    return RecoveryTestFailure("Injected persistent-store load failure")
                }
                return PipelineHistoryStore.loadPersistentStoresSynchronously(
                    container: container
                )
            },
            moveItem: { sourceURL, destinationURL in
                if sourceURL.lastPathComponent.hasSuffix("-wal") {
                    throw RecoveryTestFailure("Injected backup move failure")
                }
                try FileManager.default.moveItem(
                    at: sourceURL,
                    to: destinationURL
                )
            }
        )

        try expect(
            store.durability == .inMemoryFallback,
            "failed backup uses observable in-memory fallback"
        )
        try expect(
            FileManager.default.fileExists(
                atPath: fixture.componentURLs[1].path
            ),
            "failed move leaves the WAL original intact"
        )
        try expect(
            FileManager.default.fileExists(
                atPath: fixture.componentURLs[2].path
            ),
            "failed move leaves the SHM original intact"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw RecoveryTestFailure(label) }
    }
}

private final class StoreFixture {
    let directoryURL: URL
    let storeURL: URL

    var recoveryRootURL: URL {
        directoryURL.appendingPathComponent("History Recovery", isDirectory: true)
    }

    var componentURLs: [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        for (index, componentURL) in componentURLs.enumerated() {
            try Data("component-\(index)".utf8).write(to: componentURL)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct RecoveryTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
