import Foundation

struct NativeWhisperExecutionSnapshot: Sendable {
    struct PreparedAudio: Sendable {
        let fileURL: URL
        let cleanup: @Sendable () -> Void
    }

    let modelID: String
    let modelIsReady: @Sendable () -> Bool
    let modelURL: @Sendable () -> URL
    let validateRunnerAndModel: @Sendable (URL) throws -> Void
    let prepareAudio:
        @Sendable (URL) async throws -> PreparedAudio
    let transcribe:
        @Sendable (URL, URL, String?) async throws -> TranscriptionResult

    static func live(
        store: NativeWhisperModelStore = NativeWhisperModelStore()
    ) -> NativeWhisperExecutionSnapshot {
        let model = NativeWhisperModelCatalog.recommended
        let runtime = NativeWhisperRuntime()
        let audioPreparation = AudioImportConversionService()
        return NativeWhisperExecutionSnapshot(
            modelID: model.id,
            modelIsReady: {
                store.installStatus(for: model) == .ready
            },
            modelURL: {
                store.modelURL(for: model)
            },
            validateRunnerAndModel: { modelURL in
                try runtime.validateRunnerAndModel(modelURL: modelURL)
            },
            prepareAudio: { sourceURL in
                let prepared = try await audioPreparation
                    .prepareForNativeWhisper(sourceURL)
                return PreparedAudio(
                    fileURL: prepared.fileURL,
                    cleanup: { prepared.cleanup() }
                )
            },
            transcribe: { audioURL, modelURL, languageCode in
                try await runtime.transcribe(
                    audioURL: audioURL,
                    modelURL: modelURL,
                    languageCode: languageCode
                )
            }
        )
    }
}
