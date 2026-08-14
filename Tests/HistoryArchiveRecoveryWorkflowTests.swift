import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct HistoryArchiveRecoveryWorkflowTests {
    static func main() async throws {
        try testArchiveAdmissionRejectsEveryApplicationActivity()
        try testArchiveAdmissionRejectsReentrantWorkflowActivity()
        try testMutationAdmissionPreservesDistinctWorkflowFailures()
        print("HistoryArchiveRecoveryWorkflowTests passed")
    }

    private static func testArchiveAdmissionRejectsEveryApplicationActivity() throws {
        let state = HistoryWorkflowState(
            archiveSafety: .normal,
            archiveActivity: .idle,
            recoveryOperation: .idle,
            snapshots: [],
            inspections: [:],
            inspectionSnapshotID: nil,
            importResult: nil,
            isHistoryUnavailable: true,
            showsPersistenceWarning: true
        )
        let blockers: [(String, HistoryWorkflowAdmissionContext)] = [
            ("recording", .init(isRecording: true)),
            ("transcription", .init(isTranscribing: true)),
            ("retry", .init(hasRetryWork: true)),
            ("transcription job", .init(hasActiveTranscriptionJobs: true)),
            ("audio import", .init(hasPendingAudioImports: true)),
            ("cloud history", .init(hasCloudHistoryWork: true)),
            ("meeting summary", .init(hasMeetingSummaryWork: true)),
            ("recording journal", .init(hasActiveRecordingJournal: true)),
            ("recording finalization", .init(hasPendingRecordingFinalization: true)),
            ("recording start", .init(hasPendingRecordingStart: true)),
            ("audio-only stop", .init(hasPendingAudioOnlyStops: true)),
        ]

        for (label, context) in blockers {
            try expect(
                HistoryWorkflowAdmission.archive(
                    state: state,
                    context: context
                ) == .rejected(.applicationBusy),
                "archive rejects active \(label) work"
            )
        }
    }

    private static func testArchiveAdmissionRejectsReentrantWorkflowActivity() throws {
        var state = HistoryWorkflowState.initial
        state.isHistoryUnavailable = true
        state.archiveActivity = .transitioning(postAction: .startFresh)
        try expect(
            HistoryWorkflowAdmission.archive(
                state: state,
                context: .init()
            ) == .rejected(.archiveTransitionInProgress),
            "duplicate archive transition is rejected"
        )

        state.archiveActivity = .idle
        state.recoveryOperation = .deletingSnapshot(UUID())
        try expect(
            HistoryWorkflowAdmission.archive(
                state: state,
                context: .init()
            ) == .rejected(.recoveryOperationInProgress),
            "archive is rejected during mutating recovery work"
        )
    }

    private static func testMutationAdmissionPreservesDistinctWorkflowFailures() throws {
        var state = HistoryWorkflowState.initial
        state.archiveActivity = .transitioning(postAction: .startFresh)
        try expect(
            HistoryWorkflowAdmission.mutation(state: state)
                == .rejected(.archiveTransitionInProgress),
            "archive activity keeps its distinct mutation rejection"
        )

        state.archiveActivity = .idle
        state.recoveryOperation = .importing(UUID())
        try expect(
            HistoryWorkflowAdmission.mutation(state: state)
                == .rejected(.recoveryOperationInProgress),
            "recovery activity keeps its distinct mutation rejection"
        )

        state.recoveryOperation = .idle
        state.isHistoryUnavailable = true
        try expect(
            HistoryWorkflowAdmission.mutation(state: state)
                == .rejected(.historyUnavailable),
            "unavailable history keeps its distinct mutation rejection"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else {
            throw HistoryWorkflowTestFailure(label)
        }
    }
}

private struct HistoryWorkflowTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
