import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct CombinedCaptureDegradationTests {
    static func main() async throws {
        try await bothSourcesSucceed()
        try await sourceStartsRunConcurrently()
        try await microphoneOnlySuccessReturnsMissingSystemAudio()
        try await systemAudioOnlySuccessReturnsMissingMicrophone()
        try await totalFailureAttemptsBothSourcesAndThrows()
        try await readyCallbackAfterTotalFailureIsIgnored()
        try await readyCallbackBeforeStartReturnIsRetained()
        try await microphoneDebugFailureIsConsumedOnce()
        try await systemAudioDebugFailureIsConsumedOnce()
        try await bothDebugFailuresAreConsumedTogether()
        try await runtimeSourceLossReportsDegradationBeforeOverallFailure()
        try await sourceLossWhileOtherSourceStartsWaitsForItsOutcome()
        try await staleChildReadyCallbackCannotReadyReplacementStart()
        try await cancellingPendingCombinedStartRollsBackLateSystemAudio()
        try await cancellationCompletionWaitsForPendingStartCleanup()
        try await systemAudioCancellationRollsBackStartedMicrophone()
        try physicalAudioStartLifecycleKeepsNewStartsBlockedUntilCleanup()
        try physicalAudioCleanupPreventsStaleRollbackFromReleasingOwnership()
        try microphoneGenerationRejectsOldCallbacksAfterReplacement()
        try systemAudioGenerationRejectsPendingAndOldStreamsAfterReplacement()
        try degradedNoticeWaitsForRecordingPresentation()
        try reminderArrivalReanchorsVisibleDegradedNotice()
        try staleDismissCannotHideReplacementNotice()
        try healthyReconciliationClearsAndLaterDegradationCanReappear()
        try endingSessionPreventsPendingNoticeResurrection()
        try oldSessionRequestsAreIgnored()
        print("CombinedCaptureDegradationTests passed")
    }

    private static func bothSourcesSucceed() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                microphoneAttempts += 1
                return AudioRecorderStartResult(
                    requestedDeviceUID: deviceUID,
                    resolvedDeviceUID: "resolved-microphone",
                    usedSystemDefaultFallback: true
                )
            },
            startSystemAudio: {
                systemAudioAttempts += 1
            }
        )

        let result = try await recorder.startRecording(microphoneDeviceUID: "requested-microphone")

        try expect(microphoneAttempts == 1, "both-success start attempts the microphone once")
        try expect(systemAudioAttempts == 1, "both-success start attempts System Audio once")
        try expect(result.microphoneStarted, "both-success result marks the microphone started")
        try expect(result.systemAudioStarted, "both-success result marks System Audio started")
        try expect(result.microphoneUsedSystemDefaultFallback, "microphone fallback metadata is preserved")
        try expect(result.missingSource == nil, "both-success result has no missing source")
    }

    private static func sourceStartsRunConcurrently() async throws {
        let systemAudioStarted = DispatchSemaphore(value: 0)
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                guard systemAudioStarted.wait(timeout: .now() + 1) == .success else {
                    throw TestFailure(
                        "System Audio must be attempted without waiting for microphone startup"
                    )
                }
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                systemAudioStarted.signal()
            }
        )

        let result = try await recorder.startRecording(
            microphoneDeviceUID: "microphone"
        )

        try expect(
            result.microphoneStarted && result.systemAudioStarted,
            "a slow microphone start does not delay the independent System Audio attempt"
        )
    }

    private static func microphoneOnlySuccessReturnsMissingSystemAudio() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                microphoneAttempts += 1
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                systemAudioAttempts += 1
                throw StartFailure.systemAudio
            }
        )

        let result = try await recorder.startRecording(microphoneDeviceUID: "microphone")

        try expect(microphoneAttempts == 1, "microphone-only result attempts the microphone")
        try expect(systemAudioAttempts == 1, "microphone-only result still attempts System Audio")
        try expect(result.microphoneStarted, "microphone-only result keeps the successful microphone")
        try expect(!result.systemAudioStarted, "microphone-only result marks System Audio unavailable")
        try expect(result.missingSource == .systemAudio, "microphone-only result identifies System Audio as missing")
    }

    private static func systemAudioOnlySuccessReturnsMissingMicrophone() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { _ in
                microphoneAttempts += 1
                throw StartFailure.microphone
            },
            startSystemAudio: {
                systemAudioAttempts += 1
            }
        )

        let result = try await recorder.startRecording(microphoneDeviceUID: "microphone")

        try expect(microphoneAttempts == 1, "System-Audio-only result attempts the microphone")
        try expect(systemAudioAttempts == 1, "System-Audio-only result still attempts System Audio")
        try expect(!result.microphoneStarted, "System-Audio-only result marks the microphone unavailable")
        try expect(result.systemAudioStarted, "System-Audio-only result keeps the successful System Audio source")
        try expect(result.missingSource == .microphone, "System-Audio-only result identifies the microphone as missing")
    }

    private static func totalFailureAttemptsBothSourcesAndThrows() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { _ in
                microphoneAttempts += 1
                throw StartFailure.microphone
            },
            startSystemAudio: {
                systemAudioAttempts += 1
                throw StartFailure.systemAudio
            }
        )

        do {
            _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")
            throw TestFailure("total failure must throw")
        } catch SystemDefaultAndSystemAudioRecorderError.failedToStartAnyRecorder(let errors) {
            try expect(errors.count == 2, "total failure preserves both source errors")
        }

        try expect(microphoneAttempts == 1, "total failure attempts the microphone")
        try expect(systemAudioAttempts == 1, "total failure attempts System Audio after microphone failure")
    }

    private static func readyCallbackAfterTotalFailureIsIgnored() async throws {
        let recorder = makeRecorder(
            startMicrophone: { _ in throw StartFailure.microphone },
            startSystemAudio: { throw StartFailure.systemAudio }
        )
        var readyCount = 0
        recorder.onRecordingReady = { readyCount += 1 }

        do {
            _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")
            throw TestFailure("total failure must throw")
        } catch SystemDefaultAndSystemAudioRecorderError.failedToStartAnyRecorder {
            // Expected.
        }

        recorder.microphoneRecorder.onRecordingReady?()
        try expect(
            readyCount == 0,
            "a queued ready callback cannot revive a failed combined start"
        )
    }

    private static func readyCallbackBeforeStartReturnIsRetained() async throws {
        var recorder: SystemDefaultAndSystemAudioRecorder!
        recorder = makeRecorder(
            startMicrophone: { deviceUID in
                recorder.microphoneRecorder.onRecordingReady?()
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {}
        )
        var readyCount = 0
        recorder.onRecordingReady = { readyCount += 1 }

        _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")

        try expect(
            readyCount == 1,
            "a child ready callback is retained until its successful source is admitted"
        )
    }

    private static func microphoneDebugFailureIsConsumedOnce() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                microphoneAttempts += 1
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                systemAudioAttempts += 1
            }
        )
        recorder.debugForcesMicrophoneStartFailure = true

        let first = try await recorder.startRecording(microphoneDeviceUID: "microphone")
        let second = try await recorder.startRecording(microphoneDeviceUID: "microphone")

        try expect(first.missingSource == .microphone, "armed microphone debug failure affects the next start")
        try expect(!recorder.debugForcesMicrophoneStartFailure, "microphone debug failure resets after use")
        try expect(second.missingSource == nil, "microphone debug failure does not affect a later start")
        try expect(microphoneAttempts == 1, "injected microphone failure skips only the armed physical attempt")
        try expect(systemAudioAttempts == 2, "System Audio remains attempted on both starts")
    }

    private static func systemAudioDebugFailureIsConsumedOnce() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                microphoneAttempts += 1
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                systemAudioAttempts += 1
            }
        )
        recorder.debugForcesSystemAudioStartFailure = true

        let first = try await recorder.startRecording(microphoneDeviceUID: "microphone")
        let second = try await recorder.startRecording(microphoneDeviceUID: "microphone")

        try expect(first.missingSource == .systemAudio, "armed System Audio debug failure affects the next start")
        try expect(!recorder.debugForcesSystemAudioStartFailure, "System Audio debug failure resets after use")
        try expect(second.missingSource == nil, "System Audio debug failure does not affect a later start")
        try expect(microphoneAttempts == 2, "microphone remains attempted on both starts")
        try expect(systemAudioAttempts == 1, "injected System Audio failure skips only the armed physical attempt")
    }

    private static func bothDebugFailuresAreConsumedTogether() async throws {
        var microphoneAttempts = 0
        var systemAudioAttempts = 0
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                microphoneAttempts += 1
                return successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                systemAudioAttempts += 1
            }
        )
        recorder.debugForcesMicrophoneStartFailure = true
        recorder.debugForcesSystemAudioStartFailure = true

        do {
            _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")
            throw TestFailure("arming both debug failures must produce total failure")
        } catch SystemDefaultAndSystemAudioRecorderError.failedToStartAnyRecorder(let errors) {
            try expect(errors.count == 2, "both injected failures are reported")
        }

        try expect(!recorder.debugForcesMicrophoneStartFailure, "microphone flag is consumed on total failure")
        try expect(!recorder.debugForcesSystemAudioStartFailure, "System Audio flag is consumed on total failure")
        try expect(microphoneAttempts == 0, "injected microphone failure bypasses the physical start")
        try expect(systemAudioAttempts == 0, "injected System Audio failure bypasses the physical start")
    }

    private static func runtimeSourceLossReportsDegradationBeforeOverallFailure() async throws {
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {}
        )
        var degradedSources: [DegradedCombinedCaptureSource] = []
        var overallFailures = 0
        recorder.onRecordingDegraded = { degradedSources.append($0) }
        recorder.onRecordingFailure = { _ in overallFailures += 1 }

        _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")
        recorder.systemAudioRecorder.onRecordingFailure?(StartFailure.systemAudio)

        try expect(
            degradedSources == [.systemAudio],
            "losing one active source reports which side disappeared"
        )
        try expect(
            overallFailures == 0,
            "one surviving source keeps the combined recording alive"
        )
        try expect(
            recorder.currentMissingSource == .systemAudio,
            "a startup result consumer can reconcile against the latest source state"
        )

        recorder.microphoneRecorder.onRecordingFailure?(StartFailure.microphone)

        try expect(
            degradedSources == [.systemAudio],
            "the final source failure is not reported as another degraded state"
        )
        try expect(
            overallFailures == 1,
            "losing every active source reports one overall failure"
        )
    }

    private static func sourceLossWhileOtherSourceStartsWaitsForItsOutcome() async throws {
        let gate = AsyncStartGate()
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                await gate.run()
            }
        )
        var degradedSources: [DegradedCombinedCaptureSource] = []
        var overallFailures = 0
        recorder.onRecordingDegraded = { degradedSources.append($0) }
        recorder.onRecordingFailure = { _ in overallFailures += 1 }

        let startTask = Task {
            try await recorder.startRecording(microphoneDeviceUID: "microphone")
        }
        await gate.waitUntilStarted()
        recorder.microphoneRecorder.onRecordingFailure?(StartFailure.microphone)

        try expect(
            overallFailures == 0,
            "a source loss does not fail the session while the other start is pending"
        )
        try expect(
            degradedSources.isEmpty,
            "startup reconciliation owns the eventual degraded notice"
        )

        await gate.open()
        let result = try await startTask.value

        try expect(!result.microphoneStarted, "the failed microphone is excluded from the start result")
        try expect(result.systemAudioStarted, "System Audio keeps the combined attempt alive")
        try expect(result.missingSource == .microphone, "the result reports the source lost during startup")
        try expect(overallFailures == 0, "the surviving source avoids overall failure")
    }

    private static func staleChildReadyCallbackCannotReadyReplacementStart() async throws {
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {}
        )
        var readyCount = 0
        recorder.onRecordingReady = { readyCount += 1 }

        _ = try await recorder.startRecording(microphoneDeviceUID: "first")
        let staleReady = recorder.systemAudioRecorder.onRecordingReady
        recorder.cancelRecording()
        _ = try await recorder.startRecording(microphoneDeviceUID: "second")

        staleReady?()
        try expect(
            readyCount == 0,
            "a ready callback captured by the old combined start is ignored"
        )

        recorder.systemAudioRecorder.onRecordingReady?()
        try expect(
            readyCount == 1,
            "the current combined start can still become ready"
        )
    }

    private static func cancellingPendingCombinedStartRollsBackLateSystemAudio() async throws {
        let gate = AsyncStartGate()
        let cancellationCounter = AsyncCounter()
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                await gate.run()
            },
            cancelSystemAudio: {
                await cancellationCounter.increment()
            }
        )

        let startTask = Task {
            try await recorder.startRecording(microphoneDeviceUID: "microphone")
        }
        await gate.waitUntilStarted()
        recorder.cancelRecording()
        await gate.open()

        do {
            _ = try await startTask.value
            throw TestFailure("a cancelled pending combined start must not report success")
        } catch is CancellationError {
            // Expected: the late System Audio start was rolled back.
        }
        let cancellationCount = await cancellationCounter.value
        try expect(
            cancellationCount == 1,
            "late System Audio is cancelled exactly once after session invalidation"
        )
    }

    private static func cancellationCompletionWaitsForPendingStartCleanup() async throws {
        let startGate = AsyncStartGate()
        let completion = AsyncEvent()
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                await startGate.run()
            }
        )
        let startTask = Task {
            try await recorder.startRecording(microphoneDeviceUID: "microphone")
        }
        await startGate.waitUntilStarted()

        recorder.cancelRecording {
            Task { await completion.signal() }
        }
        let completionFiredEarly = await eventFired(
            completion,
            withinAttempts: 20
        )
        try expect(
            !completionFiredEarly,
            "combined cancellation cannot finish while a child start can still roll back"
        )

        await startGate.open()
        do {
            _ = try await startTask.value
            throw TestFailure("the cancelled combined start must not report success")
        } catch is CancellationError {
            // Expected.
        }
        await completion.wait()
    }

    private static func systemAudioCancellationRollsBackStartedMicrophone() async throws {
        let microphoneCancellationCounter = AsyncCounter()
        let recorder = makeRecorder(
            startMicrophone: { deviceUID in
                successfulMicrophoneResult(deviceUID: deviceUID)
            },
            startSystemAudio: {
                throw CancellationError()
            },
            cancelMicrophone: {
                await microphoneCancellationCounter.increment()
            }
        )

        do {
            _ = try await recorder.startRecording(microphoneDeviceUID: "microphone")
            throw TestFailure("a cancelled child start must cancel the combined attempt")
        } catch is CancellationError {
            // Expected: the successful microphone side is rolled back.
        }

        let microphoneCancellationCount = await microphoneCancellationCounter.value
        try expect(
            microphoneCancellationCount == 1,
            "System Audio cancellation rolls back the already-started microphone"
        )
    }

    private static func physicalAudioStartLifecycleKeepsNewStartsBlockedUntilCleanup() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        var lifecycle = RecordingStartLifecycle()

        try expect(lifecycle.begin(firstID), "the first physical start acquires ownership")
        try expect(!lifecycle.begin(secondID), "a second start is blocked while cleanup is pending")
        try expect(!lifecycle.finish(secondID), "an unrelated completion cannot release the active start")
        try expect(lifecycle.activeID == firstID, "the first start retains ownership")
        try expect(lifecycle.finish(firstID), "the owning completion releases the start")
        try expect(lifecycle.begin(secondID), "a new start is accepted after cleanup finishes")
    }

    private static func physicalAudioCleanupPreventsStaleRollbackFromReleasingOwnership() throws {
        let startID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000071"
        )!
        let fallbackCleanupID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000072"
        )!
        var lifecycle = RecordingStartLifecycle()

        try expect(lifecycle.begin(startID), "the physical start acquires ownership")
        let cleanupID = lifecycle.beginOrAdoptCleanup(
            fallbackID: fallbackCleanupID
        )
        try expect(cleanupID == startID, "Stop adopts the pending start operation")
        try expect(
            !lifecycle.beginCleanup(for: startID),
            "a stale startup continuation cannot become a second cleanup owner"
        )
        try expect(
            lifecycle.activeID == startID,
            "the original Stop cleanup retains ownership until its callback finishes"
        )
        try expect(
            lifecycle.finish(cleanupID),
            "the owning Stop callback releases physical cleanup"
        )
    }

    private static func microphoneGenerationRejectsOldCallbacksAfterReplacement() throws {
        let firstID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000081"
        )!
        let replacementID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000082"
        )!
        let firstOutput = NSObject()
        let replacementOutput = NSObject()
        var lifecycle = AudioRecorderGenerationLifecycle()

        lifecycle.begin(firstID)
        try expect(
            lifecycle.bind(firstOutput, to: firstID),
            "the first microphone output is owned by its recording generation"
        )
        try expect(
            lifecycle.generation(for: firstOutput) == firstID,
            "callbacks from the active microphone output retain their generation"
        )

        lifecycle.invalidateCurrent()
        try expect(
            !lifecycle.owns(firstID),
            "stopping the microphone invalidates queued failure and ready callbacks"
        )

        lifecycle.begin(replacementID)
        try expect(
            !lifecycle.owns(firstID),
            "a replacement microphone generation invalidates delayed callbacks from the old input"
        )
        try expect(
            lifecycle.generation(for: firstOutput) == nil,
            "the old capture output cannot borrow replacement-generation ownership"
        )
        try expect(
            lifecycle.bind(replacementOutput, to: replacementID),
            "the replacement microphone output acquires current generation ownership"
        )
        try expect(
            lifecycle.generation(for: replacementOutput) == replacementID,
            "callbacks from the replacement output remain accepted"
        )
    }

    private static func systemAudioGenerationRejectsPendingAndOldStreamsAfterReplacement() throws {
        let pendingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000091"
        )!
        let replacementID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000092"
        )!
        let pendingStream = NSObject()
        let replacementStream = NSObject()
        var lifecycle = SystemAudioRecorderGenerationLifecycle()

        lifecycle.begin(pendingID)
        try expect(
            lifecycle.invalidate(pendingID),
            "Stop invalidates a System Audio start before SCStream installation"
        )
        try expect(
            !lifecycle.bind(pendingStream, to: pendingID),
            "a delayed pending start cannot install a stream after Stop"
        )

        lifecycle.begin(replacementID)
        try expect(
            lifecycle.bind(replacementStream, to: replacementID),
            "the replacement System Audio stream acquires ownership"
        )
        try expect(
            lifecycle.generation(for: pendingStream) == nil,
            "callbacks from the stale stream cannot borrow replacement state"
        )
        try expect(
            lifecycle.generation(for: replacementStream) == replacementID,
            "callbacks from the current stream retain replacement ownership"
        )
    }

    private static func degradedNoticeWaitsForRecordingPresentation() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let request = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: token,
            message: "No mic",
            reminderFrame: nil
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()

        try expect(lifecycle.beginSession(sessionID) == .none, "starting an empty notice session has no panel effect")
        try expect(
            lifecycle.reconcile(request, sessionID: sessionID) == .none,
            "a request waits while the recording overlay is not ready"
        )
        try expect(lifecycle.pendingRequest == request, "the early degraded request is retained")
        try expect(lifecycle.visibleRequest == nil, "the early degraded request is not marked visible")

        let effect = lifecycle.markPresentationReady(sessionID: sessionID)

        try expect(effect == .present(request), "recording presentation flushes the retained request")
        try expect(lifecycle.pendingRequest == nil, "the retained request is consumed once")
        try expect(lifecycle.visibleRequest == request, "the retained request becomes visible")
        try expect(
            lifecycle.markPresentationReady(sessionID: sessionID) == .none,
            "repeated recording presentation does not present the request twice"
        )
    }

    private static func reminderArrivalReanchorsVisibleDegradedNotice() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let request = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: token,
            message: "No mic",
            reminderFrame: nil
        )
        let reminderFrame = CGRect(x: 576, y: 870, width: 360, height: 112)
        let reanchoredRequest = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: token,
            message: "No mic",
            reminderFrame: reminderFrame
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()
        _ = lifecycle.beginSession(sessionID)
        _ = lifecycle.markPresentationReady(sessionID: sessionID)
        _ = lifecycle.reconcile(request, sessionID: sessionID)

        try expect(
            lifecycle.updateReminderFrame(reminderFrame) == .present(reanchoredRequest),
            "a reminder arriving during degraded recording re-presents the notice below the card"
        )
        try expect(
            lifecycle.visibleRequest == reanchoredRequest,
            "the visible notice retains the new reminder anchor for later layout updates"
        )
    }

    private static func staleDismissCannotHideReplacementNotice() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstToken = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let secondToken = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let first = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: firstToken,
            message: "No mic",
            reminderFrame: nil
        )
        let replacement = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: secondToken,
            message: "No System Audio",
            reminderFrame: nil
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()
        _ = lifecycle.beginSession(sessionID)
        _ = lifecycle.markPresentationReady(sessionID: sessionID)
        _ = lifecycle.reconcile(first, sessionID: sessionID)
        _ = lifecycle.reconcile(replacement, sessionID: sessionID)

        try expect(
            lifecycle.dismiss(sessionID: sessionID, token: firstToken) == .none,
            "a stale dismiss callback cannot hide a replacement notice"
        )
        try expect(lifecycle.visibleRequest == replacement, "the replacement notice remains visible")
        try expect(
            lifecycle.dismiss(sessionID: sessionID, token: secondToken) == .hide(secondToken),
            "the current dismiss callback hides its own notice"
        )
        try expect(lifecycle.visibleRequest == nil, "the current notice is cleared after dismissal")
    }

    private static func healthyReconciliationClearsAndLaterDegradationCanReappear() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let firstToken = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let laterToken = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let first = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: firstToken,
            message: "No mic",
            reminderFrame: nil
        )
        let later = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: laterToken,
            message: "No System Audio",
            reminderFrame: nil
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()
        _ = lifecycle.beginSession(sessionID)
        _ = lifecycle.markPresentationReady(sessionID: sessionID)
        _ = lifecycle.reconcile(first, sessionID: sessionID)

        try expect(
            lifecycle.reconcile(nil, sessionID: sessionID) == .hide(firstToken),
            "healthy or single-source reconciliation hides a stale degraded notice"
        )
        try expect(lifecycle.visibleRequest == nil, "healthy reconciliation clears visible state")
        try expect(
            lifecycle.reconcile(later, sessionID: sessionID) == .present(later),
            "a later degraded input switch can show a new notice"
        )
    }

    private static func endingSessionPreventsPendingNoticeResurrection() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let request = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: sessionID,
            token: token,
            message: "No mic",
            reminderFrame: nil
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()
        _ = lifecycle.beginSession(sessionID)
        _ = lifecycle.reconcile(request, sessionID: sessionID)

        try expect(lifecycle.endSession(sessionID) == .none, "ending a pending-only session needs no panel hide")
        try expect(lifecycle.activeSessionID == nil, "session end clears the active session")
        try expect(lifecycle.pendingRequest == nil, "session end clears the pending request")
        try expect(
            lifecycle.markPresentationReady(sessionID: sessionID) == .none,
            "a late recording callback cannot resurrect an ended session"
        )
    }

    private static func oldSessionRequestsAreIgnored() throws {
        let oldSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let currentSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let oldRequest = DegradedCombinedCaptureNoticeLifecycle.Request(
            sessionID: oldSessionID,
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
            message: "No mic",
            reminderFrame: nil
        )
        var lifecycle = DegradedCombinedCaptureNoticeLifecycle()
        _ = lifecycle.beginSession(oldSessionID)
        _ = lifecycle.beginSession(currentSessionID)
        _ = lifecycle.markPresentationReady(sessionID: currentSessionID)

        try expect(
            lifecycle.reconcile(oldRequest, sessionID: oldSessionID) == .none,
            "an old start result cannot update a newer recording session"
        )
        try expect(lifecycle.visibleRequest == nil, "the current session remains free of stale notices")
    }

    private static func makeRecorder(
        startMicrophone: @escaping (String) throws -> AudioRecorderStartResult,
        startSystemAudio: @escaping () async throws -> Void,
        cancelMicrophone: @escaping () async -> Void = {},
        cancelSystemAudio: @escaping () async -> Void = {}
    ) -> SystemDefaultAndSystemAudioRecorder {
        SystemDefaultAndSystemAudioRecorder(
            microphoneRecorder: AudioRecorder(),
            systemAudioRecorder: SystemAudioRecorder(),
            mixdownService: AudioMixdownService(),
            startOperations: CombinedRecordingStartOperations(
                startMicrophone: startMicrophone,
                startSystemAudio: startSystemAudio,
                cancelMicrophone: cancelMicrophone,
                cancelSystemAudio: cancelSystemAudio
            )
        )
    }

    private static func successfulMicrophoneResult(deviceUID: String) -> AudioRecorderStartResult {
        AudioRecorderStartResult(
            requestedDeviceUID: deviceUID,
            resolvedDeviceUID: deviceUID,
            usedSystemDefaultFallback: false
        )
    }

    private static func eventFired(
        _ event: AsyncEvent,
        withinAttempts attempts: Int
    ) async -> Bool {
        for _ in 0..<attempts {
            if await event.hasFired { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await event.hasFired
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }

    private actor AsyncStartGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var resumeContinuation: CheckedContinuation<Void, Never>?

        func run() async {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func open() {
            resumeContinuation?.resume()
            resumeContinuation = nil
        }
    }

    private actor AsyncCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private actor AsyncEvent {
        private(set) var hasFired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !hasFired else { return }
            hasFired = true
            let continuations = waiters
            waiters.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }

        func wait() async {
            guard !hasFired else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private enum StartFailure: Error {
        case microphone
        case systemAudio
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
