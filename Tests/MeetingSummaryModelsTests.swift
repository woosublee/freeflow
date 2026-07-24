import Foundation

@main
struct MeetingSummaryModelsTests {
    static func main() {
        testFingerprintIsDeterministicAndChangesWithTranscript()
        testFingerprintIncludesCalendarMetadata()
        testCompletionStateSurvivesEquivalentRegeneration()
        testMarkdownRendererIncludesAllSections()
        testSourceLocatorFindsExactQuote()
        testSourceLocatorDoesNotInventFuzzyRange()
        print("MeetingSummaryModelsTests passed")
    }

    private static func testFingerprintIsDeterministicAndChangesWithTranscript() {
        let source = MeetingSummarySource(
            transcript: "Decision: ship Friday.",
            calendar: nil
        )
        let same = MeetingSummarySource(
            transcript: "Decision: ship Friday.\n",
            calendar: nil
        )
        let changed = MeetingSummarySource(
            transcript: "Decision: ship Monday.",
            calendar: nil
        )

        precondition(source.fingerprint == same.fingerprint)
        precondition(source.fingerprint != changed.fingerprint)
        precondition(source.fingerprint.count == 64)
    }

    private static func testFingerprintIncludesCalendarMetadata() {
        let start = Date(timeIntervalSince1970: 1_000)
        let calendar = MeetingSummaryCalendarContext(
            title: "Design Review",
            start: start,
            end: start.addingTimeInterval(1_800),
            attendees: ["Ada", "Lin"]
        )
        let withoutCalendar = MeetingSummarySource(
            transcript: "Discuss launch.",
            calendar: nil
        )
        let withCalendar = MeetingSummarySource(
            transcript: "Discuss launch.",
            calendar: calendar
        )

        precondition(withoutCalendar.fingerprint != withCalendar.fingerprint)
    }

    private static func testCompletionStateSurvivesEquivalentRegeneration() {
        let old = MeetingSummaryEnvelope.fixture(
            actions: [
                MeetingSummaryActionItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    task: "Write release notes",
                    owner: "Ada",
                    dueDate: "2026-07-31",
                    sourceQuote: "Ada will write release notes by July 31.",
                    isCompleted: true
                )
            ]
        )
        let regenerated = MeetingSummaryEnvelope.fixture(
            actions: [
                MeetingSummaryActionItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    task: " write release notes ",
                    owner: "ADA",
                    dueDate: " 2026-07-31 ",
                    sourceQuote: "Ada will write release notes by July 31.",
                    isCompleted: false
                )
            ]
        )

        let preserved = regenerated.preservingCompletion(from: old)

        precondition(preserved.content.actionItems[0].isCompleted)
        precondition(
            preserved.content.actionItems[0].id
                == old.content.actionItems[0].id
        )
    }

    private static func testSourceLocatorFindsExactQuote() {
        let transcript = "First paragraph.\nDecision: ship Friday.\nLast paragraph."
        let range = MeetingSummarySourceLocator.range(
            of: "Decision: ship Friday.",
            in: transcript
        )

        precondition(range != nil)
        precondition(String(transcript[range!]) == "Decision: ship Friday.")
    }

    private static func testSourceLocatorDoesNotInventFuzzyRange() {
        let range = MeetingSummarySourceLocator.range(
            of: "Ship on Thursday",
            in: "Decision: ship Friday."
        )

        precondition(range == nil)
    }

    private static func testMarkdownRendererIncludesAllSections() {
        let rendered = MeetingSummaryMarkdownRenderer.render(
            .fixture(actions: [])
        )

        precondition(rendered.contains("## Overview"))
        precondition(rendered.contains("## Key Points"))
        precondition(rendered.contains("## Decisions"))
        precondition(rendered.contains("## Action Items"))
        precondition(rendered.contains("## Open Questions"))
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
            sourceFingerprint: String(repeating: "a", count: 64),
            modelID: "test/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: "The team reviewed the release.",
                keyPoints: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                        text: "The release remains on schedule.",
                        sourceQuote: "The release remains on schedule."
                    )
                ],
                decisions: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                        text: "Ship on Friday.",
                        sourceQuote: "Decision: ship Friday."
                    )
                ],
                actionItems: actions,
                openQuestions: [
                    MeetingSummaryPoint(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                        text: "Who will announce the release?",
                        sourceQuote: nil
                    )
                ]
            )
        )
    }
}
