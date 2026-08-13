import Foundation

private final class LiveNativeWhisperExecutionEnvironment: @unchecked Sendable {
    let store: NativeWhisperModelStore
    let runtime: NativeWhisperRuntime
    let audioPreparation: AudioImportConversionService

    init(
        store: NativeWhisperModelStore,
        runtime: NativeWhisperRuntime,
        audioPreparation: AudioImportConversionService
    ) {
        self.store = store
        self.runtime = runtime
        self.audioPreparation = audioPreparation
    }
}

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
        let environment = LiveNativeWhisperExecutionEnvironment(
            store: store,
            runtime: NativeWhisperRuntime(),
            audioPreparation: AudioImportConversionService()
        )
        return NativeWhisperExecutionSnapshot(
            modelID: model.id,
            modelIsReady: {
                environment.store.installStatus(for: model) == .ready
            },
            modelURL: {
                environment.store.modelURL(for: model)
            },
            validateRunnerAndModel: { modelURL in
                try environment.runtime.validateRunnerAndModel(modelURL: modelURL)
            },
            prepareAudio: { sourceURL in
                let prepared = try await environment.audioPreparation
                    .prepareForNativeWhisper(sourceURL)
                return PreparedAudio(
                    fileURL: prepared.fileURL,
                    cleanup: { prepared.cleanup() }
                )
            },
            transcribe: { audioURL, modelURL, languageCode in
                try await environment.runtime.transcribe(
                    audioURL: audioURL,
                    modelURL: modelURL,
                    languageCode: languageCode
                )
            }
        )
    }
}
