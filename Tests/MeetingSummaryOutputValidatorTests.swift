import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryOutputValidatorTests {
    static func main() throws {
        try testRejectsSourceQuoteOutsideTranscript()
        try testRejectsGeneratedPartialProseAsMergeEvidence()
        try testRejectsActionOwnerOutsideSourceQuote()
        try testRejectsWrongLanguageInGeneratedProse()
        try testPreservesSourceQuoteLanguageWhileValidatingGeneratedProse()
        print("MeetingSummaryOutputValidatorTests passed")
    }

    private static func testRejectsSourceQuoteOutsideTranscript() throws {
        try expectFailure(.sourceQuoteNotFound) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote("invented source"),
                against: "Minsu will send it."
            )
        }
    }

    private static func testRejectsGeneratedPartialProseAsMergeEvidence() throws {
        let partial = v2WithQuote(
            "The team will ship Friday.",
            overview: "The launch is cancelled."
        )
        try expectFailure(.sourceQuoteNotFound) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote(
                    "The launch is cancelled.",
                    overview: "The release status changed."
                ),
                againstValidatedRecords: [partial]
            )
        }
    }

    private static func testRejectsActionOwnerOutsideSourceQuote() throws {
        try expectFailure(.ownerNotGrounded) {
            try MeetingSummaryOutputValidator().validate(
                v2WithOwner("Jiyun", quote: "Minsu will send it"),
                against: "Minsu will send it"
            )
        }
    }

    private static func testRejectsWrongLanguageInGeneratedProse() throws {
        try expectFailure(.languageMismatch) {
            try MeetingSummaryOutputValidator().validate(
                v2WithQuote(
                    "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
                    overview: "会议决定下周二发布产品，负责人将在今天完成说明文档。"
                ),
                outputLanguage: "Korean",
                against: "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
            )
        }
    }

    private static func testPreservesSourceQuoteLanguageWhileValidatingGeneratedProse() throws {
        let sourceQuote = "The release will ship next Tuesday."
        try MeetingSummaryOutputValidator().validate(
            v2WithQuote(sourceQuote, overview: "출시는 다음 주 화요일로 정했습니다."),
            outputLanguage: "Korean",
            against: sourceQuote
        )
    }

    private static func v2WithQuote(
        _ quote: String,
        overview: String = "The team reviewed the release schedule."
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: overview,
                sourceQuotes: [quote]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    }

    private static func v2WithOwner(
        _ owner: String,
        quote: String
    ) -> MeetingSummaryDraftContentV2 {
        MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "The team assigned the delivery task.",
                sourceQuotes: [quote]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: UUID(),
                    task: "Send it",
                    owner: owner,
                    dueDate: nil,
                    sourceQuote: quote,
                    isCompleted: false
                )
            ],
            openQuestions: []
        )
    }

    private static func expectFailure(
        _ expected: MeetingSummaryOutputValidationError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as MeetingSummaryOutputValidationError {
            guard error == expected else {
                throw MeetingSummaryOutputValidatorTestFailure(
                    "Expected \(expected), got \(error)"
                )
            }
            return
        }
        throw MeetingSummaryOutputValidatorTestFailure("Expected \(expected)")
    }
}

private struct MeetingSummaryOutputValidatorTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
