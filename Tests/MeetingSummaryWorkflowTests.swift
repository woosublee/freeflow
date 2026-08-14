import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryWorkflowTests {
    static func main() async throws {
        try await testStateAndInvalidationCommands()
        print("MeetingSummaryWorkflowTests passed")
    }

    @MainActor
    private static func testStateAndInvalidationCommands() async throws {
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw MeetingSummaryError.invalidInput
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        let noteID = UUID()
        var states: [MeetingSummaryWorkflowState] = []
        workflow.onEvent = { event in
            if case .stateChanged(let state) = event {
                states.append(state)
            }
        }

        workflow.invalidate(noteID: noteID)
        workflow.forget(noteID: noteID)
        workflow.forgetAll()

        try expect(
            workflow.state.generatingNoteIDs.isEmpty,
            "no generation is active"
        )
        try expect(
            workflow.state.pendingRevealNoteIDs.isEmpty,
            "no reveal is pending"
        )
        try expect(
            !states.isEmpty,
            "state commands emit complete snapshots"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: noteID),
            "missing reveal is not consumed"
        )
    }
}

private final class MeetingSummaryWorkflowGeneratorStub:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    typealias Operation = @Sendable (
        MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await operation(source)
    }
}

private struct MeetingSummaryWorkflowTestFailure:
    Error,
    CustomStringConvertible
{
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ description: String
) throws {
    guard condition() else {
        throw MeetingSummaryWorkflowTestFailure(
            description: description
        )
    }
}
