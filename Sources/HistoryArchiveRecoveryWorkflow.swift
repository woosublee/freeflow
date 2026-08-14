import Foundation

enum HistoryArchivePostAction: Equatable, Sendable {
    case startFresh
    case openRecovery
}

enum HistoryArchiveWorkflowActivity: Equatable, Sendable {
    case idle
    case transitioning(postAction: HistoryArchivePostAction)
}

enum HistoryRecoveryWorkflowOperation: Equatable, Sendable {
    case idle
    case importing(UUID)
    case cancellingScheduledDeletion(UUID)
    case deletingSnapshot(UUID)
}

struct HistoryWorkflowAdmissionContext: Equatable, Sendable {
    let isRecording: Bool
    let isTranscribing: Bool
    let hasRetryWork: Bool
    let hasActiveTranscriptionJobs: Bool
    let hasPendingAudioImports: Bool
    let hasCloudHistoryWork: Bool
    let hasMeetingSummaryWork: Bool
    let hasActiveRecordingJournal: Bool
    let hasPendingRecordingFinalization: Bool
    let hasPendingRecordingStart: Bool
    let hasPendingAudioOnlyStops: Bool

    init(
        isRecording: Bool = false,
        isTranscribing: Bool = false,
        hasRetryWork: Bool = false,
        hasActiveTranscriptionJobs: Bool = false,
        hasPendingAudioImports: Bool = false,
        hasCloudHistoryWork: Bool = false,
        hasMeetingSummaryWork: Bool = false,
        hasActiveRecordingJournal: Bool = false,
        hasPendingRecordingFinalization: Bool = false,
        hasPendingRecordingStart: Bool = false,
        hasPendingAudioOnlyStops: Bool = false
    ) {
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
        self.hasRetryWork = hasRetryWork
        self.hasActiveTranscriptionJobs = hasActiveTranscriptionJobs
        self.hasPendingAudioImports = hasPendingAudioImports
        self.hasCloudHistoryWork = hasCloudHistoryWork
        self.hasMeetingSummaryWork = hasMeetingSummaryWork
        self.hasActiveRecordingJournal = hasActiveRecordingJournal
        self.hasPendingRecordingFinalization = hasPendingRecordingFinalization
        self.hasPendingRecordingStart = hasPendingRecordingStart
        self.hasPendingAudioOnlyStops = hasPendingAudioOnlyStops
    }

    var hasBlockingActivity: Bool {
        isRecording
            || isTranscribing
            || hasRetryWork
            || hasActiveTranscriptionJobs
            || hasPendingAudioImports
            || hasCloudHistoryWork
            || hasMeetingSummaryWork
            || hasActiveRecordingJournal
            || hasPendingRecordingFinalization
            || hasPendingRecordingStart
            || hasPendingAudioOnlyStops
    }
}

struct HistoryWorkflowState: Equatable, Sendable {
    var archiveSafety: HistoryArchiveSafety
    var archiveActivity: HistoryArchiveWorkflowActivity
    var recoveryOperation: HistoryRecoveryWorkflowOperation
    var snapshots: [HistoryRecoverySnapshotDescriptor]
    var inspections: [UUID: HistoryRecoveryInspection]
    var inspectionSnapshotID: UUID?
    var importResult: HistoryRecoveryImportResult?
    var isHistoryUnavailable: Bool
    var showsPersistenceWarning: Bool

    static var initial: HistoryWorkflowState {
        HistoryWorkflowState(
            archiveSafety: .normal,
            archiveActivity: .idle,
            recoveryOperation: .idle,
            snapshots: [],
            inspections: [:],
            inspectionSnapshotID: nil,
            importResult: nil,
            isHistoryUnavailable: false,
            showsPersistenceWarning: false
        )
    }
}

enum HistoryWorkflowRejection: Equatable, Sendable {
    case archiveNotRequired
    case historyUnavailable
    case archiveTransitionInProgress
    case recoveryOperationInProgress
    case applicationBusy
    case snapshotUnavailable
    case inspectionInProgress
}

enum HistoryWorkflowCommandResult: Equatable, Sendable {
    case accepted
    case rejected(HistoryWorkflowRejection)
}

enum HistoryWorkflowFailure: Equatable, Sendable {
    case historyUnavailable
    case archiveTransitionFailed
    case freshStoreVerificationFailed
    case inspectionFailed(UUID)
    case recoveryImportFailed
    case activeStoreReopenFailed
    case snapshotOperationFailed
}

enum HistoryWorkflowAdmission {
    static func archive(
        state: HistoryWorkflowState,
        context: HistoryWorkflowAdmissionContext
    ) -> HistoryWorkflowCommandResult {
        guard state.isHistoryUnavailable,
              state.archiveSafety == .normal
                || state.archiveSafety == .unresolvedArchive else {
            return .rejected(.archiveNotRequired)
        }
        guard state.archiveActivity == .idle else {
            return .rejected(.archiveTransitionInProgress)
        }
        guard state.recoveryOperation == .idle else {
            return .rejected(.recoveryOperationInProgress)
        }
        guard !context.hasBlockingActivity else {
            return .rejected(.applicationBusy)
        }
        return .accepted
    }

    static func recoveryImport(
        state: HistoryWorkflowState,
        snapshotID: UUID,
        context: HistoryWorkflowAdmissionContext
    ) -> HistoryWorkflowCommandResult {
        guard !state.isHistoryUnavailable else {
            return .rejected(.historyUnavailable)
        }
        guard state.archiveActivity == .idle else {
            return .rejected(.archiveTransitionInProgress)
        }
        guard state.recoveryOperation == .idle else {
            return .rejected(.recoveryOperationInProgress)
        }
        guard !context.hasBlockingActivity else {
            return .rejected(.applicationBusy)
        }
        guard state.snapshots.contains(where: {
            $0.id == snapshotID && $0.integrity == .ready
        }) else {
            return .rejected(.snapshotUnavailable)
        }
        return .accepted
    }

    static func snapshotOperation(
        state: HistoryWorkflowState,
        snapshotID: UUID,
        requiresCompletedSnapshot: Bool
    ) -> HistoryWorkflowCommandResult {
        guard state.recoveryOperation == .idle else {
            return .rejected(.recoveryOperationInProgress)
        }
        guard state.inspectionSnapshotID == nil else {
            return .rejected(.inspectionInProgress)
        }
        guard state.snapshots.contains(where: {
            $0.id == snapshotID
                && (!requiresCompletedSnapshot
                    || ($0.integrity == .ready && $0.status == .completed))
        }) else {
            return .rejected(.snapshotUnavailable)
        }
        return .accepted
    }

    static func mutation(
        state: HistoryWorkflowState
    ) -> HistoryWorkflowCommandResult {
        guard state.archiveActivity == .idle else {
            return .rejected(.archiveTransitionInProgress)
        }
        guard state.recoveryOperation == .idle else {
            return .rejected(.recoveryOperationInProgress)
        }
        guard !state.isHistoryUnavailable else {
            return .rejected(.historyUnavailable)
        }
        return .accepted
    }
}

struct HistoryStartupResult {
    let activeStore: PipelineHistoryStore
    let state: HistoryWorkflowState
    let permitsNormalHistoryStartup: Bool
    let permitsUnresolvedArchiveStartup: Bool
}

struct HistoryFreshRuntime {
    let historyStore: PipelineHistoryStore
    let recordingJournalStore: RecordingJournalStore
    let cloudTranscriptionJobStore: CloudTranscriptionJobStore
}

enum HistoryRuntimeReplacement {
    case fresh(HistoryFreshRuntime)
    case recovered(
        historyStore: PipelineHistoryStore,
        history: [PipelineHistoryItem]
    )
}

enum HistoryWorkflowEvent {
    case stateChanged(HistoryWorkflowState)
    case installRuntime(HistoryRuntimeReplacement)
    case failed(HistoryWorkflowFailure)
    case performPostAction(HistoryArchivePostAction)
}

struct HistoryArchiveRecoveryWorkflowDependencies: Sendable {
    typealias HistoryStoreFactory = @Sendable (URL) -> PipelineHistoryStore

    var makeHistoryStore: HistoryStoreFactory
    var rollbackInterruptedTransactions: @Sendable (URL) -> HistoryArchiveSafety
    var inspectArchiveSafety: @Sendable (URL) -> HistoryArchiveSafety
    var removeExpiredSnapshots: @Sendable (URL) throws -> [UUID]
    var listSnapshots: @Sendable (URL) -> [HistoryRecoverySnapshotDescriptor]
    var archiveAndCreateFreshHistory:
        @Sendable (URL, @escaping HistoryStoreFactory) throws
            -> HistoryArchiveTransitionResult
    var inspectSnapshot:
        @Sendable (URL, UUID, [PipelineHistoryItem]) throws
            -> HistoryRecoveryInspection
    var importSnapshot:
        @Sendable (
            URL,
            UUID,
            PipelineHistoryStore,
            URL,
            URL
        ) throws -> HistoryRecoveryImportResult
    var cancelScheduledDeletion: @Sendable (URL, UUID) throws -> Void
    var deleteSnapshot: @Sendable (URL, UUID) throws -> Void
    var makeRecordingJournalStore: @Sendable (URL) -> RecordingJournalStore
    var makeCloudTranscriptionJobStore:
        @Sendable (AppStateStorageLayout) -> CloudTranscriptionJobStore

    static func live(
        makeHistoryStore: @escaping HistoryStoreFactory
    ) -> HistoryArchiveRecoveryWorkflowDependencies {
        HistoryArchiveRecoveryWorkflowDependencies(
            makeHistoryStore: makeHistoryStore,
            rollbackInterruptedTransactions: {
                HistoryArchiveTransition.rollbackInterruptedTransactions(at: $0)
            },
            inspectArchiveSafety: {
                HistoryArchiveTransition.inspect(at: $0)
            },
            removeExpiredSnapshots: {
                try HistoryRecoveryService(storageRoot: $0)
                    .removeExpiredCompletedSnapshots()
            },
            listSnapshots: {
                HistoryRecoveryService(storageRoot: $0).listSnapshots()
            },
            archiveAndCreateFreshHistory: { root, factory in
                try HistoryArchiveTransition(makeStore: factory)
                    .archiveAndCreateFreshHistory(at: root)
            },
            inspectSnapshot: { root, id, history in
                try HistoryRecoveryService(storageRoot: root)
                    .inspectSnapshot(id: id, against: history)
            },
            importSnapshot: { root, id, store, audio, transcripts in
                try HistoryRecoveryService(storageRoot: root)
                    .importSnapshot(
                        id: id,
                        into: store,
                        audioDirectory: audio,
                        transcriptDirectory: transcripts
                    )
            },
            cancelScheduledDeletion: { root, id in
                try HistoryRecoveryService(storageRoot: root)
                    .cancelScheduledDeletion(for: id)
            },
            deleteSnapshot: { root, id in
                try HistoryRecoveryService(storageRoot: root)
                    .deleteSnapshot(id: id)
            },
            makeRecordingJournalStore: {
                RecordingJournalStore(audioDirectory: $0)
            },
            makeCloudTranscriptionJobStore: {
                CloudTranscriptionJobStore(
                    jobsDirectory: $0.cloudTranscriptionJobsDirectory,
                    temporaryRoot: $0.cloudTranscriptionTemporaryDirectory
                )
            }
        )
    }
}

private enum HistorySnapshotOperation: Sendable {
    case cancelScheduledDeletion(UUID)
    case delete(UUID)

    var snapshotID: UUID {
        switch self {
        case .cancelScheduledDeletion(let id), .delete(let id):
            return id
        }
    }

    var requiresCompletedSnapshot: Bool {
        if case .cancelScheduledDeletion = self { return true }
        return false
    }

    var recoveryOperation: HistoryRecoveryWorkflowOperation {
        switch self {
        case .cancelScheduledDeletion(let id):
            return .cancellingScheduledDeletion(id)
        case .delete(let id):
            return .deletingSnapshot(id)
        }
    }

    func perform(
        root: URL,
        dependencies: HistoryArchiveRecoveryWorkflowDependencies
    ) throws {
        switch self {
        case .cancelScheduledDeletion(let id):
            try dependencies.cancelScheduledDeletion(root, id)
        case .delete(let id):
            try dependencies.deleteSnapshot(root, id)
        }
    }
}

final class HistoryArchiveRecoveryWorkflow: @unchecked Sendable {
    private let storageLayout: AppStateStorageLayout
    private let dependencies: HistoryArchiveRecoveryWorkflowDependencies
    private(set) var state = HistoryWorkflowState.initial
    var onEvent: (@MainActor (HistoryWorkflowEvent) -> Void)?
    private var inspectionQueue: [UUID] = []
    private var inspectionAttemptedIDs = Set<UUID>()
    private var inspectionRevision = 0
    private var inspectionActiveHistory: [PipelineHistoryItem] = []

    convenience init(
        storageLayout: AppStateStorageLayout,
        makeHistoryStore: @escaping
            HistoryArchiveRecoveryWorkflowDependencies.HistoryStoreFactory
    ) {
        self.init(
            storageLayout: storageLayout,
            dependencies: .live(makeHistoryStore: makeHistoryStore)
        )
    }

    init(
        storageLayout: AppStateStorageLayout,
        dependencies: HistoryArchiveRecoveryWorkflowDependencies
    ) {
        self.storageLayout = storageLayout
        self.dependencies = dependencies
    }

    func prepareStartup() -> HistoryStartupResult {
        Self.prepareDirectory(storageLayout.rootDirectory)
        Self.prepareDirectory(storageLayout.audioDirectory)
        Self.prepareDirectory(storageLayout.transcriptDirectory)

        let rollbackSafety = dependencies.rollbackInterruptedTransactions(
            storageLayout.rootDirectory
        )
        if rollbackSafety != .unresolvedInterruptedTransaction {
            _ = try? dependencies.removeExpiredSnapshots(
                storageLayout.rootDirectory
            )
        }
        let archiveSafety = dependencies.inspectArchiveSafety(
            storageLayout.rootDirectory
        )
        let activeStore = dependencies.makeHistoryStore(
            storageLayout.historyStoreURL
        )
        if activeStore.availability == .ready {
            activeStore.verifyHistoryReadable()
        }
        let unavailable = activeStore.availability == .unavailable
            || archiveSafety == .unresolvedInterruptedTransaction
        state = HistoryWorkflowState(
            archiveSafety: archiveSafety,
            archiveActivity: .idle,
            recoveryOperation: .idle,
            snapshots: dependencies.listSnapshots(
                storageLayout.rootDirectory
            ),
            inspections: [:],
            inspectionSnapshotID: nil,
            importResult: nil,
            isHistoryUnavailable: unavailable,
            showsPersistenceWarning: unavailable
                || activeStore.durability == .inMemory
        )
        return HistoryStartupResult(
            activeStore: activeStore,
            state: state,
            permitsNormalHistoryStartup:
                archiveSafety == .normal
                    && activeStore.availability == .ready,
            permitsUnresolvedArchiveStartup:
                archiveSafety == .unresolvedArchive
                    && activeStore.availability == .ready
        )
    }

    @MainActor
    func refreshSnapshots() {
        refreshSafetyAndSnapshots()
        emitState()
    }

    @MainActor
    func beginInspection(activeHistory: [PipelineHistoryItem]) {
        guard state.recoveryOperation == .idle,
              state.inspectionSnapshotID == nil else {
            return
        }
        inspectionActiveHistory = activeHistory
        inspectionAttemptedIDs = []
        inspectionQueue = state.snapshots.compactMap {
            $0.integrity == .ready ? $0.id : nil
        }
        startNextInspection()
    }

    @MainActor
    func ensureInspection(activeHistory: [PipelineHistoryItem]) {
        guard state.inspectionSnapshotID == nil,
              inspectionQueue.isEmpty,
              inspectionAttemptedIDs.isEmpty,
              state.inspections.isEmpty else {
            return
        }
        beginInspection(activeHistory: activeHistory)
    }

    @MainActor
    func retryInspection(
        id: UUID,
        activeHistory: [PipelineHistoryItem]
    ) -> HistoryWorkflowCommandResult {
        guard state.recoveryOperation == .idle else {
            return .rejected(.recoveryOperationInProgress)
        }
        guard state.inspectionSnapshotID != id else {
            return .rejected(.inspectionInProgress)
        }
        guard state.snapshots.contains(where: {
            $0.id == id && $0.integrity == .ready
        }) else {
            return .rejected(.snapshotUnavailable)
        }
        inspectionActiveHistory = activeHistory
        inspectionAttemptedIDs.remove(id)
        inspectionQueue.removeAll { $0 == id }
        inspectionQueue.insert(id, at: 0)
        startNextInspection()
        return .accepted
    }

    @MainActor
    func invalidateInspection(
        activeHistory: [PipelineHistoryItem],
        shouldReschedule: Bool
    ) {
        inspectionRevision &+= 1
        state.inspections = [:]
        inspectionQueue = []
        inspectionAttemptedIDs = []
        inspectionActiveHistory = activeHistory
        emitState()

        guard shouldReschedule,
              state.recoveryOperation == .idle else {
            return
        }
        inspectionQueue = state.snapshots.compactMap { snapshot in
            guard snapshot.integrity == .ready,
                  snapshot.status != .inspectionFailed else {
                return nil
            }
            return snapshot.id
        }
        inspectionAttemptedIDs = Set(
            state.snapshots.compactMap { snapshot in
                snapshot.status == .inspectionFailed ? snapshot.id : nil
            }
        )
        startNextInspection()
    }

    @MainActor
    @discardableResult
    func requestImport(
        snapshotID: UUID,
        context: HistoryWorkflowAdmissionContext,
        currentStore: PipelineHistoryStore,
        activeHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) -> HistoryWorkflowCommandResult {
        let admission = HistoryWorkflowAdmission.recoveryImport(
            state: state,
            snapshotID: snapshotID,
            context: context
        )
        guard admission == .accepted else { return admission }
        state.importResult = nil
        emitState()
        do {
            try currentStore.detachForArchiveVerification()
        } catch {
            emit(.failed(.historyUnavailable))
            return .rejected(.historyUnavailable)
        }

        state.recoveryOperation = .importing(snapshotID)
        emitState()
        let root = storageLayout.rootDirectory
        let layout = storageLayout
        let dependencies = dependencies
        let priorActiveHistory = activeHistory
        Task.detached(priority: .userInitiated) { [weak self] in
            let importStore = dependencies.makeHistoryStore(
                layout.historyStoreURL
            )
            do {
                guard importStore.availability == .ready,
                      importStore.durability == .durable,
                      importStore.verifyHistoryReadable() else {
                    throw HistoryRecoveryServiceError.snapshotNotReady
                }
                let result = try dependencies.importSnapshot(
                    root,
                    snapshotID,
                    importStore,
                    layout.audioDirectory,
                    layout.transcriptDirectory
                )
                try importStore.detachForArchiveVerification()
                await self?.completeImportSuccess(
                    result,
                    priorActiveHistory: priorActiveHistory,
                    shouldRescheduleInspection:
                        shouldRescheduleInspection
                )
            } catch {
                try? importStore.detachForArchiveVerification()
                await self?.completeImportFailure(
                    .recoveryImportFailed,
                    priorActiveHistory: priorActiveHistory,
                    shouldRescheduleInspection:
                        shouldRescheduleInspection
                )
            }
        }
        return .accepted
    }

    @MainActor
    func requestCancelScheduledDeletion(
        snapshotID: UUID,
        activeHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) -> HistoryWorkflowCommandResult {
        requestSnapshotOperation(
            .cancelScheduledDeletion(snapshotID),
            activeHistory: activeHistory,
            shouldRescheduleInspection: shouldRescheduleInspection
        )
    }

    @MainActor
    func requestDeleteSnapshot(
        snapshotID: UUID,
        activeHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) -> HistoryWorkflowCommandResult {
        requestSnapshotOperation(
            .delete(snapshotID),
            activeHistory: activeHistory,
            shouldRescheduleInspection: shouldRescheduleInspection
        )
    }

    @MainActor
    @discardableResult
    func requestArchive(
        context: HistoryWorkflowAdmissionContext,
        currentStore: PipelineHistoryStore,
        postAction: HistoryArchivePostAction
    ) -> HistoryWorkflowCommandResult {
        let admission = HistoryWorkflowAdmission.archive(
            state: state,
            context: context
        )
        guard admission == .accepted else { return admission }
        do {
            try currentStore.detachForHistoryArchive()
        } catch {
            emit(.failed(.historyUnavailable))
            return .rejected(.historyUnavailable)
        }

        state.archiveActivity = .transitioning(postAction: postAction)
        state.archiveSafety = .transitioning
        emitState()

        let root = storageLayout.rootDirectory
        let dependencies = dependencies
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try dependencies.archiveAndCreateFreshHistory(
                    root,
                    dependencies.makeHistoryStore
                )
                await self?.completeArchiveSuccess(
                    postAction: postAction
                )
            } catch {
                await self?.completeArchiveFailure(
                    .archiveTransitionFailed
                )
            }
        }
        return .accepted
    }

    @discardableResult
    func synchronize(
        activeStore: PipelineHistoryStore
    ) -> HistoryWorkflowState {
        state.isHistoryUnavailable =
            activeStore.availability == .unavailable
                || state.archiveSafety == .unresolvedInterruptedTransaction
        state.showsPersistenceWarning = state.isHistoryUnavailable
            || activeStore.durability == .inMemory
        return state
    }

    @MainActor
    private func requestSnapshotOperation(
        _ operation: HistorySnapshotOperation,
        activeHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) -> HistoryWorkflowCommandResult {
        let admission = HistoryWorkflowAdmission.snapshotOperation(
            state: state,
            snapshotID: operation.snapshotID,
            requiresCompletedSnapshot: operation.requiresCompletedSnapshot
        )
        guard admission == .accepted else { return admission }
        state.importResult = nil
        state.recoveryOperation = operation.recoveryOperation
        emitState()
        let root = storageLayout.rootDirectory
        let dependencies = dependencies
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try operation.perform(
                    root: root,
                    dependencies: dependencies
                )
                await self?.completeSnapshotOperationSuccess()
            } catch {
                await self?.completeSnapshotOperationFailure(
                    activeHistory: activeHistory,
                    shouldRescheduleInspection:
                        shouldRescheduleInspection
                )
            }
        }
        return .accepted
    }

    @MainActor
    private func completeImportSuccess(
        _ result: HistoryRecoveryImportResult,
        priorActiveHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) {
        let reopenedStore = dependencies.makeHistoryStore(
            storageLayout.historyStoreURL
        )
        guard reopenedStore.availability == .ready,
              reopenedStore.durability == .durable,
              reopenedStore.verifyHistoryReadable() else {
            completeImportFailure(
                .activeStoreReopenFailed,
                priorActiveHistory: priorActiveHistory,
                shouldRescheduleInspection: shouldRescheduleInspection,
                reopenedStore: reopenedStore
            )
            return
        }
        let history = reopenedStore.loadAllHistory()
        guard reopenedStore.availability == .ready else {
            completeImportFailure(
                .activeStoreReopenFailed,
                priorActiveHistory: priorActiveHistory,
                shouldRescheduleInspection: shouldRescheduleInspection,
                reopenedStore: reopenedStore
            )
            return
        }
        emit(.installRuntime(.recovered(
            historyStore: reopenedStore,
            history: history
        )))
        refreshSafetyAndSnapshots()
        state.recoveryOperation = .idle
        state.importResult = result.failedRecordCount > 0
                || result.conflictRecordCount > 0
            ? result
            : nil
        synchronizeStateForVerifiedStore(reopenedStore)
        invalidateInspection(
            activeHistory: history,
            shouldReschedule: shouldRescheduleInspection
        )
    }

    @MainActor
    private func completeImportFailure(
        _ requestedFailure: HistoryWorkflowFailure,
        priorActiveHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool,
        reopenedStore suppliedStore: PipelineHistoryStore? = nil
    ) {
        let reopenedStore = suppliedStore ?? dependencies.makeHistoryStore(
            storageLayout.historyStoreURL
        )
        var activeHistory = priorActiveHistory
        let failure: HistoryWorkflowFailure
        if reopenedStore.availability == .ready,
           reopenedStore.durability == .durable,
           reopenedStore.verifyHistoryReadable() {
            activeHistory = reopenedStore.loadAllHistory()
            if reopenedStore.availability == .ready {
                emit(.installRuntime(.recovered(
                    historyStore: reopenedStore,
                    history: activeHistory
                )))
                synchronizeStateForVerifiedStore(reopenedStore)
                failure = requestedFailure
            } else {
                state.isHistoryUnavailable = true
                state.showsPersistenceWarning = true
                failure = .activeStoreReopenFailed
            }
        } else {
            state.isHistoryUnavailable = true
            state.showsPersistenceWarning = true
            failure = .activeStoreReopenFailed
        }
        refreshSafetyAndSnapshots()
        state.recoveryOperation = .idle
        state.importResult = nil
        invalidateInspection(
            activeHistory: activeHistory,
            shouldReschedule: shouldRescheduleInspection
        )
        emit(.failed(failure))
    }

    @MainActor
    private func completeSnapshotOperationSuccess() {
        refreshSafetyAndSnapshots()
        state.recoveryOperation = .idle
        emitState()
        startNextInspection()
    }

    @MainActor
    private func completeSnapshotOperationFailure(
        activeHistory: [PipelineHistoryItem],
        shouldRescheduleInspection: Bool
    ) {
        refreshSafetyAndSnapshots()
        state.recoveryOperation = .idle
        state.importResult = nil
        invalidateInspection(
            activeHistory: activeHistory,
            shouldReschedule: shouldRescheduleInspection
        )
        emit(.failed(.snapshotOperationFailed))
    }

    @MainActor
    private func startNextInspection() {
        guard state.recoveryOperation == .idle,
              state.inspectionSnapshotID == nil else {
            return
        }
        while !inspectionQueue.isEmpty {
            let snapshotID = inspectionQueue.removeFirst()
            guard !inspectionAttemptedIDs.contains(snapshotID),
                  state.snapshots.contains(where: {
                      $0.id == snapshotID && $0.integrity == .ready
                  }) else {
                continue
            }
            inspectionAttemptedIDs.insert(snapshotID)
            state.inspectionSnapshotID = snapshotID
            emitState()
            let revision = inspectionRevision
            let activeHistory = inspectionActiveHistory
            let root = storageLayout.rootDirectory
            let inspectSnapshot = dependencies.inspectSnapshot
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let inspection = try inspectSnapshot(
                        root,
                        snapshotID,
                        activeHistory
                    )
                    await self?.completeInspection(
                        inspection,
                        snapshotID: snapshotID,
                        revision: revision
                    )
                } catch {
                    await self?.completeInspectionFailure(
                        snapshotID: snapshotID,
                        revision: revision
                    )
                }
            }
            return
        }
    }

    @MainActor
    private func completeInspection(
        _ inspection: HistoryRecoveryInspection,
        snapshotID: UUID,
        revision: Int
    ) {
        guard state.inspectionSnapshotID == snapshotID else { return }
        state.inspectionSnapshotID = nil
        refreshSafetyAndSnapshots()
        if inspectionRevision == revision,
           state.snapshots.contains(where: {
               $0.id == inspection.snapshotID
           }) {
            state.inspections[inspection.snapshotID] = inspection
        }
        emitState()
        startNextInspection()
    }

    @MainActor
    private func completeInspectionFailure(
        snapshotID: UUID,
        revision: Int
    ) {
        guard state.inspectionSnapshotID == snapshotID else { return }
        state.inspectionSnapshotID = nil
        refreshSafetyAndSnapshots()
        if inspectionRevision == revision {
            state.inspections.removeValue(forKey: snapshotID)
        }
        emitState()
        if inspectionRevision == revision {
            emit(.failed(.inspectionFailed(snapshotID)))
        }
        startNextInspection()
    }

    @MainActor
    private func completeArchiveSuccess(
        postAction: HistoryArchivePostAction
    ) {
        let activeStore = dependencies.makeHistoryStore(
            storageLayout.historyStoreURL
        )
        guard activeStore.availability == .ready,
              activeStore.durability == .durable,
              activeStore.verifyHistoryReadable() else {
            completeArchiveFailure(.freshStoreVerificationFailed)
            return
        }

        Self.prepareDirectory(storageLayout.rootDirectory)
        let audioDirectory = Self.prepareDirectory(
            storageLayout.audioDirectory
        )
        Self.prepareDirectory(storageLayout.transcriptDirectory)
        Self.prepareDirectory(storageLayout.cloudTranscriptionJobsDirectory)
        Self.prepareDirectory(storageLayout.cloudTranscriptionTemporaryDirectory)
        let runtime = HistoryFreshRuntime(
            historyStore: activeStore,
            recordingJournalStore:
                dependencies.makeRecordingJournalStore(audioDirectory),
            cloudTranscriptionJobStore:
                dependencies.makeCloudTranscriptionJobStore(storageLayout)
        )
        emit(.installRuntime(.fresh(runtime)))
        refreshSafetyAndSnapshots()
        state.archiveActivity = .idle
        synchronizeStateForVerifiedStore(activeStore)
        emitState()
        emit(.performPostAction(postAction))
    }

    @MainActor
    private func completeArchiveFailure(
        _ failure: HistoryWorkflowFailure
    ) {
        state.archiveSafety = dependencies.inspectArchiveSafety(
            storageLayout.rootDirectory
        )
        state.archiveActivity = .idle
        state.isHistoryUnavailable = true
        state.showsPersistenceWarning = true
        emitState()
        emit(.failed(failure))
    }

    @MainActor
    private func refreshSafetyAndSnapshots() {
        state.archiveSafety = dependencies.inspectArchiveSafety(
            storageLayout.rootDirectory
        )
        state.snapshots = dependencies.listSnapshots(
            storageLayout.rootDirectory
        )
        let currentIDs = Set(state.snapshots.map(\.id))
        state.inspections = state.inspections.filter {
            currentIDs.contains($0.key)
        }
        if state.archiveSafety == .unresolvedInterruptedTransaction {
            state.isHistoryUnavailable = true
            state.showsPersistenceWarning = true
        }
    }

    @MainActor
    private func synchronizeStateForVerifiedStore(
        _ activeStore: PipelineHistoryStore
    ) {
        state.isHistoryUnavailable =
            activeStore.availability == .unavailable
                || state.archiveSafety == .unresolvedInterruptedTransaction
        state.showsPersistenceWarning = state.isHistoryUnavailable
            || activeStore.durability == .inMemory
    }

    @discardableResult
    private static func prepareDirectory(_ directory: URL) -> URL {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    @MainActor
    private func emitState() {
        emit(.stateChanged(state))
    }

    @MainActor
    private func emit(_ event: HistoryWorkflowEvent) {
        onEvent?(event)
    }
}
