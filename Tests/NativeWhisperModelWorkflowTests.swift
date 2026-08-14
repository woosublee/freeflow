import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct NativeWhisperModelWorkflowTests {
    @MainActor
    static func main() async throws {
        try testInitialStateIsNotInstalled()
        try testRefreshInstallStatusUpdatesStateAndEmitsEvent()
        try await testStartInstallEmitsProgressAndSucceeds()
        try await testCancelInstallEmitsCancelledOutcome()
        try await testFailedInstallEmitsFailedOutcomeWithIssue()
        try testDeleteModelSuccessClearsIssueAndRefreshesStatus()
        try testDeleteModelFailureSetsIssue()
        try await testWaitUntilQuiescedResumesAfterCompletion()
        try testTerminationCleanupBlocksNewInstalls()
        print("NativeWhisperModelWorkflowTests passed")
    }

    @MainActor
    private static func testInitialStateIsNotInstalled() throws {
        let workflow = NativeWhisperModelWorkflow(
            dependencies: fixedStatusDependencies(.notInstalled)
        )
        try expectEqual(workflow.state.installStatus, .notInstalled, "initial status")
        try expect(!workflow.state.isInstalling, "initial not installing")
        try expectEqual(workflow.state.installProgress.downloadedBytes, 0, "initial progress")
    }

    @MainActor
    private static func testRefreshInstallStatusUpdatesStateAndEmitsEvent() throws {
        let workflow = NativeWhisperModelWorkflow(
            dependencies: fixedStatusDependencies(.ready)
        )
        var events: [NativeWhisperModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.refreshInstallStatus()

        try expectEqual(workflow.state.installStatus, .ready, "refreshed status")
        guard case .stateChanged(let state)? = events.first else {
            throw TestFailure("expected a stateChanged event")
        }
        try expectEqual(state.installStatus, .ready, "event status")
    }

    @MainActor
    private static func testStartInstallEmitsProgressAndSucceeds() async throws {
        let harness = ControlledInstallHarness()
        let workflow = NativeWhisperModelWorkflow(
            dependencies: harness.dependencies(finalStatus: .ready)
        )
        var events: [NativeWhisperModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall()
        try expect(workflow.state.isInstalling, "installing after start")

        harness.reportProgress(
            NativeWhisperDownloadProgress(downloadedBytes: 10, totalBytes: 100)
        )
        try await waitUntil { workflow.state.installProgress.downloadedBytes == 10 }

        harness.complete(.success(()))
        try await waitUntil { !workflow.state.isInstalling }

        try expectEqual(workflow.state.installStatus, .ready, "final status")
        try expect(
            events.contains { event in
                if case .installCompleted(.succeeded) = event { return true }
                return false
            },
            "installCompleted(.succeeded) event fired"
        )
    }

    @MainActor
    private static func testCancelInstallEmitsCancelledOutcome() async throws {
        let harness = ControlledInstallHarness()
        let workflow = NativeWhisperModelWorkflow(
            dependencies: harness.dependencies(finalStatus: .notInstalled)
        )
        var events: [NativeWhisperModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall()
        workflow.cancelInstall()
        try expect(workflow.state.installProgress.isCancelled, "progress marked cancelled")

        harness.complete(.failure(.cancelled))
        try await waitUntil { !workflow.state.isInstalling }

        try expect(
            events.contains { if case .installCompleted(.cancelled) = $0 { return true }; return false },
            "installCompleted(.cancelled) event fired"
        )
    }

    @MainActor
    private static func testFailedInstallEmitsFailedOutcomeWithIssue() async throws {
        let harness = ControlledInstallHarness()
        let workflow = NativeWhisperModelWorkflow(
            dependencies: harness.dependencies(finalStatus: .notInstalled)
        )
        var events: [NativeWhisperModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall()
        harness.complete(.failure(.downloadFailed("offline")))
        try await waitUntil { !workflow.state.isInstalling }

        try expectEqual(
            workflow.state.installIssue?.code,
            .localModelMissing,
            "failed install sets localModelMissing issue"
        )
        try expect(
            events.contains {
                if case .installCompleted(.failed(let issue)) = $0 {
                    return issue.code == .localModelMissing
                }
                return false
            },
            "installCompleted(.failed) event fired with matching issue"
        )
    }

    @MainActor
    private static func testDeleteModelSuccessClearsIssueAndRefreshesStatus() throws {
        final class DeleteTracker {
            var called = false
        }
        let tracker = DeleteTracker()
        let workflow = NativeWhisperModelWorkflow(
            dependencies: AppStateNativeWhisperDependencies(
                installStatus: { _ in .notInstalled },
                startInstall: { _, _, completion in
                    completion(.failure(.alreadyInProgress))
                    return NativeWhisperInstallTask()
                },
                progressSchedule: { _, operation in operation() },
                deleteModel: { _ in tracker.called = true },
                makeExecutionSnapshot: { .live(store: NativeWhisperModelStore()) }
            )
        )
        workflow.deleteModel()
        try expect(tracker.called, "delete was invoked")
        try expect(workflow.state.installIssue == nil, "issue cleared on success")
    }

    @MainActor
    private static func testDeleteModelFailureSetsIssue() throws {
        struct DeleteFailure: Error {}
        let workflow = NativeWhisperModelWorkflow(
            dependencies: AppStateNativeWhisperDependencies(
                installStatus: { _ in .notInstalled },
                startInstall: { _, _, completion in
                    completion(.failure(.alreadyInProgress))
                    return NativeWhisperInstallTask()
                },
                progressSchedule: { _, operation in operation() },
                deleteModel: { _ in throw DeleteFailure() },
                makeExecutionSnapshot: { .live(store: NativeWhisperModelStore()) }
            )
        )
        workflow.deleteModel()
        try expectEqual(
            workflow.state.installIssue?.code,
            .localModelMissing,
            "delete failure sets localModelMissing issue"
        )
    }

    @MainActor
    private static func testWaitUntilQuiescedResumesAfterCompletion() async throws {
        let harness = ControlledInstallHarness()
        let workflow = NativeWhisperModelWorkflow(
            dependencies: harness.dependencies(finalStatus: .ready)
        )
        workflow.startInstall()

        let quiesceTask = Task { await workflow.waitUntilQuiesced() }
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(!quiesceTask.isCancelled, "quiesce task still waiting")

        harness.complete(.success(()))
        await quiesceTask.value
    }

    @MainActor
    private static func testTerminationCleanupBlocksNewInstalls() throws {
        var startCount = 0
        let workflow = NativeWhisperModelWorkflow(
            dependencies: AppStateNativeWhisperDependencies(
                installStatus: { _ in .notInstalled },
                startInstall: { _, _, completion in
                    startCount += 1
                    completion(.failure(.alreadyInProgress))
                    return NativeWhisperInstallTask()
                },
                progressSchedule: { _, operation in operation() },
                deleteModel: { _ in },
                makeExecutionSnapshot: { .live(store: NativeWhisperModelStore()) }
            )
        )
        workflow.beginTerminationCleanup()
        workflow.startInstall()
        try expectEqual(startCount, 0, "no install starts after termination cleanup begins")
    }

    @MainActor
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TestFailure("timed out waiting for condition")
    }

    private static func fixedStatusDependencies(
        _ status: NativeWhisperInstallStatus
    ) -> AppStateNativeWhisperDependencies {
        AppStateNativeWhisperDependencies(
            installStatus: { _ in status },
            startInstall: { _, _, completion in
                completion(.failure(.alreadyInProgress))
                return NativeWhisperInstallTask()
            },
            progressSchedule: { _, operation in operation() },
            deleteModel: { _ in },
            makeExecutionSnapshot: {
                .live(store: NativeWhisperModelStore())
            }
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private final class ControlledInstallHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var progressCallback: ((NativeWhisperDownloadProgress) -> Void)?
    private var completionCallback: ((Result<Void, NativeWhisperInstallerError>) -> Void)?
    private var finalStatus: NativeWhisperInstallStatus = .notInstalled

    func dependencies(
        finalStatus: NativeWhisperInstallStatus
    ) -> AppStateNativeWhisperDependencies {
        self.finalStatus = finalStatus
        return AppStateNativeWhisperDependencies(
            installStatus: { [weak self] _ in self?.finalStatus ?? .notInstalled },
            startInstall: { [weak self] _, progress, completion in
                self?.lock.withLock {
                    self?.progressCallback = progress
                    self?.completionCallback = completion
                }
                return NativeWhisperInstallTask()
            },
            progressSchedule: { _, operation in operation() },
            deleteModel: { _ in },
            makeExecutionSnapshot: {
                .live(store: NativeWhisperModelStore())
            }
        )
    }

    func reportProgress(_ progress: NativeWhisperDownloadProgress) {
        let callback = lock.withLock { progressCallback }
        callback?(progress)
    }

    func complete(_ result: Result<Void, NativeWhisperInstallerError>) {
        let callback = lock.withLock { completionCallback }
        callback?(result)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
