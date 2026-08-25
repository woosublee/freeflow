import Foundation

@main
struct SystemDefaultAndSystemAudioRecorderSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/SystemDefaultAndSystemAudioRecorder.swift", encoding: .utf8)

        precondition(source.contains("final class SystemDefaultAndSystemAudioRecorder: ObservableObject"))
        precondition(source.contains("@Published var audioLevel: Float"))
        precondition(source.contains("var onRecordingReady: (() -> Void)?"))
        precondition(source.contains("var onRecordingFailure: ((Error) -> Void)?"))
        precondition(source.contains("var onRecordingDegraded: ((DegradedCombinedCaptureSource) -> Void)?"))
        precondition(source.contains("init(microphoneRecorder: AudioRecorder, systemAudioRecorder: SystemAudioRecorder, mixdownService: AudioMixdownService = AudioMixdownService())"))
        precondition(source.contains("struct CombinedRecordingStartResult: Equatable"))
        precondition(source.contains("let microphoneStarted: Bool"))
        precondition(source.contains("let systemAudioStarted: Bool"))
        precondition(source.contains("let microphoneUsedSystemDefaultFallback: Bool"))

        // Execution coverage in CombinedCaptureDegradationTests owns the four
        // start outcomes; this source contract only keeps the typed API stable.
        precondition(source.contains("enum DegradedCombinedCaptureSource: Equatable"))
        precondition(source.contains("case microphone"))
        precondition(source.contains("case systemAudio"))
        precondition(source.contains("var missingSource: DegradedCombinedCaptureSource?"))
        precondition(source.contains("var currentMissingSource: DegradedCombinedCaptureSource?"))
        precondition(source.contains("var startInProgress = false"))
        precondition(source.contains("var startCompletionGroup: DispatchGroup?"))
        precondition(source.contains("var readySources: Set<RecordingSource> = []"))
        precondition(source.contains("state.failuresDuringStart.append(failure)"))

        // Manual QA hook: let a developer force one side of the combined
        // start to fail deterministically, without touching real hardware
        // permissions, to exercise the degraded-capture notice on demand.
        // Each flag is consumed (reset) by the attempt it triggers, so it
        // only affects the next recording, never a later one.
        precondition(source.contains("var debugForcesMicrophoneStartFailure = false"))
        precondition(source.contains("var debugForcesSystemAudioStartFailure = false"))
        precondition(source.contains("case debugSimulatedStartFailure"))
        precondition(source.contains("struct CombinedStoppedRecordingSources: Equatable"))
        precondition(source.contains("func startRecording(microphoneDeviceUID: String) async throws -> CombinedRecordingStartResult"))
        precondition(source.contains("func stopRecordingSources("))
        precondition(source.contains("completion: @escaping (CombinedStoppedRecordingSources) -> Void"))
        precondition(source.contains("func stopRecording(completion: @escaping (URL?) -> Void)"))
        precondition(source.contains("func cancelRecording()"))
        precondition(source.contains("func cancelRecording(completion: (() -> Void)?)"))
        precondition(source.contains("func cleanup()"))

        precondition(source.contains("let microphoneRecorder: AudioRecorder"))
        precondition(source.contains("let systemAudioRecorder: SystemAudioRecorder"))
        precondition(source.contains("let mixdownService: AudioMixdownService"))
        precondition(source.contains("struct CombinedRecordingStartOperations"))
        precondition(source.contains("private let startOperations: CombinedRecordingStartOperations"))
        precondition(source.contains("try microphoneRecorder.startRecording(deviceUID: deviceUID)"))
        precondition(source.contains("try await systemAudioRecorder.startRecording()"))
        precondition(source.contains("microphoneRecorder.cancelRecording"))
        precondition(source.contains("cancelMicrophone: {"))
        precondition(source.contains("async let microphoneAttempt"))
        precondition(source.contains("async let systemAudioAttempt"))
        precondition(source.contains("try startOperations.startMicrophone(microphoneDeviceUID)"))
        precondition(source.contains("try await startOperations.startSystemAudio()"))
        precondition(source.contains("result.usedSystemDefaultFallback"))
        precondition(!source.contains("deviceUID: AudioInputDevice.defaultMicrophoneID"))
        precondition(source.contains("guard microphoneStarted || systemStarted else"))
        precondition(source.contains("return CombinedRecordingStartResult("))
        precondition(source.contains("let startID = UUID()"))
        precondition(source.contains("startCompletionGroup: startCompletionGroup"))
        precondition(source.contains("configureChildCallbacks(startID: startID)"))
        precondition(source.contains("source: .microphone"))
        precondition(source.contains("source: .systemAudio"))
        precondition(source.contains("state.readySources.insert(source)"))
        precondition(source.contains("state.consumeReadyIfPossible()"))
        precondition(source.contains("state.activeSources.contains"))
        precondition(source.contains("!failedSources.contains($0)"))
        precondition(source.contains("handleSourceFailure"), "SystemDefaultAndSystemAudioRecorder should aggregate child recorder failures before reporting overall failure")
        precondition(source.contains("onRecordingDegraded?(degradedSource)"))
        precondition(!source.contains("self?.onRecordingFailure?(error)"), "Child recorder failures should not be forwarded directly as overall failures")
        precondition(source.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should be able to restore audio level subscriptions after cleanup")

        guard let startRecordingRange = source.range(of: "func startRecording(microphoneDeviceUID: String) async throws"),
              let stopRecordingRange = source.range(of: "func stopRecording(completion: @escaping (URL?) -> Void)", range: startRecordingRange.upperBound..<source.endIndex) else {
            preconditionFailure("Could not locate startRecording body")
        }
        let startRecordingSource = source[startRecordingRange.lowerBound..<stopRecordingRange.lowerBound]
        precondition(startRecordingSource.contains("configureChildCallbacks(startID: startID)"), "startRecording should scope child callbacks to each start")
        precondition(startRecordingSource.contains("subscribeToAudioLevelsIfNeeded()"), "startRecording should restore audio level subscriptions when needed")
        precondition(startRecordingSource.contains("let forceMicrophoneFailure = debugForcesMicrophoneStartFailure"), "startRecording consumes the microphone debug-failure hook")
        precondition(startRecordingSource.contains("let forceSystemAudioFailure = debugForcesSystemAudioStartFailure"), "startRecording consumes the System Audio debug-failure hook")
        precondition(startRecordingSource.contains("debugForcesMicrophoneStartFailure = false"))
        precondition(startRecordingSource.contains("debugForcesSystemAudioStartFailure = false"))
        precondition(source.contains("if forceFailure {"), "each source attempt applies its consumed debug-failure hook")

        precondition(source.contains("Publishers.CombineLatest(microphoneRecorder.$audioLevel, systemAudioRecorder.$audioLevel)"))
        precondition(source.contains("max(microphoneLevel, systemAudioLevel)"))
        precondition(source.contains("microphoneRecorder.stopRecording"))
        precondition(source.contains("systemAudioRecorder.stopRecording"))
        precondition(source.contains("stopRecordingSources { sources in"))
        precondition(source.contains("group.notify(queue: .main)"), "source drain completion should return on the main queue")
        precondition(source.contains("notifyAfterPendingStart(startCompletionGroup)"))
        precondition(source.contains("startCompletionGroup.notify(queue: .main"))
        precondition(source.contains("completion(CombinedStoppedRecordingSources("))
        precondition(source.contains("DispatchQueue.global(qos: .userInitiated).async"), "mixdown should not run on the main queue")
        precondition(source.contains("let finalURL = self.finalRecordingURL("))
        precondition(source.contains("DispatchQueue.main.async {\n                completion(finalURL)\n            }"), "stop completion should return to the main queue")
        precondition(source.contains("try mixdownService.mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: microphoneURL)"))
        precondition(source.contains("try? FileManager.default.removeItem(at: systemAudioURL)"))
        precondition(source.contains("microphoneRecorder.cancelRecording(completion:"))
        precondition(source.contains("systemAudioRecorder.cancelRecording(completion:"))
        precondition(source.contains("cancelRecording(completion: nil)"))
        precondition(source.contains("microphoneRecorder.onPCM16Samples = nil"))
        precondition(source.contains("systemAudioRecorder.onPCM16Samples = nil"))
        precondition(!source.contains("microphoneRecorder.cleanup()"))
        precondition(!source.contains("systemAudioRecorder.cleanup()"))

        let bannedSymbols = ["SCStream(", "AVCaptureSession(", "SCContentFilter(", "NSLock()"]
        for symbol in bannedSymbols {
            precondition(!source.contains(symbol), "SystemDefaultAndSystemAudioRecorder must not create a new capture path with \(symbol)")
        }

        print("SystemDefaultAndSystemAudioRecorderSourceTests passed")
    }
}
