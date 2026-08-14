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
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let storageLayout = AppStateStorageLayout(rootDirectory: rootDirectory)
        let settingsDirectory = rootDirectory.appendingPathComponent("settings", isDirectory: true)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = storageLayout
        dependencies.credentialStorageLayout = CredentialStorageLayout(directory: settingsDirectory)
        defer {
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
