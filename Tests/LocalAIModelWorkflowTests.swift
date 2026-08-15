import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct LocalAIModelWorkflowTests {
    @MainActor
    static func main() async throws {
        try testInitialInstallStateIsNotInstalled()
        try testCanonicalModelRejectsForgedModels()
        try testIsModelAvailableReflectsProcessingAvailability()
        try await testStartInstallSucceedsAndEmitsReadyOutcome()
        try await testInstallerSuccessWithoutReadyStatusEmitsUnavailableOutcome()
        try await testInstallerSuccessRechecksProcessingAvailability()
        try await testFailedInstallEmitsFailedOutcomeWithIssue()
        try await testCancelInstallClearsInstallingStateWithoutEmittingOutcome()
        try await testCancelThenRestartResumesAfterCancellationCompletes()
        try await testDeleteModelDuringInstallCancelsFirst()
        try await testDeleteModelWhenIdleGoesStraightToDeletion()
        try await testDeleteFailurePreservesReadyStatusAndSetsIssue()
        try await testRefreshAllInstallStatesCompletesAndEmitsDeferredIDs()
        try await testStaleStatusRefreshGenerationIsIgnored()
        try await testInstallRequestedBeforeRefreshCompletesIsDeferredThenReported()
        try testIdleShutdownMonitoringIsIdempotentAndStops()
        try await testWaitForInstallsToQuiesceResumesAfterCompletion()
        try testTerminationCleanupBlocksNewInstalls()
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
    private static func testInstallerSuccessWithoutReadyStatusEmitsUnavailableOutcome() async throws {
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
        harness.complete(model: model, with: .success(()))
        try await waitUntil { !workflow.installState(for: model).isInstalling }

        let issue = workflow.installState(for: model).issue
        try expectEqual(issue?.code, .localAIModelUnavailable, "success without ready status issue")
        try expect(
            events.contains {
                if case .installOutcome(
                    let outcomeModel,
                    .succeededButUnavailable(let outcomeIssue)
                ) = $0 {
                    return outcomeModel.id == model.id && outcomeIssue == issue
                }
                return false
            },
            "installOutcome(.succeededButUnavailable) fired for non-ready status"
        )
    }

    @MainActor
    private static func testInstallerSuccessRechecksProcessingAvailability() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .ready)
        let availability = LocalAIValueBox(supportedProcessingAvailability())
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(
                processingAvailability: { availability.value }
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.startInstall(model)
        availability.set(unsupportedProcessingAvailability())
        harness.complete(model: model, with: .success(()))
        try await waitUntil { !workflow.installState(for: model).isInstalling }

        let issue = workflow.installState(for: model).issue
        try expectEqual(issue?.code, .localAIModelUnavailable, "availability recheck issue")
        try expect(
            events.contains {
                if case .installOutcome(
                    let outcomeModel,
                    .succeededButUnavailable(let outcomeIssue)
                ) = $0 {
                    return outcomeModel.id == model.id && outcomeIssue == issue
                }
                return false
            },
            "installOutcome(.succeededButUnavailable) fired after availability changed"
        )
    }

    @MainActor
    private static func testFailedInstallEmitsFailedOutcomeWithIssue() async throws {
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
        harness.complete(model: model, with: .failure(.downloadFailed("offline")))
        try await waitUntil { !workflow.installState(for: model).isInstalling }

        let issue = workflow.installState(for: model).issue
        try expectEqual(issue?.code, .localAIModelUnavailable, "failed install issue")
        try expect(
            events.contains {
                if case .installOutcome(let outcomeModel, .failed(let outcomeIssue)) = $0 {
                    return outcomeModel.id == model.id && outcomeIssue == issue
                }
                return false
            },
            "installOutcome(.failed) fired with mirrored issue"
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
        let deletionHarness = LocalAIDeletionCallHarness()
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
                deleteModel: { deletionHarness.record(model: $0) },
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
        try await waitUntil { deletionHarness.wasCalled }
        try await waitUntil {
            events.contains { if case .deletionOutcome = $0 { return true }; return false }
        }
    }

    @MainActor
    private static func testDeleteFailurePreservesReadyStatusAndSetsIssue() async throws {
        let model = LocalAIModelCatalog.quality
        let workflow = LocalAIModelWorkflow(
            dependencies: dependencies(
                installStatus: { _ in .ready },
                deleteModel: { _ in throw LocalAIWorkflowTestError.deletionFailed }
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        var events: [LocalAIModelWorkflowEvent] = []
        workflow.onEvent = { events.append($0) }

        workflow.refreshAllInstallStates()
        await workflow.waitForInitialStatusRefresh()
        try expectEqual(workflow.installState(for: model).status, .ready, "status before delete")

        try expect(workflow.deleteModel(model), "delete accepted for ready model")
        try await waitUntil {
            events.contains {
                if case .deletionOutcome(let outcomeModel, let errorDescription) = $0 {
                    return outcomeModel.id == model.id && errorDescription != nil
                }
                return false
            }
        }

        let state = workflow.installState(for: model)
        try expectEqual(state.status, .ready, "failed delete preserves ready status")
        try expectEqual(state.issue?.code, .localAIModelUnavailable, "failed delete issue")
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
        let statusHarness = OverlappingLocalAIStatusHarness(blockedModelID: model.id)
        let workflow = LocalAIModelWorkflow(
            dependencies: dependencies(installStatus: { statusHarness.status(for: $0) }),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        defer { statusHarness.releaseFirstLookup() }

        workflow.refreshAllInstallStates()
        statusHarness.waitUntilFirstLookupStarts()

        workflow.refreshAllInstallStates()
        await workflow.waitForInitialStatusRefresh()
        try expectEqual(
            workflow.installState(for: model).status,
            .notInstalled,
            "newer refresh applies while stale lookup remains blocked"
        )

        statusHarness.releaseFirstLookup()
        await statusHarness.waitForStaleDeliveryToDrain()
        try expectEqual(
            workflow.installState(for: model).status,
            .notInstalled,
            "stale overlapping refresh cannot overwrite newer status"
        )
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
        deleteModel: @escaping @Sendable (LocalAIModel) throws -> Void = { _ in },
        processingAvailability: @escaping () -> LocalAIProcessingAvailability = supportedProcessingAvailability
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
            deleteModel: deleteModel,
            deletePartialModel: { _ in },
            processingAvailability: processingAvailability
        )
    }

    private static func supportedProcessingAvailability() -> LocalAIProcessingAvailability {
        LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 32 * 1024 * 1024 * 1024
        )
    }

    private static func unsupportedProcessingAvailability() -> LocalAIProcessingAvailability {
        LocalAIProcessingAvailability(isAppleSilicon: false, runnerIsExecutable: false)
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

    @MainActor
    private static func testIdleShutdownMonitoringIsIdempotentAndStops() throws {
        let workflow = makeWorkflow()
        workflow.startIdleShutdownMonitoring()
        workflow.startIdleShutdownMonitoring()
        workflow.stopIdleShutdownMonitoring()
        // No crash and no dangling task is the assertion here; a second
        // stop() call must also be a safe no-op.
        workflow.stopIdleShutdownMonitoring()
    }

    @MainActor
    private static func testWaitForInstallsToQuiesceResumesAfterCompletion() async throws {
        let model = LocalAIModelCatalog.quality
        let harness = ControlledLocalAIInstallHarness(finalStatus: .ready)
        let workflow = LocalAIModelWorkflow(
            dependencies: harness.dependencies(),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()
        workflow.startInstall(model)
        try expect(workflow.hasActiveInstalls, "install active")

        let quiesceTask = Task { await workflow.waitForInstallsToQuiesce() }
        try await Task.sleep(nanoseconds: 20_000_000)

        harness.complete(model: model, with: .success(()))
        await quiesceTask.value
        try expect(!workflow.hasActiveInstalls, "install no longer active")
    }

    @MainActor
    private static func testTerminationCleanupBlocksNewInstalls() throws {
        let model = LocalAIModelCatalog.quality
        var startCount = 0
        let workflow = LocalAIModelWorkflow(
            dependencies: AppStateLocalAIDependencies(
                makeServerManager: { LocalAIServerManager(store: LocalAIModelStore()) },
                idleShutdownSleep: { _ in try await Task.sleep(nanoseconds: UInt64.max) },
                installStatus: { _ in .notInstalled },
                startInstall: { _, _, completion in
                    startCount += 1
                    completion(.failure(.alreadyInProgress))
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
            ),
            serverManager: LocalAIServerManager(store: LocalAIModelStore())
        )
        workflow.markInitialRefreshCompletedForTesting()
        workflow.beginTerminationCleanup()
        workflow.startInstall(model)
        try expectEqual(startCount, 0, "no install starts after termination cleanup begins")
    }
}

private final class OverlappingLocalAIStatusHarness: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockedModelID: String
    private var hasStartedFirstLookup = false
    private var mayFinishFirstLookup = false
    private var staleDeliveryDidDrain = false
    private var staleDeliveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedModelID: String) {
        self.blockedModelID = blockedModelID
    }

    func status(for model: LocalAIModel) -> LocalAIInstallStatus {
        condition.lock()
        guard model.id == blockedModelID, !hasStartedFirstLookup else {
            condition.unlock()
            return .notInstalled
        }
        hasStartedFirstLookup = true
        condition.broadcast()
        while !mayFinishFirstLookup {
            condition.wait()
        }
        condition.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [self] in
                self.markStaleDeliveryDrained()
            }
        }
        return .ready
    }

    func waitUntilFirstLookupStarts() {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !hasStartedFirstLookup {
            precondition(
                condition.wait(until: deadline),
                "first status lookup did not enter the controlled overlap"
            )
        }
    }

    func releaseFirstLookup() {
        condition.lock()
        guard !mayFinishFirstLookup else {
            condition.unlock()
            return
        }
        mayFinishFirstLookup = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForStaleDeliveryToDrain() async {
        if withConditionLock({ staleDeliveryDidDrain }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = withConditionLock { () -> Bool in
                if staleDeliveryDidDrain { return true }
                staleDeliveryWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    private func markStaleDeliveryDrained() {
        let waiters = withConditionLock { () -> [CheckedContinuation<Void, Never>] in
            staleDeliveryDidDrain = true
            let waiters = staleDeliveryWaiters
            staleDeliveryWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func withConditionLock<Value>(_ body: () -> Value) -> Value {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}

private final class LocalAIDeletionCallHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var calledModelIDs: [String] = []

    var wasCalled: Bool {
        lock.withLock { !calledModelIDs.isEmpty }
    }

    func record(model: LocalAIModel) {
        lock.withLock { calledModelIDs.append(model.id) }
    }
}

private final class LocalAIValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}

private final class ControlledLocalAIInstallHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [String: (Result<Void, LocalAIInstallerError>) -> Void] = [:]
    private let finalStatus: LocalAIInstallStatus

    init(finalStatus: LocalAIInstallStatus) {
        self.finalStatus = finalStatus
    }

    func dependencies(
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
            installStatus: { [weak self] _ in self?.finalStatus ?? .notInstalled },
            startInstall: { [weak self] model, _, completion in
                self?.lock.withLock { self?.completions[model.id] = completion }
                return LocalAIInstallTask()
            },
            progressSchedule: { _, operation in operation() },
            deleteModel: { _ in },
            deletePartialModel: { _ in },
            processingAvailability: processingAvailability
        )
    }

    func complete(model: LocalAIModel, with result: Result<Void, LocalAIInstallerError>) {
        let completion = lock.withLock { completions[model.id] }
        completion?(result)
    }
}

private enum LocalAIWorkflowTestError: LocalizedError {
    case deletionFailed

    var errorDescription: String? {
        "deletion failed"
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
