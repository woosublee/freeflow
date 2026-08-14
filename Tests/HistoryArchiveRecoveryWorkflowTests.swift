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
        try await testArchiveInstallsVerifiedRuntimeBeforeIdleState()
        try await testArchiveVerificationFailureNeverInstallsRuntime()
        try await testArchiveTransitionFailureNeverInstallsRuntime()
        try await testArchiveCapturesOriginatingDependencies()
        try await testInspectionQueueRunsReadySnapshotsInOrder()
        try await testInspectionRetryMovesSnapshotToFront()
        try await testInspectionRejectsDuplicateCurrentSnapshot()
        try await testInspectionInvalidationDropsStaleCompletion()
        try await testInspectionFailureContinuesToNextSnapshot()
        try await testRecoveryImportInstallsVerifiedReopenedStore()
        try await testRecoveryImportPublishesOnlyPartialFeedback()
        try await testRecoveryImportFailureRestoresVerifiedStore()
        try await testRecoveryReopenFailureNeverInstallsRuntime()
        try testRecoveryImportRejectsInvalidAndReentrantRequests()
        try await testSnapshotCancellationRefreshesCatalog()
        try await testSnapshotDeleteRefreshesCatalog()
        try await testSnapshotFailureNeverInstallsRuntime()
        try await testSnapshotOperationsWaitForInspection()
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

    private static func testArchiveInstallsVerifiedRuntimeBeforeIdleState() async throws {
        try await withArchiveWorkflow { workflow, startup, eventRecorder, _ in
            let command = await MainActor.run {
                workflow.requestArchive(
                    context: .init(),
                    currentStore: startup.activeStore,
                    postAction: .openRecovery
                )
            }
            try expect(command == .accepted, "archive command is accepted")
            try await waitUntil {
                eventRecorder.kinds.contains(.postAction)
            }
            try expect(
                eventRecorder.kinds == [
                    .stateChanged,
                    .runtimeInstalled,
                    .stateChanged,
                    .postAction,
                ],
                "verified runtime installs before idle state and post-action"
            )
            try expect(
                workflow.state.archiveActivity == .idle
                    && !workflow.state.isHistoryUnavailable,
                "successful archive returns the workflow to available idle state"
            )
        }
    }

    private static func testArchiveVerificationFailureNeverInstallsRuntime() async throws {
        try await withArchiveWorkflow(
            freshStoreUnavailable: true
        ) { workflow, startup, eventRecorder, _ in
            let command = await MainActor.run {
                workflow.requestArchive(
                    context: .init(),
                    currentStore: startup.activeStore,
                    postAction: .startFresh
                )
            }
            try expect(command == .accepted, "archive failure begins asynchronously")
            try await waitUntil {
                eventRecorder.failures.contains(.freshStoreVerificationFailed)
            }
            try expect(
                !eventRecorder.kinds.contains(.runtimeInstalled),
                "fresh-store verification failure never installs a runtime"
            )
            try expect(
                workflow.state.archiveActivity == .idle
                    && workflow.state.isHistoryUnavailable,
                "verification failure leaves protected idle state"
            )
        }
    }

    private static func testArchiveTransitionFailureNeverInstallsRuntime() async throws {
        try await withArchiveWorkflow(
            transitionShouldFail: true
        ) { workflow, startup, eventRecorder, _ in
            let command = await MainActor.run {
                workflow.requestArchive(
                    context: .init(),
                    currentStore: startup.activeStore,
                    postAction: .startFresh
                )
            }
            try expect(command == .accepted, "archive transition begins asynchronously")
            try await waitUntil {
                eventRecorder.failures.contains(.archiveTransitionFailed)
            }
            try expect(
                !eventRecorder.kinds.contains(.runtimeInstalled),
                "archive transition failure never installs a runtime"
            )
        }
    }

    private static func testArchiveCapturesOriginatingDependencies() async throws {
        try await withTemporaryDirectoryAsync { root in
            let layout = AppStateStorageLayout(rootDirectory: root)
            let storeRecorder = ArchiveStoreFactoryRecorder()
            let originatingTransition = ArchiveTransitionRecorder()
            let unrelatedTransition = ArchiveTransitionRecorder()
            var dependencies = archiveDependencies(
                root: root,
                storeRecorder: storeRecorder,
                transitionRecorder: originatingTransition
            )
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: layout,
                dependencies: dependencies
            )
            let startup = workflow.prepareStartup()
            let eventRecorder = WorkflowEventRecorder()
            await MainActor.run { eventRecorder.attach(to: workflow) }
            dependencies.archiveAndCreateFreshHistory = { root, _ in
                unrelatedTransition.record()
                return archiveTransitionResult(root: root)
            }

            let command = await MainActor.run {
                workflow.requestArchive(
                    context: .init(),
                    currentStore: startup.activeStore,
                    postAction: .startFresh
                )
            }
            try expect(command == .accepted, "archive command is accepted")
            try await waitUntil {
                eventRecorder.kinds.contains(.postAction)
            }
            try expect(
                originatingTransition.count == 1,
                "archive uses the transition captured by the workflow"
            )
            try expect(
                unrelatedTransition.count == 0,
                "later dependency mutation cannot redirect an active workflow"
            )
        }
    }

    private static func testInspectionQueueRunsReadySnapshotsInOrder() async throws {
        let ids = [UUID(), UUID()]
        try await withInspectionWorkflow(snapshotIDs: ids) { workflow, recorder in
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil {
                workflow.state.inspections.count == ids.count
            }
            try expect(
                recorder.startedIDs == ids,
                "ready snapshots inspect in catalog order"
            )
        }
    }

    private static func testInspectionRetryMovesSnapshotToFront() async throws {
        let ids = [UUID(), UUID(), UUID()]
        try await withInspectionWorkflow(snapshotIDs: ids) { workflow, recorder in
            recorder.block(id: ids[0])
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil { recorder.startedIDs == [ids[0]] }
            let retryResult = await MainActor.run {
                workflow.retryInspection(id: ids[2], activeHistory: [])
            }
            try expect(retryResult == .accepted, "eligible retry is accepted")
            recorder.release(id: ids[0])
            try await waitUntil { recorder.startedIDs.count == ids.count }
            try expect(
                recorder.startedIDs == [ids[0], ids[2], ids[1]],
                "retry moves one queued snapshot to the front"
            )
        }
    }

    private static func testInspectionRejectsDuplicateCurrentSnapshot() async throws {
        let id = UUID()
        try await withInspectionWorkflow(snapshotIDs: [id]) { workflow, recorder in
            recorder.block(id: id)
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil { recorder.startedIDs == [id] }
            let retryResult = await MainActor.run {
                workflow.retryInspection(id: id, activeHistory: [])
            }
            try expect(
                retryResult == .rejected(.inspectionInProgress),
                "retry cannot duplicate the current snapshot inspection"
            )
            recorder.release(id: id)
            try await waitUntil { workflow.state.inspections[id] != nil }
            try expect(
                recorder.startedIDs == [id],
                "current snapshot is inspected only once"
            )
        }
    }

    private static func testInspectionInvalidationDropsStaleCompletion() async throws {
        let id = UUID()
        try await withInspectionWorkflow(snapshotIDs: [id]) { workflow, recorder in
            recorder.block(id: id)
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil { recorder.startedIDs == [id] }
            await MainActor.run {
                workflow.invalidateInspection(
                    activeHistory: [],
                    shouldReschedule: false
                )
            }
            recorder.release(id: id)
            try await waitUntil { recorder.completedIDs.contains(id) }
            try await waitUntil { workflow.state.inspectionSnapshotID == nil }
            try expect(
                workflow.state.inspections[id] == nil,
                "invalidated inspection completion cannot restore stale results"
            )
        }
    }

    private static func testInspectionFailureContinuesToNextSnapshot() async throws {
        let ids = [UUID(), UUID()]
        try await withInspectionWorkflow(snapshotIDs: ids) { workflow, recorder in
            recorder.fail(id: ids[0])
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil {
                workflow.state.inspections[ids[1]] != nil
            }
            try expect(
                recorder.startedIDs == ids,
                "inspection failure continues to the next queued snapshot"
            )
            try expect(
                workflow.state.inspections[ids[0]] == nil,
                "failed snapshot has no inspection result"
            )
        }
    }

    private static func testRecoveryImportInstallsVerifiedReopenedStore() async throws {
        try await withRecoveryWorkflow { workflow, startup, recorder, events in
            recorder.importResult = HistoryRecoveryImportResult(
                snapshotID: recorder.snapshotID,
                importedRecordCount: 1,
                alreadyPresentRecordCount: 0,
                conflictRecordCount: 0,
                failedRecordCount: 0
            )
            let command = await MainActor.run {
                workflow.requestImport(
                    snapshotID: recorder.snapshotID,
                    context: .init(),
                    currentStore: startup.activeStore,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "eligible recovery import is accepted")
            try await waitUntil {
                events.kinds.contains(.runtimeInstalled)
                    && workflow.state.recoveryOperation == .idle
            }
            try expect(
                workflow.state.importResult == nil
                    && !workflow.state.isHistoryUnavailable,
                "complete import installs available history without partial feedback"
            )
        }
    }

    private static func testRecoveryImportPublishesOnlyPartialFeedback() async throws {
        try await withRecoveryWorkflow { workflow, startup, recorder, events in
            let partialResult = HistoryRecoveryImportResult(
                snapshotID: recorder.snapshotID,
                importedRecordCount: 0,
                alreadyPresentRecordCount: 0,
                conflictRecordCount: 1,
                failedRecordCount: 0
            )
            recorder.importResult = partialResult
            let command = await MainActor.run {
                workflow.requestImport(
                    snapshotID: recorder.snapshotID,
                    context: .init(),
                    currentStore: startup.activeStore,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "partial recovery import is accepted")
            try await waitUntil {
                events.kinds.contains(.runtimeInstalled)
                    && workflow.state.recoveryOperation == .idle
            }
            try expect(
                workflow.state.importResult == partialResult,
                "conflict result remains available as partial feedback"
            )
        }
    }

    private static func testRecoveryImportFailureRestoresVerifiedStore() async throws {
        try await withRecoveryWorkflow(
            importShouldFail: true
        ) { workflow, startup, recorder, events in
            let command = await MainActor.run {
                workflow.requestImport(
                    snapshotID: recorder.snapshotID,
                    context: .init(),
                    currentStore: startup.activeStore,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "failing recovery import starts")
            try await waitUntil {
                events.failures.contains(.recoveryImportFailed)
            }
            try expect(
                events.kinds.contains(.runtimeInstalled),
                "import failure restores a separately verified active store"
            )
            try expect(
                !workflow.state.isHistoryUnavailable
                    && workflow.state.recoveryOperation == .idle,
                "verified restoration returns recovery to available idle state"
            )
        }
    }

    private static func testRecoveryReopenFailureNeverInstallsRuntime() async throws {
        try await withRecoveryWorkflow(
            unavailableStoreCalls: [3]
        ) { workflow, startup, recorder, events in
            let command = await MainActor.run {
                workflow.requestImport(
                    snapshotID: recorder.snapshotID,
                    context: .init(),
                    currentStore: startup.activeStore,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "reopen failure begins after import")
            try await waitUntil {
                events.failures.contains(.activeStoreReopenFailed)
            }
            try expect(
                !events.kinds.contains(.runtimeInstalled),
                "unverified reopened store is never installed"
            )
            try expect(
                workflow.state.isHistoryUnavailable,
                "reopen failure leaves history protected"
            )
        }
    }

    private static func testRecoveryImportRejectsInvalidAndReentrantRequests() throws {
        let root = FileManager.default.temporaryDirectory
        let snapshotID = UUID()
        let descriptor = recoverySnapshotDescriptor(
            id: snapshotID,
            root: root
        )
        var state = HistoryWorkflowState.initial
        try expect(
            HistoryWorkflowAdmission.recoveryImport(
                state: state,
                snapshotID: snapshotID,
                context: .init()
            ) == .rejected(.snapshotUnavailable),
            "unknown recovery snapshot is rejected"
        )
        state.snapshots = [descriptor]
        state.recoveryOperation = .deletingSnapshot(UUID())
        try expect(
            HistoryWorkflowAdmission.recoveryImport(
                state: state,
                snapshotID: snapshotID,
                context: .init()
            ) == .rejected(.recoveryOperationInProgress),
            "reentrant recovery import is rejected"
        )
    }

    private static func testSnapshotCancellationRefreshesCatalog() async throws {
        try await withRecoveryWorkflow(
            snapshotStatus: .completed
        ) { workflow, _, recorder, events in
            let command = await MainActor.run {
                workflow.requestCancelScheduledDeletion(
                    snapshotID: recorder.snapshotID,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(
                command == .accepted,
                "completed snapshot cancellation is accepted"
            )
            try await waitUntil {
                workflow.state.snapshots.first?.scheduledDeletionAt == nil
                    && workflow.state.recoveryOperation == .idle
            }
            try expect(
                !events.kinds.contains(.runtimeInstalled),
                "retention cancellation never replaces active history"
            )
        }
    }

    private static func testSnapshotDeleteRefreshesCatalog() async throws {
        try await withRecoveryWorkflow { workflow, _, recorder, events in
            let command = await MainActor.run {
                workflow.requestDeleteSnapshot(
                    snapshotID: recorder.snapshotID,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "eligible snapshot deletion is accepted")
            try await waitUntil {
                workflow.state.snapshots.isEmpty
                    && workflow.state.recoveryOperation == .idle
            }
            try expect(
                !events.kinds.contains(.runtimeInstalled),
                "snapshot deletion never replaces active history"
            )
        }
    }

    private static func testSnapshotFailureNeverInstallsRuntime() async throws {
        try await withRecoveryWorkflow(
            deleteShouldFail: true
        ) { workflow, _, recorder, events in
            let command = await MainActor.run {
                workflow.requestDeleteSnapshot(
                    snapshotID: recorder.snapshotID,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(command == .accepted, "failing snapshot deletion starts")
            try await waitUntil {
                events.failures.contains(.snapshotOperationFailed)
            }
            try expect(
                !events.kinds.contains(.runtimeInstalled),
                "snapshot-only failure never replaces active history"
            )
            try expect(
                workflow.state.snapshots.contains(where: {
                    $0.id == recorder.snapshotID
                }),
                "snapshot-only failure preserves the catalog entry"
            )
        }
    }

    private static func testSnapshotOperationsWaitForInspection() async throws {
        try await withRecoveryWorkflow { workflow, _, recorder, _ in
            recorder.blockInspection()
            await MainActor.run {
                workflow.beginInspection(activeHistory: [])
            }
            try await waitUntil { recorder.inspectionStarted }
            let command = await MainActor.run {
                workflow.requestDeleteSnapshot(
                    snapshotID: recorder.snapshotID,
                    activeHistory: [],
                    shouldRescheduleInspection: false
                )
            }
            try expect(
                command == .rejected(.inspectionInProgress),
                "snapshot operation waits for current inspection"
            )
            recorder.releaseInspection()
            try await waitUntil {
                workflow.state.inspectionSnapshotID == nil
            }
        }
    }

    private static func withRecoveryWorkflow(
        importShouldFail: Bool = false,
        deleteShouldFail: Bool = false,
        unavailableStoreCalls: Set<Int> = [],
        snapshotStatus: HistoryRecoverySnapshotStatus = .available,
        _ operation: (
            HistoryArchiveRecoveryWorkflow,
            HistoryStartupResult,
            RecoveryOperationRecorder,
            WorkflowEventRecorder
        ) async throws -> Void
    ) async throws {
        try await withTemporaryDirectoryAsync { root in
            let snapshotID = UUID()
            let recorder = RecoveryOperationRecorder(
                snapshotID: snapshotID,
                descriptors: [
                    recoverySnapshotDescriptor(
                        id: snapshotID,
                        root: root,
                        status: snapshotStatus
                    ),
                ],
                importShouldFail: importShouldFail,
                deleteShouldFail: deleteShouldFail
            )
            let storeRecorder = RecoveryStoreFactoryRecorder(
                unavailableCalls: unavailableStoreCalls
            )
            var dependencies = HistoryArchiveRecoveryWorkflowDependencies.live(
                makeHistoryStore: { storeRecorder.makeStore(at: $0) }
            )
            dependencies.rollbackInterruptedTransactions = { _ in .normal }
            dependencies.inspectArchiveSafety = { _ in .normal }
            dependencies.removeExpiredSnapshots = { _ in [] }
            dependencies.listSnapshots = { _ in recorder.descriptors }
            dependencies.inspectSnapshot = { _, id, _ in
                try recorder.inspect(id: id)
            }
            dependencies.importSnapshot = { _, id, _, _, _ in
                try recorder.importSnapshot(id: id)
            }
            dependencies.cancelScheduledDeletion = { _, id in
                try recorder.cancelScheduledDeletion(id: id)
            }
            dependencies.deleteSnapshot = { _, id in
                try recorder.deleteSnapshot(id: id)
            }
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: AppStateStorageLayout(rootDirectory: root),
                dependencies: dependencies
            )
            let startup = workflow.prepareStartup()
            let events = WorkflowEventRecorder()
            await MainActor.run { events.attach(to: workflow) }
            try await operation(workflow, startup, recorder, events)
        }
    }

    private static func withInspectionWorkflow(
        snapshotIDs: [UUID],
        _ operation: (
            HistoryArchiveRecoveryWorkflow,
            InspectionOperationRecorder
        ) async throws -> Void
    ) async throws {
        try await withTemporaryDirectoryAsync { root in
            let recorder = InspectionOperationRecorder(
                descriptors: snapshotIDs.map {
                    recoverySnapshotDescriptor(id: $0, root: root)
                }
            )
            var dependencies = HistoryArchiveRecoveryWorkflowDependencies.live(
                makeHistoryStore: { PipelineHistoryStore(storeURL: $0) }
            )
            dependencies.rollbackInterruptedTransactions = { _ in .normal }
            dependencies.inspectArchiveSafety = { _ in .normal }
            dependencies.removeExpiredSnapshots = { _ in [] }
            dependencies.listSnapshots = { _ in recorder.descriptors }
            dependencies.inspectSnapshot = { _, id, _ in
                try recorder.inspect(id: id)
            }
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: AppStateStorageLayout(rootDirectory: root),
                dependencies: dependencies
            )
            _ = workflow.prepareStartup()
            try await operation(workflow, recorder)
        }
    }

    private static func recoverySnapshotDescriptor(
        id: UUID,
        root: URL,
        status: HistoryRecoverySnapshotStatus = .available,
        integrity: HistoryRecoverySnapshotIntegrity = .ready
    ) -> HistoryRecoverySnapshotDescriptor {
        let snapshot = HistoryArchiveSnapshot(
            schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
            id: id,
            archivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            components: []
        )
        return HistoryRecoverySnapshotDescriptor(
            snapshot: snapshot,
            snapshotURL: root
                .appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent(
                    "history-\(id.uuidString.lowercased())",
                    isDirectory: true
                ),
            payloadByteCount: 0,
            integrity: integrity,
            state: HistoryRecoveryState(
                snapshotID: id,
                status: status,
                completedAt: status == .completed
                    ? Date(timeIntervalSince1970: 1_700_000_000)
                    : nil
            )
        )
    }

    private static func withArchiveWorkflow(
        freshStoreUnavailable: Bool = false,
        transitionShouldFail: Bool = false,
        _ operation: (
            HistoryArchiveRecoveryWorkflow,
            HistoryStartupResult,
            WorkflowEventRecorder,
            ArchiveTransitionRecorder
        ) async throws -> Void
    ) async throws {
        try await withTemporaryDirectoryAsync { root in
            let storeRecorder = ArchiveStoreFactoryRecorder(
                freshStoreUnavailable: freshStoreUnavailable
            )
            let transitionRecorder = ArchiveTransitionRecorder(
                shouldFail: transitionShouldFail
            )
            let workflow = HistoryArchiveRecoveryWorkflow(
                storageLayout: AppStateStorageLayout(rootDirectory: root),
                dependencies: archiveDependencies(
                    root: root,
                    storeRecorder: storeRecorder,
                    transitionRecorder: transitionRecorder
                )
            )
            let startup = workflow.prepareStartup()
            let eventRecorder = WorkflowEventRecorder()
            await MainActor.run { eventRecorder.attach(to: workflow) }
            try await operation(
                workflow,
                startup,
                eventRecorder,
                transitionRecorder
            )
        }
    }

    private static func archiveDependencies(
        root: URL,
        storeRecorder: ArchiveStoreFactoryRecorder,
        transitionRecorder: ArchiveTransitionRecorder
    ) -> HistoryArchiveRecoveryWorkflowDependencies {
        var dependencies = HistoryArchiveRecoveryWorkflowDependencies.live(
            makeHistoryStore: { storeRecorder.makeStore(at: $0) }
        )
        dependencies.rollbackInterruptedTransactions = { _ in .normal }
        dependencies.inspectArchiveSafety = { _ in
            transitionRecorder.count > 0 ? .unresolvedArchive : .normal
        }
        dependencies.removeExpiredSnapshots = { _ in [] }
        dependencies.listSnapshots = { _ in [] }
        dependencies.archiveAndCreateFreshHistory = { storageRoot, _ in
            try transitionRecorder.perform(root: storageRoot)
        }
        return dependencies
    }

    private static func archiveTransitionResult(
        root: URL
    ) -> HistoryArchiveTransitionResult {
        let snapshotID = UUID()
        return HistoryArchiveTransitionResult(
            snapshot: HistoryArchiveSnapshot(
                schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
                id: snapshotID,
                archivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                components: []
            ),
            recoveryDirectory: root
                .appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent(
                    "history-\(snapshotID.uuidString.lowercased())",
                    isDirectory: true
                )
        )
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                throw HistoryWorkflowTestFailure(
                    "timed out waiting for asynchronous history workflow"
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func withTemporaryDirectoryAsync(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "history-workflow-archive-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
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

private enum RecordedWorkflowEventKind: Equatable {
    case stateChanged
    case runtimeInstalled
    case failed
    case postAction
}

private final class WorkflowEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedKinds: [RecordedWorkflowEventKind] = []
    private var recordedFailures: [HistoryWorkflowFailure] = []

    var kinds: [RecordedWorkflowEventKind] {
        lock.withHistoryWorkflowLock { recordedKinds }
    }

    var failures: [HistoryWorkflowFailure] {
        lock.withHistoryWorkflowLock { recordedFailures }
    }

    @MainActor
    func attach(to workflow: HistoryArchiveRecoveryWorkflow) {
        workflow.onEvent = { [weak self] event in
            self?.record(event)
        }
    }

    private func record(_ event: HistoryWorkflowEvent) {
        lock.withHistoryWorkflowLock {
            switch event {
            case .stateChanged:
                recordedKinds.append(.stateChanged)
            case .installRuntime:
                recordedKinds.append(.runtimeInstalled)
            case .failed(let failure):
                recordedKinds.append(.failed)
                recordedFailures.append(failure)
            case .performPostAction:
                recordedKinds.append(.postAction)
            }
        }
    }
}

private final class ArchiveStoreFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let freshStoreUnavailable: Bool

    init(freshStoreUnavailable: Bool = false) {
        self.freshStoreUnavailable = freshStoreUnavailable
    }

    func makeStore(at url: URL) -> PipelineHistoryStore {
        let call = lock.withHistoryWorkflowLock { () -> Int in
            callCount += 1
            return callCount
        }
        guard call > 1, !freshStoreUnavailable else {
            return PipelineHistoryStore(
                storeURL: url,
                persistentStoreLoader: { _ in
                    HistoryWorkflowTestFailure(
                        "intentional unavailable archive store"
                    )
                }
            )
        }
        return PipelineHistoryStore(storeURL: url)
    }
}

private final class ArchiveTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var executionCount = 0
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var count: Int {
        lock.withHistoryWorkflowLock { executionCount }
    }

    func record() {
        lock.withHistoryWorkflowLock {
            executionCount += 1
        }
    }

    func perform(root: URL) throws -> HistoryArchiveTransitionResult {
        record()
        if shouldFail {
            throw HistoryWorkflowTestFailure(
                "intentional archive transition failure"
            )
        }
        let snapshotID = UUID()
        return HistoryArchiveTransitionResult(
            snapshot: HistoryArchiveSnapshot(
                schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
                id: snapshotID,
                archivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                components: []
            ),
            recoveryDirectory: root
                .appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent(
                    "history-\(snapshotID.uuidString.lowercased())",
                    isDirectory: true
                )
        )
    }
}

private final class RecoveryStoreFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let unavailableCalls: Set<Int>

    init(unavailableCalls: Set<Int>) {
        self.unavailableCalls = unavailableCalls
    }

    func makeStore(at url: URL) -> PipelineHistoryStore {
        let call = lock.withHistoryWorkflowLock { () -> Int in
            callCount += 1
            return callCount
        }
        guard unavailableCalls.contains(call) else {
            return PipelineHistoryStore(storeURL: url)
        }
        return PipelineHistoryStore(
            storeURL: url,
            persistentStoreLoader: { _ in
                HistoryWorkflowTestFailure(
                    "intentional unavailable recovery store"
                )
            }
        )
    }
}

private final class RecoveryOperationRecorder: @unchecked Sendable {
    let snapshotID: UUID
    private let lock = NSLock()
    private var storedDescriptors: [HistoryRecoverySnapshotDescriptor]
    private var storedImportResult: HistoryRecoveryImportResult
    private let importShouldFail: Bool
    private let deleteShouldFail: Bool
    private var inspectionSemaphore: DispatchSemaphore?
    private var didStartInspection = false

    init(
        snapshotID: UUID,
        descriptors: [HistoryRecoverySnapshotDescriptor],
        importShouldFail: Bool,
        deleteShouldFail: Bool
    ) {
        self.snapshotID = snapshotID
        self.storedDescriptors = descriptors
        self.storedImportResult = HistoryRecoveryImportResult(
            snapshotID: snapshotID,
            importedRecordCount: 0,
            alreadyPresentRecordCount: 0,
            conflictRecordCount: 0,
            failedRecordCount: 0
        )
        self.importShouldFail = importShouldFail
        self.deleteShouldFail = deleteShouldFail
    }

    var descriptors: [HistoryRecoverySnapshotDescriptor] {
        lock.withHistoryWorkflowLock { storedDescriptors }
    }

    var importResult: HistoryRecoveryImportResult {
        get {
            lock.withHistoryWorkflowLock { storedImportResult }
        }
        set {
            lock.withHistoryWorkflowLock {
                storedImportResult = newValue
            }
        }
    }

    var inspectionStarted: Bool {
        lock.withHistoryWorkflowLock { didStartInspection }
    }

    func blockInspection() {
        lock.withHistoryWorkflowLock {
            inspectionSemaphore = DispatchSemaphore(value: 0)
        }
    }

    func releaseInspection() {
        let semaphore = lock.withHistoryWorkflowLock {
            inspectionSemaphore
        }
        semaphore?.signal()
    }

    func inspect(id: UUID) throws -> HistoryRecoveryInspection {
        let semaphore = lock.withHistoryWorkflowLock {
            didStartInspection = true
            return inspectionSemaphore
        }
        semaphore?.wait()
        return HistoryRecoveryInspection(
            snapshotID: id,
            readableRecordCount: 1,
            alreadyPresentRecordCount: 0,
            conflictRecordCount: 0
        )
    }

    func importSnapshot(id: UUID) throws -> HistoryRecoveryImportResult {
        guard id == snapshotID else {
            throw HistoryWorkflowTestFailure("unexpected recovery snapshot")
        }
        if importShouldFail {
            throw HistoryWorkflowTestFailure(
                "intentional recovery import failure"
            )
        }
        return importResult
    }

    func cancelScheduledDeletion(id: UUID) throws {
        try lock.withHistoryWorkflowLock {
            guard let index = storedDescriptors.firstIndex(where: {
                $0.id == id
            }), let state = storedDescriptors[index].state else {
                throw HistoryWorkflowTestFailure(
                    "missing completed recovery snapshot"
                )
            }
            var cancelledState = state
            cancelledState.automaticDeletionCancelledAt = Date(
                timeIntervalSince1970: 1_700_000_100
            )
            let descriptor = storedDescriptors[index]
            storedDescriptors[index] = HistoryRecoverySnapshotDescriptor(
                snapshot: descriptor.snapshot,
                snapshotURL: descriptor.snapshotURL,
                payloadByteCount: descriptor.payloadByteCount,
                integrity: descriptor.integrity,
                state: cancelledState
            )
        }
    }

    func deleteSnapshot(id: UUID) throws {
        if deleteShouldFail {
            throw HistoryWorkflowTestFailure(
                "intentional snapshot deletion failure"
            )
        }
        lock.withHistoryWorkflowLock {
            storedDescriptors.removeAll { $0.id == id }
        }
    }
}

private final class InspectionOperationRecorder: @unchecked Sendable {
    let descriptors: [HistoryRecoverySnapshotDescriptor]
    private let lock = NSLock()
    private var started: [UUID] = []
    private var completed: [UUID] = []
    private var blocked: [UUID: DispatchSemaphore] = [:]
    private var failingIDs = Set<UUID>()

    init(descriptors: [HistoryRecoverySnapshotDescriptor]) {
        self.descriptors = descriptors
    }

    var startedIDs: [UUID] {
        lock.withHistoryWorkflowLock { started }
    }

    var completedIDs: [UUID] {
        lock.withHistoryWorkflowLock { completed }
    }

    func block(id: UUID) {
        lock.withHistoryWorkflowLock {
            blocked[id] = DispatchSemaphore(value: 0)
        }
    }

    func release(id: UUID) {
        let semaphore = lock.withHistoryWorkflowLock {
            blocked[id]
        }
        semaphore?.signal()
    }

    func fail(id: UUID) {
        lock.withHistoryWorkflowLock {
            _ = failingIDs.insert(id)
        }
    }

    func inspect(id: UUID) throws -> HistoryRecoveryInspection {
        let configuration = lock.withHistoryWorkflowLock {
            started.append(id)
            return (blocked[id], failingIDs.contains(id))
        }
        configuration.0?.wait()
        lock.withHistoryWorkflowLock {
            completed.append(id)
        }
        if configuration.1 {
            throw HistoryWorkflowTestFailure(
                "intentional inspection failure"
            )
        }
        return HistoryRecoveryInspection(
            snapshotID: id,
            readableRecordCount: 1,
            alreadyPresentRecordCount: 0,
            conflictRecordCount: 0
        )
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
