import Foundation

struct AppStateTestEnvironment {
    let rootDirectory: URL
    let storageLayout: AppStateStorageLayout
    let dependencies: AppStateDependencies
}

@MainActor
enum AppStateTestStorage {
    static func withIsolatedStorage<T>(
        _ operation: (AppStateTestEnvironment) async throws -> T
    ) async throws -> T {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let originalSettingsDirectory = AppSettingsStorage.storageDirectoryOverride
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let storageLayout = AppStateStorageLayout(rootDirectory: rootDirectory)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = storageLayout
        AppSettingsStorage.storageDirectoryOverride = rootDirectory
            .appendingPathComponent("settings", isDirectory: true)
        defer {
            AppSettingsStorage.storageDirectoryOverride = originalSettingsDirectory
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        return try await operation(
            AppStateTestEnvironment(
                rootDirectory: rootDirectory,
                storageLayout: storageLayout,
                dependencies: dependencies
            )
        )
    }
}
