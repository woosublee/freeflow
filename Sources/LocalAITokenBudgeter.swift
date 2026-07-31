import Foundation

struct LocalAITokenBudget: Equatable, Sendable {
    let sourceTokenLimit: Int
    let maxCompletionTokens: Int
}

protocol LocalAITokenCounting: Sendable {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int
}

enum LocalAITokenBudgetRole: Sendable {
    case postProcessing(inputReservation: Int)
    case summaryExtraction
    case summaryIntermediateMerge
    case summaryFinalMerge

    fileprivate var maxCompletionTokens: Int {
        switch self {
        case let .postProcessing(inputReservation):
            return min(max(inputReservation, 0) + 512, 6_144)
        case .summaryExtraction, .summaryIntermediateMerge, .summaryFinalMerge:
            return 1_024
        }
    }
}

struct LocalAITokenBudgeter: Sendable {
    static let safetyMarginTokens = 512

    let contextWindow: Int
    let tokenCounter: any LocalAITokenCounting

    func budget(
        forRenderedChatPrompt prompt: String,
        role: LocalAITokenBudgetRole
    ) async throws -> LocalAITokenBudget? {
        let renderedPromptTokens = try await tokenCounter.tokenCount(
            forRenderedChatPrompt: prompt
        )
        let sourceTokenLimit = contextWindow
            - renderedPromptTokens
            - role.maxCompletionTokens
            - Self.safetyMarginTokens
        guard sourceTokenLimit > 0 else { return nil }

        return LocalAITokenBudget(
            sourceTokenLimit: sourceTokenLimit,
            maxCompletionTokens: role.maxCompletionTokens
        )
    }
}
