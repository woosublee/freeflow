import Foundation

enum LocalAIDiagnosticCategory: String, Equatable, Sendable {
    case none
    case serverOutput = "server-output"
}

struct LocalAIDiagnostics: Equatable, Sendable {
    let category: LocalAIDiagnosticCategory
    let trailingLines: [String]

    func boundedExcerpt(maximumLines: Int = 8, maximumCharacters: Int = 1_024) -> String {
        let lines = trailingLines.suffix(max(0, maximumLines)).joined(separator: "\n")
        return String(lines.suffix(max(0, maximumCharacters)))
    }
}

enum LocalAIDiagnosticStream: Hashable, Sendable {
    case standardOutput
    case standardError
}

final class LocalAIDiagnosticsBuffer: @unchecked Sendable {
    private static let maximumLineCount = 64
    private static let maximumByteCount = 16 * 1024
    private static let maximumLineLength = 512
    private static let maximumPartialByteCount = maximumLineLength * 4

    private let lock = NSLock()
    private var partialLines: [LocalAIDiagnosticStream: PartialLine] = [:]
    private var trailingLines: [String] = []
    private var storedByteCount = 0
    private var isFinished = false

    func append(_ data: Data, from stream: LocalAIDiagnosticStream) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        var partial = partialLines[stream] ?? PartialLine()
        for byte in data {
            if byte == 0x0A {
                appendCompletedLine(partial)
                partial = PartialLine()
                continue
            }
            guard !partial.isKnownLong else { continue }
            partial.bytes.append(byte)
            if partial.bytes.count > Self.maximumPartialByteCount {
                partial.bytes.removeAll(keepingCapacity: false)
                partial.isKnownLong = true
            }
        }
        partialLines[stream] = partial
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        for stream in [LocalAIDiagnosticStream.standardOutput, .standardError] {
            if let partial = partialLines[stream], partial.isKnownLong || !partial.bytes.isEmpty {
                appendCompletedLine(partial)
            }
        }
        partialLines.removeAll()
        isFinished = true
    }

    func snapshot() -> LocalAIDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return LocalAIDiagnostics(
            category: trailingLines.isEmpty ? .none : .serverOutput,
            trailingLines: trailingLines
        )
    }

    private func appendCompletedLine(_ partial: PartialLine) {
        let line: String
        if partial.isKnownLong {
            line = "[redacted: diagnostic line exceeds 512 characters]"
        } else {
            line = Self.sanitized(String(decoding: partial.bytes, as: UTF8.self))
        }
        appendSanitizedLine(line)
    }

    private func appendSanitizedLine(_ line: String) {
        let lineByteCount = line.utf8.count + 1
        while !trailingLines.isEmpty,
              trailingLines.count >= Self.maximumLineCount
                || storedByteCount + lineByteCount > Self.maximumByteCount {
            let removed = trailingLines.removeFirst()
            storedByteCount -= removed.utf8.count + 1
        }
        guard lineByteCount <= Self.maximumByteCount else { return }
        trailingLines.append(line)
        storedByteCount += lineByteCount
    }

    private static func sanitized(_ line: String) -> String {
        guard line.count <= maximumLineLength else {
            return "[redacted: diagnostic line exceeds 512 characters]"
        }
        if contains(authorizationPattern, in: line) {
            return "[redacted: authorization value]"
        }
        if contains(jsonSourceFieldPattern, in: line) {
            return "[redacted: source field]"
        }
        if contains(dataURLPattern, in: line) {
            return "[redacted: data URL]"
        }
        return replacing(absolutePathPattern, in: line, with: "[redacted: filesystem path]")
    }

    private static func contains(_ pattern: NSRegularExpression, in string: String) -> Bool {
        pattern.firstMatch(
            in: string,
            options: [],
            range: NSRange(string.startIndex..., in: string)
        ) != nil
    }

    private static func replacing(
        _ pattern: NSRegularExpression,
        in string: String,
        with replacement: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(string.startIndex..., in: string),
            withTemplate: replacement
        )
    }

    private static let authorizationPattern = try! NSRegularExpression(
        pattern: "(?i)authorization\\s*:.*",
        options: []
    )
    private static let jsonSourceFieldPattern = try! NSRegularExpression(
        pattern: "(?i)\\\"(?:transcript|selectedText|calendar)\\\"\\s*:",
        options: []
    )
    private static let dataURLPattern = try! NSRegularExpression(
        pattern: "(?i)data:[^\\s\\\"']+",
        options: []
    )
    private static let absolutePathPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])/(?:[^\\s\\\"'<>])+",
        options: []
    )
}

private struct PartialLine {
    var bytes = Data()
    var isKnownLong = false
}
