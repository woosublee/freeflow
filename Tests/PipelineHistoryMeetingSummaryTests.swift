import Foundation

@main
struct PipelineHistoryMeetingSummaryTests {
    static func main() throws {
        try testLegacyItemDecodesMissingSummaryAsNil()
        try testSummaryRoundTripsThroughCodable()
        try testSummaryPersistsEvidenceBearingV2()
        try testUnverifiedSummaryRoundTripsThroughCoreDataStore()
        try testSummaryRoundTripsThroughCoreDataStore()
        try testSpokenLanguageAndSummaryAttemptRoundTrip()
        testUnavailableSpokenLanguageNeverRetainsCode()
        testItemCopyHelpersPreserveSummary()
        testMeetingSummaryAttemptCopyHelperPreservesSummary()
        print("PipelineHistoryMeetingSummaryTests passed")
    }

    private static func testLegacyItemDecodesMissingSummaryAsNil() throws {
        let data = try JSONEncoder().encode(makeItem())
        let decoded = try JSONDecoder().decode(
            PipelineHistoryItem.self,
            from: data
        )

        precondition(decoded.meetingSummaryJSON == nil)
        precondition(decoded.meetingSummary == nil)
    }

    private static func testSummaryRoundTripsThroughCodable() throws {
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(
            PipelineHistoryItem.self,
            from: data
        )

        precondition(decoded.meetingSummary == item.meetingSummary)
    }

    private static func testSummaryPersistsEvidenceBearingV2() throws {
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        let summaryJSON = try unwrap(item.meetingSummaryJSON)
        let root = try JSONSerialization.jsonObject(with: summaryJSON) as? [String: Any]
        let content = root?["content"] as? [String: Any]
        let overview = content?["overview"] as? [String: Any]

        precondition(root?["schemaVersion"] as? Int == 4)
        precondition(overview?["text"] as? String == "Release review")
        precondition(overview?["sourceQuotes"] as? [String] == ["Decision: ship Friday."])
    }

    private static func testUnverifiedSummaryRoundTripsThroughCoreDataStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let unverified = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 3,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sourceFingerprint: "f",
            modelID: "summary/model",
            backendKind: .local,
            evidenceVerification: .unverified,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Release review",
                    sourceQuotes: ["Invented citation."]
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )
        _ = try store.append(
            makeItem().withMeetingSummary(unverified),
            maxCount: 10
        )
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.meetingSummary?.effectiveEvidenceVerification == .unverified)
    }

    private static func testSummaryRoundTripsThroughCoreDataStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        _ = try store.append(item, maxCount: 10)
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.meetingSummary == item.meetingSummary)
    }

    private static func testSpokenLanguageAndSummaryAttemptRoundTrip() throws {
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
            issue: QuillUserIssueRecord(
                code: .meetingSummaryInvalidResponse,
                context: QuillUserIssueContext(
                    meetingSummaryFailureSubtype: .contextBudget
                )
            ),
            sourceFingerprint: String(repeating: "a", count: 64)
        )
        let item = makeItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt
        )
        let store = PipelineHistoryStore(inMemory: true)

        _ = try store.append(item, maxCount: 10)
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.spokenLanguage == item.spokenLanguage)
        precondition(loaded.meetingSummaryAttempt == attempt)
    }

    private static func testUnavailableSpokenLanguageNeverRetainsCode() {
        let item = makeItem(
            spokenLanguageCode: "en",
            spokenLanguageResolution: .unavailable
        )

        precondition(
            item.spokenLanguage == SpokenLanguageResolution(
                languageCode: nil,
                source: .unavailable
            ),
            "an unavailable result cannot revive an older spoken language code"
        )
    }

    private static func testItemCopyHelpersPreserveSummary() {
        let item = makeItem().withMeetingSummary(
            .fixture(
                actions: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                        task: "Write release notes",
                        owner: "Ada",
                        dueDate: nil,
                        sourceQuote: nil,
                        isCompleted: true
                    )
                ]
            )
        )

        precondition(
            item.withCustomTitle("Release review").meetingSummary
                == item.meetingSummary
        )
        precondition(
            item.markInterruptedBeforeCompletion().meetingSummary
                == item.meetingSummary
        )
    }

    private static func testMeetingSummaryAttemptCopyHelperPreservesSummary() {
        let summary = MeetingSummaryEnvelope.fixture(actions: [])
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_100),
            outcome: .succeeded,
            backendKind: .local,
            modelID: "summary/model",
            providerHost: nil,
            language: nil,
            issue: nil
        )
        let item = makeItem()
            .withMeetingSummary(summary)
            .withMeetingSummaryAttempt(attempt)

        precondition(item.meetingSummary == summary)
        precondition(item.meetingSummaryAttempt == attempt)
    }

    private static func makeItem(
        spokenLanguageCode: String? = nil,
        spokenLanguageResolution: SpokenLanguageResolutionSource? = nil,
        meetingSummaryAttempt: MeetingSummaryAttempt? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "Decision: ship Friday.",
            postProcessedTranscript: "Decision: ship Friday.",
            postProcessingPrompt: nil,
            contextSummary: "Unrelated context",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt
        )
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw TestError.missingValue }
        return value
    }
}

private extension MeetingSummaryEnvelope {
    static func fixture(
        actions: [MeetingSummaryActionItem]
    ) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 2_000),
            sourceFingerprint: String(repeating: "b", count: 64),
            modelID: "test/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Release review",
                    sourceQuotes: ["Decision: ship Friday."]
                ),
                keyPoints: [],
                decisions: [],
                actionItems: actions,
                openQuestions: []
            )
        )
    }
}

private enum TestError: Error {
    case missingValue
}
