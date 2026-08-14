import Foundation

struct MeetingSummaryGeneratorConfiguration: Sendable {
    let backendExecutor: AIProcessingBackendExecutor
    let cloudFallbackModelID: String?
}

struct MeetingSummaryWorkflowDependencies {
    var makeGenerator:
        @MainActor (MeetingSummaryGeneratorConfiguration)
            -> any MeetingSummaryGenerating
    var now: @Sendable () -> Date
}

struct MeetingSummaryWorkflowRequest {
    let noteID: UUID
    let initialItem: PipelineHistoryItem
    let requestedOutputLanguage: String
    let configuredBackendKind: MeetingSummaryBackendKind
    let configuredModelID: String
    let providerHost: String?
    let generatorConfiguration: MeetingSummaryGeneratorConfiguration
}

struct MeetingSummaryHistoryAccess {
    var durability:
        @MainActor @Sendable () -> PipelineHistoryDurability
    var item:
        @MainActor @Sendable (UUID) -> PipelineHistoryItem?
    var persist:
        @MainActor @Sendable (PipelineHistoryItem, Bool) throws -> Void
}

struct MeetingSummaryWorkflowState: Equatable, Sendable {
    var generatingNoteIDs: Set<UUID>
    var pendingRevealNoteIDs: Set<UUID>

    static let initial = MeetingSummaryWorkflowState(
        generatingNoteIDs: [],
        pendingRevealNoteIDs: []
    )
}

enum MeetingSummaryWorkflowEvent {
    case stateChanged(MeetingSummaryWorkflowState)
    case itemPersisted(PipelineHistoryItem)
}

enum MeetingSummaryWorkflowOutcome {
    case verifiedSuccess
    case unverifiedSuccess
    case invalidInput
    case sourceChanged
    case generationFailed(Error)
    case persistenceFailed
}

@MainActor
final class MeetingSummaryWorkflow {
    private let dependencies: MeetingSummaryWorkflowDependencies
    private var generationRevisionByID: [UUID: Int] = [:]
    private(set) var state = MeetingSummaryWorkflowState.initial
    var onEvent: ((MeetingSummaryWorkflowEvent) -> Void)?

    init(dependencies: MeetingSummaryWorkflowDependencies) {
        self.dependencies = dependencies
    }

    func invalidate(noteID: UUID) {
        generationRevisionByID[noteID, default: 0] += 1
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        emitState()
    }

    func forget(noteID: UUID) {
        generationRevisionByID.removeValue(forKey: noteID)
        state.generatingNoteIDs.remove(noteID)
        state.pendingRevealNoteIDs.remove(noteID)
        emitState()
    }

    func forgetAll() {
        generationRevisionByID.removeAll()
        state = .initial
        emitState()
    }

    func consumePendingReveal(noteID: UUID) -> Bool {
        let consumed = state.pendingRevealNoteIDs.remove(noteID) != nil
        if consumed { emitState() }
        return consumed
    }

    private func emitState() {
        onEvent?(.stateChanged(state))
    }
}
