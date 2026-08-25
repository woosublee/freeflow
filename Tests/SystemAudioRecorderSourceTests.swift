import Foundation

@main
struct SystemAudioRecorderSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/SystemAudioRecorder.swift", encoding: .utf8)
        let microphoneSource = try String(
            contentsOfFile: "Sources/AudioRecorder.swift",
            encoding: .utf8
        )

        precondition(source.contains("final class SystemAudioRecorder"))
        precondition(source.contains("SCStreamOutput"))
        precondition(source.contains("SCStreamDelegate"))
        precondition(source.contains("configuration.capturesAudio = true"))
        precondition(source.contains("configuration.excludesCurrentProcessAudio = true"))
        precondition(source.contains("try stream.addStreamOutput(self, type: .audio"))
        precondition(source.contains("func startRecording() async throws"))
        precondition(source.contains("func stopRecording(completion: @escaping (URL?) -> Void)"))
        precondition(source.contains("func cancelRecording()"))
        precondition(source.contains("func cancelRecording(completion: (() -> Void)?)"))
        precondition(source.contains("cancelRecording(completion: nil)"))
        precondition(source.contains("expectedStream: currentStream"))
        precondition(source.contains("completion?()"))
        precondition(source.contains("func cleanup()"))
        precondition(source.contains("struct SystemAudioRecorderGenerationLifecycle"))
        precondition(source.contains("private let generationLock = OSAllocatedUnfairLock("))
        precondition(source.contains("initialState: SystemAudioRecorderGenerationLifecycle()"))
        let startBody = try functionBody(named: "startRecording", in: source)
        precondition(startBody.contains("let generationID = UUID()"))
        precondition(startBody.contains("generation.begin(generationID)"))
        precondition(startBody.contains("generation.bind(stream, to: generationID)"))
        precondition(startBody.contains("guard currentStreamSnapshot() === stream,"))
        precondition(startBody.contains("try? await stream.stopCapture()"))
        let outputBody = try functionBody(named: "stream", in: source)
        precondition(outputBody.contains("guard let generationID = generationLock.withLock"))
        precondition(outputBody.contains("generation.generation(for: stream)"))
        precondition(outputBody.contains("generation.generation(for: stream) == generationID"))
        let stoppedBody = try functionBody(named: "stream", in: source, occurrence: 2)
        precondition(stoppedBody.contains("expectedStream: stream"))
        precondition(source.contains("expectedStream: SCStream? = nil"))
        precondition(source.contains("guard self.stream === expectedStream else {"))
        precondition(source.contains("var onPCM16Samples: ((Data) -> Void)?"))
        precondition(source.contains("onRecordingFailure?(error)"))
        precondition(!source.contains("if !readyFired && rms > 0"))
        precondition(source.contains("if !readyFired {\n            readyFired = true"))
        precondition(source.contains("let onRecordingReady = self.onRecordingReady"))
        precondition(microphoneSource.contains("if !readyFired {"))
        precondition(!microphoneSource.contains("if !readyFired && rms > 0"))
        precondition(microphoneSource.contains("let onRecordingReady = self.onRecordingReady"))
        precondition(microphoneSource.contains("struct AudioRecorderGenerationLifecycle"))
        precondition(microphoneSource.contains("private let generationLock = OSAllocatedUnfairLock("))
        precondition(microphoneSource.contains("initialState: AudioRecorderGenerationLifecycle()"))
        precondition(microphoneSource.contains("let generationID = UUID()"))
        precondition(microphoneSource.contains("generation.begin(generationID)"))
        precondition(microphoneSource.contains("generation.bind(dataOutput, to: generationID)"))
        precondition(microphoneSource.contains("private let callbacksLock = OSAllocatedUnfairLock(initialState: CallbackState())"))
        precondition(microphoneSource.contains("get { callbacksLock.withLock { $0.onRecordingReady } }"))
        precondition(microphoneSource.contains("set { callbacksLock.withLock { $0.onRecordingReady = newValue } }"))
        precondition(microphoneSource.contains("get { callbacksLock.withLock { $0.onRecordingFailure } }"))
        precondition(microphoneSource.contains("set { callbacksLock.withLock { $0.onRecordingFailure = newValue } }"))
        precondition(microphoneSource.contains("get { callbacksLock.withLock { $0.onPCM16Samples } }"))
        precondition(microphoneSource.contains("set { callbacksLock.withLock { $0.onPCM16Samples = newValue } }"))
        let microphoneFailureBody = try functionBody(
            named: "reportRecordingFailure",
            in: microphoneSource
        )
        let failureCaptureRange = try requiredRange(
            of: "let onRecordingFailure = self.onRecordingFailure",
            in: microphoneFailureBody
        )
        let failureQueueRange = try requiredRange(
            of: "sessionQueue.async",
            in: microphoneFailureBody
        )
        precondition(failureCaptureRange.lowerBound < failureQueueRange.lowerBound)
        precondition(microphoneSource.contains("expectedGenerationID: UUID"))
        precondition(
            countOccurrences(
                of: "generation.owns(expectedGenerationID)",
                in: microphoneFailureBody
            ) == 2
        )
        precondition(microphoneFailureBody.contains("onRecordingFailure?(error)"))
        precondition(!microphoneFailureBody.contains("self.onRecordingFailure?(error)"))
        let microphoneCaptureBody = try functionBody(
            named: "captureOutput",
            in: microphoneSource
        )
        precondition(microphoneCaptureBody.contains(
            "generation.generation(for: output)"
        ))
        precondition(microphoneCaptureBody.contains(
            "generation.owns(generationID)"
        ))
        let microphoneStopBody = try functionBody(
            named: "stopRecording",
            in: microphoneSource
        )
        precondition(microphoneStopBody.contains("generation.invalidateCurrent()"))
        let microphoneCancelBody = try functionBody(
            named: "cancelRecording",
            in: microphoneSource,
            occurrence: 2
        )
        precondition(microphoneCancelBody.contains("generation.invalidateCurrent()"))
        let systemFailureBody = try functionBody(
            named: "reportRecordingFailure",
            in: source
        )
        let systemFailureCaptureRange = try requiredRange(
            of: "let onRecordingFailure = self.onRecordingFailure",
            in: systemFailureBody
        )
        let systemFailureQueueRange = try requiredRange(
            of: "sessionQueue.async",
            in: systemFailureBody
        )
        precondition(systemFailureCaptureRange.lowerBound < systemFailureQueueRange.lowerBound)
        precondition(!source.contains("if discard, let outputURL"))
        precondition(source.contains("fileURLToDelete = finalizedURL"))
        precondition(source.contains("if let fileURLToDelete = finishedRecording.fileURLToDelete"))
        precondition(source.contains("var shouldDiscardRecording = false"))
        precondition(source.contains("shouldDiscardRecording = true"))
        let stopBody = try functionBody(named: "stopRecording", in: source)
        precondition(stopBody.contains("invalidateCurrentGeneration()"))
        precondition(stopBody.contains("expectedStream: currentStream"))
        let cancelBody = try functionBody(
            named: "cancelRecording",
            in: source,
            occurrence: 2
        )
        precondition(cancelBody.contains("invalidateCurrentGeneration()"))
        precondition(cancelBody.contains("expectedStream: currentStream"))
        let watchdogBody = try functionBody(named: "startBufferWatchdog", in: source)
        precondition(source.contains("expectedStream: SCStream,"))
        precondition(watchdogBody.contains("generation.generation(for: expectedStream)"))
        precondition(watchdogBody.contains("expectedStream: expectedStream"))
        let finishBody = try functionBody(named: "finishRecording", in: source)
        precondition(finishBody.contains(
            "guard self.stream === expectedStream else"
        ))
        precondition(source.contains(
            "finishRecording(\n                expectedStream: currentStream,"
        ))
        precondition(source.contains("private let callbacksLock = OSAllocatedUnfairLock(initialState: CallbackState())"))
        precondition(source.contains("private let normalizedPCM16SinkLock ="))
        precondition(source.contains("OSAllocatedUnfairLock<(any NormalizedPCM16Sink)?>(initialState: nil)"))
        precondition(source.contains("var normalizedPCM16Sink: (any NormalizedPCM16Sink)?"))
        precondition(source.contains("private func writeCanonicalRecordingBuffer("))
        precondition(source.contains("try RecordingPCMBufferCopy.data("))
        precondition(source.contains("let firstFrameMonotonicNanoseconds = RecordingMonotonicClock.nowNanoseconds()"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: UInt64"))
        precondition(source.contains("firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds"))
        precondition(source.contains("sink.enqueue(\n            copiedPCM16LE,\n            firstFrameMonotonicNanoseconds: firstFrameMonotonicNanoseconds\n        )"))
        precondition(source.contains("private struct CallbackState"))
        precondition(source.contains("private func resetSampleBufferState(outputURL: URL?, recordingStartTime: CFAbsoluteTime = 0) -> URL?"))
        precondition(source.contains("let staleOutputURL = self.resetSampleBufferState(outputURL: outputURL, recordingStartTime: t0)"))
        precondition(source.contains("let finishedRecording = self.finishAudioFileLocked(discard: discard)"))
        let appendBody = try functionBody(named: "appendSampleBufferToFile", in: source)
        precondition(
            countOccurrences(
                of: "try writeCanonicalRecordingBuffer(",
                in: appendBody
            ) == 2
        )
        let canonicalWriteBody = try functionBody(
            named: "writeCanonicalRecordingBuffer",
            in: source
        )
        precondition(canonicalWriteBody.contains("try activeAudioFile.write(from: buffer)"))
        precondition(canonicalWriteBody.contains("recordedFrameCount +="))
        precondition(canonicalWriteBody.contains("normalizedPCM16SinkLock.withLock"))
        precondition(!canonicalWriteBody.contains("checkpoint"))
        precondition(!canonicalWriteBody.contains("fsync"))
        precondition(!canonicalWriteBody.contains("manifest"))
        let realtimeBody = try functionBody(named: "emitPCM16IfNeeded", in: source)
        precondition(realtimeBody.contains("pcm16TargetFormat"))
        precondition(realtimeBody.contains("handler(data)"))
        let levelBody = try functionBody(named: "updateAudioLevel", in: source)
        precondition(levelBody.contains("generation.generation(for: stream) == generationID"))

        let bannedSymbols = [
            "SCRecordingOutput",
            "captureMicrophone",
            "SCStreamOutputTypeMicrophone",
            "type: .microphone"
        ]
        for symbol in bannedSymbols {
            precondition(!source.contains(symbol), "SystemAudioRecorder must not use \(symbol) in the first implementation")
        }

        print("SystemAudioRecorderSourceTests passed")
    }

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func requiredRange(
        of needle: String,
        in text: String
    ) throws -> Range<String.Index> {
        guard let range = text.range(of: needle) else {
            throw TestFailure("missing text: \(needle)")
        }
        return range
    }

    private static func functionBody(
        named name: String,
        in text: String,
        occurrence: Int = 1
    ) throws -> String {
        var searchStart = text.startIndex
        var signatureRange: Range<String.Index>?
        for _ in 0..<occurrence {
            signatureRange = text.range(
                of: "func \(name)",
                range: searchStart..<text.endIndex
            )
            guard let signatureRange else {
                throw TestFailure("missing function \(name) occurrence \(occurrence)")
            }
            searchStart = signatureRange.upperBound
        }
        guard let signatureRange,
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing function \(name)")
        }

        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: openBrace)..<index])
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        throw TestFailure("unterminated function \(name)")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
