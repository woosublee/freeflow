import AVFoundation
import Foundation
import os.log

private let transcriptionLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Transcription")

class TranscriptionService {
    private let apiKey: String
    private let baseURL: String
    private let forceHTTP2: Bool
    private let useLocalTranscription: Bool
    private let localWhisperPath: String?
    private let transcriptionLanguage: TranscriptionLanguage
    private let transcriptionModel: TranscriptionModel
    private let groqTranscriptionModel = "whisper-large-v3"
    private let transcriptionTimeoutSeconds: TimeInterval = 20
    private let localTranscriptionTimeoutSeconds: TimeInterval = 3600
    private let uploadSampleRate = 16_000.0
    private let uploadChannelCount: AVAudioChannelCount = 1

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        forceHTTP2: Bool = false,
        useLocalTranscription: Bool = false,
        localWhisperPath: String? = nil,
        transcriptionLanguage: TranscriptionLanguage = .auto,
        transcriptionModel: TranscriptionModel = .default
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.forceHTTP2 = forceHTTP2
        self.useLocalTranscription = useLocalTranscription
        self.localWhisperPath = localWhisperPath
        self.transcriptionLanguage = transcriptionLanguage
        self.transcriptionModel = transcriptionModel
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        if useLocalTranscription {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else {
                        throw TranscriptionError.submissionFailed("Service deallocated")
                    }
                    return try await self.transcribeAudioLocally(fileURL: fileURL)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.localTranscriptionTimeoutSeconds * 1_000_000_000))
                    throw TranscriptionError.transcriptionTimedOut(self.localTranscriptionTimeoutSeconds)
                }

                guard let result = try await group.next() else {
                    throw TranscriptionError.submissionFailed("No transcription result")
                }
                group.cancelAll()
                return result
            }
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw TranscriptionError.submissionFailed("Service deallocated")
                }
                return try await self.transcribeAudio(fileURL: fileURL)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.transcriptionTimeoutSeconds * 1_000_000_000))
                throw TranscriptionError.transcriptionTimedOut(self.transcriptionTimeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw TranscriptionError.submissionFailed("No transcription result")
            }
            group.cancelAll()
            return result
        }
    }

    // Run mlx_whisper locally and return transcript text
    private func transcribeAudioLocally(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [localWhisperPath, transcriptionLanguage, transcriptionModel] in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let whisperBin = (localWhisperPath?.isEmpty == false)
                ? localWhisperPath!
                : "\(home)/.local/bin/mlx_whisper"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperBin)
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin",
                "HOME": home
            ]

            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDir) }

            var arguments = [
                fileURL.path,
                "--model", transcriptionModel.id,
                "--output-format", "txt",
                "--output-dir", outputDir.path,
                "--condition-on-previous-text", "False"
            ]
            if let langCode = transcriptionLanguage.whisperArgument {
                arguments += ["--language", langCode]
            }
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw TranscriptionError.submissionFailed("mlx_whisper not found at \(whisperBin). Install with: pipx install mlx-whisper")
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw TranscriptionError.submissionFailed("mlx_whisper failed (exit \(process.terminationStatus)): \(errorText)")
            }

            // mlx_whisper outputs a .txt file with the same name as the input
            let inputName = fileURL.deletingPathExtension().lastPathComponent
            let outputFile = outputDir.appendingPathComponent(inputName).appendingPathExtension("txt")

            guard let text = try? String(contentsOf: outputFile, encoding: .utf8) else {
                // fallback: read stdout
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let outputText = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !outputText.isEmpty else {
                    throw TranscriptionError.pollFailed("mlx_whisper produced no output")
                }
                return outputText
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw TranscriptionError.pollFailed("mlx_whisper produced empty transcript")
            }
            return trimmed
        }.value
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL) async throws -> String {
        let preparedAudio = try prepareAudioForUpload(from: fileURL)
        defer { preparedAudio.cleanup() }

        if forceHTTP2 {
            return try await transcribeAudioWithCurl(fileURL: preparedAudio.fileURL)
        }
        return try await transcribeAudioWithURLSession(fileURL: preparedAudio.fileURL)
    }

    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let body = makeMultipartBody(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            model: groqTranscriptionModel,
            boundary: boundary
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            let nsError = error as NSError
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload failed for %{public}@ (transport=%{public}@, bytes=%{public}lld): domain=%{public}@ code=%ld desc=%{public}@",
                fileURL.lastPathComponent,
                "urlsession-default",
                fileSizeBytes(for: fileURL),
                nsError.domain,
                nsError.code,
                error.localizedDescription
            )
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (transport=%{public}@, bytes=%{public}lld)",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                "urlsession-default",
                fileSizeBytes(for: fileURL)
            )
            throw TranscriptionError.submissionFailed("Status \(httpResponse.statusCode): \(responseBody)")
        }

        return try parseTranscript(from: data)
    }

    private func transcribeAudioWithCurl(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [apiKey, groqTranscriptionModel] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent",
                "--show-error",
                "--fail",
                "--http2",
                "--max-time", String(Int(self.transcriptionTimeoutSeconds)),
                "\(self.baseURL)/audio/transcriptions",
                "-H", "Authorization: Bearer \(apiKey)",
                "-F", "model=\(groqTranscriptionModel)",
                "-F", "file=@\(fileURL.path);type=\(self.audioContentType(for: fileURL.lastPathComponent))"
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                os_log(
                    .error,
                    log: transcriptionLog,
                    "curl upload failed for %{public}@ (transport=%{public}@, bytes=%{public}lld): exit=%d%{public}@",
                    fileURL.lastPathComponent,
                    "http2-curl",
                    self.fileSizeBytes(for: fileURL),
                    process.terminationStatus,
                    errorText.isEmpty ? "" : " stderr=\(errorText)"
                )
                throw TranscriptionError.submissionFailed(
                    "curl transport failed with exit \(process.terminationStatus): \(errorText)"
                )
            }

            return try self.parseTranscript(from: outputData)
        }.value
    }

    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func makeMultipartBody(audioData: Data, fileName: String, model: String, boundary: String) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType(for: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    private func prepareAudioForUpload(from fileURL: URL) throws -> PreparedUploadAudio {
        let inputFile = try AVAudioFile(forReading: fileURL)
        if isPreferredUploadFormat(file: inputFile, fileURL: fileURL) {
            return PreparedUploadAudio(fileURL: fileURL, deleteOnCleanup: false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        do {
            try AudioNormalization.writePreferredAudioCopy(from: fileURL, to: outputURL)
        } catch {
            throw TranscriptionError.audioPreparationFailed(error.localizedDescription)
        }
        return PreparedUploadAudio(fileURL: outputURL, deleteOnCleanup: true)
    }

    private func isPreferredUploadFormat(file: AVAudioFile, fileURL: URL) -> Bool {
        let format = file.fileFormat
        return fileURL.pathExtension.lowercased() == "wav"
            && abs(format.sampleRate - uploadSampleRate) < 0.5
            && format.channelCount == uploadChannelCount
            && format.commonFormat == .pcmFormatInt16
    }

    private func parseTranscript(from data: Data) throws -> String {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return text
    }
}

enum TranscriptionError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
