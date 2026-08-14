import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryWorkflowTests {
    static func main() async throws {
        try await testStateAndInvalidationCommands()
        try await testVerifiedSuccessPersistsBeforeEventAndPreservesCompletion()
        try await testUnverifiedSuccessPersistsWarningAndAttempt()
        try await testExplicitLanguageOverridesSpokenLanguage()
        try await testEngineDetectedLanguageRequiresNoPreliminaryWrite()
        try await testTranscriptInferredLanguagePersistsBeforeGeneration()
        try await testUnavailableLanguageReturnsExistingIssue()
        try await testGenerationFailurePersistsAttemptWithoutReplacingSummary()
        try await testInferredLanguagePersistenceFailureIsTyped()
        try await testFailedAttemptPersistenceFailureIsTyped()
        try await testSuccessfulSummaryPersistenceFailureIsTyped()
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

    @MainActor
    private static func testExplicitLanguageOverridesSpokenLanguage() async throws {
        let initial = makeWorkflowItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: "English"
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "explicit language succeeds")
        try expect(
            source?.languageContext.appliedLanguageCode == "en",
            "explicit output language overrides spoken language"
        )
        try expect(
            source?.languageContext.resolutionSource == .configured,
            "explicit output language records configured resolution"
        )
        try expect(
            history.persistedItems.count == 1,
            "explicit language requires only the Summary write"
        )
    }

    @MainActor
    private static func
        testEngineDetectedLanguageRequiresNoPreliminaryWrite() async throws
    {
        let initial = makeWorkflowItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "detected language succeeds")
        try expect(
            source?.languageContext.appliedLanguageCode == "ko",
            "engine-detected language is applied"
        )
        try expect(
            source?.languageContext.resolutionSource == .engineDetected,
            "engine-detected source is preserved"
        )
        try expect(
            history.persistedItems.count == 1,
            "engine-detected language requires no preliminary write"
        )
    }

    @MainActor
    private static func
        testTranscriptInferredLanguagePersistsBeforeGeneration() async throws
    {
        let transcript = "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        let initial = makeWorkflowItem(
            transcript: transcript,
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "inferred language succeeds")
        try expect(
            history.persistedItems.first?.spokenLanguage
                == SpokenLanguageResolution(
                    languageCode: "ko",
                    source: .transcriptInferred
                ),
            "inferred Korean is durably saved first"
        )
        try expect(
            source?.languageContext.appliedLanguageCode == "ko",
            "generator receives the inferred Korean language"
        )
        try expect(
            source?.languageContext.resolutionSource == .transcriptInferred,
            "generator receives transcript-inferred resolution"
        )
        try expect(
            history.operations == ["persist-1", "persist-2"],
            "language metadata is saved before the Summary"
        )
        try expect(
            eventRecorder.persistedItems.count == 2,
            "each durable write emits one item event"
        )
    }

    @MainActor
    private static func testUnavailableLanguageReturnsExistingIssue() async throws {
        let initial = makeWorkflowItem(
            transcript: "",
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )

        guard case .generationFailed(let error) = outcome,
              let issue = error as? QuillUserIssueError else {
            throw MeetingSummaryWorkflowTestFailure(
                description: "language failure preserves its user issue"
            )
        }
        try expect(
            issue.record.code == .meetingSummaryLanguageUnavailable,
            "unavailable language uses the existing issue code"
        )
    }

    @MainActor
    private static func
        testGenerationFailurePersistsAttemptWithoutReplacingSummary() async throws
    {
        let actionID = UUID()
        let existing = makeWorkflowEnvelope(actionID: actionID, completed: true)
        let initial = makeWorkflowItem().withMeetingSummary(existing)
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let failure = MeetingSummaryError.outputRejected(
            .languageMismatch,
            modelID: "fallback/model"
        )
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw failure
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isGenerationFailure(outcome, matching: failure),
            "generation failure is typed"
        )
        try expect(
            history.storedItem?.meetingSummary == existing,
            "failure preserves the existing Summary"
        )
        try expect(
            history.storedItem?.meetingSummary?
                .content.actionItems.first?.isCompleted == true,
            "failure preserves action completion"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .failed,
            "failure persists a failed attempt"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.modelID
                == "fallback/model",
            "failure records the effective model"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.providerHost
                == "api.example.com",
            "failure records the captured provider host"
        )
    }

    @MainActor
    private static func testInferredLanguagePersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem(
            transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )

        try expect(
            isPersistenceFailure(outcome),
            "language persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed language persistence emits no item event"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed language persistence creates no pending reveal"
        )
    }

    @MainActor
    private static func testFailedAttemptPersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw MeetingSummaryError.outputRejected(
                            .languageMismatch,
                            modelID: "fallback/model"
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
            isPersistenceFailure(outcome),
            "failed-attempt persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed-attempt write emits no item event"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt == nil,
            "failed-attempt write does not mutate durable state"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed attempt creates no pending reveal"
        )
    }

    @MainActor
    private static func testSuccessfulSummaryPersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
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
            isPersistenceFailure(outcome),
            "successful Summary persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed Summary write emits no item event"
        )
        try expect(
            history.storedItem?.meetingSummary == nil,
            "failed Summary write does not mutate durable state"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed Summary write creates no pending reveal"
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

private actor MeetingSummaryWorkflowSourceRecorder {
    private var sources: [MeetingSummarySource] = []

    func record(_ source: MeetingSummarySource) {
        sources.append(source)
    }

    func latest() -> MeetingSummarySource? {
        sources.last
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

private func isGenerationFailure(
    _ outcome: MeetingSummaryWorkflowOutcome,
    matching expected: MeetingSummaryError
) -> Bool {
    guard case .generationFailed(let error) = outcome,
          let summaryError = error as? MeetingSummaryError else {
        return false
    }
    return summaryError == expected
}

private func isPersistenceFailure(
    _ outcome: MeetingSummaryWorkflowOutcome
) -> Bool {
    if case .persistenceFailed = outcome { return true }
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
