import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionRetryWorkflowTests {
    static func main() async throws {
        try await testInitialStateIsInstanceOwned()
        print("TranscriptionRetryWorkflowTests passed")
    }

    @MainActor
    private static func testInitialStateIsInstanceOwned() async throws {
        let first = TranscriptionRetryWorkflow(
            dependencies: unusedDependencies(token: UUID())
        )
        let second = TranscriptionRetryWorkflow(
            dependencies: unusedDependencies(token: UUID())
        )

        try expectEqual(first.state, .initial, "first initial state")
        try expectEqual(second.state, .initial, "second initial state")
        try expect(first.state.retryingNoteIDs.isEmpty, "first retry state")
        try expect(second.state.progressByNoteID.isEmpty, "second progress state")
    }

    private static func unusedDependencies(
        token: UUID
    ) -> TranscriptionRetryWorkflowDependencies {
        TranscriptionRetryWorkflowDependencies(
            transcribe: { _, _, _, _ in
                throw TranscriptionRetryWorkflowTestFailure(
                    "unexpected transcription"
                )
            },
            makeAttemptToken: { token }
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else {
            throw TranscriptionRetryWorkflowTestFailure(label)
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TranscriptionRetryWorkflowTestFailure(
                "\(label): expected \(expected), got \(actual)"
            )
        }
    }
}

private struct TranscriptionRetryWorkflowTestFailure:
    Error,
    CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
