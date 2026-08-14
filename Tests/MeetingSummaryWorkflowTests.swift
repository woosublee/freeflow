import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryWorkflowTests {
    static func main() async throws {
        try await testStateAndInvalidationCommands()
        try await testVerifiedSuccessPersistsBeforeEventAndPreservesCompletion()
        try await testUnverifiedSuccessPersistsWarningAndAttempt()
        print("MeetingSummaryWorkflowTests passed")
    }

    @MainActor
    private static func testStateAndInvalidationCommands() async throws {
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw MeetingSummaryError.invalidInput
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        let noteID = UUID()
        var states: [MeetingSummaryWorkflowState] = []
        workflow.onEvent = { event in
            if case .stateChanged(let state) = event {
                states.append(state)
            }
        }

        workflow.invalidate(noteID: noteID)
        workflow.forget(noteID: noteID)
        workflow.forgetAll()

        try expect(
            workflow.state.generatingNoteIDs.isEmpty,
            "no generation is active"
        )
        try expect(
            workflow.state.pendingRevealNoteIDs.isEmpty,
            "no reveal is pending"
        )
        try expect(
            !states.isEmpty,
            "state commands emit complete snapshots"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: noteID),
            "missing reveal is not consumed"
        )
    }

    @MainActor
    private static func
        testVerifiedSuccessPersistsBeforeEventAndPreservesCompletion() async throws
    {
        let actionID = UUID()
        let initial = makeWorkflowItem().withMeetingSummary(
            makeWorkflowEnvelope(actionID: actionID, completed: true)
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult(actionID: actionID)
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(isVerifiedSuccess(outcome), "verified success is typed")
        try expect(
            history.storedItem?.meetingSummary?
                .content.actionItems.first?.isCompleted == true,
            "successful generation preserves action completion"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .succeeded,
            "successful generation persists a succeeded attempt"
        )
        try expect(
            eventRecorder.itemEventsObservedAfterPersistence,
            "item events follow durable persistence"
        )
        try expect(
            workflow.consumePendingReveal(noteID: initial.id),
            "success creates pending reveal"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "pending reveal is consumed once"
        )
    }

    @MainActor
    private static func testUnverifiedSuccessPersistsWarningAndAttempt() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult(
                            evidenceVerification: .unverified
                        )
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isUnverifiedSuccess(outcome),
            "unverified success is typed"
        )
        try expect(
            history.storedItem?.meetingSummary?
                .effectiveEvidenceVerification == .unverified,
            "unverified evidence state is persisted"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .succeeded,
            "unverified success persists a succeeded attempt"
        )
        try expect(
            eventRecorder.persistedItems.count == 1,
            "unverified success emits one persisted item"
        )
    }
}

@MainActor
private final class MeetingSummaryWorkflowHistoryRecorder {
    var storedItem: PipelineHistoryItem?
    var durabilityValue: PipelineHistoryDurability = .durable
    var failingPersistCalls = Set<Int>()
    private var persistCallCount = 0
    private(set) var persistedItems: [PipelineHistoryItem] = []
    private(set) var operations: [String] = []

    init(item: PipelineHistoryItem?) {
        storedItem = item
    }

    var access: MeetingSummaryHistoryAccess {
        MeetingSummaryHistoryAccess(
            durability: { [weak self] in
                self?.durabilityValue ?? .inMemory
            },
            item: { [weak self] id in
                guard self?.storedItem?.id == id else { return nil }
                return self?.storedItem
            },
            persist: { [weak self] item, requiresDurableStore in
                guard let self else { return }
                persistCallCount += 1
                operations.append("persist-\(persistCallCount)")
                if failingPersistCalls.contains(persistCallCount) {
                    throw MeetingSummaryWorkflowTestFailure(
                        description: "intentional persistence failure"
                    )
                }
                if requiresDurableStore,
                   durabilityValue != .durable {
                    throw MeetingSummaryWorkflowTestFailure(
                        description: "durable store required"
                    )
                }
                storedItem = item
                persistedItems.append(item)
            }
        )
    }
}

@MainActor
private final class MeetingSummaryWorkflowEventRecorder {
    private let history: MeetingSummaryWorkflowHistoryRecorder
    private(set) var persistedItems: [PipelineHistoryItem] = []
    private(set) var itemEventsObservedAfterPersistence = true

    init(history: MeetingSummaryWorkflowHistoryRecorder) {
        self.history = history
    }

    func record(_ event: MeetingSummaryWorkflowEvent) {
        guard case .itemPersisted(let item) = event else { return }
        if history.persistedItems.last?.id != item.id {
            itemEventsObservedAfterPersistence = false
        }
        persistedItems.append(item)
    }
}

private func makeWorkflowItem(
    id: UUID = UUID(),
    transcript: String = "Decision: ship Friday.",
    spokenLanguageCode: String? = "en",
    spokenLanguageResolution:
        SpokenLanguageResolutionSource? = .engineDetected
) -> PipelineHistoryItem {
    PipelineHistoryItem(
        id: id,
        timestamp: Date(timeIntervalSince1970: 1_000),
        rawTranscript: transcript,
        postProcessedTranscript: transcript,
        postProcessingPrompt: nil,
        contextSummary: "Excluded context",
        contextPrompt: nil,
        contextScreenshotDataURL: nil,
        contextScreenshotStatus: "No screenshot",
        postProcessingStatus: "Post-processing succeeded",
        debugStatus: "Done",
        customVocabulary: "",
        usedPostProcessing: false,
        transcriptionLanguageCode: "auto",
        spokenLanguageCode: spokenLanguageCode,
        spokenLanguageResolution: spokenLanguageResolution
    )
}

private func makeWorkflowEnvelope(
    actionID: UUID,
    completed: Bool
) -> MeetingSummaryEnvelope {
    MeetingSummaryEnvelope(
        schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
        promptVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1_500),
        sourceFingerprint: String(repeating: "c", count: 64),
        modelID: "summary/model",
        backendKind: .cloud,
        content: MeetingSummaryContent(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: actionID,
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Decision: ship Friday.",
                    isCompleted: completed
                )
            ],
            openQuestions: []
        )
    )
}

private func makeWorkflowGenerationResult(
    actionID: UUID = UUID(),
    evidenceVerification:
        MeetingSummaryEvidenceVerification = .verified
) -> MeetingSummaryGenerationResult {
    MeetingSummaryGenerationResult(
        draft: MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: actionID,
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Decision: ship Friday.",
                    isCompleted: false
                )
            ],
            openQuestions: []
        ),
        promptVersion: 1,
        modelID: "summary/model",
        backendKind: .cloud,
        evidenceVerification: evidenceVerification
    )
}

private func makeWorkflowGeneratorConfiguration()
    -> MeetingSummaryGeneratorConfiguration
{
    MeetingSummaryGeneratorConfiguration(
        backendExecutor: AIProcessingBackendExecutor(
            choice: .cloud(modelID: "summary/model"),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "test-key"
        ),
        cloudFallbackModelID: "summary/fallback"
    )
}

private func makeWorkflowRequest(
    item: PipelineHistoryItem,
    requestedOutputLanguage: String = "English"
) -> MeetingSummaryWorkflowRequest {
    MeetingSummaryWorkflowRequest(
        noteID: item.id,
        initialItem: item,
        requestedOutputLanguage: requestedOutputLanguage,
        configuredBackendKind: .cloud,
        configuredModelID: "summary/model",
        providerHost: "api.example.com",
        generatorConfiguration: makeWorkflowGeneratorConfiguration()
    )
}

private func isVerifiedSuccess(_ outcome: MeetingSummaryWorkflowOutcome) -> Bool {
    if case .verifiedSuccess = outcome { return true }
    return false
}

private func isUnverifiedSuccess(_ outcome: MeetingSummaryWorkflowOutcome) -> Bool {
    if case .unverifiedSuccess = outcome { return true }
    return false
}

private final class MeetingSummaryWorkflowGeneratorStub:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    typealias Operation = @Sendable (
        MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await operation(source)
    }
}

private struct MeetingSummaryWorkflowTestFailure:
    Error,
    CustomStringConvertible
{
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ description: String
) throws {
    guard condition() else {
        throw MeetingSummaryWorkflowTestFailure(
            description: description
        )
    }
}
