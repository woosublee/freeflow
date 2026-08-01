import Foundation
import NaturalLanguage

enum AIOutputLanguageValidation: Equatable, Sendable {
    case notRequested
    case accepted
    case uncertain
    case mismatch
}

struct AIOutputLanguageValidator: Sendable {
    private let expectedLanguages: Set<NLLanguage>?

    init(outputLanguage: String?) {
        expectedLanguages = Self.languages(for: outputLanguage)
    }

    func validate(generatedProse: String) -> AIOutputLanguageValidation {
        guard let expectedLanguages else { return .notRequested }

        let prose = Self.removingProtectedAtoms(from: generatedProse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prose.rangeOfCharacter(from: .letters) != nil else {
            return .uncertain
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let detectedLanguage = recognizer.dominantLanguage else {
            return .uncertain
        }
        return expectedLanguages.contains(detectedLanguage) ? .accepted : .mismatch
    }

    private static func languages(for outputLanguage: String?) -> Set<NLLanguage>? {
        let language = outputLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return switch language {
        case "", "auto":
            nil
        case "korean", "ko", "ko-kr":
            [.korean]
        case "english", "en", "en-us", "en-gb":
            [.english]
        case "japanese", "ja", "ja-jp":
            [.japanese]
        case "chinese", "zh":
            [.simplifiedChinese, .traditionalChinese]
        case "zh-hans", "zh-cn", "zh-sg":
            [.simplifiedChinese]
        case "zh-hant", "zh-hk", "zh-mo", "zh-tw":
            [.traditionalChinese]
        case "spanish", "es", "es-es":
            [.spanish]
        case "french", "fr", "fr-fr":
            [.french]
        case "german", "de", "de-de":
            [.german]
        case "portuguese", "pt", "pt-br", "pt-pt":
            [.portuguese]
        default:
            nil
        }
    }

    private static func removingProtectedAtoms(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"`[^`]*`"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"https?://\S+|\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_./:-]*\b"#,
                with: " ",
                options: .regularExpression
            )
    }
}
