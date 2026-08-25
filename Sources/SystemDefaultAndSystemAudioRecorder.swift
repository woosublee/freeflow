import Combine
import Foundation
import os

enum DegradedCombinedCaptureSource: Equatable {
    case microphone
    case systemAudio
}

struct CombinedRecordingStartResult: Equatable {
    let microphoneStarted: Bool
    let systemAudioStarted: Bool
    let microphoneUsedSystemDefaultFallback: Bool

    /// Which source is missing when exactly one side of a combined start
    /// failed, or nil when both started (startRecording throws instead of
    /// returning a result when neither did).
    var missingSource: DegradedCombinedCaptureSource? {
        if !microphoneStarted { return .microphone }
        if !systemAudioStarted { return .systemAudio }
        return nil
    }
}

struct CombinedRecordingStartOperations {
    let startMicrophone: (String) throws -> AudioRecorderStartResult
    let startSystemAudio: () async throws -> Void
    let cancelMicrophone: () async -> Void
    let cancelSystemAudio: () async -> Void

    init(
        startMicrophone: @escaping (String) throws -> AudioRecorderStartResult,
        startSystemAudio: @escaping () async throws -> Void,
        cancelMicrophone: @escaping () async -> Void = {},
        cancelSystemAudio: @escaping () async -> Void = {}
    ) {
        self.startMicrophone = startMicrophone
        self.startSystemAudio = startSystemAudio
        self.cancelMicrophone = cancelMicrophone
        self.cancelSystemAudio = cancelSystemAudio
    }
}

struct CombinedStoppedRecordingSources: Equatable {
    let microphoneURL: URL?
    let systemAudioURL: URL?
}

final class SystemDefaultAndSystemAudioRecorder: ObservableObject {
    let microphoneRecorder: AudioRecorder
    let systemAudioRecorder: SystemAudioRecorder
    let mixdownService: AudioMixdownService
    private let startOperations: CombinedRecordingStartOperations

    @Published var audioLevel: Float = 0.0

    var currentMissingSource: DegradedCombinedCaptureSource? {
        stateLock.withLock { state in
            let microphoneActive = state.activeSources.contains(.microphone)
                && !state.failedSources.contains(.microphone)
            let systemAudioActive = state.activeSources.contains(.systemAudio)
                && !state.failedSources.contains(.systemAudio)
            if microphoneActive == systemAudioActive { return nil }
            return microphoneActive ? .systemAudio : .microphone
        }
    }

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    var onRecordingDegraded: ((DegradedCombinedCaptureSource) -> Void)?

    /// Manual QA hooks: force one side of the next combined start to fail
    /// without touching real hardware/permissions, so the degraded-capture
    /// notice can be exercised on demand. Each flag resets itself after the
    /// attempt it triggers.
    var debugForcesMicrophoneStartFailure = false
    var debugForcesSystemAudioStartFailure = false

    private enum RecordingSource: Hashable {
        case microphone
        case systemAudio

        var degradedSource: DegradedCombinedCaptureSource {
            switch self {
            case .microphone: .microphone
            case .systemAudio: .systemAudio
            }
        }
    }

    private enum SourceFailureEffect {
        case none
        case degraded(DegradedCombinedCaptureSource)
        case overallFailure
    }

    private enum MicrophoneStartAttempt {
        case started(AudioRecorderStartResult)
        case failed(Error)
        case cancelled
    }

    private enum SystemAudioStartAttempt {
        case started
        case failed(Error)
        case cancelled
    }

    private struct RecordingState {
        var startID: UUID?
        var startInProgress = false
        var startCompletionGroup: DispatchGroup?
        var microphoneStarted = false
        var systemStarted = false
        var readyFired = false
        var readySources: Set<RecordingSource> = []
        var activeSources: Set<RecordingSource> = []
        var failedSources: Set<RecordingSource> = []
        var failuresDuringStart: [Error] = []
        var overallFailureReported = false

        mutating func admitStartedSource(_ source: RecordingSource) {
            switch source {
            case .microphone:
                microphoneStarted = true
            case .systemAudio:
                systemStarted = true
            }
            activeSources.insert(source)
        }

        mutating func consumeReadyIfPossible() -> Bool {
            guard !readyFired,
                  activeSources.contains(where: {
                      readySources.contains($0)
                          && !failedSources.contains($0)
                  }) else {
                return false
            }
            readyFired = true
            return true
        }

        mutating func resetForStart(
            startID: UUID,
            startCompletionGroup: DispatchGroup
        ) {
            self.startID = startID
            startInProgress = true
            self.startCompletionGroup = startCompletionGroup
            microphoneStarted = false
            systemStarted = false
            readyFired = false
            readySources = []
            activeSources = []
            failedSources = []
            failuresDuringStart = []
            overallFailureReported = false
        }

        mutating func resetIdle() {
            startID = nil
            startInProgress = false
            startCompletionGroup = nil
            microphoneStarted = false
            systemStarted = false
            readyFired = false
            readySources = []
            activeSources = []
            failedSources = []
            failuresDuringStart = []
            overallFailureReported = false
        }
    }

    private struct StoppedRecordingURLs {
        var microphoneURL: URL?
        var systemAudioURL: URL?
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: RecordingState())
    private var cancellables: Set<AnyCancellable> = []

    convenience init(microphoneRecorder: AudioRecorder, systemAudioRecorder: SystemAudioRecorder, mixdownService: AudioMixdownService = AudioMixdownService()) {
        self.init(
            microphoneRecorder: microphoneRecorder,
            systemAudioRecorder: systemAudioRecorder,
            mixdownService: mixdownService,
            startOperations: CombinedRecordingStartOperations(
                startMicrophone: { deviceUID in
                    try microphoneRecorder.startRecording(deviceUID: deviceUID)
                },
                startSystemAudio: {
                    try await systemAudioRecorder.startRecording()
                },
                cancelMicrophone: {
                    await withCheckedContinuation { continuation in
                        microphoneRecorder.cancelRecording {
                            continuation.resume()
                        }
                    }
                },
                cancelSystemAudio: {
                    await withCheckedContinuation { continuation in
                        systemAudioRecorder.cancelRecording {
                            continuation.resume()
                        }
                    }
                }
            )
        )
    }

    init(
        microphoneRecorder: AudioRecorder,
        systemAudioRecorder: SystemAudioRecorder,
        mixdownService: AudioMixdownService,
        startOperations: CombinedRecordingStartOperations
    ) {
        self.microphoneRecorder = microphoneRecorder
        self.systemAudioRecorder = systemAudioRecorder
        self.mixdownService = mixdownService
        self.startOperations = startOperations
        subscribeToAudioLevelsIfNeeded()
    }

    func startRecording(microphoneDeviceUID: String) async throws -> CombinedRecordingStartResult {
        let startID = UUID()
        let startCompletionGroup = DispatchGroup()
        startCompletionGroup.enter()
        defer { startCompletionGroup.leave() }
        stateLock.withLock { state in
            state.resetForStart(
                startID: startID,
                startCompletionGroup: startCompletionGroup
            )
        }
        configureChildCallbacks(startID: startID)
        subscribeToAudioLevelsIfNeeded()

        let forceMicrophoneFailure = debugForcesMicrophoneStartFailure
        let forceSystemAudioFailure = debugForcesSystemAudioStartFailure
        debugForcesMicrophoneStartFailure = false
        debugForcesSystemAudioStartFailure = false

        async let microphoneAttempt = attemptMicrophoneStart(
            microphoneDeviceUID: microphoneDeviceUID,
            startID: startID,
            forceFailure: forceMicrophoneFailure
        )
        async let systemAudioAttempt = attemptSystemAudioStart(
            startID: startID,
            forceFailure: forceSystemAudioFailure
        )
        let (microphoneOutcome, systemAudioOutcome) = await (
            microphoneAttempt,
            systemAudioAttempt
        )

        let startWasCancelled: Bool
        switch (microphoneOutcome, systemAudioOutcome) {
        case (.cancelled, _), (_, .cancelled):
            startWasCancelled = true
        default:
            startWasCancelled = false
        }
        if startWasCancelled {
            let shouldRollbackStartedSources = stateLock.withLock { state -> Bool in
                guard state.startID == startID else { return false }
                state.resetIdle()
                return true
            }
            if shouldRollbackStartedSources {
                if case .started = microphoneOutcome {
                    await startOperations.cancelMicrophone()
                }
                if case .started = systemAudioOutcome {
                    await startOperations.cancelSystemAudio()
                }
            }
            throw CancellationError()
        }

        var startErrors: [Error] = []
        var microphoneUsedSystemDefaultFallback = false
        if case .started(let result) = microphoneOutcome {
            microphoneUsedSystemDefaultFallback = result.usedSystemDefaultFallback
        } else if case .failed(let error) = microphoneOutcome {
            startErrors.append(error)
        }
        if case .failed(let error) = systemAudioOutcome {
            startErrors.append(error)
        }

        guard let (microphoneStarted, systemStarted, failuresDuringStart) = stateLock.withLock({ state -> (Bool, Bool, [Error])? in
            guard state.startID == startID else { return nil }
            state.startInProgress = false
            state.microphoneStarted = state.microphoneStarted
                && !state.failedSources.contains(.microphone)
            state.systemStarted = state.systemStarted
                && !state.failedSources.contains(.systemAudio)
            state.activeSources = []
            if state.microphoneStarted {
                state.activeSources.insert(.microphone)
            }
            if state.systemStarted {
                state.activeSources.insert(.systemAudio)
            }
            return (
                state.microphoneStarted,
                state.systemStarted,
                state.failuresDuringStart
            )
        }) else {
            throw CancellationError()
        }
        guard microphoneStarted || systemStarted else {
            throw SystemDefaultAndSystemAudioRecorderError.failedToStartAnyRecorder(
                startErrors + failuresDuringStart
            )
        }
        return CombinedRecordingStartResult(
            microphoneStarted: microphoneStarted,
            systemAudioStarted: systemStarted,
            microphoneUsedSystemDefaultFallback: microphoneUsedSystemDefaultFallback
        )
    }

    private func acceptStartedSource(
        _ source: RecordingSource,
        startID: UUID
    ) -> Bool {
        let (accepted, shouldFireReady) = stateLock.withLock { state in
            guard state.startID == startID else { return (false, false) }
            state.admitStartedSource(source)
            return (true, state.consumeReadyIfPossible())
        }
        if shouldFireReady {
            onRecordingReady?()
        }
        return accepted
    }

    private func attemptMicrophoneStart(
        microphoneDeviceUID: String,
        startID: UUID,
        forceFailure: Bool
    ) async -> MicrophoneStartAttempt {
        do {
            if forceFailure {
                throw SystemDefaultAndSystemAudioRecorderError.debugSimulatedStartFailure
            }
            let result = try startOperations.startMicrophone(microphoneDeviceUID)
            guard acceptStartedSource(.microphone, startID: startID) else {
                await startOperations.cancelMicrophone()
                return .cancelled
            }
            return .started(result)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    private func attemptSystemAudioStart(
        startID: UUID,
        forceFailure: Bool
    ) async -> SystemAudioStartAttempt {
        do {
            if forceFailure {
                throw SystemDefaultAndSystemAudioRecorderError.debugSimulatedStartFailure
            }
            try await startOperations.startSystemAudio()
            guard acceptStartedSource(.systemAudio, startID: startID) else {
                await startOperations.cancelSystemAudio()
                return .cancelled
            }
            return .started
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        stopRecordingSources { sources in
            self.temporaryCombinedFallback(
                sources,
                completion: completion
            )
        }
    }

    func stopRecordingSources(
        completion: @escaping (CombinedStoppedRecordingSources) -> Void
    ) {
        let (
            shouldStopMicrophone,
            shouldStopSystemAudio,
            startCompletionGroup
        ) = stateLock.withLock { state in
            let result = (
                state.microphoneStarted,
                state.systemStarted,
                state.startCompletionGroup
            )
            state.resetIdle()
            return result
        }

        let group = DispatchGroup()
        let stoppedURLs = OSAllocatedUnfairLock(initialState: StoppedRecordingURLs())

        if shouldStopMicrophone {
            group.enter()
            microphoneRecorder.stopRecording { url in
                stoppedURLs.withLock { urls in
                    urls.microphoneURL = url
                }
                group.leave()
            }
        }

        if shouldStopSystemAudio {
            group.enter()
            systemAudioRecorder.stopRecording { url in
                stoppedURLs.withLock { urls in
                    urls.systemAudioURL = url
                }
                group.leave()
            }
        }

        notifyAfterPendingStart(startCompletionGroup) {
            group.notify(queue: .main) {
                let urls = stoppedURLs.withLock { $0 }
                completion(CombinedStoppedRecordingSources(
                    microphoneURL: urls.microphoneURL,
                    systemAudioURL: urls.systemAudioURL
                ))
            }
        }
    }

    func cancelRecording() {
        cancelRecording(completion: nil)
    }

    func cancelRecording(completion: (() -> Void)?) {
        let (
            shouldCancelMicrophone,
            shouldCancelSystemAudio,
            startCompletionGroup
        ) = stateLock.withLock { state in
            let result = (
                state.microphoneStarted,
                state.systemStarted,
                state.startCompletionGroup
            )
            state.resetIdle()
            return result
        }

        let group = DispatchGroup()
        if shouldCancelMicrophone {
            group.enter()
            microphoneRecorder.cancelRecording(completion: {
                group.leave()
            })
        }
        if shouldCancelSystemAudio {
            group.enter()
            systemAudioRecorder.cancelRecording(completion: {
                group.leave()
            })
        }
        notifyAfterPendingStart(startCompletionGroup) {
            group.notify(queue: .main) {
                self.audioLevel = 0.0
                completion?()
            }
        }
    }

    private func notifyAfterPendingStart(
        _ startCompletionGroup: DispatchGroup?,
        completion: @escaping () -> Void
    ) {
        guard let startCompletionGroup else {
            completion()
            return
        }
        startCompletionGroup.notify(queue: .main, execute: completion)
    }

    func temporaryCombinedFallback(
        _ sources: CombinedStoppedRecordingSources,
        completion: @escaping (URL?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finalURL = self.finalRecordingURL(
                microphoneURL: sources.microphoneURL,
                systemAudioURL: sources.systemAudioURL
            )
            DispatchQueue.main.async {
                completion(finalURL)
            }
        }
    }

    func cleanup() {
        cancellables.removeAll()
        stateLock.withLock { state in
            state.resetIdle()
        }
        audioLevel = 0.0
        microphoneRecorder.onRecordingReady = nil
        microphoneRecorder.onRecordingFailure = nil
        microphoneRecorder.onPCM16Samples = nil
        systemAudioRecorder.onRecordingReady = nil
        systemAudioRecorder.onRecordingFailure = nil
        systemAudioRecorder.onPCM16Samples = nil
    }

    private func configureChildCallbacks(startID: UUID) {
        microphoneRecorder.onRecordingReady = { [weak self] in
            self?.fireRecordingReadyOnce(
                source: .microphone,
                startID: startID
            )
        }
        systemAudioRecorder.onRecordingReady = { [weak self] in
            self?.fireRecordingReadyOnce(
                source: .systemAudio,
                startID: startID
            )
        }
        microphoneRecorder.onRecordingFailure = { [weak self] failure in
            self?.handleSourceFailure(.microphone, error: failure, startID: startID)
        }
        systemAudioRecorder.onRecordingFailure = { [weak self] failure in
            self?.handleSourceFailure(.systemAudio, error: failure, startID: startID)
        }
    }

    private func subscribeToAudioLevelsIfNeeded() {
        guard cancellables.isEmpty else { return }

        Publishers.CombineLatest(microphoneRecorder.$audioLevel, systemAudioRecorder.$audioLevel)
            .map { microphoneLevel, systemAudioLevel in
                max(microphoneLevel, systemAudioLevel)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)
    }

    private func handleSourceFailure(
        _ source: RecordingSource,
        error failure: Error,
        startID: UUID
    ) {
        let effect = stateLock.withLock { state -> SourceFailureEffect in
            guard state.startID == startID,
                  !state.failedSources.contains(source),
                  !state.overallFailureReported,
                  state.startInProgress || state.activeSources.contains(source) else {
                return .none
            }

            state.failedSources.insert(source)
            if state.startInProgress {
                state.failuresDuringStart.append(failure)
                return .none
            }

            let sourceFailuresExhaustedRecording = !state.activeSources.isEmpty
                && state.activeSources.isSubset(of: state.failedSources)
            if sourceFailuresExhaustedRecording {
                state.overallFailureReported = true
                return .overallFailure
            }
            return .degraded(source.degradedSource)
        }

        switch effect {
        case .none:
            break
        case .degraded(let degradedSource):
            onRecordingDegraded?(degradedSource)
        case .overallFailure:
            onRecordingFailure?(failure)
        }
    }

    private func fireRecordingReadyOnce(
        source: RecordingSource,
        startID: UUID
    ) {
        let shouldFire = stateLock.withLock { state in
            guard state.startID == startID else { return false }
            state.readySources.insert(source)
            return state.consumeReadyIfPossible()
        }
        if shouldFire {
            onRecordingReady?()
        }
    }

    private func finalRecordingURL(microphoneURL: URL?, systemAudioURL: URL?) -> URL? {
        switch (microphoneURL, systemAudioURL) {
        case let (microphoneURL?, systemAudioURL?):
            do {
                let mixedURL = try mixdownService.mix(microphoneURL: microphoneURL, systemAudioURL: systemAudioURL)
                try? FileManager.default.removeItem(at: microphoneURL)
                try? FileManager.default.removeItem(at: systemAudioURL)
                return mixedURL
            } catch {
                try? FileManager.default.removeItem(at: systemAudioURL)
                return microphoneURL
            }
        case let (microphoneURL?, nil):
            return microphoneURL
        case let (nil, systemAudioURL?):
            return systemAudioURL
        case (nil, nil):
            return nil
        }
    }
}

enum SystemDefaultAndSystemAudioRecorderError: LocalizedError {
    case failedToStartAnyRecorder([Error])
    case debugSimulatedStartFailure

    var errorDescription: String? {
        switch self {
        case .failedToStartAnyRecorder(let errors):
            let details = errors.map(\.localizedDescription).joined(separator: "; ")
            return details.isEmpty ? "Could not start Microphone + System Audio recording." : "Could not start Microphone + System Audio recording: \(details)"
        case .debugSimulatedStartFailure:
            return "Debug: simulated start failure."
        }
    }
}
