import Foundation

struct MeetingSummaryTextChunk: Equatable, Sendable {
    let index: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
}

struct MeetingSummaryTextChunker: Sendable {
    static let defaultMaxCharacters = 12_000

    let maxCharacters: Int

    init(maxCharacters: Int = Self.defaultMaxCharacters) {
        precondition(maxCharacters > 0)
        self.maxCharacters = maxCharacters
    }

    func chunks(for text: String) -> [MeetingSummaryTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [MeetingSummaryTextChunk] = []
        var start = text.startIndex
        var startOffset = 0

        while start < text.endIndex {
            let remainingCount = text.distance(from: start, to: text.endIndex)
            let end: String.Index
            if remainingCount <= maxCharacters {
                end = text.endIndex
            } else {
                let hardEnd = text.index(start, offsetBy: maxCharacters)
                end = preferredBoundary(
                    in: text,
                    from: start,
                    hardEnd: hardEnd
                )
            }

            let chunkText = String(text[start..<end])
            let endOffset = startOffset + chunkText.count
            chunks.append(
                MeetingSummaryTextChunk(
                    index: chunks.count,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    text: chunkText
                )
            )
            start = end
            startOffset = endOffset
        }

        return chunks
    }

    private func preferredBoundary(
        in text: String,
        from start: String.Index,
        hardEnd: String.Index
    ) -> String.Index {
        let searchRange = start..<hardEnd

        if let paragraph = text.range(
            of: "\n\n",
            options: .backwards,
            range: searchRange
        ) {
            return paragraph.upperBound
        }

        if let newline = text.range(
            of: "\n",
            options: .backwards,
            range: searchRange
        ) {
            return newline.upperBound
        }

        let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var index = hardEnd
        while index > start {
            let previous = text.index(before: index)
            if terminators.contains(text[previous]) {
                return index
            }
            index = previous
        }

        return hardEnd
    }
}
