import Foundation

enum NoteAssetStoreError: Error {
    case audioSaveFailed(underlying: Error)
    case transcriptSaveFailed(underlying: Error)
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

    /// Directory preparation intentionally stays best-effort, matching the
    /// existing `AppState` directory-preparation contract established when
    /// instance-owned storage layouts were introduced: callers proceed with
    /// the directory URL regardless of creation success, and the subsequent
    /// save/load operation is what surfaces a failure.
    @discardableResult
    func prepareDirectories() -> (audioDirectory: URL, transcriptDirectory: URL) {
        (
            Self.preparedDirectory(storageLayout.audioDirectory),
            Self.preparedDirectory(storageLayout.transcriptDirectory)
        )
    }

    func saveAudio(from tempURL: URL) throws -> AppState.SavedAudioFile {
        let fileName = UUID().uuidString + "." + AudioImportOptions.storageExtension(
            for: tempURL.lastPathComponent
        )
        let destURL = storageLayout.audioDirectory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return AppState.SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            throw NoteAssetStoreError.audioSaveFailed(underlying: error)
        }
    }

    func saveSecurityScopedAudio(from fileURL: URL) async throws -> AppState.SavedAudioFile {
        try await Task.detached(priority: .userInitiated) {
            let accessGranted = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            return try self.saveAudio(from: fileURL)
        }.value
    }

    func deleteAudio(fileName: String) throws {
        try Self.removeItemIfPresent(
            at: storageLayout.audioDirectory.appendingPathComponent(fileName)
        )
    }

    func saveTranscript(
        rawTranscript: String,
        postProcessedTranscript: String
    ) throws -> String {
        let fileName = UUID().uuidString + ".txt"
        let fileURL = storageLayout.transcriptDirectory.appendingPathComponent(fileName)
        let content = postProcessedTranscript.isEmpty ? rawTranscript : postProcessedTranscript
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileName
        } catch {
            throw NoteAssetStoreError.transcriptSaveFailed(underlying: error)
        }
    }

    func loadTranscript(fileName: String) throws -> String {
        let fileURL = storageLayout.transcriptDirectory.appendingPathComponent(fileName)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw NoteAssetStoreError.transcriptLoadFailed(underlying: error)
        }
    }

    func deleteTranscript(fileName: String) throws {
        try Self.removeItemIfPresent(
            at: storageLayout.transcriptDirectory.appendingPathComponent(fileName)
        )
    }

    /// Attempts both deletions independently — matching the existing
    /// best-effort semantics of `AppState`'s asset cleanup — so a failure
    /// deleting one asset never skips the other. If either deletion fails,
    /// the first failure is thrown after both have been attempted.
    func deleteAssets(audioFileName: String?, transcriptFileName: String?) throws {
        var firstError: Error?
        if let audioFileName {
            do {
                try deleteAudio(fileName: audioFileName)
            } catch {
                firstError = error
            }
        }
        if let transcriptFileName {
            do {
                try deleteTranscript(fileName: transcriptFileName)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
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

    /// Deleting an already-missing file is treated as success (matching the
    /// idempotent delete semantics used throughout `AppState`'s existing
    /// asset cleanup). Any other failure — permissions, a read-only volume,
    /// a directory that cannot be removed — propagates to the caller.
    private static func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                return
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                return
            }
            throw error
        }
    }
}
