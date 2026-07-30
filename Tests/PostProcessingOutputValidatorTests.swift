import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingOutputValidatorTests {
    static func main() throws {
        try testMeaningfulTranscriptCannotBecomeEmptySentinel()
        try testKoreanOutputRejectsChineseReplacement()
        try testProtectedFlagsAndPathsMustSurvive()
        try testPromptTemplateLeakIsRejected()
        try testDisproportionatelyCollapsedMeaningfulTranscriptIsRejected()
        print("PostProcessingOutputValidatorTests passed")
    }

    private static func testMeaningfulTranscriptCannotBecomeEmptySentinel() throws {
        let result = PostProcessingOutputValidator().validate(
            source: "이번 주 금요일에 출시합니다.",
            output: "EMPTY",
            outputLanguage: "Korean",
            vocabulary: []
        )

        try expectFailure(result, equals: .nonFillerEmpty)
    }

    private static func testKoreanOutputRejectsChineseReplacement() throws {
        let result = PostProcessingOutputValidator().validate(
            source: "이번 주 금요일에 출시합니다.",
            output: "本次会议决定发布。",
            outputLanguage: "Korean",
            vocabulary: []
        )

        try expectFailure(result, equals: .languageMismatch)
    }

    private static func testProtectedFlagsAndPathsMustSurvive() throws {
        let result = PostProcessingOutputValidator().validate(
            source: "Run --fix for /tmp/report.json",
            output: "Run the fix.",
            outputLanguage: "",
            vocabulary: []
        )

        try expectFailure(result, equals: .protectedAtomMissing)
    }

    private static func testPromptTemplateLeakIsRejected() throws {
        let result = PostProcessingOutputValidator().validate(
            source: "Please keep this text.",
            output: "<<<RAW_TRANSCRIPTION\nPlease keep this text.\nRAW_TRANSCRIPTION",
            outputLanguage: "English",
            vocabulary: []
        )

        try expectFailure(result, equals: .promptLeak)
    }

    private static func testDisproportionatelyCollapsedMeaningfulTranscriptIsRejected() throws {
        let source = String(repeating: "The release owner confirmed the migration plan and rollback steps. ", count: 20)
        let result = PostProcessingOutputValidator().validate(
            source: source,
            output: "Okay.",
            outputLanguage: "English",
            vocabulary: []
        )

        try expectFailure(result, equals: .disproportionateCollapse)
    }

    private static func expectFailure(
        _ result: Result<String, AIValidationFailure>,
        equals expected: AIValidationFailure
    ) throws {
        switch result {
        case .success(let output):
            throw PostProcessingOutputValidatorTestFailure(
                "Expected \(expected), accepted \(output)"
            )
        case .failure(let actual):
            guard actual == expected else {
                throw PostProcessingOutputValidatorTestFailure(
                    "Expected \(expected), got \(actual)"
                )
            }
        }
    }
}

private struct PostProcessingOutputValidatorTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
