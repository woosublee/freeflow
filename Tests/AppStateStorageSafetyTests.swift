import Darwin
import Foundation

struct AppStateStorageSafetyTests {
    static func main() async throws {
        try await verifiesHistoryCreatedAfterAssetsDoesNotSweep()
        try await verifiesHistoryRowsLostAfterSnapshotDoesNotSweep()
        try await verifiesUnavailableHistoryBlocksMutatingActions()
        try await verifiesExplicitArchiveCreatesFreshSeparatedHistory()
        try await verifiesInterruptedArchiveKeepsHistoryProtected()
        try await verifiesMissingSnapshotWithUnreferencedAudioDoesNotSweep()
        try await verifiesMatchingHistorySnapshotSweepsOrphansAtStartup()
        try await verifiesTrustedHistorySweepsOrphans()
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let fallbackAudioURL = try await verifiesFallbackHistoryDoesNotSweepStoredAudio()
            try await verifiesMissingHistoryDoesNotSweepStoredAudio(
                audioURL: fallbackAudioURL,
                rootDirectory: rootDirectory
            )

            let audioDirectory = AppState.audioStorageDirectory()
                .standardizedFileURL
            let transcriptDirectory = AppState.transcriptStorageDirectory()
                .standardizedFileURL
            let rootPath = rootDirectory.standardizedFileURL.path + "/"

            try expect(
                audioDirectory.path.hasPrefix(rootPath),
                "AppState tests write audio below their isolated root"
            )
            try expect(
                transcriptDirectory.path.hasPrefix(rootPath),
                "AppState tests write transcripts below their isolated root"
            )
        }
        print("AppStateStorageSafetyTests passed")
    }

    private static func verifiesHistoryCreatedAfterAssetsDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let audioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("history-lost.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            _ = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )

            _ = await MainActor.run { AppState() }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "history created after stored audio never treats it as an orphan"
            )
        }
    }

    private static func verifiesHistoryRowsLostAfterSnapshotDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let historyStore = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )
            let audioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("history-row-lost.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)
            try historyStore.saveAssetReferenceSnapshot(
                audioFileNames: [audioURL.lastPathComponent],
                transcriptFileNames: []
            )

            _ = await MainActor.run { AppState() }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "a history snapshot mismatch never sweeps audio after history rows are lost"
            )
        }
    }

    private static func verifiesUnavailableHistoryBlocksMutatingActions() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let audioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("protected-audio.wav")
            let transcriptURL = AppState.transcriptStorageDirectory()
                .appendingPathComponent("protected-transcript.txt")
            try Data("audio".utf8).write(to: audioURL)
            try Data("original transcript".utf8).write(to: transcriptURL)
            let unavailableStore = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite"),
                persistentStoreLoader: { _ in
                    TestFailure("Injected protected history failure")
                }
            )
            let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
            AppState.pipelineHistoryStoreFactory = { unavailableStore }
            defer {
                AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            }

            let item = PipelineHistoryItem(
                timestamp: Date(),
                rawTranscript: "original transcript",
                postProcessedTranscript: "original transcript",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: "",
                audioFileName: audioURL.lastPathComponent,
                transcriptFileName: transcriptURL.lastPathComponent
            )
            let appState = await MainActor.run { AppState() }
            await MainActor.run {
                appState.pipelineHistory = [item]
                appState.clearPipelineHistory()
                appState.updateTranscript(id: item.id, text: "replacement transcript")
                appState.toggleRecording()
            }

            try expect(appState.isHistoryUnavailable, "history load failure enters protection mode")
            try expect(
                appState.pipelineHistory.map(\.id) == [item.id],
                "protected history clear does not alter in-memory note ownership"
            )
            try expect(
                FileManager.default.fileExists(atPath: audioURL.path),
                "protected history clear does not delete audio"
            )
            let storedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
            try expect(
                storedTranscript == "original transcript",
                "protected history transcript edit does not write a sidecar"
            )
            try expect(!appState.isRecording, "protected history cannot start recording")
        }
    }

    private static func verifiesExplicitArchiveCreatesFreshSeparatedHistory() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let storeURL = rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            let originalSQLiteBytes = Data("unreadable original SQLite".utf8)
            try originalSQLiteBytes.write(to: storeURL)
            let audioURL = AppState.audioStorageDirectory().appendingPathComponent("archived.wav")
            let transcriptURL = AppState.transcriptStorageDirectory().appendingPathComponent("archived.txt")
            let cloudJobURL = rootDirectory
                .appendingPathComponent("cloud-transcription/jobs/archived.json")
            try Data("archived audio".utf8).write(to: audioURL)
            try Data("archived transcript".utf8).write(to: transcriptURL)
            try FileManager.default.createDirectory(
                at: cloudJobURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("archived cloud job".utf8).write(to: cloudJobURL)

            let unavailableStore = PipelineHistoryStore(
                storeURL: storeURL,
                persistentStoreLoader: { _ in
                    TestFailure("Injected unavailable history for explicit archive")
                }
            )
            let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
            AppState.pipelineHistoryStoreFactory = { unavailableStore }
            defer {
                AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            }

            let appState = await MainActor.run { AppState() }
            let archiveSucceeded = await MainActor.run {
                appState.archiveOldHistoryAndStartFresh()
            }

            try expect(archiveSucceeded, "explicit archive is accepted from protection mode")
            try await waitForArchiveCompletion(appState)
            try expect(!appState.isHistoryUnavailable, "verified fresh history leaves protection mode")
            try expect(
                appState.historyArchiveSafety == .unresolvedArchive,
                "published archive keeps automatic cleanup in its safe state"
            )
            try expect(
                appState.historyPersistenceWarning?.code == .historyArchived,
                "published archive keeps a persistent recovery-folder notice"
            )
            try expect(appState.pipelineHistory.isEmpty, "fresh history starts with no old notes")

            let recoveryDirectory = rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
            guard let snapshotDirectory = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first(where: { $0.lastPathComponent.hasPrefix("history-") }) else {
                throw TestFailure("explicit archive did not publish a recovery snapshot")
            }
            let payload = snapshotDirectory.appendingPathComponent("payload", isDirectory: true)
            let archivedSQLiteBytes = try Data(
                contentsOf: payload.appendingPathComponent("PipelineHistory.sqlite")
            )
            let archivedAudioBytes = try Data(
                contentsOf: payload.appendingPathComponent("audio/archived.wav")
            )
            let archivedTranscriptBytes = try Data(
                contentsOf: payload.appendingPathComponent("transcripts/archived.txt")
            )
            let archivedCloudJobBytes = try Data(
                contentsOf: payload.appendingPathComponent("cloud-transcription/jobs/archived.json")
            )
            try expect(
                archivedSQLiteBytes == originalSQLiteBytes,
                "archive preserves the original unavailable SQLite bytes"
            )
            try expect(
                archivedAudioBytes == Data("archived audio".utf8),
                "archive preserves old audio outside the active generation"
            )
            try expect(
                archivedTranscriptBytes == Data("archived transcript".utf8),
                "archive preserves old transcripts outside the active generation"
            )
            try expect(
                archivedCloudJobBytes == Data("archived cloud job".utf8),
                "archive preserves old cloud jobs outside the active generation"
            )

            let freshStore = PipelineHistoryStore(storeURL: storeURL)
            try expect(freshStore.availability == .ready, "active store is fresh and readable")
            try expect(freshStore.loadAllHistory().isEmpty, "active store contains no archive probe records")
            let freshItem = PipelineHistoryItem(
                timestamp: Date(),
                rawTranscript: "new generation",
                postProcessedTranscript: "new generation",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: ""
            )
            _ = try freshStore.upsert(freshItem, maxCount: Int.max)
            AppState.pipelineHistoryStoreFactory = {
                AppState.makeDefaultPipelineHistoryStore()
            }

            let relaunchedAppState = await MainActor.run { AppState() }
            try expect(
                !relaunchedAppState.isHistoryUnavailable,
                "published archive does not turn the fresh active store into protection mode"
            )
            try expect(
                relaunchedAppState.pipelineHistory.map(\.id) == [freshItem.id],
                "published archive still loads the new active generation on restart"
            )
        }
    }

    private static func verifiesInterruptedArchiveKeepsHistoryProtected() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            _ = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )
            let transactionDirectory = rootDirectory
                .appendingPathComponent("Recovery/.transactions", isDirectory: true)
            try FileManager.default.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
            try Data("corrupt interrupted archive transaction".utf8).write(
                to: transactionDirectory.appendingPathComponent("interrupted.json")
            )

            let appState = await MainActor.run { AppState() }

            try expect(
                appState.historyArchiveSafety == .unresolvedInterruptedTransaction,
                "unreadable transaction journal remains explicitly unresolved"
            )
            try expect(
                appState.isHistoryUnavailable,
                "unresolved archive transaction blocks history mutations even with a readable store"
            )
            try expect(
                appState.historyPersistenceWarning?.code == .historyPersistenceUnavailable,
                "unresolved archive transaction shows the protected-history warning"
            )
        }
    }

    private static func verifiesMissingSnapshotWithUnreferencedAudioDoesNotSweep() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let historyStore = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )
            let referencedAudioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("still-referenced.wav")
            let unreferencedAudioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("history-row-lost-without-snapshot.wav")
            for fileURL in [referencedAudioURL, unreferencedAudioURL] {
                try Data("fixture".utf8).write(to: fileURL)
                try setOldModificationDate(of: fileURL)
            }
            _ = try historyStore.upsert(
                PipelineHistoryItem(
                    timestamp: Date(),
                    rawTranscript: "fixture",
                    postProcessedTranscript: "fixture",
                    postProcessingPrompt: nil,
                    contextSummary: "",
                    contextScreenshotDataURL: nil,
                    contextScreenshotStatus: "No screenshot",
                    postProcessingStatus: "succeeded",
                    debugStatus: "",
                    customVocabulary: "",
                    audioFileName: referencedAudioURL.lastPathComponent
                ),
                maxCount: 10
            )

            _ = await MainActor.run { AppState() }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            _ = await MainActor.run { AppState() }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try expect(
                FileManager.default.fileExists(atPath: unreferencedAudioURL.path),
                "a missing snapshot never sweeps audio absent from the loaded history"
            )
        }
    }

    private static func verifiesMatchingHistorySnapshotSweepsOrphansAtStartup() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let historyStore = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )
            try historyStore.saveAssetReferenceSnapshot(
                audioFileNames: [],
                transcriptFileNames: []
            )
            let audioURL = AppState.audioStorageDirectory()
                .appendingPathComponent("known-orphan.wav")
            try Data("fixture".utf8).write(to: audioURL)
            try setOldModificationDate(of: audioURL)

            _ = await MainActor.run { AppState() }
            try await waitForFileRemoval(at: audioURL)
            try expect(
                !FileManager.default.fileExists(atPath: audioURL.path),
                "matching history snapshots sweep old unreferenced audio at startup"
            )
        }
    }

    private static func verifiesTrustedHistorySweepsOrphans() async throws {
        try await AppStateTestStorage.withIsolatedStorage { rootDirectory in
            let historyStore = PipelineHistoryStore(
                storeURL: rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
            )
            try expect(
                historyStore.referenceTrust == .complete,
                "new persistent history is trusted before recording files exist"
            )
            let audioDirectory = AppState.audioStorageDirectory()
            let transcriptDirectory = AppState.transcriptStorageDirectory()
            let audioURL = audioDirectory.appendingPathComponent("trusted-orphan.wav")
            let transcriptURL = transcriptDirectory.appendingPathComponent("trusted-orphan.txt")
            for fileURL in [audioURL, transcriptURL] {
                try Data("fixture".utf8).write(to: fileURL)
            }

            AppState.sweepOrphanStoredFiles(
                audioDirectory: audioDirectory,
                transcriptDirectory: transcriptDirectory,
                referencedAudioFileNames: [],
                referencedTranscriptFileNames: [],
                protectedInflightAudioFileNames: [],
                referenceTrust: .complete,
                now: Date(timeIntervalSinceNow: 301)
            )
            try expect(
                !FileManager.default.fileExists(atPath: audioURL.path),
                "trusted history removes old unreferenced audio at startup"
            )
            try expect(
                !FileManager.default.fileExists(atPath: transcriptURL.path),
                "trusted history removes old unreferenced transcripts at startup"
            )
        }
    }

    private static func verifiesFallbackHistoryDoesNotSweepStoredAudio() async throws -> URL {
        let audioURL = AppState.audioStorageDirectory()
            .appendingPathComponent("fallback-history.wav")
        try Data("fixture".utf8).write(to: audioURL)
        try setOldModificationDate(of: audioURL)

        let fallbackStore = PipelineHistoryStore(
            storeURL: AppState.appStorageRootDirectory()
                .appendingPathComponent("FallbackHistory.sqlite"),
            persistentStoreLoader: { _ in
                TestFailure("Injected history load failure")
            }
        )
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        AppState.pipelineHistoryStoreFactory = { fallbackStore }
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
        }

        _ = await MainActor.run { AppState() }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try expect(
            FileManager.default.fileExists(atPath: audioURL.path),
            "fallback history never sweeps existing audio"
        )
        return audioURL
    }

    private static func verifiesMissingHistoryDoesNotSweepStoredAudio(
        audioURL: URL,
        rootDirectory: URL
    ) async throws {
        _ = await MainActor.run { AppState() }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try expect(
            FileManager.default.fileExists(atPath: audioURL.path),
            "a missing history database never sweeps existing audio"
        )
        try expect(
            FileManager.default.fileExists(
                atPath: rootDirectory
                    .appendingPathComponent(
                        "History Recovery/asset-references-incomplete",
                        isDirectory: true
                    ).path
            ),
            "missing history records persistent incomplete-reference evidence"
        )
    }

    private static func waitForArchiveCompletion(_ appState: AppState) async throws {
        let deadline = Date(timeIntervalSinceNow: 6)
        while await MainActor.run(body: { appState.isHistoryArchiveTransitioning }), Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let isStillTransitioning = await MainActor.run {
            appState.isHistoryArchiveTransitioning
        }
        try expect(
            !isStillTransitioning,
            "archive transition completes within the test timeout"
        )
    }

    private static func waitForFileRemoval(at fileURL: URL) async throws {
        let deadline = Date(timeIntervalSinceNow: 6)
        while FileManager.default.fileExists(atPath: fileURL.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func setOldModificationDate(of fileURL: URL) throws {
        let seconds = time_t(Date(timeIntervalSinceNow: -301).timeIntervalSince1970)
        var timestamps = [
            timeval(tv_sec: seconds, tv_usec: 0),
            timeval(tv_sec: seconds, tv_usec: 0)
        ]
        let result = fileURL.withUnsafeFileSystemRepresentation { path in
            utimes(path, &timestamps)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
