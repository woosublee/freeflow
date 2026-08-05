import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingUserIssueTests {
    static func main() throws {
        try testPostProcessingErrorsMapToWarningRecords()
        try testTimeoutIssueDoesNotPersistSourceContent()
        try testRawFallbackOutcomeIsPersistedWithTheOriginalTranscript()
        try testRequestFailuresKeepOnlyAllowlistedProviderCode()
        try testNonSuccessResponsesDoNotStoreRawBodies()
        print("PostProcessingUserIssueTests passed")
    }

    private static func testPostProcessingErrorsMapToWarningRecords() throws {
        let cases: [(PostProcessingError, QuillUserIssueCode, QuillUserRecoveryAction)] = [
            (.requestFailed(statusCode: 401, providerCode: "invalid_api_key"), .authenticationFailed, .openProviderSettings),
            (.requestFailed(statusCode: 500, providerCode: nil), .postProcessingFailed, .retryTranscription),
            (.rateLimited(model: "provider/model", retryAfter: 10), .postProcessingRateLimited, .retryTranscription),
            (.invalidResponse("missing content"), .postProcessingFailed, .retryTranscription),
            (.emptyOutput, .postProcessingFailed, .retryTranscription),
            (.requestTimedOut(30), .requestTimedOut, .retryTranscription),
            (.suspectedInstructionExecution, .postProcessingGuardFallback, .none),
            (.outputRejected(.languageMismatch), .postProcessingGuardFallback, .none)
        ]

        for (error, expectedCode, expectedAction) in cases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "provider/model"
            )
            try expect(issue.record.code == expectedCode, "\(error) stable code")
            try expect(issue.record.severity == .warning, "\(error) is a non-terminal warning")
            try expect(issue.record.recoveryAction == expectedAction, "\(error) recovery action")
            try expect(issue.record.context.providerHost == "api.example.com", "safe provider context")
            try expect(issue.record.context.modelID == "provider/model", "safe model context")
            if case .requestTimedOut = error {
                try expect(
                    issue.record.context.operation == .postProcessing,
                    "timeout identifies post-processing operation"
                )
                let presentation = issue.record.presentation(language: "en")
                try expect(
                    presentation.title == "Transcript cleanup timed out",
                    "timeout uses cleanup-specific copy"
                )
                try expect(
                    presentation.body.contains("original transcript"),
                    "timeout copy explains raw transcript preservation"
                )
                let decoded = try QuillUserIssueRecord.decodePersistedStatus(
                    issue.record.persistedStatus
                )
                try expect(
                    decoded.code == .requestTimedOut,
                    "timeout code round-trips"
                )
                try expect(
                    decoded.context.operation == .postProcessing,
                    "timeout operation round-trips"
                )
            }
        }
    }

    private static func testTimeoutIssueDoesNotPersistSourceContent() throws {
        let sentinel = "RAW_TRANSCRIPT PROMPT_SECRET sk-secret /Users/private RESPONSE_BODY"
        let error = PostProcessingError.requestTimedOut(120)
        let issue = error.userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model",
            localBackend: "Local AI"
        )
        let payload = try decodedPayloadString(issue.record.encodedStatus())

        try expect(
            issue.record.code == .requestTimedOut,
            "timeout has dedicated stable code"
        )
        try expect(
            issue.record.context.modelID == "provider/model",
            "timeout keeps safe model metadata"
        )
        try expect(
            issue.record.context.localBackend == "Local AI",
            "timeout keeps safe backend metadata"
        )
        try expect(
            !payload.contains(sentinel),
            "timeout record excludes source sentinels"
        )
        try expect(
            !issue.privateDiagnostic.contains(sentinel),
            "timeout diagnostic excludes source sentinels"
        )
    }

    private static func testRawFallbackOutcomeIsPersistedWithTheOriginalTranscript() throws {
        let rawTranscript = "이번 주 금요일에 출시합니다."
        let item = PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: rawTranscript,
            postProcessedTranscript: rawTranscript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing was not applied; the original transcript was kept.",
            aiProcessingOutcome: "raw-fallback:languageMismatch",
            debugStatus: "",
            customVocabulary: ""
        )

        try expect(
            item.aiProcessingOutcome == "raw-fallback:languageMismatch",
            "history retains the typed raw fallback outcome"
        )
        try expect(
            item.rawTranscript == rawTranscript && item.postProcessedTranscript == rawTranscript,
            "raw fallback history keeps the non-empty original transcript"
        )
    }

    private static func testRequestFailuresKeepOnlyAllowlistedProviderCode() throws {
        let sentinel = "RAW_PROVIDER_BODY sk-secret-api-key /Users/private prompt transcript stderr"
        let data = try JSONSerialization.data(withJSONObject: [
            "error": [
                "code": "invalid_api_key",
                "type": "authentication_error",
                "message": sentinel
            ]
        ])
        let providerCode = PostProcessingService.safeProviderErrorCode(from: data)
        let error = PostProcessingError.requestFailed(
            statusCode: 401,
            providerCode: providerCode
        )
        let issue = error.userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model"
        )
        let payload = try decodedPayloadString(issue.record.encodedStatus())

        try expect(providerCode == "invalid_api_key", "allowlisted provider code is preserved")
        try expect(!payload.contains(sentinel), "raw provider message is not persisted")
        try expect(!error.localizedDescription.contains(sentinel), "raw provider message is not displayed")
    }

    private static func testNonSuccessResponsesDoNotStoreRawBodies() throws {
        let source = try String(
            contentsOfFile: "Sources/PostProcessingService.swift",
            encoding: .utf8
        )
        try expect(
            !source.contains("let message = String(data: data, encoding: .utf8) ?? \"\""),
            "non-success responses do not convert raw bodies into errors"
        )
    }

    private static func decodedPayloadString(_ status: String) throws -> String {
        let encoded = String(status.dropFirst(QuillUserIssueRecord.persistedStatusPrefix.count))
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            throw TestFailure("Unable to decode persisted payload")
        }
        return text
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
