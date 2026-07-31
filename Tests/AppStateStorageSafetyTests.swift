import Darwin
import Foundation

struct AppStateStorageSafetyTests {
    static func main() async throws {
        try await verifiesHistoryCreatedAfterAssetsDoesNotSweep()
        try await verifiesHistoryRowsLostAfterSnapshotDoesNotSweep()
        try await verifiesUnavailableHistoryBlocksMutatingActions()
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
            try await Task.sleep(nanoseconds: 1_200_000_000)
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
