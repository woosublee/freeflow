import Foundation

@main
struct SystemAudioInputSelectionTests {
    static func main() throws {
        testSystemAudioInputIdentifier()
        testSystemDefaultAndSystemAudioInputIdentifier()
        testSpecialInputClassification()
        testSingleSourceClassification()
        testMicrophoneOnlyClassification()
        testAudioSourceMapping()
        testAudioSourceCatalog()
        testMicrophoneDeviceNormalization()
        try testSettingsSeparatesSourceAndMicrophone()
        try testMenuBarSeparatesSourceAndMicrophone()
        try testSettingsPickerIncludesMicrophoneAndSystemAudio()
        try testMenuBarPickerIncludesMicrophoneAndSystemAudio()
        try testSetupOmitsAudioInputPicker()
        print("SystemAudioInputSelectionTests passed")
    }

    private static func testSystemAudioInputIdentifier() {
        assert(AudioInputDevice.systemAudioID == "__system_audio__")
        assert(AudioInputDevice.defaultMicrophoneID == "default")
        assert(AudioInputDevice.isSystemAudio(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSystemAudio(AudioInputDevice.defaultMicrophoneID))
        assert(!AudioInputDevice.isSystemAudio(""))
    }

    private static func testSystemDefaultAndSystemAudioInputIdentifier() {
        assert(AudioInputDevice.systemDefaultAndSystemAudioID == "__system_default_and_system_audio__")
        assert(AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.systemDefaultAndSystemAudioID))
        assert(!AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSystemDefaultAndSystemAudio(AudioInputDevice.defaultMicrophoneID))
    }

    private static func testSpecialInputClassification() {
        assert(AudioInputDevice.isSpecialInput(AudioInputDevice.systemAudioID))
        assert(AudioInputDevice.isSpecialInput(AudioInputDevice.systemDefaultAndSystemAudioID))
        assert(!AudioInputDevice.isSpecialInput(AudioInputDevice.defaultMicrophoneID))
    }

    private static func testSingleSourceClassification() {
        assert(AudioInputDevice.isSingleSource(AudioInputDevice.defaultMicrophoneID))
        assert(AudioInputDevice.isSingleSource(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isSingleSource(AudioInputDevice.systemDefaultAndSystemAudioID))
    }

    private static func testMicrophoneOnlyClassification() {
        assert(AudioInputDevice.isMicrophoneOnly(AudioInputDevice.defaultMicrophoneID))
        assert(!AudioInputDevice.isMicrophoneOnly(AudioInputDevice.systemAudioID))
        assert(!AudioInputDevice.isMicrophoneOnly(AudioInputDevice.systemDefaultAndSystemAudioID))
    }

    private static func testAudioSourceMapping() {
        assert(AudioInputDevice.audioSourceID(for: "device-uid") == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.audioSourceID(for: AudioInputDevice.defaultMicrophoneID) == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.audioSourceID(for: AudioInputDevice.systemAudioID) == AudioInputDevice.systemAudioID)
        assert(AudioInputDevice.audioSourceID(for: AudioInputDevice.systemDefaultAndSystemAudioID) == AudioInputDevice.systemDefaultAndSystemAudioID)
    }

    private static func testAudioSourceCatalog() {
        assert(AudioRecordingSource.allCases == [
            .microphone,
            .systemAudio,
            .microphoneAndSystemAudio
        ])
        assert(AudioRecordingSource.microphone.id == AudioInputDevice.defaultMicrophoneID)
        assert(AudioRecordingSource.systemAudio.id == AudioInputDevice.systemAudioID)
        assert(
            AudioRecordingSource.microphoneAndSystemAudio.id
                == AudioInputDevice.systemDefaultAndSystemAudioID
        )
        assert(AudioRecordingSource(inputID: "device-uid") == .microphone)
        assert(AudioRecordingSource(inputID: AudioInputDevice.systemAudioID) == .systemAudio)
        assert(
            AudioRecordingSource(
                inputID: AudioInputDevice.systemDefaultAndSystemAudioID
            ) == .microphoneAndSystemAudio
        )
        assert(AudioRecordingSource.microphone.requiresMicrophonePermission)
        assert(!AudioRecordingSource.microphone.requiresSystemAudioPermission)
        assert(AudioRecordingSource.microphone.supportsLiveTranscription)
        assert(!AudioRecordingSource.systemAudio.requiresMicrophonePermission)
        assert(AudioRecordingSource.systemAudio.requiresSystemAudioPermission)
        assert(AudioRecordingSource.systemAudio.supportsLiveTranscription)
        assert(AudioRecordingSource.microphoneAndSystemAudio.requiresMicrophonePermission)
        assert(AudioRecordingSource.microphoneAndSystemAudio.requiresSystemAudioPermission)
        assert(!AudioRecordingSource.microphoneAndSystemAudio.supportsLiveTranscription)
    }

    private static func testMicrophoneDeviceNormalization() {
        assert(AudioInputDevice.normalizedMicrophoneDeviceID(nil) == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.normalizedMicrophoneDeviceID("") == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.normalizedMicrophoneDeviceID(AudioInputDevice.systemAudioID) == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.normalizedMicrophoneDeviceID(AudioInputDevice.systemDefaultAndSystemAudioID) == AudioInputDevice.defaultMicrophoneID)
        assert(AudioInputDevice.normalizedMicrophoneDeviceID("device-uid") == "device-uid")
    }

    private static func testSettingsSeparatesSourceAndMicrophone() throws {
        let source = try sourceFile("Sources/SettingsView.swift")
        assertOrder(
            source: source,
            first: "SettingsCard(\"Audio Source\"",
            second: "SettingsCard(\"Microphone\"",
            file: "Sources/SettingsView.swift"
        )
        assertContains(source, "appState.selectAudioSource(")
        assertContains(source, "appState.selectMicrophoneDevice(")
        assertContains(source, ".disabled(appState.isRecording)")
    }

    private static func testMenuBarSeparatesSourceAndMicrophone() throws {
        let source = try sourceFile("Sources/MenuBarView.swift")
        assertOrder(
            source: source,
            first: "Menu(\"Audio Source\")",
            second: "Menu(\"Microphone\")",
            file: "Sources/MenuBarView.swift"
        )
        assertContains(source, "appState.selectAudioSource(")
        assertContains(source, "appState.selectMicrophoneDevice(")
    }

    private static func testSettingsPickerIncludesMicrophoneAndSystemAudio() throws {
        let source = try sourceFile("Sources/SettingsView.swift")
        assertContains(source, "ForEach(AudioRecordingSource.allCases)")
        assertContains(source, "catalogKey: source.titleKey")
        assertContains(source, "appState.isAudioSourceSelectable(source)")
    }

    private static func testMenuBarPickerIncludesMicrophoneAndSystemAudio() throws {
        let source = try sourceFile("Sources/MenuBarView.swift")
        assertContains(source, "ForEach(AudioRecordingSource.allCases)")
        assertContains(source, "localizedCatalogString(source.titleKey)")
        assertContains(source, "appState.isAudioSourceSelectable(source)")
    }

    private static func testSetupOmitsAudioInputPicker() throws {
        let source = try sourceFile("Sources/SetupView.swift")
        precondition(!source.contains("setupMicrophoneSelection"))
        precondition(!source.contains("Picker(\"Input:\""))
        precondition(!source.contains("testTranscriptionStep"))
    }

    private static func sourceFile(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func assertOrder(source: String, first: String, second: String, file: String) {
        guard let firstRange = source.range(of: first) else {
            preconditionFailure("Missing first marker in \(file): \(first)")
        }
        guard let secondRange = source.range(of: second) else {
            preconditionFailure("Missing second marker in \(file): \(second)")
        }
        precondition(
            firstRange.lowerBound < secondRange.lowerBound,
            "Expected \(first) to appear before \(second) in \(file)"
        )
    }

    private static func assertContains(_ source: String, _ marker: String) {
        precondition(source.contains(marker), "Missing marker: \(marker)")
    }
}
