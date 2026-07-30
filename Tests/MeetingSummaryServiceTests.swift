import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryServiceTests {
    static func main() async throws {
        try await testCloudRequestUsesSummaryPromptAndStrictJSON()
        try await testLocalRequestUsesLoopbackWithoutAuthorization()
        try testUnknownTopLevelKeyIsRejected()
        try testOwnerAndDueDateMayBeNull()
        try await testRateLimitUsesConfiguredFallback()
        try await testLongTranscriptExtractsEveryChunkThenMerges()
        try await testHierarchyUsesBoundedIntermediateMergesAndCompletionCeiling()
        try await testChunkFailureDoesNotReturnPartialSummary()
        try testUserIssueMapsToSummaryDomainCodes()
        print("MeetingSummaryServiceTests passed")
    }

    private static let successfulReadinessProbe: LocalAIServerManager.ReadinessProbe = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}".utf8), response)
    }

    private static func testUserIssueMapsToSummaryDomainCodes() throws {
        let unavailableCases: [MeetingSummaryError] = [
            .requestFailed(statusCode: 500, providerCode: nil),
            .rateLimited(model: "m", retryAfter: 1),
            .requestTimedOut(120),
            .invalidInput,
            .sourceChanged
        ]
        for error in unavailableCases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            try expect(
                issue.code == .meetingSummaryUnavailable,
                "\(error) maps to meetingSummaryUnavailable"
            )
            try expect(
                issue.recoveryAction == .none,
                "\(error) has no recovery action"
            )
        }

        for error: MeetingSummaryError in [.invalidResponse("bad"), .emptyOutput] {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            try expect(
                issue.code == .meetingSummaryInvalidResponse,
                "\(error) maps to meetingSummaryInvalidResponse"
            )
            try expect(
                issue.recoveryAction == .none,
                "\(error) has no recovery action"
            )
        }

        let authIssue = MeetingSummaryError.requestFailed(
            statusCode: 401,
            providerCode: nil
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "summary/model",
            localBackend: nil
        )
        try expect(
            authIssue.code == .authenticationFailed,
            "401 maps to authenticationFailed"
        )
        try expect(
            authIssue.recoveryAction == .openProviderSettings,
            "401 opens provider settings"
        )
    }

    private static func testCloudRequestUsesSummaryPromptAndStrictJSON() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService { request in
            recorder.record(request)
            return try successResponse(request: request, content: validJSON)
        }
        let start = Date(timeIntervalSince1970: 1_000)
        let source = MeetingSummarySource(
            transcript: summaryTranscript,
            calendar: MeetingSummaryCalendarContext(
                title: "Product Weekly",
                start: start,
                end: start.addingTimeInterval(1_800),
                attendees: ["Ada", "Lin"]
            )
        )

        let result = try await service.generate(source: source)
        let request = try recorder.requests().only()
        let body = try requestBody(request)
        let messages = try array(body["messages"])
        let system = try string(try dictionary(messages[0])["content"])
        let user = try string(try dictionary(messages[1])["content"])

        try expect(result.draft.overview.text == "Release review", "decoded overview")
        try expect(request.url?.path.hasSuffix("/chat/completions") == true, "chat completions path")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
            "cloud authorization"
        )
        try expect(system.contains("source quote"), "evidence contract")
        try expect(user.contains("\"feature\":\"meeting_summary_extraction\""), "summary source envelope")
        try expect(user.contains("Product Weekly"), "calendar is included in the source envelope")
        try expect(body["max_tokens"] == nil, "cloud Summary omits the local legacy completion key")
    }

    private static func testLocalRequestUsesLoopbackWithoutAuthorization() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let process = MeetingSummaryFakeProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        let service = MeetingSummaryService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.fast.id),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-secret",
                localServerManager: manager
            ),
            cloudFallbackModelID: "cloud/fallback",
            outputLanguage: "English",
            transport: { request in
                recorder.record(request)
                return try successResponse(request: request, content: validJSON)
            }
        )

        _ = try await service.generate(
            source: MeetingSummarySource(transcript: summaryTranscript, calendar: nil)
        )

        let request = try recorder.requests().only()
        let body = try requestBody(request)
        try expect(request.url?.host == "127.0.0.1", "local loopback host")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == nil,
            "local authorization omitted"
        )
        try expect(body["model"] as? String == "local", "local request model")
        try expect(
            body["max_completion_tokens"] as? Int == 1_024,
            "local Summary retains the 1,024-token completion ceiling"
        )
        try expect(
            body["max_tokens"] as? Int == 1_024,
            "local Summary sends the legacy 1,024-token completion ceiling"
        )
    }

    private static func testUnknownTopLevelKeyIsRejected() throws {
        let invalid = validJSON.dropLast() + #", "unexpected": true}"#
        try expectFailure("unknown top-level key") {
            _ = try MeetingSummaryStrictDecoder.decode(String(invalid))
        }
    }

    private static func testOwnerAndDueDateMayBeNull() throws {
        let decoded = try MeetingSummaryStrictDecoder.decode(validJSON)
        try expect(decoded.actionItems.count == 1, "one action item")
        try expect(decoded.actionItems[0].owner == nil, "null owner")
        try expect(decoded.actionItems[0].dueDate == nil, "null due date")
    }

    private static func testRateLimitUsesConfiguredFallback() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(fallbackModel: "fallback/model") { request in
            recorder.record(request)
            let model = try string(try requestBody(request)["model"])
            if model == "primary/model" {
                return rateLimitedResponse(request: request)
            }
            return try successResponse(request: request, content: validJSON)
        }

        let result = try await service.generate(
            source: MeetingSummarySource(transcript: summaryTranscript, calendar: nil)
        )
        let models = try recorder.requests().map {
            try string(try requestBody($0)["model"])
        }

        try expect(models == ["primary/model", "fallback/model"], "fallback request order")
        try expect(result.modelID == "fallback/model", "fallback result model")
    }

    private static func testLongTranscriptExtractsEveryChunkThenMerges() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maxCharacters: 35)
        ) { request in
            recorder.record(request)
            let user = try userMessage(request)
            if user.contains("validatedPartials") {
                return try successResponse(request: request, content: mergedJSON)
            }
            let content = user.contains("First paragraph")
                ? partialJSON
                : partialSecondJSON
            return try successResponse(request: request, content: content)
        }
        let transcript = [
            "First paragraph has a decision.",
            "Second paragraph has an action."
        ].joined(separator: "\n\n")

        _ = try await service.generate(
            source: MeetingSummarySource(transcript: transcript, calendar: nil)
        )
        let requests = recorder.requests()

        try expect(requests.count == 3, "two extraction requests and one merge")
        let extractionPrompts = try requests.prefix(2).map(userMessage)
        try expect(extractionPrompts[0].contains("First paragraph"), "first chunk included")
        try expect(extractionPrompts[1].contains("Second paragraph"), "second chunk included")
        try expect(try userMessage(requests[2]).contains("validatedPartials"), "merge prompt")
    }

    private static func testHierarchyUsesBoundedIntermediateMergesAndCompletionCeiling() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let tokenCounter = MeetingSummaryRecordingTokenCounter()
        let budgeter = LocalAITokenBudgeter(
            contextWindow: 5_000,
            tokenCounter: tokenCounter
        )
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maximumSourceBytes: 24),
            tokenBudgeter: budgeter
        ) { request in
            recorder.record(request)
            return try successResponse(request: request, content: largeEvidenceJSON)
        }

        _ = try await service.generate(
            source: MeetingSummarySource(
                transcript: String(repeating: "Evidence line. ", count: 10),
                calendar: nil
            )
        )

        let requests = recorder.requests()
        let mergeCount = try requests
            .map(userMessage)
            .filter { $0.contains("validatedPartials") }
            .count
        try expect(mergeCount >= 2, "long summaries use at least two bounded intermediate merge requests")
        for request in requests {
            let body = try requestBody(request)
            try expect(
                body["max_completion_tokens"] as? Int == 1_024,
                "every Summary request reserves the 1,024-token completion ceiling"
            )
        }
        for request in requests {
            let messages = try array(try requestBody(request)["messages"])
            let system = try string(try dictionary(messages[0])["content"])
            let user = try string(try dictionary(messages[1])["content"])
            let rendered = "[System]\n\(system)\n\n[User]\n\(user)"
            try expect(
                rendered.utf8.count + 1_024 + 512 <= 5_000,
                "every generated Summary request stays inside the injected context budget"
            )
        }
    }

    private static func testChunkFailureDoesNotReturnPartialSummary() async throws {
        let requestCount = MeetingSummaryRequestRecorder()
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maxCharacters: 35)
        ) { request in
            requestCount.record(request)
            if requestCount.requests().count == 2 {
                return try successResponse(request: request, content: #"{"overview":""}"#)
            }
            return try successResponse(request: request, content: partialJSON)
        }
        let transcript = [
            "First paragraph has a decision.",
            "Second paragraph has an action."
        ].joined(separator: "\n\n")

        do {
            _ = try await service.generate(
                source: MeetingSummarySource(transcript: transcript, calendar: nil)
            )
            throw MeetingSummaryServiceTestFailure("Expected chunk failure")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {
            try expect(requestCount.requests().count == 2, "merge not attempted after chunk failure")
        }
    }

    private static func makeCloudService(
        fallbackModel: String? = nil,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping MeetingSummaryService.Transport
    ) -> MeetingSummaryService {
        let baseURL = "https://api.example.com/openai/v1/\(UUID().uuidString)"
        return MeetingSummaryService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "primary/model"),
                cloudBaseURL: baseURL,
                cloudAPIKey: "test-key"
            ),
            cloudFallbackModelID: fallbackModel,
            outputLanguage: "English",
            chunker: chunker,
            tokenBudgeter: tokenBudgeter,
            transport: transport
        )
    }

    private static func userMessage(_ request: URLRequest) throws -> String {
        let messages = try array(try requestBody(request)["messages"])
        return try string(try dictionary(messages[1])["content"])
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingSummaryServiceTestFailure("Invalid request body")
        }
        return body
    }

    private static func successResponse(
        request: URLRequest,
        content: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private static func rateLimitedResponse(
        request: URLRequest
    ) -> (Data, URLResponse) {
        (
            Data(#"{"error":{"code":"rate_limit"}}"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "1"]
            )!
        )
    }

    private static func expectFailure(
        _ label: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw MeetingSummaryServiceTestFailure("Expected \(label)")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {}
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ label: String
    ) throws {
        guard try condition() else {
            throw MeetingSummaryServiceTestFailure(label)
        }
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw MeetingSummaryServiceTestFailure("Expected dictionary")
        }
        return value
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw MeetingSummaryServiceTestFailure("Expected array")
        }
        return value
    }

    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw MeetingSummaryServiceTestFailure("Expected string")
        }
        return value
    }

    private static let summaryTranscript = "Release review. Launch remains on schedule. Decision: ship Friday. Write release notes."

    private static let validJSON = #"{"overview":{"text":"Release review","sourceQuotes":["Release review."]},"keyPoints":[{"text":"Launch remains on schedule.","sourceQuote":"Launch remains on schedule."}],"decisions":[{"text":"Ship Friday.","sourceQuote":"Decision: ship Friday."}],"actionItems":[{"task":"Write release notes","owner":null,"dueDate":null,"sourceQuote":"Write release notes."}],"openQuestions":[]}"#

    private static let partialJSON = #"{"overview":{"text":"Chunk findings","sourceQuotes":["First paragraph has a decision."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let partialSecondJSON = #"{"overview":{"text":"Chunk findings","sourceQuotes":["Second paragraph has an action."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let mergedJSON = #"{"overview":{"text":"Merged review","sourceQuotes":["First paragraph has a decision."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let largeEvidenceJSON = #"{"overview":{"text":"The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan.","sourceQuotes":["Evidence line."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
}

private actor MeetingSummaryRecordingTokenCounter: LocalAITokenCounting {
    private(set) var prompts: [String] = []

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompts.append(prompt)
        return prompt.utf8.count
    }
}

private final class MeetingSummaryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }
}

private extension Array {
    func only() throws -> Element {
        guard count == 1, let first else {
            throw MeetingSummaryServiceTestFailure("Expected one element")
        }
        return first
    }
}

private final class MeetingSummaryFakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func forceTerminate() {
        terminate()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {}
}

private struct MeetingSummaryServiceTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
