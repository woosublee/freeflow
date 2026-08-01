import Foundation

struct RecordingJournalStoppedFinalizationResult {
    let artifact: FinalizedSegmentedRecordingArtifact
    let manifest: RecordingJournalManifest
}

/// Transfers a stopped segmented journal from the MainActor to the serial
/// recording-journal finalization queue. The controller is removed from
/// AppState and its audio sinks are detached before this work item is made.
/// `SegmentedRecordingJournalController` serializes lifecycle access internally,
/// and `RecordingJournalStore` serializes filesystem access with its lock.
/// The work item itself must run on only that finalization queue.
final class RecordingJournalFinalizationWork: @unchecked Sendable {
    private let controller: SegmentedRecordingJournalController
    private let store: RecordingJournalStore

    init(
        controller: SegmentedRecordingJournalController,
        store: RecordingJournalStore
    ) {
        self.controller = controller
        self.store = store
    }

    var recordingID: UUID {
        controller.recordingID
    }

    var hasTerminalPersistenceFailure: Bool {
        controller.terminalPersistenceFailure != nil
    }

    func recoverAfterPersistenceFailure() -> Result<RecoveredRecordingArtifact, Error> {
        do {
            _ = try controller.closeAfterPersistenceFailure()
            let artifact = try SegmentedRecordingArtifactFinalizer(
                store: store,
                mixdownService: AudioMixdownService()
            ).finalizeAndPromote(recordingID: controller.recordingID)
            let manifest = try store.loadManifest(recordingID: artifact.recordingID)
            return .success(RecoveredRecordingArtifact(
                recordingID: artifact.recordingID,
                audioURL: artifact.destinationURL,
                promotion: artifact.promotion,
                manifest: manifest,
                mode: artifact.mode
            ))
        } catch {
            return .failure(error)
        }
    }

    func finalizeStoppedRecording() throws -> RecordingJournalStoppedFinalizationResult {
        try controller.stopAndClose()
        let artifact = try SegmentedRecordingArtifactFinalizer(
            store: store,
            mixdownService: AudioMixdownService()
        ).finalizeAndPromote(recordingID: controller.recordingID)
        let manifest = try store.loadManifest(recordingID: artifact.recordingID)
        return RecordingJournalStoppedFinalizationResult(
            artifact: artifact,
            manifest: manifest
        )
    }

    func preserveForRecovery() throws {
        try controller.preserveForRecovery()
    }
}
