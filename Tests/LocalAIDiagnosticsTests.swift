import Foundation

@main
struct LocalAIDiagnosticsTests {
    static func main() throws {
        try testDiagnosticsRetainOnlyBoundedRedactedTrailingLines()
        print("LocalAIDiagnosticsTests passed")
    }

    private static func testDiagnosticsRetainOnlyBoundedRedactedTrailingLines() throws {
        let buffer = LocalAIDiagnosticsBuffer()
        for index in 0..<70 {
            buffer.append(Data("diagnostic \(index)\n".utf8), from: .standardOutput)
        }
        for index in 0..<64 {
            buffer.append(Data((String(repeating: "b", count: 500) + " \(index)\n").utf8), from: .standardOutput)
        }
        buffer.append(Data("loading /Users/private/model.gguf\n".utf8), from: .standardError)
        buffer.append(Data("Authorization: Bearer secret-token\n".utf8), from: .standardError)
        buffer.append(Data("{\"selectedText\":\"private source\"}\n".utf8), from: .standardError)
        buffer.append(Data("data:image/png;base64,private-pixels\n".utf8), from: .standardError)
        buffer.append(Data((String(repeating: "x", count: 513) + "\n").utf8), from: .standardError)
        buffer.finish()

        let diagnostics = buffer.snapshot()
        let joined = diagnostics.trailingLines.joined(separator: "\n")
        try expect(diagnostics.category == .serverOutput, "diagnostics identify server output")
        try expect(diagnostics.trailingLines.count <= 64, "diagnostics retain at most 64 lines")
        try expect(
            diagnostics.trailingLines.reduce(0) { $0 + $1.utf8.count + 1 } <= 16 * 1024,
            "diagnostics retain at most 16 KiB after sanitization"
        )
        try expect(!joined.contains("/Users/private"), "diagnostics redact filesystem paths")
        try expect(!joined.contains("secret-token"), "diagnostics redact authorization values")
        try expect(!joined.contains("private source"), "diagnostics redact JSON source fields")
        try expect(!joined.contains("private-pixels"), "diagnostics redact data URLs")
        try expect(!joined.contains(String(repeating: "x", count: 513)), "diagnostics redact overlong lines")
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
