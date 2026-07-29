enum AudioRecordingSource: CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case microphoneAndSystemAudio

    var id: String {
        switch self {
        case .microphone:
            return AudioInputDevice.defaultMicrophoneID
        case .systemAudio:
            return AudioInputDevice.systemAudioID
        case .microphoneAndSystemAudio:
            return AudioInputDevice.systemDefaultAndSystemAudioID
        }
    }

    var titleKey: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .microphoneAndSystemAudio:
            return "Microphone + System Audio"
        }
    }

    var requiresMicrophonePermission: Bool {
        self != .systemAudio
    }

    var requiresSystemAudioPermission: Bool {
        self != .microphone
    }

    var supportsLiveTranscription: Bool {
        self != .microphoneAndSystemAudio
    }

    init(inputID: String) {
        if AudioInputDevice.isSystemAudio(inputID) {
            self = .systemAudio
        } else if AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) {
            self = .microphoneAndSystemAudio
        } else {
            self = .microphone
        }
    }
}

enum AudioInputDevice {
    static let systemAudioID = "__system_audio__"
    static let systemDefaultAndSystemAudioID = "__system_default_and_system_audio__"
    static let defaultMicrophoneID = "default"

    static func isSystemAudio(_ id: String) -> Bool {
        id == systemAudioID
    }

    static func isSystemDefaultAndSystemAudio(_ id: String) -> Bool {
        id == systemDefaultAndSystemAudioID
    }

    static func isSpecialInput(_ id: String) -> Bool {
        isSystemAudio(id) || isSystemDefaultAndSystemAudio(id)
    }

    static func isSingleSource(_ id: String) -> Bool {
        !isSystemDefaultAndSystemAudio(id)
    }

    static func isMicrophoneOnly(_ id: String) -> Bool {
        !isSpecialInput(id)
    }

    static func audioSourceID(for inputID: String) -> String {
        isSpecialInput(inputID) ? inputID : defaultMicrophoneID
    }

    /// Treats an empty id as the system default microphone so the two spellings
    /// compare equal.
    static func normalized(_ id: String) -> String {
        id.isEmpty ? defaultMicrophoneID : id
    }

    static func normalizedMicrophoneDeviceID(_ id: String?) -> String {
        guard let id, !id.isEmpty, !isSpecialInput(id) else {
            return defaultMicrophoneID
        }
        return id
    }

    static func isSameInput(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
}
