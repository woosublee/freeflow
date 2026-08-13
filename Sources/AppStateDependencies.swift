import Foundation

struct AppStateStorageLayout: Sendable {
    let rootDirectory: URL

    var audioDirectory: URL {
        rootDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    var transcriptDirectory: URL {
        rootDirectory.appendingPathComponent("transcripts", isDirectory: true)
    }

    var historyStoreURL: URL {
        rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
    }

    var cloudTranscriptionJobsDirectory: URL {
        rootDirectory.appendingPathComponent(
            "cloud-transcription/jobs",
            isDirectory: true
        )
    }

    var cloudTranscriptionTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.woosublee.quill",
                isDirectory: true
            )
            .appendingPathComponent("cloud-transcription", isDirectory: true)
    }

    static var live: AppStateStorageLayout {
        AppStateStorageLayout(rootDirectory: AppName.applicationSupportDirectory)
    }
}

struct AppStateDependencies {
    var storageLayout: AppStateStorageLayout
    var makePipelineHistoryStore:
        @Sendable (URL) -> PipelineHistoryStore
    var makeMeetingSummaryGenerator:
        @MainActor (AppState) -> any MeetingSummaryGenerating
    var makeRetryCloudTranscriptionDependencies:
        @Sendable () -> CloudTranscriptionDependencies

    static var live: AppStateDependencies {
        AppStateDependencies(
            storageLayout: .live,
            makePipelineHistoryStore: { PipelineHistoryStore(storeURL: $0) },
            makeMeetingSummaryGenerator: { appState in
                appState.makeMeetingSummaryService()
            },
            makeRetryCloudTranscriptionDependencies: { .live }
        )
    }
}
