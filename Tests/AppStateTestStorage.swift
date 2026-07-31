import Foundation

@MainActor
enum AppStateTestStorage {
    static func withIsolatedStorage<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let originalStorageRootProvider = AppState.storageRootProvider
        let originalHistoryStoreFactory = AppState.pipelineHistoryStoreFactory
        let originalSettingsDirectory = AppSettingsStorage.storageDirectoryOverride

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        AppState.storageRootProvider = { rootDirectory }
        AppState.pipelineHistoryStoreFactory = {
            AppState.makeDefaultPipelineHistoryStore()
        }
        AppSettingsStorage.storageDirectoryOverride = rootDirectory
            .appendingPathComponent("settings", isDirectory: true)
        defer {
            AppState.storageRootProvider = originalStorageRootProvider
            AppState.pipelineHistoryStoreFactory = originalHistoryStoreFactory
            AppSettingsStorage.storageDirectoryOverride = originalSettingsDirectory
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        return try await operation(rootDirectory)
    }
}
