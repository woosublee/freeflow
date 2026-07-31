import Foundation

@main
struct LocalAIModelTests {
    static func main() throws {
        try testQualityModelMetadata()
        try testModelsDeclareTextOnlyCapabilitiesAndRuntime()
        try testCapabilityLookupUsesStoredModelDescriptors()
        try testCatalogArtifactsAreCompleteAndValid()
        try testCatalogContainsOnlyQualityModel()
        try testRetiredModelDoesNotHaveProductStorageMetadata()
        try testDownloadProgressDisplayText()
        try testLocalizedModelMetadataAndDownloadProgress()
        print("LocalAIModelTests passed")
    }

    private static func testQualityModelMetadata() throws {
        let model = LocalAIModelCatalog.quality
        assert(model.id == "qwen2.5-7b-instruct")
        assert(model.displayName == "Qwen2.5 7B Instruct")
        assert(model.artifacts.count == 2)

        let first = model.artifacts[0]
        assert(first.downloadURL.absoluteString == "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")
        assert(first.expectedFileName == "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")
        assert(first.approximateBytes == 3_993_201_344)
        assert(first.checksumSHA256 == "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db")

        let second = model.artifacts[1]
        assert(second.downloadURL.absoluteString == "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")
        assert(second.expectedFileName == "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")
        assert(second.approximateBytes == 689_872_288)
        assert(second.checksumSHA256 == "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a")

        assert(model.approximateBytes == 4_683_073_632)
        assert(model.primaryArtifact == first)
        assert(model.approximateResidentRAMBytes > model.approximateBytes)
    }

    private static func testModelsDeclareTextOnlyCapabilitiesAndRuntime() throws {
        for model in LocalAIModelCatalog.all {
            assert(model.runtime == .textChat)
            assert(model.capabilities.supports(.postProcessing))
            assert(model.capabilities.supports(.meetingSummary))
            assert(!model.capabilities.supportsContextCapture)
        }
    }

    private static func testCapabilityLookupUsesStoredModelDescriptors() throws {
        for model in LocalAIModelCatalog.all {
            assert(LocalAIModelCatalog.capabilities(for: model.id) == model.capabilities)
        }
        assert(LocalAIModelCatalog.capabilities(for: "does-not-exist") == nil)
    }

    private static func testCatalogArtifactsAreCompleteAndValid() throws {
        for model in LocalAIModelCatalog.all {
            assert(!model.artifacts.isEmpty)
            assert(Set(model.artifacts.map(\.expectedFileName)).count == model.artifacts.count)
            for artifact in model.artifacts {
                assert(artifact.checksumSHA256.count == 64)
                assert(artifact.checksumSHA256.allSatisfy { $0.isHexDigit })
            }
        }
    }

    private static func testCatalogContainsOnlyQualityModel() throws {
        assert(LocalAIModelCatalog.all.map(\.id) == ["qwen2.5-7b-instruct"])
        assert(LocalAIModelCatalog.model(id: "qwen2.5-7b-instruct") == LocalAIModelCatalog.quality)
        assert(LocalAIModelCatalog.model(id: "does-not-exist") == nil)
    }

    private static func testRetiredModelDoesNotHaveProductStorageMetadata() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let retiredModelID = "qwen2.5-1.5b-instruct"
        let retiredArtifactName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        let productSources = try [
            "Sources/LocalAIModel.swift",
            "Sources/AIModelCapabilities.swift",
            "Sources/LocalAIInstaller.swift",
            "Sources/LocalAIServerManager.swift"
        ].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }

        assert(LocalAIModelCatalog.model(id: retiredModelID) == nil)
        assert(LocalAIModelCatalog.capabilities(for: retiredModelID) == nil)
        for source in productSources {
            assert(!source.contains(retiredModelID))
            assert(!source.contains(retiredArtifactName))
            assert(!source.contains("Qwen2.5-1.5B-Instruct-GGUF"))
        }
    }

    private static func testDownloadProgressDisplayText() throws {
        assert(LocalAIDownloadProgress(downloadedBytes: 0, totalBytes: 100).displayText == "Starting...")
        assert(LocalAIDownloadProgress(downloadedBytes: 50, totalBytes: 100).displayText == "50% · 50 bytes")
        assert(LocalAIDownloadProgress(downloadedBytes: 100, totalBytes: 100, isCancelled: true).displayText == "Canceled")
    }

    private static func testLocalizedModelMetadataAndDownloadProgress() throws {
        let bundle = try compiledLocalizationBundle()

        assert(
            LocalAIModelCatalog.quality.localizedDescription(
                language: "ko",
                bundle: bundle
            ) == "최고 품질입니다. 더 많은 메모리가 필요합니다."
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 0,
                totalBytes: 100
            ).localizedDisplayText(language: "ko", bundle: bundle) == "시작하는 중..."
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 100,
                totalBytes: 100,
                isCancelled: true
            ).localizedDisplayText(language: "ko", bundle: bundle) == "취소됨"
        )
        assert(
            LocalAIDownloadProgress(
                downloadedBytes: 50,
                totalBytes: 100
            ).localizedDisplayText(language: "ko", bundle: bundle) == "50% · 50 bytes"
        )
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationRoot = root.appendingPathComponent("build/localization")
        guard let bundle = Bundle(path: localizationRoot.path) else {
            throw NSError(
                domain: "LocalAIModelTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing compiled localization bundle"]
            )
        }
        return bundle
    }
}
