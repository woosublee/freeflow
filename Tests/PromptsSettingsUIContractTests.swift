import Foundation

@main
struct PromptsSettingsUIContractTests {
    static func main() throws {
        let tabs = try source("Sources/CalendarIntegrationModels.swift")
        let settings = try source("Sources/SettingsView.swift")

        testNavigation(tabs: tabs, settings: settings)
        testCardOrder(settings)
        testPromptPersistence(settings)
        testBackendAwareTests(settings)
        testInstructionGuard(settings)
        testScreenshotResolutionStaysOut(settings)

        print("PromptsSettingsUIContractTests passed")
    }

    private static func testNavigation(tabs: String, settings: String) {
        precondition(tabs.contains("case prompts"), "Missing Prompts settings tab")
        precondition(
            tabs.contains("[.general, .appearance, .models, .prompts, .shortcuts, .input, .calendar, .about, .runLog, .debug]"),
            "Prompts must appear between Models and Shortcuts"
        )
        precondition(tabs.contains("case .prompts: return \"Prompts\""))
        precondition(tabs.contains("case .prompts: return \"text.bubble\""))
        precondition(settings.contains("case .prompts:\n                    PromptsSettingsView()"))
    }

    private static func testCardOrder(_ source: String) {
        let prompts = promptsBlock(source)
        guard let system = prompts.range(of: "SettingsCard(\"System Prompt\""),
              let guardCard = prompts.range(of: "SettingsCard(\"Instruction Guard\""),
              let context = prompts.range(of: "SettingsCard(\"Context Prompt\"") else {
            preconditionFailure("Missing Prompt settings cards")
        }
        precondition(system.lowerBound < guardCard.lowerBound)
        precondition(guardCard.lowerBound < context.lowerBound)
    }

    private static func testPromptPersistence(_ source: String) {
        let prompts = promptsBlock(source)
        for expected in [
            "@State private var customSystemPromptInput: String = \"\"",
            "@State private var customContextPromptInput: String = \"\"",
            "PostProcessingService.defaultSystemPrompt",
            "AppContextService.defaultContextPrompt",
            "appState.customSystemPrompt = trimmed",
            "appState.customSystemPromptLastModified = today",
            "appState.customContextPrompt = trimmed",
            "appState.customContextPromptLastModified = today",
            "Button(\"Switch to Default\")",
            "Button(\"Reset to Default\")"
        ] {
            precondition(prompts.contains(expected), "Missing Prompt persistence behavior: \(expected)")
        }
    }

    private static func testBackendAwareTests(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(prompts.contains("appState.isAIProcessingBackendReady(for: .postProcessing)"))
        precondition(prompts.contains("appState.isAIProcessingBackendReady(for: .context)"))
        precondition(prompts.contains("let service = appState.makePostProcessingService()"))
        precondition(prompts.contains("let service = appState.makeAppContextService()"))
        precondition(!prompts.contains("let service = PostProcessingService("))
        precondition(prompts.contains("QuillUserIssueView("))
        precondition(prompts.contains("settingsTestRecoveryAction("))
        precondition(prompts.contains("providerConfigurationWarning("))
        precondition(prompts.contains("if postProcessingUsesCloud && !hasConfiguredCloudAPIKey"))
        precondition(prompts.contains("if contextUsesCloud && !hasConfiguredCloudAPIKey"))
    }

    private static func testInstructionGuard(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(prompts.contains("isOn: $appState.instructionExecutionGuardEnabled"))
        precondition(prompts.contains("Prevent dictated prompts from being executed"))
    }

    private static func testScreenshotResolutionStaysOut(_ source: String) {
        let prompts = promptsBlock(source)
        precondition(!prompts.contains("Screenshot Resolution"))
        precondition(!prompts.contains("contextScreenshotMaxDimension"))
    }

    private static func promptsBlock(_ source: String) -> String {
        block(
            in: source,
            from: "struct PromptsSettingsView",
            to: "// MARK: - Shortcuts Settings"
        )
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func block(in source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            preconditionFailure("Unable to locate source block from \(start) to \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
