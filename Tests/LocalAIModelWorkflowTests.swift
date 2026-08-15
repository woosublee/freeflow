import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct LocalAIModelWorkflowTests {
    static func main() async throws {
        try testInitialInstallStateIsNotInstalled()
        try testCanonicalModelRejectsForgedModels()
        try testIsModelAvailableReflectsProcessingAvailability()
        try await testStartInstallSucceedsAndEmitsReadyOutcome()
        try await testCancelInstallClearsInstallingStateWithoutEmittingOutcome()
        try await testCancelThenRestartResumesAfterCancellationCompletes()
        try await testDeleteModelDuringInstallCancelsFirst()
        try await testDeleteModelWhenIdleGoesStraightToDeletion()
        try await testRefreshAllInstallStatesCompletesAndEmitsDeferredIDs()
        try await testStaleStatusRefreshGenerationIsIgnored()
        try await testInstallRequestedBeforeRefreshCompletesIsDeferredThenReported()
        print("LocalAIModelWorkflowTests passed")
    }

    @MainActor
    private static func testInitialInstallStateIsNotInstalled() throws {
        let workflow = makeWorkflow()
        let model = LocalAIModelCatalog.quality
        try expectEqual(
            workflow.installState(for: model).status,
            .notInstalled,
            "initial install state"
        )
    }

    @MainActor
    private static func testCanonicalModelRejectsForgedModels() throws {
        let workflow = makeWorkflow()
        let real = LocalAIModelCatalog.quality
        try expect(workflow.canonicalModel(for: real) == real, "genuine catalog model is canonical")

        let forged = LocalAIModel(
            id: real.id,
            displayName: "Forged Model",
            description: real.description,
            artifacts: real.artifacts,
            approximateResidentRAMBytes: real.approximateResidentRAMBytes,
            minimumPhysicalMemoryBytes: real.minimumPhysicalMemoryBytes,
            capabilities: real.capabilities,
            runtime: real.runtime
        )
        try expect(workflow.canonicalModel(for: forged) == nil, "forged model with same id is rejected")
    }

    @MainActor
    private static func testIsModelAvailableReflectsProcessingAvailability() throws {
        let model = LocalAIModelCatalog.quality
        let unsupportedWorkflow = LocalAIModelWorkflow(
            dependencies: dependencies(
                processingAvailability: {
                    LocalAIProcessingAvailability(isAppleSilicon: false, runnerIsExecutable: false)
                }
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        try expect(!unsupportedWorkflow.isModelAvailable(model), "unsupported hardware is unavailable")

        let supportedWorkflow = LocalAIModelWorkflow(
            dependencies: dependencies(
                processingAvailability: {
                    LocalAIProcessingAvailability(
                        isAppleSilicon: true,
                        runnerIsExecutable: true,
                        physicalMemory: 32 * 1024 * 1024 * 1024
                    )
                }
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        try expect(supportedWorkflow.isModelAvailable(model), "supported hardware is available")
    }

    @MainActor
    private static func testStartInstallSucceedsAndEmitsReadyOutcome() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .ready)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall(model)
        try expect(workflow.installState(for: model).isInstalling, "installing after start")

        harness.complete(model: model, with: .success(()))
        try await waitUntil { !workflow.installState(for: model).isInstalling }

        try expect(
            events.contains {
                if case .installOutcome(let outcomeModel, .readyAndAvailable) = $0 {
                    return outcomeModel.id == model.id
                }
                return false
            },
            "installOutcome(.readyAndAvailable) fired"
        )
    }

    @MainActor
    private static func testCancelInstallClearsInstallingStateWithoutEmittingOutcome() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .notInstalled)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall(model)
        try expect(workflow.cancelInstall(model), "cancel reports it found an active task")
        try expect(workflow.installState(for: model).progress.isCancelled, "progress marked cancelled")

        harness.complete(model: model, with: .failure(.cancelled))
        try await waitUntil { !workflow.installState(for: model).isInstalling }

        try expect(!workflow.installState(for: model).isInstalling, "isInstalling cleared after cancellation")
        try expect(workflow.installState(for: model).issue == nil, "issue cleared after cancellation")
        try expect(workflow.installState(for: model).progress.isCancelled, "progress still marked cancelled after completion")
        try expect(
            !events.contains {
                if case .installOutcome(_, .cancelled) = $0 { return true }
                return false
            },
            "tracked cancellation completion does not emit an installOutcome(.cancelled) event"
        )
    }

    @MainActor
    private static func testCancelThenRestartResumesAfterCancellationCompletes() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .notInstalled)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()

        workflow.startInstall(model)
        workflow.cancelInstall(model)
        // A second startInstall while cancellation is still in flight requests
        // a restart once the cancelled attempt finishes.
        workflow.startInstall(model)

        harness.complete(model: model, with: .failure(.cancelled))
        try await waitUntil { workflow.installState(for: model).isInstalling }
        try expect(workflow.installState(for: model).isInstalling, "restarted install is in flight")
    }

    @MainActor
    private static func testDeleteModelDuringInstallCancelsFirst() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .notInstalled)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()

        workflow.startInstall(model)
        try expect(workflow.deleteModel(model), "delete accepted during install")
        try expect(workflow.installState(for: model).progress.isCancelled, "install marked cancelled by delete")
    }

    @MainActor
    private static func testDeleteModelWhenIdleGoesStraightToDeletion() async throws {
        let model = LocalAIModelCatalog.quality
        var deleteCalled = false
        let workflow = LocalAIModelWorkflow(
            dependencies: AppStateLocalAIDependencies(
                makeServerManager: { LocalAIServerManager(store: LocalAIModelStore()) },
                idleShutdownSleep: { _ in try await Task.sleep(nanoseconds: UInt64.max) },
                installStatus: { _ in .notInstalled },
                startInstall: { _, _, completion in
                    completion(.failure(.alreadyInProgress))
                    return LocalAIInstallTask()
                },
                progressSchedule: { _, operation in operation() },
                deleteModel: { _ in deleteCalled = true },
                deletePartialModel: { _ in },
                processingAvailability: {
                    LocalAIProcessingAvailability(
                        isAppleSilicon: true,
                        runnerIsExecutable: true,
                        physicalMemory: 32 * 1024 * 1024 * 1024
                    )
                }
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        try expect(workflow.deleteModel(model), "delete accepted when idle")
        try await waitUntil { deleteCalled }
        try await waitUntil {
            events.contains { if case .deletionOutcome = $0 { return true }; return false }
        }
    }

    @MainActor
    private static func testRefreshAllInstallStatesCompletesAndEmitsDeferredIDs() async throws {
        let workflow = LocalAIModelWorkflow(
            dependencies: dependencies(installStatus: { _ in .notInstalled }),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.refreshAllInstallStates()
        try await waitUntil { workflow.state.hasCompletedInitialStatusRefresh }

        try expect(
            events.contains {
                if case .initialStatusRefreshCompleted = $0 { return true }
                return false
            },
            "initialStatusRefreshCompleted fired"
        )
    }

    @MainActor
    private static func testStaleStatusRefreshGenerationIsIgnored() async throws {
        let model = LocalAIModelCatalog.quality
        let statusBox = LocalAIStatusBox(.notInstalled)
        let workflow = LocalAIModelWorkflow(
            dependencies: dependencies(installStatus: { statusBox.status(for: $0) }),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.refreshAllInstallStates()
        try await waitUntil { workflow.state.hasCompletedInitialStatusRefresh }

        // A second refresh bumps the generation; only its result should apply.
        statusBox.set(.ready, for: model)
        workflow.refreshAllInstallStates()
        try await waitUntil { workflow.state.hasCompletedInitialStatusRefresh }
        try expectEqual(workflow.installState(for: model).status, .ready, "latest refresh wins")
    }

    @MainActor
    private static func testInstallRequestedBeforeRefreshCompletesIsDeferredThenReported() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .notInstalled)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        var deferredModelIDsSeen: Set<String>?
        workflow.onEvent = { event in
            if case .initialStatusRefreshCompleted(let deferredModelIDs) = event {
                deferredModelIDsSeen = deferredModelIDs
            }
        }

        workflow.startInstall(model)
        try expect(!workflow.installState(for: model).isInstalling, "install deferred before refresh")

        workflow.refreshAllInstallStates()
        try await waitUntil { workflow.state.hasCompletedInitialStatusRefresh }

        try expect(
            deferredModelIDsSeen?.contains(model.id) == true,
            "deferred model ID reported in initialStatusRefreshCompleted event"
        )
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

    @MainActor
    private static func makeWorkflow() -> LocalAIModelWorkflow {
        LocalAIModelWorkflow(
            dependencies: dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
    }

    private static func dependencies(
        installStatus: @escaping @Sendable (LocalAIModel) -> LocalAIInstallStatus = { _ in .notInstalled },
        processingAvailability: @escaping () -> LocalAIProcessingAvailability = {
            LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 32 * 1024 * 1024 * 1024
            )
        }
    ) -> AppStateLocalAIDependencies {
        AppStateLocalAIDependencies(
            makeServerManager: { LocalAIServerManager(store: LocalAIModelStore()) },
            idleShutdownSleep: { _ in try await Task.sleep(nanoseconds: UInt64.max) },
            installStatus: installStatus,
            startInstall: { _, _, completion in
                completion(.failure(.alreadyInProgress))
                return LocalAIInstallTask()
            },
            progressSchedule: { _, operation in operation() },
            deleteModel: { _ in },
            deletePartialModel: { _ in },
            processingAvailability: processingAvailability
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

private final class LocalAIStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [String: LocalAIInstallStatus] = [:]
    private let defaultStatus: LocalAIInstallStatus

    init(_ defaultStatus: LocalAIInstallStatus) {
        self.defaultStatus = defaultStatus
    }

    func status(for model: LocalAIModel) -> LocalAIInstallStatus {
        lock.withLock { overrides[model.id] ?? defaultStatus }
    }

    func set(_ status: LocalAIInstallStatus, for model: LocalAIModel) {
        lock.withLock { overrides[model.id] = status }
    }
}

private final class ControlledLocalAIInstallHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [String: (Result<Void, LocalAIInstallerError>) -> Void] = [:]
    private let finalStatus: LocalAIInstallStatus

    init(finalStatus: LocalAIInstallStatus) {
        self.finalStatus = finalStatus
    }

    func dependencies() -> AppStateLocalAIDependencies {
        AppStateLocalAIDependencies(
            makeServerManager: { LocalAIServerManager(store: LocalAIModelStore()) },
            idleShutdownSleep: { _ in try await Task.sleep(nanoseconds: UInt64.max) },
            installStatus: { [weak self] _ in self?.finalStatus ?? .notInstalled },
            startInstall: { [weak self] model, _, completion in
                self?.lock.withLock { self?.completions[model.id] = completion }
                return LocalAIInstallTask()
            },
            progressSchedule: { _, operation in operation() },
            deleteModel: { _ in },
            deletePartialModel: { _ in },
            processingAvailability: {
                LocalAIProcessingAvailability(
                    isAppleSilicon: true,
                    runnerIsExecutable: true,
                    physicalMemory: 32 * 1024 * 1024 * 1024
                )
            }
        )
    }

    func complete(model: LocalAIModel, with result: Result<Void, LocalAIInstallerError>) {
        let completion = lock.withLock { completions[model.id] }
        completion?(result)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
