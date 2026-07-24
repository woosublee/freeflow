import Foundation

@main
struct PipelineHistoryMeetingSummaryTests {
    static func main() throws {
        try testLegacyItemDecodesMissingSummaryAsNil()
        try testSummaryRoundTripsThroughCodable()
        try testSummaryRoundTripsThroughCoreDataStore()
        testItemCopyHelpersPreserveSummary()
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

    private static func testSummaryRoundTripsThroughCoreDataStore() throws {
        let store = PipelineHistoryStore(inMemory: true)
        let item = makeItem().withMeetingSummary(.fixture(actions: []))
        _ = try store.append(item, maxCount: 10)
        let loaded = try unwrap(store.loadAllHistory().first)

        precondition(loaded.meetingSummary == item.meetingSummary)
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

    private static func makeItem() -> PipelineHistoryItem {
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
            customVocabulary: ""
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
                overview: "Release review",
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
