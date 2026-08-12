import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingChunkingTests {
    static func main() throws {
        try testParagraphsArePreferredAndRemainOrdered()
        try testSentencesSplitWhenParagraphExceedsBudget()
        try testLongTokenFallsBackToSafeByteBoundaries()
        try testMultibyteCharactersRespectSafeBoundaries()
        try testLargeUnbrokenTokenPreservesOrderAndBudget()
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

    private static func testMultibyteCharactersRespectSafeBoundaries() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 7)
        let source = "가나다🙂라마"

        let chunks = splitter.chunks(for: source)

        try expect(
            chunks.map(\.text).joined() == source,
            "multibyte chunks preserve every Character in order"
        )
        try expect(
            chunks.allSatisfy { chunk in
                chunk.text.count == 1 || chunk.text.utf8.count <= 7
            },
            "multibyte chunks stay within budget unless one Character exceeds it"
        )
    }

    private static func testLargeUnbrokenTokenPreservesOrderAndBudget() throws {
        let splitter = PostProcessingTranscriptSplitter(maximumSourceBytes: 1_024)
        let source = String(repeating: "abcdefghij", count: 10_000)

        let chunks = splitter.chunks(for: source)

        try expect(chunks.map(\.text).joined() == source, "large token preserves source order")
        try expect(chunks.count > 1, "large token is split")
        try expect(
            chunks.allSatisfy { $0.text.utf8.count <= 1_024 },
            "every ASCII chunk respects the byte budget"
        )
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
