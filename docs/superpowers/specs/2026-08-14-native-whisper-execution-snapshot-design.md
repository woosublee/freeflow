# Native Whisper Execution Snapshot Design

## Context

Issue #316 moved Native Whisper model-management behavior owned by `AppState`—install status, install start, progress scheduling, and deletion—onto instance-owned `AppStateNativeWhisperDependencies`. Its live implementation creates one `NativeWhisperModelStore` and shares that store across the model-management lifecycle.

The actual Native Whisper transcription worker still opens a separate live environment. `TranscriptionService.transcribeWithNativeWhisper` constructs `NativeWhisperModelStore()` and `NativeWhisperRuntime()` directly, resolves the recommended model URL from that store, and then performs runtime/model preflight and transcription. An `AppState` can therefore report readiness from one injected model environment while the worker executes against the process-default model root and runtime.

Issue #327 completes the deferred execution half of that boundary. The change remains behavior-preserving: it does not alter model metadata, installation, transcription routing, UI, or user-facing error copy.

## Goal

Capture a focused Native Whisper execution snapshot from the originating `AppState` and pass it through every file-transcription request so readiness, model-path resolution, runtime preflight, and transcription all use the same instance-owned environment.

## Scope

- Add a focused `NativeWhisperExecutionSnapshot` value containing the selected model, its originating model-environment operations, and the runtime used for that request.
- Make `AppStateNativeWhisperDependencies.live` build execution snapshots from the same `NativeWhisperModelStore` used by install status, install start, and deletion.
- Capture the snapshot before asynchronous work begins in:
  - audio import,
  - manual Retry,
  - and stopped-recording file transcription.
- Carry the snapshot through the existing local transcription execution snapshot and service-construction boundaries.
- Remove direct `NativeWhisperModelStore()` and `NativeWhisperRuntime()` construction from the Native Whisper worker path.
- Preserve runtime/model preflight before audio conversion.
- Replace the exact-source-text preflight-order assertion with behavioral coverage.

## Non-goals

- No abstraction of Apple Speech or legacy mlx-whisper execution.
- No general local-transcription service protocol or workflow extraction.
- No Native Whisper installer redesign.
- No model catalog, download URL, file name, checksum, recommendation, or hardware requirement change.
- No transcription provider, model-selection, retry-policy, chunking, timeout, or UI change.
- No `AppState.swift` split or general retry/resume workflow extraction.

## Architecture

### Focused execution snapshot

Introduce a Sendable value dedicated to Native Whisper execution. It captures:

- the `NativeWhisperModel` selected for the request,
- an install-status operation bound to the originating model environment,
- a model-URL operation bound to the same environment,
- the `NativeWhisperRuntime` selected for the request,
- and the audio-preparation operation needed to behaviorally verify preflight ordering without introducing a process-global test seam.

The snapshot is a request value, not a service locator. Production constructs it once from an `AppState` dependency value, and an active request keeps that value for its lifetime.

The model file itself is not copied or retained in memory. The snapshot fixes which model environment and runtime are consulted. File existence and runtime validity are still checked immediately before conversion and execution, so deleting a model after snapshot capture continues to yield the existing missing-model behavior.

### One live model environment

`AppStateNativeWhisperDependencies.live` continues to create one `NativeWhisperModelStore`. It adds `makeExecutionSnapshot`, whose closure captures that same store and creates a request-specific `NativeWhisperRuntime`.

This keeps the live relationship coherent:

```text
AppStateNativeWhisperDependencies.live
  └─ NativeWhisperModelStore
       ├─ install status
       ├─ installer
       ├─ deletion
       └─ execution snapshot
            ├─ install status
            ├─ model URL
            └─ request runtime
```

Copy-and-override tests may replace `makeExecutionSnapshot` independently. Production `.live` always uses the shared store.

### Existing execution boundaries

The design reuses existing request snapshots rather than creating a competing transcription workflow.

- `AudioImportTaskConfiguration` stores the originating Native Whisper execution snapshot when the selected backend is Native Whisper.
- `LocalTranscriptionExecutionSnapshot` stores the snapshot for Retry and other `TranscriptionExecutionSnapshot.local` service construction.
- stopped-recording file transcription captures the snapshot alongside the existing API key, backend, language, and model values before creating its asynchronous task.

Apple Speech and legacy mlx-whisper requests carry no Native Whisper execution snapshot and continue through their existing paths.

### Service construction

`TranscriptionService` accepts a Native Whisper execution snapshot. Direct callers may use a default live snapshot chosen when the service is initialized, preserving the existing initializer ergonomics without reopening a live environment inside an active worker.

Every service created by `AppState` passes the originating instance's snapshot explicitly. The default exists for non-`AppState` direct callers and focused tests, not as a fallback for `AppState` production routing.

`TranscriptionExecutionSnapshot.makeTranscriptionService` passes the stored Native Whisper snapshot from `LocalTranscriptionExecutionSnapshot` into `TranscriptionService`.

## Data Flow

### Audio import

1. `AppState` resolves the chosen backend synchronously on the main actor.
2. If the choice is Native Whisper, it calls `dependencies.nativeWhisper.makeExecutionSnapshot()`.
3. `AudioImportTaskConfiguration` retains the returned value.
4. Detached import work constructs `TranscriptionService` from that configuration.
5. Native Whisper execution uses only the retained snapshot.

### Manual Retry

1. `makeRetrySnapshot` resolves the local backend from the history item and current retry configuration.
2. For Native Whisper, it captures `dependencies.nativeWhisper.makeExecutionSnapshot()` before the retry task starts.
3. The value is stored in `LocalTranscriptionExecutionSnapshot` inside `RetrySnapshot.execution`.
4. `TranscriptionExecutionSnapshot.makeTranscriptionService` passes it to the service.

### Stopped recording

1. The stop path captures the current backend and other settings before asynchronous completion work starts.
2. For Native Whisper, it captures `dependencies.nativeWhisper.makeExecutionSnapshot()` at the same boundary.
3. The stopped-recording task passes the captured value to `TranscriptionService`.
4. Later changes to any `AppState` or test dependency cannot redirect the active request.

## Native Whisper Worker Sequence

`TranscriptionService.transcribeWithNativeWhisper` preserves this order:

1. Use the snapshot's install-status operation to confirm the model is ready.
2. Resolve the model URL from the same snapshot environment.
3. Call the snapshot runtime's `validateRunnerAndModel`.
4. Prepare audio for Native Whisper.
5. Call the same snapshot runtime's `transcribe` with the same model URL.

The worker no longer constructs an unconfigured `NativeWhisperModelStore` or `NativeWhisperRuntime`.

## Error Handling

Existing user-issue behavior remains unchanged:

- model not ready or missing: `.localModelMissing`, backend `Native Whisper`, existing model ID;
- runner unavailable: `.localRuntimeMissing`;
- audio preparation failure: `.audioPreparationFailed`;
- runtime process or output failure: `.localTranscriptionFailed`;
- cancellation: `CancellationError` remains cancellation and is not remapped.

The snapshot introduces no durable serialization. Paths, runtime details, and secrets remain runtime-only. Existing `NativeWhisperRuntimeError.userIssue` rules continue to keep filesystem and process details in private diagnostics rather than persisted user-issue payloads.

## Testing

### Behavioral preflight ordering

Replace `testNativeWhisperPreparesAudioBeforeRuntime`, which scans source text, with a behavioral test:

- inject a snapshot runtime whose preflight fails,
- inject an audio-preparation operation that records invocation,
- execute Native Whisper transcription,
- assert the preflight error is mapped as before,
- and assert audio preparation was never invoked.

A success-path companion verifies that preflight, audio preparation, and transcription receive the same model URL in the required order.

### Isolation

Add tests that create two Native Whisper execution snapshots with different model URLs and runtime harnesses. Construct two services and prove that each service uses only its originating URL/runtime. Mutating or creating a later dependency value must not affect an already-created service or active request.

### AppState propagation

Cover the three production request paths:

- audio import configuration retains the originating snapshot,
- Retry stores it in `LocalTranscriptionExecutionSnapshot`,
- stopped recording captures it before its asynchronous task.

Prefer behavior tests. Where the UI and recorder orchestration make direct execution disproportionate, retain only a narrow, documented structural assertion at the exact capture boundary. Do not add a process-global mutable seam to simplify these tests.

### Compatibility

Retain or extend tests for:

- missing model,
- missing runner,
- audio preparation failure,
- runtime failure,
- snapshot immutability,
- and direct `TranscriptionService` initialization.

Run focused Native Whisper/runtime/snapshot/AppState suites, `make check-test-wiring`, `make test`, and `make all CODESIGN_IDENTITY=Quill`. Run `/code-review medium` once before PR delivery. If CodeRabbit is rate-limited, do not repeatedly request reviews; rely on the local medium review and CI.

## Delivery

Implement in an isolated worktree on a dedicated branch. Keep the PR limited to issue #327 and close it from the PR body. Update roadmap #321 only after merge. Keep broader workflow issues #318 and #320 open.
