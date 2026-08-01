import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryAppStateTests {
    static func main() async throws {
        let originalFactory = await MainActor.run {
            AppState.meetingSummaryGeneratorFactory
        }
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        do {
            try await testGenerationPersistsOnlyAfterSuccess()
            try await testUnverifiedGenerationPersistsSummaryWarningState()
            try await testNonDurableHistoryWarningPreventsSummaryPersistence()
            try await testRecoveredHistoryWarningAllowsSummaryPersistence()
            try await testFailurePreservesExistingSummary()
            try await testGroundingFailurePreservesExistingSummaryAndCompletion()
            try await testLanguageMismatchPreservesSummaryAndRecordsAttempt()
            try await testLegacyAutoNotePersistsInferredKoreanOnGeneration()
            try await testSuccessfulAttemptSurvivesDurableReload()
            try await testFailedAttemptSurvivesDurableReload()
            try await testFailedAttemptPersistenceFailureRemainsTransient()
            try await testSourceChangePreservesExistingFailedAttempt()
            try await testTranscriptChangeDiscardsInflightResult()
            try await testTranscriptChangeFailureDoesNotPersistAttempt()
            try await testSuccessfulRetryInvalidatesInflightSummaryGeneration()
            try await testRetryWithMissingHistoryEntryKeepsSummaryGenerationActive()
            try await testDeleteWithMissingHistoryEntryKeepsSummaryGenerationActive()
            try await testClearWithSaveFailureKeepsSummaryGenerationActive()
            try await testDeleteDuringGenerationDoesNotRestoreSummary()
            try await testDeleteDuringGenerationFailureDoesNotPersistAttempt()
            try await testTranscriptReplacementReinfersDerivedSpokenLanguage()
            try await testTranscriptReplacementPreservesEngineDetectedLanguage()
            try await testTranscriptEditingPreservesSummaryMetadata()
            try await testActionCompletionPersists()
            try await testPostProcessingDisabledDoesNotBlockSummary()
            try await testDeleteMeetingSummaryRemovesEntireSummaryState()
            try await testDeleteMeetingSummaryRemovesFailedOnlyState()
            try await testDeleteMeetingSummaryRejectsStaleFailedAttempt()
            try await testDeleteFailedSummaryStatePersistsAndInvalidatesInflightGeneration()
            try await testFailedSummaryDeletePreservesStateWhenDurableWriteFails()
            try await testDeleteMeetingSummaryWithoutExistingSummaryThrows()
            try await testFailureAttemptUsesEffectiveFallbackModel()
            try await testSuccessfulGenerationMarksPendingRevealConsumableOnce()
            try await testFailedGenerationDoesNotMarkPendingReveal()
        } catch {
            await MainActor.run {
                AppState.meetingSummaryGeneratorFactory = originalFactory
            }
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            throw error
        }
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = originalFactory
        }
        AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
        print("MeetingSummaryAppStateTests passed")
    }

    private static func testSuccessfulGenerationMarksPendingRevealConsumableOnce() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
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
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.invalidResponse(.responseEnvelope)
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

    private static func testDeleteMeetingSummaryRemovesEntireSummaryState() async throws {
        let failedAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
            sourceFingerprint: String(repeating: "a", count: 64)
        )
        let item = makeItem()
            .withMeetingSummary(envelope(completed: false))
            .withMeetingSummaryAttempt(failedAttempt)
        let appState = try await configuredAppState(item: item)

        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
        }

        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == nil,
                "deleting a saved summary also clears a failed regeneration attempt"
            )
        }
    }

    private static func testDeleteMeetingSummaryRemovesFailedOnlyState() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        let failedAttempt = await MainActor.run {
            MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        _ = try store.upsert(failedOnly, maxCount: 10, requiresDurableStore: true)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let persistedAppState = await configuredPersistedAppState()

        try await MainActor.run {
            try persistedAppState.deleteMeetingSummary(noteID: item.id)
            precondition(persistedAppState.pipelineHistory[0].meetingSummary == nil)
            precondition(persistedAppState.pipelineHistory[0].meetingSummaryAttempt == nil)
        }
        guard let reloaded = store.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing deleted failed-only note")
        }
        precondition(reloaded.meetingSummary == nil)
        precondition(reloaded.meetingSummaryAttempt == nil)
    }

    private static func testDeleteMeetingSummaryRejectsStaleFailedAttempt() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        let staleAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
            sourceFingerprint: String(repeating: "b", count: 64)
        )
        await MainActor.run {
            appState.pipelineHistory[0] = item.withMeetingSummaryAttempt(staleAttempt)
        }

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure(
                "Expected stale summary attempt rejection"
            )
        } catch let error as MeetingSummaryError {
            precondition(error == .invalidInput)
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == staleAttempt,
                "a stale attempt is not deleted as a current hard failure"
            )
        }
    }

    private static func testDeleteFailedSummaryStatePersistsAndInvalidatesInflightGeneration() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem()
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await configuredPersistedAppState()
        let failedAttempt = await MainActor.run {
            let attempt = MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
            return attempt
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        try store.update(failedOnly, requiresDurableStore: true)
        await MainActor.run {
            appState.pipelineHistory = store.loadAllHistory()
        }

        let generator = MeetingSummaryControlledGenerator()
        await MainActor.run {
            configureSummaryGeneration(appState, generator: generator)
        }
        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt == nil)
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "deleting a failed-only summary immediately invalidates generation"
            )
        }
        guard let reloaded = store.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing deleted history entry")
        }
        precondition(reloaded.meetingSummary == nil)
        precondition(reloaded.meetingSummaryAttempt == nil)

        generator.complete(with: .success(generationResult))
        try await expectSourceChanged(summaryTask)
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummary == nil)
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testFailedSummaryDeletePreservesStateWhenDurableWriteFails() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var shouldFailSave = false
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: PipelineHistoryStore.loadPersistentStoresSynchronously,
            contextSaver: { context in
                if shouldFailSave {
                    throw MeetingSummaryAppStateTestFailure("Injected summary delete failure")
                }
                try context.save()
            }
        )
        let item = makeItem()
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await configuredPersistedAppState()
        let failedAttempt = await MainActor.run {
            MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: QuillUserIssueRecord(code: .meetingSummaryInvalidResponse),
                sourceFingerprint: appState.meetingSummarySource(for: item).fingerprint
            )
        }
        let failedOnly = item.withMeetingSummaryAttempt(failedAttempt)
        try store.update(failedOnly, requiresDurableStore: true)
        await MainActor.run {
            appState.pipelineHistory = store.loadAllHistory()
        }
        let generator = MeetingSummaryControlledGenerator()
        await MainActor.run {
            configureSummaryGeneration(appState, generator: generator)
        }
        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        shouldFailSave = true

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure("Expected durable summary delete failure")
        } catch let error as QuillUserIssueError {
            precondition(error.record.code == .historyPersistenceUnavailable)
        }

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == failedAttempt,
                "failed durable delete keeps its retryable diagnostic"
            )
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "failed durable delete keeps the in-flight summary state"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteMeetingSummaryWithoutExistingSummaryThrows() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)

        do {
            try await MainActor.run {
                try appState.deleteMeetingSummary(noteID: item.id)
            }
            throw MeetingSummaryAppStateTestFailure("Expected invalidInput")
        } catch let error as MeetingSummaryError {
            precondition(error == .invalidInput)
        }
    }

    private static func testFailureAttemptUsesEffectiveFallbackModel() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.rateLimited(
                        model: "fallback/model",
                        retryAfter: 1
                    )
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected fallback failure")
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {}

        await MainActor.run {
            let attempt = appState.pipelineHistory[0].meetingSummaryAttempt
            precondition(
                attempt?.modelID == "fallback/model",
                "failed attempt records the model that returned the terminal failure"
            )
            precondition(
                attempt?.issue?.context.modelID == "fallback/model",
                "failure Details identify the model that returned the terminal failure"
            )
        }
    }

    private static func testGenerationPersistsOnlyAfterSuccess() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let appState = try await configuredAppState(item: makeItem())
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

    private static func testUnverifiedGenerationPersistsSummaryWarningState() async throws {
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        let unverifiedResult = MeetingSummaryGenerationResult(
            draft: generationResult.draft,
            promptVersion: generationResult.promptVersion,
            modelID: generationResult.modelID,
            backendKind: generationResult.backendKind,
            evidenceVerification: .unverified
        )
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in unverifiedResult }
            }
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummary?.effectiveEvidenceVerification
                    == .unverified,
                "unresolved citations persist an unverified saved summary"
            )
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt?.outcome == .succeeded,
                "unverified evidence remains a successful summary result"
            )
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
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.invalidResponse(.responseEnvelope)
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
        let appState = try await configuredAppState(item: item)
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

    private static func testLanguageMismatchPreservesSummaryAndRecordsAttempt() async throws {
        let existing = envelope(completed: true)
        let item = makeItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        ).withMeetingSummary(existing)
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.outputRejected(.languageMismatch)
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected language mismatch")
        } catch let error as MeetingSummaryError {
            precondition(error == .outputRejected(.languageMismatch))
        }

        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.meetingSummary == existing)
            precondition(saved.meetingSummary?.content.actionItems[0].isCompleted == true)
            precondition(saved.meetingSummaryAttempt?.outcome == .failed)
            precondition(saved.meetingSummaryAttempt?.language?.appliedLanguageCode == "ko")
        }
    }

    private static func testLegacyAutoNotePersistsInferredKoreanOnGeneration() async throws {
        let item = makeItem(
            transcriptionLanguageCode: "auto",
            rawTranscript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
            postProcessedTranscript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        )
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.spokenLanguage == SpokenLanguageResolution(
                languageCode: "ko",
                source: .transcriptInferred
            ))
            precondition(saved.meetingSummary?.languageContext?.appliedLanguageCode == "ko")
            precondition(saved.meetingSummary?.languageContext?.resolutionSource == .transcriptInferred)
        }
    }

    private static func testSuccessfulAttemptSurvivesDurableReload() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        let store = PipelineHistoryStore(storeURL: storeURL)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await configuredPersistedAppState()
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
        }

        try await appState.generateMeetingSummary(id: item.id)

        let reloaded = PipelineHistoryStore(storeURL: storeURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded success item")
        }
        precondition(persisted.meetingSummary != nil)
        precondition(persisted.meetingSummaryAttempt?.outcome == .succeeded)
        precondition(
            persisted.meetingSummary?.languageContext
                == persisted.meetingSummaryAttempt?.language
        )
    }

    private static func testFailedAttemptSurvivesDurableReload() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        let store = PipelineHistoryStore(storeURL: storeURL)
        let existing = envelope(completed: true)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        ).withMeetingSummary(existing)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await configuredPersistedAppState()
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.outputRejected(.languageMismatch)
                }
            }
        }

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected summary failure")
        } catch let failure as MeetingSummaryAppStateTestFailure {
            throw failure
        } catch {}

        let reloaded = PipelineHistoryStore(storeURL: storeURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded failed item")
        }
        precondition(persisted.meetingSummary == existing)
        precondition(persisted.meetingSummaryAttempt?.outcome == .failed)
        precondition(persisted.meetingSummaryAttempt?.language?.appliedLanguageCode == "en")
    }

    private static func testFailedAttemptPersistenceFailureRemainsTransient() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        var shouldFailUpdate = false
        let store = PipelineHistoryStore(
            storeURL: storeURL,
            persistentStoreLoader: PipelineHistoryStore.loadPersistentStoresSynchronously,
            contextSaver: { context in
                if shouldFailUpdate {
                    throw MeetingSummaryAppStateTestFailure("Injected update failure")
                }
                try context.save()
            }
        )
        let existing = envelope(completed: true)
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        ).withMeetingSummary(existing)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)

        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await configuredPersistedAppState()
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in
                    throw MeetingSummaryError.outputRejected(.languageMismatch)
                }
            }
        }
        shouldFailUpdate = true

        do {
            try await appState.generateMeetingSummary(id: item.id)
            throw MeetingSummaryAppStateTestFailure("Expected persistence failure")
        } catch let issue as QuillUserIssueError {
            precondition(issue.record.code == .historyPersistenceUnavailable)
        }

        await MainActor.run {
            let visible = appState.pipelineHistory[0]
            precondition(visible.meetingSummary == existing)
            precondition(visible.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
        let reloaded = PipelineHistoryStore(storeURL: storeURL)
        guard let persisted = reloaded.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing reloaded transient item")
        }
        precondition(persisted.meetingSummary == existing)
        precondition(persisted.meetingSummaryAttempt == nil)
    }

    private static func testTranscriptEditingPreservesSummaryMetadata() async throws {
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "ko",
                resolutionSource: .engineDetected
            ),
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable)
        )
        let item = makeItem()
            .withSpokenLanguage(
                SpokenLanguageResolution(
                    languageCode: "ko",
                    source: .engineDetected
                )
            )
            .withMeetingSummaryAttempt(attempt)
        let store = PipelineHistoryStore(inMemory: true)
        _ = try store.append(item, maxCount: 10)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
        }
        AppState.pipelineHistoryStoreFactory = { store }
        let appState = await MainActor.run { AppState() }

        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Edited transcript.")

            let updated = appState.pipelineHistory[0]
            precondition(updated.postProcessedTranscript == "Edited transcript.")
            precondition(updated.spokenLanguage == item.spokenLanguage)
            precondition(updated.meetingSummaryAttempt == attempt)
        }

        guard let persisted = store.loadAllHistory().first else {
            throw MeetingSummaryAppStateTestFailure("Missing persisted note")
        }
        precondition(persisted.spokenLanguage == item.spokenLanguage)
        precondition(persisted.meetingSummaryAttempt == attempt)
    }

    private static func testSourceChangePreservesExistingFailedAttempt() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let previousAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable)
        )
        let item = makeItem().withMeetingSummaryAttempt(previousAttempt)
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Transcript B changed.")
        }
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == previousAttempt,
                "source invalidation leaves prior attempt historical instead of replacing it"
            )
        }
    }

    private static func testTranscriptChangeDiscardsInflightResult() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Transcript changed.")
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "source replacement immediately clears the invalidated generation state"
            )
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
            precondition(
                appState.pipelineHistory[0].meetingSummaryAttempt == nil,
                "source invalidation is not persisted as a provider failure"
            )
        }
    }

    private static func testTranscriptChangeFailureDoesNotPersistAttempt() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem()
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.updateTranscript(id: item.id, text: "Transcript B changed.")
        }
        generator.complete(with: .failure(URLError(.timedOut)))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            precondition(appState.pipelineHistory[0].meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testSuccessfulRetryInvalidatesInflightSummaryGeneration() async throws {
        let audioFileName = "retry-summary-invalidation-\(UUID().uuidString).mp3"
        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
        try Data([0]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem(audioFileName: audioFileName)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        let originalRetryDependenciesFactory = AppState.retryCloudTranscriptionDependenciesFactory
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            AppState.retryCloudTranscriptionDependenciesFactory = originalRetryDependenciesFactory
        }
        AppState.pipelineHistoryStoreFactory = { store }
        AppState.retryCloudTranscriptionDependenciesFactory = {
            CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: 10_000,
                upload: { request, _ in
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                    return (Data(#"{"text":"Retry source B."}"#.utf8), response)
                },
                checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in }
            )
        }
        let generator = MeetingSummaryControlledGenerator()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.apiKey = "configured-key"
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "https://provider.example/v1"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            appState.disablePostProcessing = true
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
            precondition(
                appState.meetingSummaryAvailability(for: appState.pipelineHistory[0])
                    == .available,
                "successful retry test requires an available summary source"
            )
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.retryTranscription(item: item)
        }
        try await waitUntilRetryCompletes(appState, noteID: item.id)

        await MainActor.run {
            let updated = appState.pipelineHistory[0]
            precondition(updated.postProcessedTranscript == "Retry source B.")
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "successful retry clears the invalidated summary generation state"
            )
        }
        generator.complete(with: .success(generationResult))

        do {
            try await summaryTask.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            let updated = appState.pipelineHistory[0]
            precondition(updated.meetingSummary == nil)
            precondition(updated.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testRetryWithMissingHistoryEntryKeepsSummaryGenerationActive() async throws {
        let audioFileName = "retry-missing-history-\(UUID().uuidString).mp3"
        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
        try Data([0]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected,
            audioFileName: audioFileName
        )
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        let originalRetryDependenciesFactory = AppState.retryCloudTranscriptionDependenciesFactory
        defer {
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            AppState.retryCloudTranscriptionDependenciesFactory = originalRetryDependenciesFactory
        }
        AppState.pipelineHistoryStoreFactory = { store }
        AppState.retryCloudTranscriptionDependenciesFactory = retryCloudDependencies(
            transcript: "Retry source B."
        )
        let generator = MeetingSummaryControlledGenerator()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.pipelineHistory = [item]
            configureSummaryGeneration(appState, generator: generator)
            appState.transcriptionAPIKey = "test-api-key"
            appState.transcriptionAPIURL = "https://provider.example/v1"
            appState.setNoteBrowserTranscriptionChoice(
                .apiStandard(modelID: "whisper-large-v3")
            )
            appState.disablePostProcessing = true
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.retryTranscription(item: item)
        }
        try await waitUntilRetryCompletes(appState, noteID: item.id)

        await MainActor.run {
            precondition(appState.pipelineHistory[0].postProcessedTranscript == item.postProcessedTranscript)
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "missing durable retry target leaves the existing summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteWithMissingHistoryEntryKeepsSummaryGenerationActive() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let generator = MeetingSummaryControlledGenerator()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.pipelineHistory = [item]
            configureSummaryGeneration(appState, generator: generator)
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        await MainActor.run {
            appState.deleteHistoryEntry(id: item.id)
            precondition(appState.pipelineHistory.map(\.id) == [item.id])
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "missing durable delete target leaves summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testClearWithSaveFailureKeepsSummaryGenerationActive() async throws {
        let directoryURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var shouldFailSave = false
        let store = PipelineHistoryStore(
            storeURL: directoryURL.appendingPathComponent("PipelineHistory.sqlite"),
            persistentStoreLoader: PipelineHistoryStore.loadPersistentStoresSynchronously,
            contextSaver: { context in
                if shouldFailSave {
                    throw MeetingSummaryAppStateTestFailure("Injected clear failure")
                }
                try context.save()
            }
        )
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        defer { AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory }
        AppState.pipelineHistoryStoreFactory = { store }
        let generator = MeetingSummaryControlledGenerator()
        let appState = await configuredPersistedAppState()
        await MainActor.run {
            configureSummaryGeneration(appState, generator: generator)
        }

        let summaryTask = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        shouldFailSave = true
        await MainActor.run {
            appState.clearPipelineHistory()
            precondition(appState.pipelineHistory.map(\.id) == [item.id])
            precondition(
                appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "failed durable clear leaves summary generation active"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.sourceChanged))
        try await expectSourceChanged(summaryTask)
    }

    private static func testDeleteDuringGenerationDoesNotRestoreSummary() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "deletion immediately clears the invalidated generation state"
            )
        }
        generator.complete(with: .success(generationResult))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected deletion invalidation")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.meetingSummary == nil)
            precondition(saved.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testDeleteDuringGenerationFailureDoesNotPersistAttempt() async throws {
        let generator = MeetingSummaryControlledGenerator()
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in generator }
        }

        let task = Task { @MainActor in
            try await appState.generateMeetingSummary(id: item.id)
        }
        await generator.waitUntilStarted()
        try await MainActor.run {
            try appState.deleteMeetingSummary(noteID: item.id)
            precondition(
                !appState.meetingSummaryGeneratingNoteIDs.contains(item.id),
                "deletion clears generation state before a provider failure returns"
            )
        }
        generator.complete(with: .failure(MeetingSummaryError.invalidResponse(.responseEnvelope)))

        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected deletion invalidation")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
        await MainActor.run {
            let saved = appState.pipelineHistory[0]
            precondition(saved.meetingSummary == nil)
            precondition(saved.meetingSummaryAttempt == nil)
            precondition(!appState.consumeMeetingSummaryPendingReveal(id: item.id))
        }
    }

    private static func testTranscriptReplacementReinfersDerivedSpokenLanguage() async throws {
        let item = makeItem(
            spokenLanguageCode: nil,
            spokenLanguageResolution: .unavailable,
            rawTranscript: "12345 ---",
            postProcessedTranscript: "12345 ---"
        )
        let appState = try await configuredAppState(item: item)
        await MainActor.run {
            AppState.meetingSummaryGeneratorFactory = { _ in
                MeetingSummaryGeneratorStub { _ in generationResult }
            }
            appState.updateTranscript(
                id: item.id,
                text: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
        }

        try await appState.generateMeetingSummary(id: item.id)

        await MainActor.run {
            precondition(appState.pipelineHistory[0].spokenLanguage == SpokenLanguageResolution(
                languageCode: "ko",
                source: .transcriptInferred
            ))
        }
    }

    private static func testTranscriptReplacementPreservesEngineDetectedLanguage() async throws {
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected
        )
        let appState = try await configuredAppState(item: item)

        await MainActor.run {
            appState.updateTranscript(
                id: item.id,
                text: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
            precondition(appState.pipelineHistory[0].spokenLanguage == SpokenLanguageResolution(
                languageCode: "en",
                source: .engineDetected
            ))
        }
    }

    private static func testActionCompletionPersists() async throws {
        let item = makeItem().withMeetingSummary(envelope(completed: false))
        let appState = try await configuredAppState(item: item)
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
        let appState = try await configuredAppState(item: item)
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

    private static func temporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private static func configuredPersistedAppState() async -> AppState {
        await MainActor.run {
            let appState = AppState()
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            return appState
        }
    }

    private static func configuredAppState(
        item: PipelineHistoryItem
    ) async throws -> AppState {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-meeting-summary-tests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let store = PipelineHistoryStore(storeURL: storeURL)
        _ = try store.upsert(item, maxCount: 10, requiresDurableStore: true)
        AppState.pipelineHistoryStoreFactory = { store }
        return await MainActor.run {
            let appState = AppState()
            appState.apiKey = "configured-key"
            appState.selectAIProcessingBackendChoice(
                .cloud(modelID: "summary/model"),
                for: .meetingSummary
            )
            appState.disableMeetingSummary = false
            return appState
        }
    }

    @MainActor
    private static func configureSummaryGeneration(
        _ appState: AppState,
        generator: MeetingSummaryControlledGenerator
    ) {
        appState.apiKey = "configured-key"
        appState.selectAIProcessingBackendChoice(
            .cloud(modelID: "summary/model"),
            for: .meetingSummary
        )
        appState.disableMeetingSummary = false
        AppState.meetingSummaryGeneratorFactory = { _ in generator }
        precondition(
            appState.meetingSummaryAvailability(for: appState.pipelineHistory[0])
                == .available,
            "test requires an available summary source"
        )
    }

    private static func retryCloudDependencies(
        transcript: String
    ) -> () -> CloudTranscriptionDependencies {
        {
            CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: 10_000,
                upload: { request, _ in
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                    return (Data(#"{"text":"\#(transcript)"}"#.utf8), response)
                },
                checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in }
            )
        }
    }

    private static func expectSourceChanged(
        _ task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            throw MeetingSummaryAppStateTestFailure("Expected source change")
        } catch let error as MeetingSummaryError {
            precondition(error == .sourceChanged)
        }
    }

    private static func waitUntilRetryCompletes(
        _ appState: AppState,
        noteID: UUID
    ) async throws {
        for _ in 0..<100 {
            let isRetrying = await MainActor.run {
                appState.retryingItemIDs.contains(noteID)
            }
            if !isRetrying { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MeetingSummaryAppStateTestFailure("Timed out waiting for retry")
    }

    private static func makeItem(
        transcriptionLanguageCode: String = "auto",
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        rawTranscript: String = "Decision: ship Friday.",
        postProcessedTranscript: String = "Decision: ship Friday.",
        audioFileName: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: nil,
            contextSummary: "Excluded context",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            audioFileName: audioFileName,
            usedPostProcessing: false,
            transcriptionLanguageCode: transcriptionLanguageCode,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution
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
