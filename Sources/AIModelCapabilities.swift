enum AIModelFeature: Hashable, Sendable, Codable {
    case postProcessing
    case contextCapture
    case meetingSummary
}

enum AIModelModality: Hashable, Sendable, Codable {
    case text
    case image
}

struct AIModelCapabilities: Hashable, Sendable, Codable {
    let features: Set<AIModelFeature>
    let modalities: Set<AIModelModality>
    let recommendedContextWindow: Int?

    func supports(_ feature: AIModelFeature) -> Bool {
        features.contains(feature)
    }

    var supportsContextCapture: Bool {
        supports(.contextCapture) && modalities.contains(.image)
    }
}

enum LocalAIRuntime: Hashable, Sendable, Codable {
    case textChat
    case visionChat(projectorArtifactFileName: String)
}

enum AIModelCapabilityCatalog {
    static let qwenTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: 16_384
    )

    static let qwenCloudVisionCapabilities = AIModelCapabilities(
        features: [.postProcessing, .contextCapture, .meetingSummary],
        modalities: [.text, .image],
        recommendedContextWindow: nil
    )

    static let cloudTextCapabilities = AIModelCapabilities(
        features: [.postProcessing, .meetingSummary],
        modalities: [.text],
        recommendedContextWindow: nil
    )

    static func capabilities(forCloudModelID modelID: String) -> AIModelCapabilities {
        modelID == "qwen/qwen3.6-27b"
            ? qwenCloudVisionCapabilities
            : cloudTextCapabilities
    }

    static func capabilities(forLocalModelID modelID: String) -> AIModelCapabilities? {
        switch modelID {
        case "qwen2.5-7b-instruct", "qwen2.5-1.5b-instruct":
            qwenTextCapabilities
        default:
            nil
        }
    }
}
