import Foundation

struct MeetingSummaryGenerationResult: Equatable, Sendable {
    let draft: MeetingSummaryDraftContent
    let promptVersion: Int
    let modelID: String
    let backendKind: MeetingSummaryBackendKind
}

enum MeetingSummaryError: Error, Equatable {
    case invalidInput
    case requestFailed(statusCode: Int, providerCode: String?)
    case rateLimited(model: String, retryAfter: TimeInterval)
    case invalidResponse(String)
    case emptyOutput
    case requestTimedOut(TimeInterval)
    case allModelsCoolingDown
    case sourceChanged

    func userIssue(
        providerHost: String?,
        modelID: String,
        localBackend: String?
    ) -> QuillUserIssueRecord {
        let code: QuillUserIssueCode
        let status: Int?
        switch self {
        case .requestTimedOut:
            code = .meetingSummaryUnavailable
            status = nil
        case .rateLimited, .allModelsCoolingDown:
            code = .meetingSummaryUnavailable
            status = 429
        case .requestFailed(let statusCode, _):
            status = statusCode > 0 ? statusCode : nil
            if statusCode == 401 || statusCode == 403 {
                code = .authenticationFailed
            } else {
                code = .meetingSummaryUnavailable
            }
        case .invalidResponse, .emptyOutput:
            code = .meetingSummaryInvalidResponse
            status = nil
        case .invalidInput, .sourceChanged:
            code = .meetingSummaryUnavailable
            status = nil
        }
        return QuillUserIssueRecord(
            code: code,
            context: QuillUserIssueContext(
                httpStatus: status,
                providerHost: providerHost,
                modelID: modelID,
                localBackend: localBackend
            )
        )
    }
}

enum MeetingSummaryStrictDecoder {
    static func decode(_ text: String) throws -> MeetingSummaryDraftContent {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid summary JSON.")
        }
        try requireKeys(
            root,
            expected: [
                "overview",
                "keyPoints",
                "decisions",
                "actionItems",
                "openQuestions"
            ]
        )

        let overview = try requiredString(root["overview"], field: "overview")
        let keyPoints = try points(root["keyPoints"], field: "keyPoints")
        let decisions = try points(root["decisions"], field: "decisions")
        let actionItems = try actions(root["actionItems"])
        let openQuestions = try points(
            root["openQuestions"],
            field: "openQuestions"
        )
        return MeetingSummaryDraftContent(
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    private static func points(
        _ value: Any?,
        field: String
    ) throws -> [MeetingSummaryDraftPoint] {
        guard let values = value as? [Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid \(field).")
        }
        return try values.map { value in
            guard let dictionary = value as? [String: Any] else {
                throw MeetingSummaryError.invalidResponse("Invalid \(field) item.")
            }
            try requireKeys(dictionary, expected: ["text", "sourceQuote"])
            return MeetingSummaryDraftPoint(
                text: try requiredString(dictionary["text"], field: "text"),
                sourceQuote: try optionalString(
                    dictionary["sourceQuote"],
                    field: "sourceQuote"
                )
            )
        }
    }

    private static func actions(
        _ value: Any?
    ) throws -> [MeetingSummaryDraftActionItem] {
        guard let values = value as? [Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid actionItems.")
        }
        return try values.map { value in
            guard let dictionary = value as? [String: Any] else {
                throw MeetingSummaryError.invalidResponse(
                    "Invalid actionItems item."
                )
            }
            try requireKeys(
                dictionary,
                expected: ["task", "owner", "dueDate", "sourceQuote"]
            )
            return MeetingSummaryDraftActionItem(
                task: try requiredString(dictionary["task"], field: "task"),
                owner: try optionalString(dictionary["owner"], field: "owner"),
                dueDate: try optionalString(
                    dictionary["dueDate"],
                    field: "dueDate"
                ),
                sourceQuote: try optionalString(
                    dictionary["sourceQuote"],
                    field: "sourceQuote"
                )
            )
        }
    }

    private static func requireKeys(
        _ dictionary: [String: Any],
        expected: Set<String>
    ) throws {
        guard Set(dictionary.keys) == expected else {
            throw MeetingSummaryError.invalidResponse(
                "Unexpected summary fields."
            )
        }
    }

    private static func requiredString(
        _ value: Any?,
        field: String
    ) throws -> String {
        guard let value = value as? String else {
            throw MeetingSummaryError.invalidResponse("Invalid \(field).")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingSummaryError.invalidResponse("Empty \(field).")
        }
        return trimmed
    }

    private static func optionalString(
        _ value: Any?,
        field: String
    ) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let value = value as? String else {
            throw MeetingSummaryError.invalidResponse("Invalid \(field).")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol MeetingSummaryGenerating: Sendable {
    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult
}

final class MeetingSummaryService: MeetingSummaryGenerating, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct DraftResult {
        let draft: MeetingSummaryDraftContent
        let modelID: String
        let backendKind: MeetingSummaryBackendKind
    }

    private static let requestTimeout: TimeInterval = 120
    private static let defaultTransport: Transport = { request in
        try await LLMAPITransport.data(for: request)
    }

    private let backendExecutor: AIProcessingBackendExecutor
    private let cloudFallbackModelID: String?
    private let outputLanguage: String
    private let chunker: MeetingSummaryTextChunker
    private let transport: Transport

    init(
        backendExecutor: AIProcessingBackendExecutor,
        cloudFallbackModelID: String?,
        outputLanguage: String,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        transport: @escaping Transport = MeetingSummaryService.defaultTransport
    ) {
        self.backendExecutor = backendExecutor
        self.cloudFallbackModelID = cloudFallbackModelID
        self.outputLanguage = outputLanguage
        self.chunker = chunker
        self.transport = transport
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        guard !source.normalizedTranscript.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }

        let chunks = chunker.chunks(for: source.normalizedTranscript)
        let final: DraftResult
        if chunks.count == 1 {
            final = try await generateDraft(
                prompt: MeetingSummaryPromptFactory.singlePass(
                    source: source,
                    outputLanguage: outputLanguage
                )
            )
        } else {
            var partialJSON: [String] = []
            for chunk in chunks {
                let partial = try await generateDraft(
                    prompt: MeetingSummaryPromptFactory.chunkExtraction(
                        chunk: chunk,
                        calendar: source.calendar,
                        outputLanguage: outputLanguage
                    )
                )
                partialJSON.append(try encode(partial.draft))
            }
            final = try await generateDraft(
                prompt: MeetingSummaryPromptFactory.merge(
                    partialJSON: partialJSON,
                    outputLanguage: outputLanguage
                )
            )
        }

        return MeetingSummaryGenerationResult(
            draft: final.draft,
            promptVersion: MeetingSummaryPromptFactory.version,
            modelID: final.modelID,
            backendKind: final.backendKind
        )
    }

    private func generateDraft(
        prompt: MeetingSummaryPrompt
    ) async throws -> DraftResult {
        if backendExecutor.choice.isLocal {
            return try await requestDraft(
                prompt: prompt,
                executor: backendExecutor
            )
        }
        return try await requestCloudDraft(prompt: prompt)
    }

    private func requestCloudDraft(
        prompt: MeetingSummaryPrompt
    ) async throws -> DraftResult {
        let primary = backendExecutor.choice.modelID
        let fallback = normalizedFallback(primary: primary)
        guard let effective = await LLMCooldownManager.shared.effectivePrimary(
            baseURL: backendExecutor.cloudBaseURL,
            primary: primary,
            fallback: fallback
        ) else {
            throw MeetingSummaryError.allModelsCoolingDown
        }

        var models = [effective]
        if effective == primary, let fallback {
            models.append(fallback)
        }

        var lastError: Error?
        for (index, modelID) in models.enumerated() {
            do {
                return try await requestDraft(
                    prompt: prompt,
                    executor: backendExecutor.replacingChoice(
                        .cloud(modelID: modelID)
                    )
                )
            } catch let error as MeetingSummaryError {
                lastError = error
                if case .rateLimited(_, let retryAfter) = error {
                    await LLMCooldownManager.shared.setCooldown(
                        LLMCooldownIdentity(
                            baseURL: backendExecutor.cloudBaseURL,
                            model: modelID
                        ),
                        retryAfterSeconds: retryAfter
                    )
                }
                let canRetry = index + 1 < models.count
                    && isFallbackEligible(error)
                if canRetry { continue }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError ?? MeetingSummaryError.allModelsCoolingDown
    }

    private func requestDraft(
        prompt: MeetingSummaryPrompt,
        executor: AIProcessingBackendExecutor
    ) async throws -> DraftResult {
        try await executor.withEndpoint { [self] endpoint in
            let request = try makeRequest(prompt: prompt, endpoint: endpoint)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(request)
            } catch let error as URLError where error.code == .timedOut {
                throw MeetingSummaryError.requestTimedOut(Self.requestTimeout)
            } catch {
                throw MeetingSummaryError.requestFailed(
                    statusCode: 0,
                    providerCode: nil
                )
            }

            guard let http = response as? HTTPURLResponse else {
                throw MeetingSummaryError.invalidResponse(
                    "Missing HTTP response."
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                let providerCode = providerErrorCode(data)
                if http.statusCode == 429 {
                    let cooldown = LLMCooldownManager.rateLimitCooldown(from: http)
                    throw MeetingSummaryError.rateLimited(
                        model: endpoint.selectedModelID,
                        retryAfter: cooldown.seconds
                    )
                }
                throw MeetingSummaryError.requestFailed(
                    statusCode: http.statusCode,
                    providerCode: providerCode
                )
            }

            let content = try responseContent(data)
            let config = ModelConfiguration.config(for: endpoint.selectedModelID)
            let cleaned = config.shouldStripThinkTags
                ? ModelConfiguration.stripThinkTags(content)
                : content
            let trimmed = cleaned.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else {
                throw MeetingSummaryError.emptyOutput
            }
            let draft = try MeetingSummaryStrictDecoder.decode(trimmed)
            return DraftResult(
                draft: draft,
                modelID: endpoint.selectedModelID,
                backendKind: endpoint.kind == .local ? .local : .cloud
            )
        }
    }

    private func makeRequest(
        prompt: MeetingSummaryPrompt,
        endpoint: AIProcessingEndpoint
    ) throws -> URLRequest {
        let url = endpoint.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = endpoint.authorizationToken {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let config = ModelConfiguration.config(for: endpoint.selectedModelID)
        var payload: [String: Any] = [
            "model": endpoint.requestModelID,
            "temperature": 0.0,
            "max_completion_tokens": config.maxCompletionTokens ?? 8_192,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user]
            ]
        ]
        if let effort = config.reasoningEffort {
            payload["reasoning_effort"] = effort
        }
        if let include = config.includeReasoning {
            payload["include_reasoning"] = include
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func normalizedFallback(primary: String) -> String? {
        guard let cloudFallbackModelID else { return nil }
        let trimmed = cloudFallbackModelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, trimmed != primary else { return nil }
        return trimmed
    }

    private func isFallbackEligible(_ error: MeetingSummaryError) -> Bool {
        switch error {
        case .rateLimited, .invalidResponse, .emptyOutput:
            return true
        case .invalidInput, .requestFailed, .requestTimedOut,
             .allModelsCoolingDown, .sourceChanged:
            return false
        }
    }

    private func responseContent(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MeetingSummaryError.invalidResponse(
                "Missing summary response content."
            )
        }
        return content
    }

    private func providerErrorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        return error["code"] as? String
    }

    private func encode(
        _ draft: MeetingSummaryDraftContent
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(draft)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MeetingSummaryError.invalidResponse(
                "Unable to encode partial summary."
            )
        }
        return text
    }
}
