import Foundation

@main
struct AIModelCapabilitiesTests {
    static func main() throws {
        try testContextRequiresImageModality()
        try testQualityQwenFeatures()
        try testCloudCapabilitiesAreExplicit()
        print("AIModelCapabilitiesTests passed")
    }

    private static func testContextRequiresImageModality() throws {
        let textOnly = AIModelCapabilities(
            features: [.contextCapture],
            modalities: [.text],
            recommendedContextWindow: 16_384
        )

        try expect(!textOnly.supportsContextCapture,
                   "text-only models cannot support Context")
    }

    private static func testQualityQwenFeatures() throws {
        let model = LocalAIModelCatalog.quality

        try expect(model.capabilities.supports(.postProcessing), "quality supports cleanup")
        try expect(model.capabilities.supports(.meetingSummary), "quality supports summary")
        try expect(!model.capabilities.supportsContextCapture, "quality excludes Context")
        try expect(model.capabilities.recommendedContextWindow == 16_384,
                   "quality uses 16K context")
    }

    private static func testCloudCapabilitiesAreExplicit() throws {
        try expect(
            ModelConfiguration.capabilities(for: "qwen/qwen3.6-27b").supportsContextCapture,
            "the declared Cloud Qwen vision model supports Context"
        )
        for modelID in ModelConfiguration.llmModels where modelID != "qwen/qwen3.6-27b" {
            try expect(
                !ModelConfiguration.capabilities(for: modelID).supportsContextCapture,
                "\(modelID) is not Context-capable until explicitly declared"
            )
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(
                domain: "AIModelCapabilitiesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
