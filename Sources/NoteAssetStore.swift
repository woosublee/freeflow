import Foundation

enum NoteAssetStoreError: Error {
    case audioSaveFailed
    case transcriptSaveFailed
    case transcriptLoadFailed(underlying: Error)
}

/// A focused, instance-owned boundary over `AppStateStorageLayout` for note
/// audio and transcript files.
///
/// This does not yet own every audio/transcript call site in `AppState`.
/// Several existing call sites (audio import, stopped-recording save/delete,
/// cloud-transcription cleanup) are pinned by exact-source-text regression
/// tests in other suites (`AudioImportFileCopyTests`,
/// `CombinedRecordingNormalStopIntegrationTests`,
/// `AppStateCloudTranscriptionCleanupSourceTests`,
/// `AppStateRecordingJournalIntegrationSourceTests`). Migrating those call
/// sites requires first converting those tests to behavioral coverage, which
/// is out of scope here. This type provides the throwing API surface and
/// migrates only the call sites those tests do not lock in place: the
/// `loadTranscript(from:)` and `storedAudioURL(for:)` instance methods on
/// `AppState`.
struct NoteAssetStore: Sendable {
    let storageLayout: AppStateStorageLayout

    @discardableResult
    func prepareDirectories() -> (audioDirectory: URL, transcriptDirectory: URL) {
        (
            Self.preparedDirectory(storageLayout.audioDirectory),
            Self.preparedDirectory(storageLayout.transcriptDirectory)
        )
    }

    func saveAudio(from tempURL: URL) throws -> AppState.SavedAudioFile {
        guard let saved = AppState.saveAudioFile(
            from: tempURL,
            audioDirectory: storageLayout.audioDirectory
        ) else {
            throw NoteAssetStoreError.audioSaveFailed
        }
        return saved
    }

    func saveSecurityScopedAudio(from fileURL: URL) async throws -> AppState.SavedAudioFile {
        guard let saved = await AppState.saveSecurityScopedAudioFileOffMain(
            from: fileURL,
            audioDirectory: storageLayout.audioDirectory
        ) else {
            throw NoteAssetStoreError.audioSaveFailed
        }
        return saved
    }

    func deleteAudio(fileName: String) {
        let fileURL = storageLayout.audioDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func saveTranscript(
        rawTranscript: String,
        postProcessedTranscript: String
    ) throws -> String {
        guard let fileName = AppState.saveTranscriptFile(
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            transcriptDirectory: storageLayout.transcriptDirectory
        ) else {
            throw NoteAssetStoreError.transcriptSaveFailed
        }
        return fileName
    }

    func loadTranscript(fileName: String) throws -> String {
        let fileURL = storageLayout.transcriptDirectory.appendingPathComponent(fileName)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw NoteAssetStoreError.transcriptLoadFailed(underlying: error)
        }
    }

    func deleteTranscript(fileName: String) {
        AppState.deleteTranscriptFile(
            fileName,
            transcriptDirectory: storageLayout.transcriptDirectory
        )
    }

    func deleteAssets(audioFileName: String?, transcriptFileName: String?) {
        if let audioFileName {
            deleteAudio(fileName: audioFileName)
        }
        if let transcriptFileName {
            deleteTranscript(fileName: transcriptFileName)
        }
    }

    func storedAudioURL(for item: PipelineHistoryItem) -> URL? {
        guard let fileName = item.audioFileName else { return nil }
        return storageLayout.audioDirectory.appendingPathComponent(fileName)
    }

    private static func preparedDirectory(_ directory: URL) -> URL {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }
}
