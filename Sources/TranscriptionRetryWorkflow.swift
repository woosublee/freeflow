import Foundation

enum TranscriptionRetryOrigin: Equatable, Sendable {
    case manual
    case startupResume
}

enum TranscriptionRetryDeliveryPolicy: Equatable, Sendable {
    case interactive
    case historyOnly
}

struct TranscriptionRetrySourceIdentity: Equatable, Sendable {
    let noteID: UUID
    let noteTimestamp: Date
    let audioFileName: String
}

enum TranscriptionRetryProcessingDisposition: Equatable, Sendable {
    case succeeded
    case fallback
}

struct TranscriptionRetryProcessingResult: Sendable {
    let rawTranscript: String
    let finalTranscript: String
    let prompt: String?
    let postProcessingStatus: String
    let aiProcessingOutcome: AIProcessingOutcome
    let spokenLanguage: SpokenLanguageResolution
    let disposition: TranscriptionRetryProcessingDisposition
}

struct TranscriptionRetryProcessingBehavior {
    var process:
        @MainActor (TranscriptionResult) async
            -> TranscriptionRetryProcessingResult
}

struct TranscriptionRetryHistoryMetadata: Sendable {
    let customVocabulary: String
    let customSystemPrompt: String
    let usedLocalTranscription: Bool
    let usedPostProcessing: Bool
    let transcriptionLanguageCode: String
    let localTranscriptionModelID: String
    let successDebugStatus: String
}

struct TranscriptionRetryFailureContext: Sendable {
    let fallbackCode: QuillUserIssueCode
    let providerHost: String?
    let modelID: String
    let localBackend: String?
}

struct TranscriptionRetryWorkflowRequest {
    let origin: TranscriptionRetryOrigin
    let deliveryPolicy: TranscriptionRetryDeliveryPolicy
    let initialItem: PipelineHistoryItem
    let sourceIdentity: TranscriptionRetrySourceIdentity
    let audioURL: URL
    let execution: TranscriptionExecutionSnapshot
    let cloudDependencies: CloudTranscriptionDependencies
    let processing: TranscriptionRetryProcessingBehavior
    let historyMetadata: TranscriptionRetryHistoryMetadata
    let failureContext: TranscriptionRetryFailureContext
}

struct TranscriptionRetryStartupInput {
    let reconciliation: CloudTranscriptionReconciliation
    let runtime: CloudTranscriptionExecutionSnapshot
    let history: [PipelineHistoryItem]
    let audioDirectory: URL
    let cloudDependenciesFactory:
        @Sendable () -> CloudTranscriptionDependencies
    let makeProcessingBehavior:
        @MainActor (
            PipelineHistoryItem,
            TranscriptionCompletionSnapshot
        ) -> TranscriptionRetryProcessingBehavior
}

struct TranscriptionRetryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) throws -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}

struct TranscriptionRetryAssetAccess: Sendable {
    var saveTranscript:
        @Sendable (String, String) throws -> String
    var deleteTranscript:
        @Sendable (String) throws -> Void
}

struct TranscriptionRetryCloudAccess {
    let jobStore: CloudTranscriptionJobStore
    var cancelExistingExecution:
        @MainActor @Sendable (UUID) -> Void
}

struct TranscriptionRetryWorkflowRuntime {
    let history: TranscriptionRetryHistoryAccess
    let assets: TranscriptionRetryAssetAccess
    let cloud: TranscriptionRetryCloudAccess
}

struct TranscriptionRetryWorkflowState: Equatable, Sendable {
    var retryingNoteIDs: Set<UUID>
    var progressByNoteID: [UUID: CloudTranscriptionDisplayProgress]

    static let initial = TranscriptionRetryWorkflowState(
        retryingNoteIDs: [],
        progressByNoteID: [:]
    )
}

struct TranscriptionRetryPersistedEffects: Equatable, Sendable {
    let advancesWarningGeneration: Bool
    let invalidatesMeetingSummary: Bool
}

struct TranscriptionRetryCompletion: Equatable, Sendable {
    let interactiveTranscript: String?
    let transcriptAssetPersisted: Bool
    let cleanupFailureDescription: String?
}

struct TranscriptionRetryFailure: Equatable, Sendable {
    let issue: QuillUserIssueRecord
    let historyPersisted: Bool
}

enum TranscriptionRetryWorkflowOutcome: Equatable, Sendable {
    case succeeded(TranscriptionRetryCompletion)
    case fallback(TranscriptionRetryCompletion)
    case failed(TranscriptionRetryFailure)
    case cancelled
    case stale
    case persistenceFailed(QuillUserIssueRecord)
}

enum TranscriptionRetryWorkflowEvent {
    case stateChanged(TranscriptionRetryWorkflowState)
    case itemPersisted(
        PipelineHistoryItem,
        TranscriptionRetryPersistedEffects
    )
    case completed(UUID, TranscriptionRetryWorkflowOutcome)
}

struct TranscriptionRetryWorkflowDependencies {
    var transcribe:
        @Sendable (
            TranscriptionExecutionSnapshot,
            URL,
            CloudTranscriptionDependencies,
            CloudTranscriptionExecutionContext?
        ) async throws -> TranscriptionResult
    var makeAttemptToken: @Sendable () -> UUID

    static let live = TranscriptionRetryWorkflowDependencies(
        transcribe: { execution, audioURL, cloudDependencies, cloudContext in
            let service = try execution.makeTranscriptionService(
                cloudDependencies: cloudDependencies,
                cloudExecutionContext: cloudContext
            )
            return try await service.transcribe(fileURL: audioURL)
        },
        makeAttemptToken: { UUID() }
    )
}

private struct TranscriptionRetryActiveAttempt {
    let token: UUID
    var task: Task<Void, Never>?
    let jobStore: CloudTranscriptionJobStore
    let session: CloudTranscriptionJobSession
}

final class TranscriptionRetryWorkflow: @unchecked Sendable {
    private let dependencies: TranscriptionRetryWorkflowDependencies
    @MainActor private var activeAttempts: [UUID: TranscriptionRetryActiveAttempt] = [:]
    @MainActor private(set) var state = TranscriptionRetryWorkflowState.initial
    nonisolated(unsafe) var onEvent:
        (@MainActor (TranscriptionRetryWorkflowEvent) -> Void)?

    init(dependencies: TranscriptionRetryWorkflowDependencies = .live) {
        self.dependencies = dependencies
    }

    @MainActor
    @discardableResult
    func startManual(
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime
    ) -> Bool {
        let noteID = request.sourceIdentity.noteID
        guard runtime.history.durability() == .durable else {
            onEvent?(
                .completed(
                    noteID,
                    .persistenceFailed(
                        QuillUserIssueRecord(
                            code: .historyPersistenceUnavailable
                        )
                    )
                )
            )
            return false
        }

        cancelCurrentAttempt(noteID: noteID)
        runtime.cloud.cancelExistingExecution(noteID)

        let token = dependencies.makeAttemptToken()
        let session = runtime.cloud.jobStore.beginSession(historyID: noteID)
        let cloudContext = makeCloudContext(
            request: request,
            store: runtime.cloud.jobStore,
            session: session,
            token: token
        )
        activeAttempts[noteID] = TranscriptionRetryActiveAttempt(
            token: token,
            task: nil,
            jobStore: runtime.cloud.jobStore,
            session: session
        )
        state.retryingNoteIDs.insert(noteID)
        state.progressByNoteID.removeValue(forKey: noteID)
        emitState()

        let dependencies = dependencies
        let task = Task { [weak self] in
            do {
                let transcription = try await dependencies.transcribe(
                    request.execution,
                    request.audioURL,
                    request.cloudDependencies,
                    cloudContext
                )
                try Task.checkCancellation()
                let processing = await request.processing.process(transcription)
                self?.finishProcessedAttempt(
                    request: request,
                    runtime: runtime,
                    token: token,
                    processing: processing
                )
            } catch is CancellationError {
                self?.finishAttempt(
                    noteID: noteID,
                    token: token,
                    outcome: .cancelled
                )
            } catch {
                self?.finishFailedAttempt(
                    error,
                    request: request,
                    runtime: runtime,
                    token: token
                )
            }
        }
        guard activeAttempts[noteID]?.token == token else {
            task.cancel()
            return false
        }
        activeAttempts[noteID]?.task = task
        return true
    }

    static func classifyFailure(
        _ error: Error,
        context: TranscriptionRetryFailureContext
    ) -> QuillUserIssueError {
        if let issue = error as? QuillUserIssueError {
            return issue
        }
        if let code = urlErrorCode(in: error) {
            return QuillUserIssueError.cloudTransport(
                URLError(code),
                providerHost: context.providerHost,
                modelID: context.modelID
            )
        }
        let nsError = error as NSError
        return QuillUserIssueError(
            record: QuillUserIssueRecord(
                code: context.fallbackCode,
                context: QuillUserIssueContext(
                    providerHost: context.localBackend == nil
                        ? context.providerHost
                        : nil,
                    modelID: context.modelID,
                    localBackend: context.localBackend
                )
            ),
            privateDiagnostic: "\(nsError.domain) \(nsError.code)"
        )
    }

    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        var current: Error? = error
        var depth = 0
        while let candidate = current, depth < 8 {
            if let urlError = candidate as? URLError {
                return urlError.code
            }
            let nsError = candidate as NSError
            if nsError.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: nsError.code)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }

    @MainActor
    private func makeCloudContext(
        request: TranscriptionRetryWorkflowRequest,
        store: CloudTranscriptionJobStore,
        session: CloudTranscriptionJobSession,
        token: UUID
    ) -> CloudTranscriptionExecutionContext? {
        guard case .cloud(_, let completion) = request.execution else {
            return nil
        }
        let noteID = request.sourceIdentity.noteID
        return CloudTranscriptionExecutionContext(
            historyID: noteID,
            session: session,
            checkpointStore: store.checkpointStore(
                session: session,
                completionPolicy: completion.cloudJobPolicy
            ),
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.recordProgress(
                        progress,
                        noteID: noteID,
                        token: token
                    )
                }
            }
        )
    }

    @MainActor
    private func recordProgress(
        _ progress: CloudTranscriptionProgress,
        noteID: UUID,
        token: UUID
    ) {
        guard activeAttempts[noteID]?.token == token else { return }
        state.progressByNoteID[noteID] = Self.displayProgress(progress)
        emitState()
    }

    private static func displayProgress(
        _ progress: CloudTranscriptionProgress
    ) -> CloudTranscriptionDisplayProgress {
        switch progress {
        case .planned(let completed, let total):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: completed,
                totalChunkCount: total,
                activeAttempt: nil
            )
        case .uploading(let index, let total, let attempt):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: index,
                totalChunkCount: total,
                activeAttempt: attempt
            )
        case .completed(let total):
            return CloudTranscriptionDisplayProgress(
                completedChunkCount: total,
                totalChunkCount: total,
                activeAttempt: nil
            )
        }
    }

    @MainActor
    private func finishProcessedAttempt(
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime,
        token: UUID,
        processing: TranscriptionRetryProcessingResult
    ) {
        let noteID = request.sourceIdentity.noteID
        guard activeAttempts[noteID]?.token == token else { return }

        let currentItem: PipelineHistoryItem
        do {
            guard let item = try runtime.history.item(noteID) else {
                finishAttempt(noteID: noteID, token: token, outcome: .stale)
                return
            }
            currentItem = item
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }
        guard currentItem.timestamp == request.sourceIdentity.noteTimestamp,
              currentItem.audioFileName == request.sourceIdentity.audioFileName else {
            finishAttempt(noteID: noteID, token: token, outcome: .stale)
            return
        }

        let transcriptFileName: String?
        let createdTranscriptFileName: String?
        if let existingFileName = currentItem.transcriptFileName {
            transcriptFileName = existingFileName
            createdTranscriptFileName = nil
        } else {
            let created = try? runtime.assets.saveTranscript(
                processing.rawTranscript,
                processing.finalTranscript
            )
            transcriptFileName = created
            createdTranscriptFileName = created
        }

        guard activeAttempts[noteID]?.token == token else {
            if let createdTranscriptFileName {
                try? runtime.assets.deleteTranscript(createdTranscriptFileName)
            }
            return
        }

        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: processing.rawTranscript,
            postProcessedTranscript: processing.finalTranscript,
            postProcessingPrompt: processing.prompt,
            postProcessingStatus: processing.postProcessingStatus,
            aiProcessingOutcome: processing.aiProcessingOutcome.pipelineHistoryStatus,
            debugStatus: request.historyMetadata.successDebugStatus,
            customVocabulary: request.historyMetadata.customVocabulary,
            customSystemPrompt: request.historyMetadata.customSystemPrompt,
            usedLocalTranscription: request.historyMetadata.usedLocalTranscription,
            usedPostProcessing: request.historyMetadata.usedPostProcessing,
            transcriptionLanguageCode:
                request.historyMetadata.transcriptionLanguageCode,
            spokenLanguage: processing.spokenLanguage,
            localTranscriptionModelID:
                request.historyMetadata.localTranscriptionModelID,
            transcriptFileName: transcriptFileName
        )
        let updatedItem = currentItem.replacingTranscription(
            with: replacement
        )

        do {
            try runtime.history.persist(updatedItem, true)
        } catch {
            if let createdTranscriptFileName {
                try? runtime.assets.deleteTranscript(createdTranscriptFileName)
            }
            finishAttempt(
                noteID: noteID,
                token: token,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }

        guard activeAttempts[noteID]?.token == token else { return }
        onEvent?(
            .itemPersisted(
                updatedItem,
                TranscriptionRetryPersistedEffects(
                    advancesWarningGeneration: true,
                    invalidatesMeetingSummary: request.origin == .manual
                )
            )
        )

        let completion = TranscriptionRetryCompletion(
            interactiveTranscript: request.deliveryPolicy == .interactive
                ? processing.finalTranscript
                : nil,
            transcriptAssetPersisted: transcriptFileName != nil,
            cleanupFailureDescription: nil
        )
        let outcome: TranscriptionRetryWorkflowOutcome
        switch processing.disposition {
        case .succeeded:
            outcome = .succeeded(completion)
        case .fallback:
            outcome = .fallback(completion)
        }
        finishAttempt(noteID: noteID, token: token, outcome: outcome)
    }

    @MainActor
    private func finishFailedAttempt(
        _ error: Error,
        request: TranscriptionRetryWorkflowRequest,
        runtime: TranscriptionRetryWorkflowRuntime,
        token: UUID
    ) {
        let noteID = request.sourceIdentity.noteID
        guard activeAttempts[noteID]?.token == token else { return }
        let issue = Self.classifyFailure(
            error,
            context: request.failureContext
        )

        let currentItem: PipelineHistoryItem
        do {
            guard let item = try runtime.history.item(noteID) else {
                finishAttempt(noteID: noteID, token: token, outcome: .stale)
                return
            }
            currentItem = item
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }
        guard currentItem.timestamp == request.sourceIdentity.noteTimestamp,
              currentItem.audioFileName == request.sourceIdentity.audioFileName else {
            finishAttempt(noteID: noteID, token: token, outcome: .stale)
            return
        }

        guard request.origin == .manual else {
            finishAttempt(
                noteID: noteID,
                token: token,
                outcome: .failed(
                    TranscriptionRetryFailure(
                        issue: issue.record,
                        historyPersisted: false
                    )
                )
            )
            return
        }

        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: currentItem.rawTranscript,
            postProcessedTranscript: currentItem.postProcessedTranscript,
            postProcessingPrompt: currentItem.postProcessingPrompt,
            postProcessingStatus: issue.persistedStatus,
            aiProcessingOutcome: currentItem.aiProcessingOutcome,
            debugStatus: "Retry failed",
            customVocabulary: request.historyMetadata.customVocabulary,
            customSystemPrompt: request.historyMetadata.customSystemPrompt,
            usedLocalTranscription: request.historyMetadata.usedLocalTranscription,
            usedPostProcessing: request.historyMetadata.usedPostProcessing,
            transcriptionLanguageCode:
                request.historyMetadata.transcriptionLanguageCode,
            spokenLanguage: currentItem.spokenLanguage,
            localTranscriptionModelID:
                request.historyMetadata.localTranscriptionModelID,
            transcriptFileName: currentItem.transcriptFileName
        )
        let updatedItem = currentItem.replacingTranscription(
            with: replacement
        )
        do {
            try runtime.history.persist(updatedItem, true)
        } catch {
            finishAttempt(
                noteID: noteID,
                token: token,
                outcome: .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            )
            return
        }

        guard activeAttempts[noteID]?.token == token else { return }
        onEvent?(
            .itemPersisted(
                updatedItem,
                TranscriptionRetryPersistedEffects(
                    advancesWarningGeneration: true,
                    invalidatesMeetingSummary: false
                )
            )
        )
        finishAttempt(
            noteID: noteID,
            token: token,
            outcome: .failed(
                TranscriptionRetryFailure(
                    issue: issue.record,
                    historyPersisted: true
                )
            )
        )
    }

    @MainActor
    private func cancelCurrentAttempt(noteID: UUID) {
        guard let attempt = activeAttempts.removeValue(forKey: noteID) else {
            return
        }
        attempt.task?.cancel()
        attempt.jobStore.invalidateSession(historyID: noteID)
        state.retryingNoteIDs.remove(noteID)
        state.progressByNoteID.removeValue(forKey: noteID)
    }

    @MainActor
    private func finishAttempt(
        noteID: UUID,
        token: UUID,
        outcome: TranscriptionRetryWorkflowOutcome
    ) {
        guard let attempt = activeAttempts[noteID],
              attempt.token == token else {
            return
        }
        activeAttempts.removeValue(forKey: noteID)
        attempt.jobStore.invalidateSession(historyID: noteID)
        state.retryingNoteIDs.remove(noteID)
        state.progressByNoteID.removeValue(forKey: noteID)
        emitState()
        onEvent?(.completed(noteID, outcome))
    }

    @MainActor
    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
