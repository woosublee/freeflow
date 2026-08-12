import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateDependenciesTests {
    static func main() throws {
        try verifiesStorageLayoutPreservesCanonicalPaths()
        try verifiesLiveDependenciesReturnFreshValues()
        print("AppStateDependenciesTests passed")
    }

    private static func verifiesStorageLayoutPreservesCanonicalPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-layout-contract", isDirectory: true)
        let layout = AppStateStorageLayout(rootDirectory: root)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.woosublee.quill"

        try expect(layout.audioDirectory == root.appendingPathComponent("audio", isDirectory: true),
                   "audio remains below the AppState root")
        try expect(layout.transcriptDirectory == root.appendingPathComponent("transcripts", isDirectory: true),
                   "transcripts remain below the AppState root")
        try expect(layout.historyStoreURL == root.appendingPathComponent("PipelineHistory.sqlite"),
                   "history keeps its existing file name")
        try expect(layout.cloudTranscriptionJobsDirectory == root
            .appendingPathComponent("cloud-transcription/jobs", isDirectory: true),
                   "cloud jobs keep their existing relative path")
        try expect(layout.cloudTranscriptionTemporaryDirectory == FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("cloud-transcription", isDirectory: true),
                   "cloud temporary files keep the bundle-scoped path")
    }

    private static func verifiesLiveDependenciesReturnFreshValues() throws {
        var first = AppStateDependencies.live
        let second = AppStateDependencies.live
        let overriddenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-overridden-layout", isDirectory: true)
        first.storageLayout = AppStateStorageLayout(rootDirectory: overriddenRoot)

        try expect(second.storageLayout.rootDirectory == AppName.applicationSupportDirectory,
                   "mutating one dependency value does not alter a later live value")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure(message) }
    }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
