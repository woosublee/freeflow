import Foundation

@main
struct AIOutputLanguageValidatorTests {
    static func main() throws {
        try testKoreanProseIsAcceptedForKoreanSelection()
        try testChineseProseIsRejectedForKoreanSelection()
        try testEnglishProseIsRejectedForKoreanSelection()
        try testIdentifierOnlyOutputIsUncertainForKoreanSelection()
        try testNoConfiguredLanguageDoesNotForceTranslation()
        print("AIOutputLanguageValidatorTests passed")
    }

    private static func testKoreanProseIsAcceptedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "회의에서 다음 주 화요일에 출시하기로 결정했습니다. 담당자는 오늘 안에 안내 문서를 작성합니다."
        )

        try expect(result == .accepted, "Korean prose is accepted for Korean output")
    }

    private static func testChineseProseIsRejectedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "会议决定下周二发布产品，负责人将在今天完成说明文档。"
        )

        try expect(result == .mismatch, "Chinese prose is rejected for Korean output")
    }

    private static func testEnglishProseIsRejectedForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "The team decided to ship the product next Tuesday and will finish the notes today."
        )

        try expect(result == .mismatch, "English prose is rejected for Korean output")
    }

    private static func testIdentifierOnlyOutputIsUncertainForKoreanSelection() throws {
        let result = AIOutputLanguageValidator(outputLanguage: "Korean").validate(
            generatedProse: "quill_release_2026_v2"
        )

        try expect(result == .uncertain, "identifier-only output is handled as uncertain")
    }

    private static func testNoConfiguredLanguageDoesNotForceTranslation() throws {
        let result = AIOutputLanguageValidator(outputLanguage: nil).validate(
            generatedProse: "The team decided to ship next Tuesday."
        )

        try expect(result == .notRequested, "no language selection does not require a language match")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
