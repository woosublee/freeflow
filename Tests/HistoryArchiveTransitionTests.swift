import CoreData
import Foundation

@main
struct HistoryArchiveTransitionTests {
    static func main() throws {
        try testArchiveMovesAnEntireGenerationAndCreatesAnEmptyDurableStore()
        try testArchiveAcceptsMissingSQLiteCompanions()
        try testFreshStoreProbeFailureRollsBackTheOriginalGeneration()
        try testFirstMoveFailurePreservesTheOriginalSQLite()
        try testMoveFailureRollsBackEveryMovedComponent()
        try testPublishSyncFailureLeavesTransactionForSafeStartupRecovery()
        try testInterruptedTransactionRollsBackWithoutCreatingFreshHistory()
        try testAbandonedTransactionTempFileDoesNotBlockStartup()
        print("HistoryArchiveTransitionTests passed")
    }

    private static func testArchiveMovesAnEntireGenerationAndCreatesAnEmptyDurableStore() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }

        let archiveID = UUID(uuidString: "A3E4BA14-2F2E-4724-BFCF-1F8F1667E577")!
        let archiveDate = Date(timeIntervalSince1970: 1_754_010_203)
        let transition = HistoryArchiveTransition(
            now: { archiveDate },
            makeID: { archiveID }
        )

        let result = try transition.archiveAndCreateFreshHistory(at: fixture.rootURL)
        let snapshotDirectory = fixture.rootURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "history-20250801T010323Z-\(archiveID.uuidString.lowercased())",
                isDirectory: true
            )
        let payloadURL = snapshotDirectory.appendingPathComponent("payload", isDirectory: true)

        try expect(result.snapshot.id == archiveID, "archive reports the published snapshot")
        try expect(
            FileManager.default.fileExists(atPath: snapshotDirectory.path),
            "archive publishes a recovery snapshot"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.audioDirectory.path),
            "old audio generation is removed from the active root"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.transcriptsDirectory.path),
            "old transcript generation is removed from the active root"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.cloudJobsDirectory.path),
            "old cloud job generation is removed from the active root"
        )
        try expect(
            try Data(contentsOf: payloadURL.appendingPathComponent("PipelineHistory.sqlite"))
                == fixture.sqliteBytes,
            "archive preserves the original SQLite bytes"
        )
        try expect(
            try Data(contentsOf: payloadURL.appendingPathComponent("PipelineHistory.sqlite-wal"))
                == fixture.walBytes,
            "archive preserves the original WAL bytes"
        )
        try expect(
            try Data(contentsOf: payloadURL.appendingPathComponent("PipelineHistory.sqlite-shm"))
                == fixture.shmBytes,
            "archive preserves the original SHM bytes"
        )
        try expect(
            try Data(contentsOf: payloadURL
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent("inflight", isDirectory: true)
                .appendingPathComponent("recording", isDirectory: true)
                .appendingPathComponent("manifest.json")) == fixture.inflightBytes,
            "archive preserves inflight recording journals"
        )
        try expect(
            try Data(contentsOf: payloadURL
                .appendingPathComponent("transcripts", isDirectory: true)
                .appendingPathComponent("note.txt")) == fixture.transcriptBytes,
            "archive preserves transcript content outside the manifest"
        )
        try expect(
            try Data(contentsOf: payloadURL
                .appendingPathComponent("cloud-transcription/jobs", isDirectory: true)
                .appendingPathComponent("job.json")) == fixture.cloudJobBytes,
            "archive preserves cloud job sidecars"
        )
        try expect(
            FileManager.default.fileExists(atPath: payloadURL
                .appendingPathComponent("History Recovery", isDirectory: true)
                .appendingPathComponent("asset-references-incomplete", isDirectory: true)
                .path),
            "archive preserves legacy recovery evidence"
        )

        let manifestURL = snapshotDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(HistoryArchiveSnapshot.self, from: manifestData)
        try expect(manifest.id == archiveID, "manifest identifies the published archive")
        let expectedAudioByteCount = UInt64(
            Data("audio".utf8).count + fixture.inflightBytes.count
        )
        try expect(
            manifest.components.first(where: { $0.identifier == .audio })?.byteCount
                == expectedAudioByteCount,
            "manifest recursively records every archived audio byte"
        )
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        try expect(
            !manifestText.contains("Transcript content must not appear in metadata"),
            "manifest excludes transcript content"
        )
        try expect(
            !manifestText.contains("Bearer secret-token"),
            "manifest excludes cloud authorization content"
        )
        try expect(
            !manifestText.contains(fixture.rootURL.path),
            "manifest excludes absolute paths"
        )

        let freshStore = PipelineHistoryStore(storeURL: fixture.storeURL)
        try expect(
            freshStore.referenceTrust == .recovered,
            "active store recognizes the published archive as unresolved history"
        )
        try expect(freshStore.availability == .ready, "fresh active history is readable")
        try expect(freshStore.durability == .durable, "fresh active history is durable")
        try expect(freshStore.loadAllHistory().isEmpty, "fresh active history has no probe records")
    }

    private static func testArchiveAcceptsMissingSQLiteCompanions() throws {
        let fixture = try HistoryArchiveFixture(includesSQLiteCompanions: false)
        defer { fixture.remove() }

        let result = try HistoryArchiveTransition().archiveAndCreateFreshHistory(at: fixture.rootURL)
        let componentIDs = Set(result.snapshot.components.map(\.identifier))
        let snapshotURL = try FileManager.default.contentsOfDirectory(
            at: result.recoveryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first { $0.lastPathComponent.hasPrefix("history-") }
        guard let snapshotURL else {
            throw HistoryArchiveTestFailure("missing published snapshot for companion test")
        }
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)

        try expect(
            !componentIDs.contains(.sqliteWAL) && !componentIDs.contains(.sqliteSHM),
            "archive omits absent SQLite companions from its manifest"
        )
        try expect(
            !FileManager.default.fileExists(atPath: payloadURL
                .appendingPathComponent("PipelineHistory.sqlite-wal").path),
            "archive does not fabricate a missing WAL payload"
        )
        try expect(
            !FileManager.default.fileExists(atPath: payloadURL
                .appendingPathComponent("PipelineHistory.sqlite-shm").path),
            "archive does not fabricate a missing SHM payload"
        )
    }

    private static func testInterruptedTransactionRollsBackWithoutCreatingFreshHistory() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }

        let transactionID = UUID(uuidString: "730D385C-4EF4-4541-868B-18CA6D7B6F87")!
        let recoveryDirectory = fixture.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        let stagingName = ".staging-\(transactionID.uuidString.lowercased())"
        let stagingPayload = recoveryDirectory
            .appendingPathComponent(stagingName, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingPayload, withIntermediateDirectories: true)
        try fixture.sqliteBytes.write(to: stagingPayload.appendingPathComponent("PipelineHistory.sqlite"))
        try Data("fresh history that must be removed".utf8).write(to: fixture.storeURL)

        var transaction = HistoryArchiveTransaction(
            id: transactionID,
            createdAt: Date(timeIntervalSince1970: 1_754_010_203),
            stagingDirectoryName: stagingName,
            snapshotDirectoryName: "history-20250801T010323Z-\(transactionID.uuidString.lowercased())",
            components: [
                HistoryArchiveTransactionComponent(
                    identifier: .sqlite,
                    relativePath: "PipelineHistory.sqlite",
                    byteCount: UInt64(fixture.sqliteBytes.count),
                    isDirectory: false,
                    state: .moved
                )
            ]
        )
        transaction.phase = .probingFreshHistory
        let transactionDirectory = recoveryDirectory
            .appendingPathComponent(".transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(transaction).write(
            to: transactionDirectory.appendingPathComponent("\(transactionID.uuidString.lowercased()).json")
        )

        let safety = HistoryArchiveTransition.rollbackInterruptedTransactions(at: fixture.rootURL)

        try expect(safety == .normal, "completed rollback restores normal archive safety")
        try expect(
            try Data(contentsOf: fixture.storeURL) == fixture.sqliteBytes,
            "interrupted transaction restores the original SQLite bytes"
        )
        try expect(
            !FileManager.default.fileExists(atPath: recoveryDirectory
                .appendingPathComponent(stagingName, isDirectory: true)
                .path),
            "interrupted transaction removes only its staging directory"
        )
        try expect(
            !FileManager.default.fileExists(atPath: recoveryDirectory
                .appendingPathComponent("history-20250801T010323Z-\(transactionID.uuidString.lowercased())", isDirectory: true)
                .path),
            "interrupted transaction does not publish or complete a fresh archive"
        )
    }

    private static func testAbandonedTransactionTempFileDoesNotBlockStartup() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }
        let temporaryJournalURL = fixture.rootURL
            .appendingPathComponent("Recovery/.transactions/.journal.partial.tmp")
        try FileManager.default.createDirectory(
            at: temporaryJournalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial transaction journal".utf8).write(to: temporaryJournalURL)

        let safety = HistoryArchiveTransition.rollbackInterruptedTransactions(at: fixture.rootURL)

        try expect(safety == .normal, "abandoned transaction temp file does not block startup")
        try expect(
            !FileManager.default.fileExists(atPath: temporaryJournalURL.path),
            "startup removes only the abandoned transaction temp file"
        )
    }

    private static func testPublishSyncFailureLeavesTransactionForSafeStartupRecovery() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }
        let archiveID = UUID(uuidString: "53A097CE-5A71-4A64-9B9E-A5B9B93DF9DE")!
        let archiveDate = Date(timeIntervalSince1970: 1_754_010_203)
        let recoveryDirectory = fixture.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        let transition = HistoryArchiveTransition(
            now: { archiveDate },
            makeID: { archiveID },
            syncDirectory: { directory in
                let publishedSnapshotExists = ((try? FileManager.default.contentsOfDirectory(
                    atPath: recoveryDirectory.path
                )) ?? []).contains(where: { $0.hasPrefix("history-") })
                if directory == recoveryDirectory, publishedSnapshotExists {
                    throw NSError(
                        domain: "HistoryArchiveTransitionTests",
                        code: 3,
                        userInfo: nil
                    )
                }
            }
        )

        do {
            _ = try transition.archiveAndCreateFreshHistory(at: fixture.rootURL)
            throw HistoryArchiveTestFailure("publish sync failure must not report archive success")
        } catch is HistoryArchiveTestFailure {
            throw HistoryArchiveTestFailure("publish sync failure unexpectedly reported archive success")
        } catch {
            // expected: the snapshot cannot be considered published until its directory sync succeeds.
        }

        let snapshotDirectory = recoveryDirectory.appendingPathComponent(
            "history-20250801T010323Z-\(archiveID.uuidString.lowercased())",
            isDirectory: true
        )
        let transactionURL = recoveryDirectory
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent("\(archiveID.uuidString.lowercased()).json")
        try expect(
            FileManager.default.fileExists(atPath: snapshotDirectory.path),
            "publish sync failure retains the snapshot payload for a safe later decision"
        )
        try expect(
            FileManager.default.fileExists(atPath: transactionURL.path),
            "publish sync failure retains the rollback journal until snapshot publication is durable"
        )
        try expect(
            try Data(contentsOf: snapshotDirectory
                .appendingPathComponent("payload/PipelineHistory.sqlite")) == fixture.sqliteBytes,
            "publish sync failure preserves original SQLite in the retained snapshot"
        )
        try expect(
            FileManager.default.fileExists(atPath: fixture.storeURL.path),
            "publish sync failure preserves the verified fresh active store"
        )

        let unsyncedStartupSafety = transition.rollbackInterruptedTransactions(
            at: fixture.rootURL
        )
        try expect(
            unsyncedStartupSafety == .unresolvedInterruptedTransaction,
            "startup keeps the journal when it cannot make a visible snapshot durable"
        )
        try expect(
            FileManager.default.fileExists(atPath: transactionURL.path),
            "startup does not remove the journal before the recovery directory sync succeeds"
        )

        let startupSafety = HistoryArchiveTransition.rollbackInterruptedTransactions(
            at: fixture.rootURL
        )
        try expect(
            startupSafety == .unresolvedArchive,
            "a retained published snapshot becomes an archive notice after safe startup cleanup"
        )
        try expect(
            !FileManager.default.fileExists(atPath: transactionURL.path),
            "startup clears the journal only after it syncs the published snapshot"
        )
    }

    private static func testFirstMoveFailurePreservesTheOriginalSQLite() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }
        let transition = HistoryArchiveTransition(
            moveItem: { _, _, _ in
                throw NSError(
                    domain: "HistoryArchiveTransitionTests",
                    code: 4,
                    userInfo: nil
                )
            }
        )

        do {
            _ = try transition.archiveAndCreateFreshHistory(at: fixture.rootURL)
            throw HistoryArchiveTestFailure("first move failure must fail the archive")
        } catch is HistoryArchiveTestFailure {
            throw HistoryArchiveTestFailure("first move failure unexpectedly succeeded")
        } catch {
            // expected
        }

        try expect(
            try Data(contentsOf: fixture.storeURL) == fixture.sqliteBytes,
            "first move failure preserves the original SQLite bytes"
        )
        let recoveryDirectory = fixture.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryEntries = (try? FileManager.default.contentsOfDirectory(
            atPath: recoveryDirectory.path
        )) ?? []
        try expect(
            !recoveryEntries.contains(where: { $0.hasPrefix("history-") }),
            "first move failure does not publish an archive"
        )
    }

    private static func testMoveFailureRollsBackEveryMovedComponent() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }
        var moveCount = 0
        let transition = HistoryArchiveTransition(
            moveItem: { fileManager, sourceURL, destinationURL in
                moveCount += 1
                if moveCount == 5 {
                    throw NSError(
                        domain: "HistoryArchiveTransitionTests",
                        code: 2,
                        userInfo: nil
                    )
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        )

        do {
            _ = try transition.archiveAndCreateFreshHistory(at: fixture.rootURL)
            throw HistoryArchiveTestFailure("move failure must fail the archive")
        } catch is HistoryArchiveTestFailure {
            throw HistoryArchiveTestFailure("move failure unexpectedly succeeded")
        } catch {
            // expected
        }

        try expect(
            try Data(contentsOf: fixture.storeURL) == fixture.sqliteBytes,
            "move failure restores SQLite after prior moves"
        )
        try expect(
            try Data(contentsOf: fixture.audioDirectory.appendingPathComponent("recording.wav"))
                == Data("audio".utf8),
            "move failure leaves audio at the canonical root"
        )
        try expect(
            try Data(contentsOf: fixture.transcriptsDirectory.appendingPathComponent("note.txt"))
                == fixture.transcriptBytes,
            "move failure leaves transcripts at the canonical root"
        )
        let recoveryDirectory = fixture.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryEntries = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)) ?? []
        try expect(
            !recoveryEntries.contains(where: { $0.hasPrefix("history-") }),
            "move failure never publishes a recovery snapshot"
        )
    }

    private static func testFreshStoreProbeFailureRollsBackTheOriginalGeneration() throws {
        let fixture = try HistoryArchiveFixture()
        defer { fixture.remove() }

        let transition = HistoryArchiveTransition(
            makeStore: { storeURL in
                PipelineHistoryStore(
                    storeURL: storeURL,
                    persistentStoreLoader: { _ in
                        NSError(
                            domain: "HistoryArchiveTransitionTests",
                            code: 1,
                            userInfo: nil
                        )
                    }
                )
            }
        )

        do {
            _ = try transition.archiveAndCreateFreshHistory(at: fixture.rootURL)
            throw HistoryArchiveTestFailure("fresh store probe failure must fail the archive")
        } catch is HistoryArchiveTestFailure {
            throw HistoryArchiveTestFailure("fresh store probe failure unexpectedly succeeded")
        } catch {
            // expected
        }

        try expect(
            try Data(contentsOf: fixture.storeURL) == fixture.sqliteBytes,
            "probe failure restores original SQLite bytes"
        )
        try expect(
            try Data(contentsOf: URL(fileURLWithPath: fixture.storeURL.path + "-wal"))
                == fixture.walBytes,
            "probe failure restores original WAL bytes"
        )
        try expect(
            try Data(contentsOf: URL(fileURLWithPath: fixture.storeURL.path + "-shm"))
                == fixture.shmBytes,
            "probe failure restores original SHM bytes"
        )
        try expect(
            try Data(contentsOf: fixture.audioDirectory.appendingPathComponent("recording.wav"))
                == Data("audio".utf8),
            "probe failure restores audio"
        )
        try expect(
            try Data(contentsOf: fixture.transcriptsDirectory.appendingPathComponent("note.txt"))
                == fixture.transcriptBytes,
            "probe failure restores transcripts"
        )
        try expect(
            try Data(contentsOf: fixture.cloudJobsDirectory.appendingPathComponent("job.json"))
                == fixture.cloudJobBytes,
            "probe failure restores cloud sidecars"
        )
        try expect(
            FileManager.default.fileExists(atPath: fixture.rootURL
                .appendingPathComponent("History Recovery/asset-references-incomplete", isDirectory: true)
                .path),
            "probe failure restores legacy recovery evidence"
        )
        let recoveryDirectory = fixture.rootURL.appendingPathComponent("Recovery", isDirectory: true)
        let recoveryEntries = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)) ?? []
        try expect(
            !recoveryEntries.contains(where: { $0.hasPrefix("history-") }),
            "probe failure never publishes a partial archive"
        )
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ label: String
    ) throws {
        guard try condition() else { throw HistoryArchiveTestFailure(label) }
    }
}

private final class HistoryArchiveFixture {
    let rootURL: URL
    let storeURL: URL
    let audioDirectory: URL
    let transcriptsDirectory: URL
    let cloudJobsDirectory: URL
    let sqliteBytes = Data("unreadable sqlite source".utf8)
    let walBytes = Data("unreadable wal source".utf8)
    let shmBytes = Data("unreadable shm source".utf8)
    let inflightBytes = Data("inflight journal".utf8)
    let transcriptBytes = Data("Transcript content must not appear in metadata".utf8)
    let cloudJobBytes = Data("Bearer secret-token".utf8)

    init(includesSQLiteCompanions: Bool = true) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeURL = rootURL.appendingPathComponent("PipelineHistory.sqlite")
        audioDirectory = rootURL.appendingPathComponent("audio", isDirectory: true)
        transcriptsDirectory = rootURL.appendingPathComponent("transcripts", isDirectory: true)
        cloudJobsDirectory = rootURL
            .appendingPathComponent("cloud-transcription/jobs", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try sqliteBytes.write(to: storeURL)
        if includesSQLiteCompanions {
            try walBytes.write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
            try shmBytes.write(to: URL(fileURLWithPath: storeURL.path + "-shm"))
        }
        try Data("{\"audioFileNames\":[],\"transcriptFileNames\":[]}".utf8).write(
            to: rootURL.appendingPathComponent("PipelineHistory-asset-references.json")
        )
        try fileManager.createDirectory(
            at: audioDirectory
                .appendingPathComponent("inflight/recording", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: audioDirectory.appendingPathComponent("recording.wav"))
        try inflightBytes.write(
            to: audioDirectory
                .appendingPathComponent("inflight/recording/manifest.json")
        )
        try fileManager.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        try transcriptBytes.write(to: transcriptsDirectory.appendingPathComponent("note.txt"))
        try fileManager.createDirectory(at: cloudJobsDirectory, withIntermediateDirectories: true)
        try cloudJobBytes.write(to: cloudJobsDirectory.appendingPathComponent("job.json"))
        try fileManager.createDirectory(
            at: rootURL
                .appendingPathComponent("History Recovery/asset-references-incomplete", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct HistoryArchiveTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
