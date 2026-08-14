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

final class TranscriptionRetryWorkflow: @unchecked Sendable {
    private let dependencies: TranscriptionRetryWorkflowDependencies
    @MainActor private(set) var state = TranscriptionRetryWorkflowState.initial
    nonisolated(unsafe) var onEvent:
        (@MainActor (TranscriptionRetryWorkflowEvent) -> Void)?

    init(dependencies: TranscriptionRetryWorkflowDependencies = .live) {
        self.dependencies = dependencies
    }

    @MainActor
    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
