import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingChunkingTests {
    static func main() throws {
        try testParagraphsArePreferredAndRemainOrdered()
        try testSentencesSplitWhenParagraphExceedsBudget()
        try testLongTokenFallsBackToSafeByteBoundaries()
        print("PostProcessingChunkingTests passed")
    }

    private static func testParagraphsArePreferredAndRemainOrdered() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 32)
        let source = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["First paragraph.", "Second paragraph.", "Third paragraph."],
            "paragraph chunks preserve source order"
        )
    }

    private static func testSentencesSplitWhenParagraphExceedsBudget() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 20)
        let source = "First sentence. Second sentence."

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["First sentence.", "Second sentence."],
            "sentence chunks avoid splitting within a sentence"
        )
    }

    private static func testLongTokenFallsBackToSafeByteBoundaries() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 8)
        let source = "abcdefghijklmno"

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text) == ["abcdefgh", "ijklmno"],
            "oversized token splits at safe byte boundaries"
        )
        try expect(chunks.allSatisfy { $0.text.utf8.count <= 8 }, "every chunk respects the byte budget")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PostProcessingChunkingTestFailure(message) }
    }
}

private struct PostProcessingChunkingTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
