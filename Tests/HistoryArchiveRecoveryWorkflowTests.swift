import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct HistoryArchiveRecoveryWorkflowTests {
    static func main() async throws {
        try testArchiveAdmissionRejectsEveryApplicationActivity()
        try testArchiveAdmissionRejectsReentrantWorkflowActivity()
        try testMutationAdmissionPreservesDistinctWorkflowFailures()
        try testStartupRollsBackBeforeRetentionAndInspection()
        try testUnavailableStoreProtectsHistory()
        try testUnresolvedRollbackSkipsRetentionAndProtectsHistory()
        try testPublishedUnresolvedArchivePermitsProtectedStartupBranch()
        try testRetentionFailureStillLoadsRecoveryCatalog()
        try testStartupUsesOriginatingStoreFactory()
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

    private static func testStartupRollsBackBeforeRetentionAndInspection() throws {
        try withTemporaryWorkflow { workflow, root, recorder in
            let result = workflow.prepareStartup()

            try expect(
                Array(recorder.events.prefix(4)) == [
                    "rollback", "retention", "inspect", "make-store",
                ],
                "startup rollback precedes retention, safety inspection, and store construction"
            )
            try expect(
                result.permitsNormalHistoryStartup,
                "normal verified history permits normal startup work"
            )
            try expect(
                result.state.archiveSafety == .normal
                    && !result.state.isHistoryUnavailable,
                "startup result carries normal available state"
            )
            try expect(
                result.activeStore === recorder.madeStores.first,
                "startup returns the store from the originating factory"
            )
            try expect(
                recorder.madeStoreURLs == [root.appendingPathComponent("PipelineHistory.sqlite")],
                "startup requests the active history URL"
            )
        }
    }

    private static func testUnavailableStoreProtectsHistory() throws {
        try withTemporaryWorkflow { workflow, _, recorder in
            recorder.makeUnavailableStore = true

            let result = workflow.prepareStartup()

            try expect(
                result.state.isHistoryUnavailable
                    && result.state.showsPersistenceWarning,
                "unavailable active store protects history and publishes a warning"
            )
            try expect(
                !result.permitsNormalHistoryStartup
                    && !result.permitsUnresolvedArchiveStartup,
                "unavailable active store blocks startup history loading"
            )
        }
    }

    private static func testUnresolvedRollbackSkipsRetentionAndProtectsHistory() throws {
        try withTemporaryWorkflow { workflow, _, recorder in
            recorder.rollbackSafety = .unresolvedInterruptedTransaction
            recorder.inspectedSafety = .unresolvedInterruptedTransaction

            let result = workflow.prepareStartup()

            try expect(
                !recorder.events.contains("retention"),
                "unresolved rollback never deletes completed snapshots"
            )
            try expect(
                result.state.isHistoryUnavailable
                    && result.state.showsPersistenceWarning,
                "unresolved transaction keeps history protected"
            )
            try expect(
                !result.permitsNormalHistoryStartup
                    && !result.permitsUnresolvedArchiveStartup,
                "unresolved transaction blocks all history loading"
            )
        }
    }

    private static func testPublishedUnresolvedArchivePermitsProtectedStartupBranch() throws {
        try withTemporaryWorkflow { workflow, _, recorder in
            recorder.inspectedSafety = .unresolvedArchive

            let result = workflow.prepareStartup()

            try expect(
                result.permitsUnresolvedArchiveStartup
                    && !result.permitsNormalHistoryStartup,
                "published unresolved archive uses only its protected startup branch"
            )
            try expect(
                !result.state.isHistoryUnavailable,
                "verified fresh history stays available beside a published archive"
            )
        }
    }

    private static func testRetentionFailureStillLoadsRecoveryCatalog() throws {
        try withTemporaryWorkflow { workflow, _, recorder in
            recorder.failRetention = true

            let result = workflow.prepareStartup()

            try expect(
                result.permitsNormalHistoryStartup,
                "best-effort retention failure keeps active history available"
            )
            try expect(
                recorder.events.contains("catalog"),
                "retention failure still loads the recovery catalog"
            )
        }
    }

    private static func testStartupUsesOriginatingStoreFactory() throws {
        try withTemporaryDirectory { root in
            let layout = AppStateStorageLayout(rootDirectory: root)
            let originatingRecorder = StartupOperationRecorder()
            let unrelatedRecorder = StartupOperationRecorder()
            var dependencies = startupDependencies(
                recorder: originatingRecorder
            )
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: layout,
                dependencies: dependencies
            )
            dependencies.makeHistoryStore = { url in
                let store = PipelineHistoryStore(storeURL: url)
                unrelatedRecorder.recordStore(url: url, store: store)
                return store
            }

            let result = workflow.prepareStartup()

            try expect(
                result.activeStore === originatingRecorder.madeStores.first,
                "startup remains bound to the factory captured by the workflow"
            )
            try expect(
                unrelatedRecorder.madeStores.isEmpty,
                "later dependency mutation cannot redirect startup"
            )
        }
    }

    private static func withTemporaryWorkflow(
        _ operation: (
            HistoryArchiveRecoveryWorkflow,
            URL,
            StartupOperationRecorder
        ) throws -> Void
    ) throws {
        try withTemporaryDirectory { root in
            let recorder = StartupOperationRecorder()
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: AppStateStorageLayout(rootDirectory: root),
                dependencies: startupDependencies(recorder: recorder)
            )
            try operation(workflow, root, recorder)
        }
    }

    private static func startupDependencies(
        recorder: StartupOperationRecorder
    ) -> HistoryArchiveRecoveryWorkflowDependencies {
        var dependencies = HistoryArchiveRecoveryWorkflowDependencies.live(
            makeHistoryStore: { url in
                recorder.record("make-store")
                let store: PipelineHistoryStore
                if recorder.makeUnavailableStore {
                    store = PipelineHistoryStore(
                        storeURL: url,
                        persistentStoreLoader: { _ in
                            HistoryWorkflowTestFailure(
                                "intentional unavailable startup store"
                            )
                        }
                    )
                } else {
                    store = PipelineHistoryStore(storeURL: url)
                }
                recorder.recordStore(url: url, store: store)
                return store
            }
        )
        dependencies.rollbackInterruptedTransactions = { _ in
            recorder.record("rollback")
            return recorder.rollbackSafety
        }
        dependencies.removeExpiredSnapshots = { _ in
            recorder.record("retention")
            if recorder.failRetention {
                throw HistoryWorkflowTestFailure(
                    "intentional retention cleanup failure"
                )
            }
            return []
        }
        dependencies.inspectArchiveSafety = { _ in
            recorder.record("inspect")
            return recorder.inspectedSafety
        }
        dependencies.listSnapshots = { _ in
            recorder.record("catalog")
            return []
        }
        return dependencies
    }

    private static func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "history-workflow-startup-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
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

private final class StartupOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedStoreURLs: [URL] = []
    private var recordedStores: [PipelineHistoryStore] = []
    var rollbackSafety: HistoryArchiveSafety = .normal
    var inspectedSafety: HistoryArchiveSafety = .normal
    var makeUnavailableStore = false
    var failRetention = false

    var events: [String] {
        lock.withHistoryWorkflowLock { recordedEvents }
    }

    var madeStoreURLs: [URL] {
        lock.withHistoryWorkflowLock { recordedStoreURLs }
    }

    var madeStores: [PipelineHistoryStore] {
        lock.withHistoryWorkflowLock { recordedStores }
    }

    func record(_ event: String) {
        lock.withHistoryWorkflowLock {
            recordedEvents.append(event)
        }
    }

    func recordStore(url: URL, store: PipelineHistoryStore) {
        lock.withHistoryWorkflowLock {
            recordedStoreURLs.append(url)
            recordedStores.append(store)
        }
    }
}

private struct HistoryWorkflowTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private extension NSLock {
    func withHistoryWorkflowLock<Value>(
        _ body: () throws -> Value
    ) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
