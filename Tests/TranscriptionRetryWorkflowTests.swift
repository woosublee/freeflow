import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionRetryWorkflowTests {
    static func main() async throws {
        try await testInitialStateIsInstanceOwned()
        try testHistoryReplacementPreservesUnrelatedMetadata()
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

    private static func testHistoryReplacementPreservesUnrelatedMetadata() throws {
        let summary = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 3_000),
            sourceFingerprint: String(repeating: "a", count: 64),
            modelID: "summary/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Existing overview",
                    sourceQuotes: []
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 3_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "provider.example",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable)
        )
        let initial = PipelineHistoryItem(
            intent: .dictation,
            selectedText: "selected",
            capturedSelection: "captured",
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            recordingStartedAt: Date(timeIntervalSince1970: 900),
            recordingEndedAt: Date(timeIntervalSince1970: 990),
            calendarMatch: nil,
            rawTranscript: "old raw",
            postProcessedTranscript: "old final",
            postProcessingPrompt: "old prompt",
            systemPrompt: "system",
            contextSummary: "context",
            contextSystemPrompt: "context system",
            contextPrompt: "context prompt",
            contextScreenshotDataURL: "data:image/jpeg;base64,AA==",
            contextScreenshotStatus: "captured",
            postProcessingStatus: "old status",
            aiProcessingOutcome: "failed:old",
            debugStatus: "old debug",
            customVocabulary: "old vocabulary",
            customSystemPrompt: "old custom prompt",
            audioFileName: "recording.wav",
            usedLocalTranscription: false,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "en",
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt,
            localTranscriptionModelID: "old/local",
            transcriptFileName: "old.txt",
            contextAppName: "Editor",
            contextBundleIdentifier: "com.example.editor",
            contextWindowTitle: "Document",
            customTitle: "Custom title",
            meetingSummaryJSON: try JSONEncoder().encode(summary)
        )
        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: "new raw",
            postProcessedTranscript: "new final",
            postProcessingPrompt: "new prompt",
            postProcessingStatus: "new status",
            aiProcessingOutcome: AIProcessingOutcome.succeeded.pipelineHistoryStatus,
            debugStatus: "Retried",
            customVocabulary: "new vocabulary",
            customSystemPrompt: "new custom prompt",
            usedLocalTranscription: true,
            usedPostProcessing: false,
            transcriptionLanguageCode: "ko",
            spokenLanguage: SpokenLanguageResolution(
                languageCode: "ko",
                source: .engineDetected
            ),
            localTranscriptionModelID: "new/local",
            transcriptFileName: "new.txt"
        )

        let updated = initial.replacingTranscription(with: replacement)

        try expectEqual(updated.rawTranscript, "new raw", "raw transcript")
        try expectEqual(updated.postProcessedTranscript, "new final", "final transcript")
        try expectEqual(updated.customTitle, "Custom title", "custom title")
        try expectEqual(updated.meetingSummary, summary, "meeting summary")
        try expectEqual(updated.meetingSummaryAttempt, attempt, "summary attempt")
        try expectEqual(updated.capturedSelection, "captured", "selection")
        try expectEqual(updated.contextAppName, "Editor", "context app")
        try expectEqual(updated.audioFileName, "recording.wav", "audio identity")
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
