import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryAppStateTests {
    static func main() async throws {
        let originalFactory = await MainActor.run {
            AppState.meetingSummaryGeneratorFactory
        }
        do {
            try await testGenerationPersistsOnlyAfterSuccess()
            try await testNonDurableHistoryWarningPreventsSummaryPersistence()
            try await testRecoveredHistoryWarningAllowsSummaryPersistence()
            try await testFailurePreservesExistingSummary()
            try await testGroundingFailurePreservesExistingSummaryAndCompletion()
            try await testTranscriptChangeDiscardsInflightResult()
            try await testActionCompletionPersists()
            try await testPostProcessingDisabledDoesNotBlockSummary()
            try await testDeleteMeetingSummaryRemovesEnvelope()
            try await testDeleteMeetingSummaryWithoutExistingSummaryThrows()
            try await testSuccessfulGenerationMarksPendingRevealConsumableOnce()
            try await testFailedGenerationDoesNotMarkPendingReveal()
        } catch {
            await MainActor.run {
                AppState.meetingSummaryGeneratorFactory = originalFactory
            }
            throw error
        }
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = originalFactory
        }
        print("MeetingSummaryAppStateTests passed")
    }

    private static func testSuccessfulGenerationMarksPendingRevealConsumableOnce() async throws {
        let item = makeItem()
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(
                appState.consumeMeetingSummaryPendingReveal(id: item.id),
                "pending reveal is set after a successful generation"
            )
            precondition(
                !appState.consumeMeetingSummaryPendingReveal(id: item.id),
                "pending reveal is consumed only once"
            )
        }
    }

    private static func testFailedGenerationDoesNotMarkPendingReveal() async throws {
        let item = makeItem()
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.invalidResponse("Invalid")
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
        } catch {}

        await MainActor.run {
            precondition(
                !appState.consumeMeetingSummaryPendingReveal(id: item.id),
                "failed generation does not mark pending reveal"
            )
        }
    }

    private static func testDeleteMeetingSummaryRemovesEnvelope() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let appState = await configuredAppState(item: item)

        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
        }

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
        }
    }

    private static func testDeleteMeetingSummaryWithoutExistingSummaryThrows() async throws {
        let item = makeItem()
        let appState = await configuredAppState(item: item)

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure("Expected invalidInput")
        } catch let error as MeetingSummaryError {
            precondition(error == .invalidInput)
        }
    }

    private static func testGenerationPersistsOnlyAfterSuccess() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredAppState(item: makeItem())
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(
                id: appState.pipelineHistory[0].id
            )
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(
                    appState.pipelineHistory[0].id
                )
            )
        }

        generator.complete(with: .success(generationResult))
        try await task.value

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary != nil)
            precondition(appState.meetingSummaryGeneratingNoteIDs.isEmpty)
        }
    }

    private static func testNonDurableHistoryWarningPreventsSummaryPersistence() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = makeInMemoryFallbackStore(at: directoryURL)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
        }
        AppState.pipelineHistoryStoreFactory = { store }

        let item = makeItem()
        let appState = await MainActor.run {
            AppState()
        }
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            appState.pipelineHistory = [item]
            precondition(
                appState.historyPersistenceWarning?.code
                    == .historyPersistenceUnavailable,
                "in-memory history warns for this session"
            )
        }
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure(
                "Expected non-durable history warning"
            )
        } catch let issue as QuillUserIssueError {
            await MainActor.run {
                precondition(
                    issue.record.code == .historyPersistenceUnavailable,
                    "summary persistence uses the non-durable history warning"
                )
                precondition(
                    appState.pipelineHistory[0].meetingSummary == nil,
                    "new summary is not claimed as durably saved"
                )
            }
        }
    }

    private static func testRecoveredHistoryWarningAllowsSummaryPersistence() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = try makeRecoveredStore(at: directoryURL)
        let item = makeItem()
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
        }
        AppState.pipelineHistoryStoreFactory = { store }

        let appState = await MainActor.run {
            AppState()
        }
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            precondition(
                appState.historyPersistenceWarning?.code
                    == .historyRecovered,
                "recovered history warns without being treated as non-durable"
            )
            precondition(
                appState.pipelineHistory.contains(where: { $0.id == item.id }),
                "recovered durable history loads previously saved notes"
            )
        }
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(
                appState.pipelineHistory.first(where: { $0.id == item.id })?
                    .meetingSummary != nil,
                "recovered durable history accepts persisted summaries"
            )
        }
    }

    private static func testFailurePreservesExistingSummary() async throws {
        let existing = envelope(completed: true)
        let item = makeItem().withMeetingSummary(existing)
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.invalidResponse("Invalid")
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected generation failure")
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {}

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == existing)
        }
    }

    private static func testGroundingFailurePreservesExistingSummaryAndCompletion() async throws {
        let existing = envelope(completed: true)
        let item = makeItem().withMeetingSummary(existing)
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.outputRejected(.sourceQuoteNotFound)
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected grounding failure")
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {}

        await MainActor.run {
            let saved = appState.pipelineHistory[0].meetingSummary
            precondition(saved == existing)
            precondition(saved?.content.actionItems[0].isCompleted == true)
        }
    }

    private static func testTranscriptChangeDiscardsInflightResult() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem()
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Transcript changed.")
        }
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
        }
    }

    private static func testActionCompletionPersists() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let appState = await configuredAppState(item: item)
        let actionID = item.meetingSummary!.content.actionItems[0].id

        try await MainActor.run {
            try appState.setMeetingSummaryActionCompleted(
                noteID: item.id,
                actionID: actionID,
                isCompleted: true
            )
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0]
                    .meetingSummary?.content.actionItems[0].isCompleted == true
            )
        }
    }

    private static func testPostProcessingDisabledDoesNotBlockSummary() async throws {
        let item = makeItem()
        let appState = await configuredAppState(item: item)
        await MainActor.run {
            appState.disablePostProcessing = true
            precondition(
                appState.meetingSummaryAvailability(for: item) == .available
            )
        }
    }

    private static func makeInMemoryFallbackStore(
        at directoryURL: URL
    ) -> PipelineHistoryStore {
        var persistentLoadAttempts = 0
        return PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: { container in
                persistentLoadAttempts += 1
                if persistentLoadAttempts <= 2 {
                    return MeetingSummaryAppStateTestFailure(
                        "Injected persistent-store load failure"
                    )
                }
                return PipelineHistoryStore.loadPersistentStoresSynchronously(
                    container: container
                )
            }
        )
    }

    private static func makeRecoveredStore(
        at directoryURL: URL
    ) throws -> PipelineHistoryStore {
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try Data("invalid SQLite store".utf8).write(
                to: URL(fileURLWithPath: storeURL.path + suffix)
            )
        }
        var persistentLoadAttempts = 0
        return PipelineHistoryStore(
            storeURL: storeURL,
            persistentStoreLoader: { container in
                persistentLoadAttempts += 1
                if persistentLoadAttempts == 1 {
                    return MeetingSummaryAppStateTestFailure(
                        "Injected persistent-store load failure"
                    )
                }
                return PipelineHistoryStore.loadPersistentStoresSynchronously(
                    container: container
                )
            }
        )
    }

    private static func configuredAppState(
        item: PipelineHistoryItem
    ) async -> AppState {
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            appState.pipelineHistory = [item]
            return appState
        }
    }

    private static func makeItem() -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "Decision: ship Friday.",
            postProcessedTranscript: "Decision: ship Friday.",
            postProcessingPrompt: nil,
            contextSummary: "Excluded context",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            usedPostProcessing: false
        )
    }

    private static func envelope(completed: Bool) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
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
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                        task: "Write release notes",
                        owner: nil,
                        dueDate: nil,
                        sourceQuote: "Write release notes.",
                        isCompleted: completed
                    )
                ],
                openQuestions: []
            )
        )
    }

    private static let generationResult = MeetingSummaryGenerationResult(
        draft: MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: UUID(),
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Write release notes.",
                    isCompleted: false
                )
            ],
            openQuestions: []
        ),
        promptVersion: 1,
        modelID: "summary/model",
        backendKind: .cloud
    )
}

private final class MeetingSummaryGeneratorStub:
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

private final class MeetingSummaryControlledGenerator:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<MeetingSummaryGenerationResult, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            hasStarted = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ hasStarted }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if hasStarted { return true }
                startedWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func complete(
        with result: Result<MeetingSummaryGenerationResult, Error>
    ) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Value>(
        _ body: () throws -> Value
    ) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct MeetingSummaryAppStateTestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
