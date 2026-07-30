import Foundation

struct MeetingSummaryGenerationResult: Equatable, Sendable {
    let draft: MeetingSummaryDraftContentV2
    let promptVersion: Int
    let modelID: String
    let backendKind: MeetingSummaryBackendKind
}

enum MeetingSummaryError: Error, Equatable {
    case invalidInput
    case requestFailed(statusCode: Int, providerCode: String?)
    case rateLimited(model: String, retryAfter: TimeInterval)
    case invalidResponse(String)
    case outputRejected(MeetingSummaryOutputValidationError)
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
        case .invalidResponse, .outputRejected, .emptyOutput:
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
    static func decode(_ text: String) throws -> MeetingSummaryDraftContentV2 {
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

        return MeetingSummaryDraftContentV2(
            overview: try overview(root["overview"]),
            keyPoints: try points(root["keyPoints"], field: "keyPoints"),
            decisions: try points(root["decisions"], field: "decisions"),
            actionItems: try actions(root["actionItems"]),
            openQuestions: try points(root["openQuestions"], field: "openQuestions")
        )
    }

    private static func overview(_ value: Any?) throws -> MeetingSummaryEvidenceText {
        guard let dictionary = value as? [String: Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid overview.")
        }
        try requireKeys(dictionary, expected: ["text", "sourceQuotes"])
        guard let sourceQuotes = dictionary["sourceQuotes"] as? [Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid overview source quotes.")
        }
        let quotes = try sourceQuotes.map {
            try requiredString($0, field: "sourceQuotes")
        }
        guard !quotes.isEmpty else {
            throw MeetingSummaryError.invalidResponse("Overview needs source evidence.")
        }
        return MeetingSummaryEvidenceText(
            text: try requiredString(dictionary["text"], field: "overview text"),
            sourceQuotes: quotes
        )
    }

    private static func points(
        _ value: Any?,
        field: String
    ) throws -> [MeetingSummaryPoint] {
        guard let values = value as? [Any] else {
            throw MeetingSummaryError.invalidResponse("Invalid \(field).")
        }
        return try values.map { value in
            guard let dictionary = value as? [String: Any] else {
                throw MeetingSummaryError.invalidResponse("Invalid \(field) item.")
            }
            try requireKeys(dictionary, expected: ["text", "sourceQuote"])
            return MeetingSummaryPoint(
                id: UUID(),
                text: try requiredString(dictionary["text"], field: "text"),
                sourceQuote: try requiredString(
                    dictionary["sourceQuote"],
                    field: "sourceQuote"
                )
            )
        }
    }

    private static func actions(
        _ value: Any?
    ) throws -> [MeetingSummaryActionItem] {
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
            return MeetingSummaryActionItem(
                id: UUID(),
                task: try requiredString(dictionary["task"], field: "task"),
                owner: try optionalString(dictionary["owner"], field: "owner"),
                dueDate: try optionalString(
                    dictionary["dueDate"],
                    field: "dueDate"
                ),
                sourceQuote: try requiredString(
                    dictionary["sourceQuote"],
                    field: "sourceQuote"
                ),
                isCompleted: false
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

private struct MeetingSummaryByteTokenCounter: LocalAITokenCounting {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompt.utf8.count
    }
}

final class MeetingSummaryService: MeetingSummaryGenerating, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct DraftResult {
        let draft: MeetingSummaryDraftContentV2
        let modelID: String
        let backendKind: MeetingSummaryBackendKind
    }

    private struct MergeRecord {
        let draft: MeetingSummaryDraftContentV2
        let modelID: String
        let backendKind: MeetingSummaryBackendKind
    }

    private static let requestTimeout: TimeInterval = 120
    private static let contextWindow = 16_384
    private static let completionCeiling = 1_024
    private static let defaultTransport: Transport = { request in
        try await LLMAPITransport.data(for: request)
    }

    private let backendExecutor: AIProcessingBackendExecutor
    private let cloudFallbackModelID: String?
    private let outputLanguage: String
    private let chunker: MeetingSummaryTextChunker
    private let tokenBudgeter: LocalAITokenBudgeter
    private let transport: Transport

    init(
        backendExecutor: AIProcessingBackendExecutor,
        cloudFallbackModelID: String?,
        outputLanguage: String,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping Transport = MeetingSummaryService.defaultTransport
    ) {
        self.backendExecutor = backendExecutor
        self.cloudFallbackModelID = cloudFallbackModelID
        self.outputLanguage = outputLanguage
        self.chunker = chunker
        self.tokenBudgeter = tokenBudgeter ?? LocalAITokenBudgeter(
            contextWindow: Self.contextWindow,
            tokenCounter: MeetingSummaryByteTokenCounter()
        )
        self.transport = transport
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        let normalizedTranscript = source.normalizedTranscript
        guard !normalizedTranscript.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }

        let extractionBudgetPrompt = try MeetingSummaryPromptFactory.singlePass(
            source: MeetingSummarySource(transcript: "", calendar: source.calendar),
            outputLanguage: outputLanguage
        )
        let extractionBudget = try await sourceBudget(
            for: extractionBudgetPrompt,
            role: .summaryExtraction
        )
        let sourceByteLimit = min(
            chunker.maximumSourceBytes,
            max(1, extractionBudget.sourceTokenLimit / 2)
        )
        let chunks = MeetingSummaryTextChunker(
            maximumSourceBytes: sourceByteLimit
        ).chunks(for: normalizedTranscript)
        guard !chunks.isEmpty else {
            throw MeetingSummaryError.invalidInput
        }

        var records: [MergeRecord] = []
        for chunk in chunks {
            let prompt = try MeetingSummaryPromptFactory.chunkExtraction(
                chunk: chunk,
                calendar: source.calendar,
                outputLanguage: outputLanguage
            )
            let partial = try await generateDraft(
                prompt: prompt,
                role: .summaryExtraction
            )
            try validate(
                partial.draft,
                against: SummarySourceData(
                    transcript: chunk.text,
                    calendar: source.calendar
                )
            )
            records.append(
                MergeRecord(
                    draft: partial.draft,
                    modelID: partial.modelID,
                    backendKind: partial.backendKind
                )
            )
        }

        let final: DraftResult
        if records.count == 1, let only = records.first {
            final = DraftResult(
                draft: only.draft,
                modelID: only.modelID,
                backendKind: only.backendKind
            )
        } else {
            final = try await merge(records: records)
        }

        return MeetingSummaryGenerationResult(
            draft: final.draft,
            promptVersion: MeetingSummaryPromptFactory.version,
            modelID: final.modelID,
            backendKind: final.backendKind
        )
    }

    private func merge(records initialRecords: [MergeRecord]) async throws -> DraftResult {
        var records = initialRecords
        while records.count > 1 {
            let allDrafts = records.map(\.draft)
            let finalPrompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: allDrafts,
                outputLanguage: outputLanguage
            )
            if try await fits(
                finalPrompt,
                role: .summaryFinalMerge
            ) {
                let final = try await generateDraft(
                    prompt: finalPrompt,
                    role: .summaryFinalMerge
                )
                try validate(final.draft, againstValidatedRecords: allDrafts)
                return final
            }

            let batches = try await largestMergeBatches(from: records)
            guard batches.allSatisfy({ $0.count > 1 }) else {
                throw MeetingSummaryError.invalidResponse(
                    "Validated summary partial exceeds the safe merge budget."
                )
            }

            var merged: [MergeRecord] = []
            for batch in batches {
                let inputs = batch.map(\.draft)
                let prompt = try MeetingSummaryPromptFactory.merge(
                    validatedPartials: inputs,
                    outputLanguage: outputLanguage
                )
                let result = try await generateDraft(
                    prompt: prompt,
                    role: .summaryIntermediateMerge
                )
                try validate(result.draft, againstValidatedRecords: inputs)
                merged.append(
                    MergeRecord(
                        draft: result.draft,
                        modelID: result.modelID,
                        backendKind: result.backendKind
                    )
                )
            }
            records = merged
        }

        guard let record = records.first else {
            throw MeetingSummaryError.invalidResponse("Missing summary merge result.")
        }
        return DraftResult(
            draft: record.draft,
            modelID: record.modelID,
            backendKind: record.backendKind
        )
    }

    private func largestMergeBatches(
        from records: [MergeRecord]
    ) async throws -> [[MergeRecord]] {
        var batches: [[MergeRecord]] = []
        var current: [MergeRecord] = []

        for record in records {
            let candidate = current + [record]
            let prompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: candidate.map(\.draft),
                outputLanguage: outputLanguage
            )
            if try await fits(prompt, role: .summaryIntermediateMerge) {
                current = candidate
                continue
            }

            if current.isEmpty {
                throw MeetingSummaryError.invalidResponse(
                    "Validated summary partial exceeds the safe merge budget."
                )
            }
            batches.append(current)
            current = [record]
            let singlePrompt = try MeetingSummaryPromptFactory.merge(
                validatedPartials: [record.draft],
                outputLanguage: outputLanguage
            )
            guard try await fits(
                singlePrompt,
                role: .summaryIntermediateMerge
            ) else {
                throw MeetingSummaryError.invalidResponse(
                    "Validated summary partial exceeds the safe merge budget."
                )
            }
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private func generateDraft(
        prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole
    ) async throws -> DraftResult {
        guard try await fits(prompt, role: role) else {
            throw MeetingSummaryError.invalidResponse(
                "Summary request exceeds the safe context budget."
            )
        }
        if backendExecutor.choice.isLocal {
            return try await requestDraft(
                prompt: prompt,
                executor: backendExecutor
            )
        }
        return try await requestCloudDraft(prompt: prompt)
    }

    private func sourceBudget(
        for prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole
    ) async throws -> LocalAITokenBudget {
        guard let budget = try await tokenBudgeter.budget(
            forRenderedChatPrompt: renderedPrompt(prompt),
            role: role
        ) else {
            throw MeetingSummaryError.invalidResponse(
                "Summary request exceeds the safe context budget."
            )
        }
        return budget
    }

    private func fits(
        _ prompt: MeetingSummaryPrompt,
        role: LocalAITokenBudgetRole
    ) async throws -> Bool {
        try await tokenBudgeter.budget(
            forRenderedChatPrompt: renderedPrompt(prompt),
            role: role
        ) != nil
    }

    private func renderedPrompt(_ prompt: MeetingSummaryPrompt) -> String {
        "[System]\n\(prompt.system)\n\n[User]\n\(prompt.user)"
    }

    private func validate(
        _ draft: MeetingSummaryDraftContentV2,
        against source: SummarySourceData
    ) throws {
        do {
            try MeetingSummaryOutputValidator().validate(
                draft,
                outputLanguage: outputLanguage,
                against: source
            )
        } catch let error as MeetingSummaryOutputValidationError {
            throw MeetingSummaryError.outputRejected(error)
        }
    }

    private func validate(
        _ draft: MeetingSummaryDraftContentV2,
        againstValidatedRecords records: [MeetingSummaryDraftContentV2]
    ) throws {
        do {
            try MeetingSummaryOutputValidator().validate(
                draft,
                outputLanguage: outputLanguage,
                againstValidatedRecords: records
            )
        } catch let error as MeetingSummaryOutputValidationError {
            throw MeetingSummaryError.outputRejected(error)
        }
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
            "max_completion_tokens": Self.completionCeiling,
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
        case .rateLimited, .invalidResponse, .outputRejected, .emptyOutput:
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
}
