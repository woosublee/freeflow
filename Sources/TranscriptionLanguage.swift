import Foundation

struct TranscriptionLanguage: Identifiable, Hashable, Codable {
    let code: String      // mlx-whisper에 넘기는 언어 코드 (e.g. "ko")
    let displayName: String  // UI에 표시되는 이름 (e.g. "한국어")

    var id: String { code }

    // 자동 감지 옵션
    static let auto = TranscriptionLanguage(code: "auto", displayName: "Auto Detect")

    // 지원 언어 목록 — 언어 추가 시 여기에만 추가하면 됨
    static let all: [TranscriptionLanguage] = [
        .auto,
        TranscriptionLanguage(code: "ko", displayName: "한국어"),
        TranscriptionLanguage(code: "en", displayName: "English"),
        TranscriptionLanguage(code: "ja", displayName: "日本語"),
        TranscriptionLanguage(code: "zh", displayName: "中文"),
        TranscriptionLanguage(code: "es", displayName: "Español"),
        TranscriptionLanguage(code: "fr", displayName: "Français"),
        TranscriptionLanguage(code: "de", displayName: "Deutsch"),
    ]

    static func find(code: String) -> TranscriptionLanguage {
        all.first { $0.code == code } ?? .auto
    }

    // mlx-whisper에 넘길 인자값 (auto이면 language 옵션 생략)
    var whisperArgument: String? {
        code == "auto" ? nil : code
    }
}
