# Local AI Post-processing Timeout and History Accuracy — Design

## Context

Quill currently applies the same 20-second default request timeout to Cloud and Local post-processing. Production Local Qwen2.5 7B non-streaming completions can legitimately exceed 20 seconds, especially during a cold server start, and then fail with `NSURLErrorDomain -1001`.

The transport layer already supports request-specific timeouts longer than 20 seconds. `LLMAPITransport` creates an ephemeral session whose request and resource timeouts match a longer `URLRequest.timeoutInterval`. The missing behavior is therefore in the post-processing service and its result propagation:

1. `PostProcessingService` does not choose a timeout from `AIProcessingEndpoint.kind`.
2. A real `URLError(.timedOut)` is not converted to `PostProcessingError.requestTimedOut` after the previous operation-wide watchdog was removed.
3. Raw transcript fallback works, but the untyped network error becomes a generic `post-processing-failed` outcome.
4. Audio import and retry history construction can omit the actual `aiProcessingOutcome`, allowing the default `succeeded` value to be persisted.

## Goals

1. Apply a 120-second default timeout to each Local post-processing request.
2. Preserve the existing 20-second default for each Cloud post-processing request.
3. Preserve the existing positive `post_processing_timeout_seconds` override for both backends.
4. Convert real network timeouts into the post-processing timeout domain error.
5. Keep the raw transcript whenever post-processing times out.
6. Persist `request-timed-out` consistently as both the post-processing status code and failed AI processing outcome reason.
7. Preserve the real AI processing outcome in audio import and retry history paths.
8. Keep diagnostics useful without recording transcript text, prompt text, request bodies, response bodies, credentials, or private paths.

## Non-goals

- Streaming or SSE response parsing.
- Adaptive timeout calculation based on transcript length, chunk count, or hardware.
- Changing the Local AI five-minute idle shutdown policy.
- Raising every Cloud request timeout to 120 seconds.
- Restoring an operation-wide watchdog.
- Large-scale `AppState` result-type or history-builder refactoring.
- Changing the Core Data schema or the existing string representation of AI processing outcomes.
- Redefining manual transcript editing outcomes.

## Timeout Policy

`PostProcessingService` computes an effective timeout after resolving the `AIProcessingEndpoint`.

```text
finite positive post_processing_timeout_seconds override
  → use the override for Local and Cloud requests

no valid override
  ├─ endpoint.kind == .local → 120 seconds
  └─ endpoint.kind == .cloud → 20 seconds
```

Zero, negative, non-finite, or missing override values are invalid and fall back to the backend default.

The effective timeout is assigned to every post-processing `URLRequest.timeoutInterval`, including normal cleanup, command transforms, chunks, and backend fallback attempts. Each request keeps its own timeout:

```text
Local attempt  → up to 120 seconds by default
Cloud fallback → up to 20 seconds by default
```

The combined operation may therefore exceed either individual timeout. No outer task-group watchdog is introduced.

`LLMAPITransport.sharedRequestTimeout` remains 20 seconds. Requests longer than that continue using the existing ephemeral session path.

## Transport Error Mapping

The transport boundary converts only a real URL loading timeout into the post-processing domain error:

```text
transport throws URLError(.timedOut)
  → PostProcessingError.requestTimedOut(effective timeout)
```

Other transport failures keep their existing behavior. The mapping is shared by cleanup and command-transform requests so both operations classify timeouts consistently.

A timeout is exposed as a post-processing-specific user issue whose persisted code is `request-timed-out`. It does not reuse transcription-oriented timeout copy. The user-facing message explains that cleanup timed out and the original transcript was retained.

Diagnostic context may contain only bounded operational metadata:

- backend kind,
- selected model ID,
- effective timeout seconds,
- stable error code.

It must not contain transcript content, prompt content, request JSON, provider response text, authorization values, screenshot data, or absolute paths.

## Raw Transcript Fallback

The existing `AppState.processTranscript` fallback remains the source of truth.

```text
Raw transcript
  ↓
Local post-processing request
  ↓ URLError(.timedOut)
PostProcessingError.requestTimedOut
  ↓
Generated result is not accepted
  ↓
Raw transcript remains the final transcript
  ↓
postProcessingStatus = request-timed-out
aiProcessingOutcome = failed:request-timed-out
```

The timeout correction changes classification and telemetry, not the fallback ownership or transcript-selection architecture.

## History Accuracy

### Audio import

The audio import path passes `result.aiProcessingOutcome` explicitly to `recordPipelineHistoryEntry`. A successful transcription followed by post-processing timeout must not use the history API's `succeeded` default.

### Retry and resumed retry

`makeRetryHistoryItem` accepts the actual AI processing outcome as a required parameter. Every successful retry processing call, including the resumed Cloud transcription path that uses the same history builder, passes the outcome returned by `processTranscript`.

When a retry fails before producing a new processing outcome, reconstruction preserves the previous history item's outcome instead of resetting it to `succeeded`.

The persistence layer continues storing the existing strings, for example:

```text
succeeded
failed:request-timed-out
raw-fallback:<validation-reason>
```

Legacy stored rows may continue using the existing read-time fallback. This change removes default-success reliance only where a new or reconstructed history item has a known outcome.

## Testing Strategy

Tests are written before implementation and must begin from production seams rather than manually constructing the expected domain error.

### Post-processing timeout conversion

An injected transport throws `URLError(.timedOut)`.

Expected result:

```text
PostProcessingError.requestTimedOut
```

The test covers normal cleanup and command transform so neither transport call site can bypass the mapping.

### Backend timeout selection

An injected transport records `URLRequest.timeoutInterval`.

Expected defaults:

```text
Local endpoint → 120 seconds
Cloud endpoint → 20 seconds
```

Expected explicit override:

```text
post_processing_timeout_seconds = 45
Local endpoint → 45 seconds
Cloud endpoint → 45 seconds
```

Tests remove the global `UserDefaults` key during cleanup. Invalid values fall back to backend defaults.

Existing tests that allow multi-chunk and Local-to-Cloud fallback operations to exceed a single request timeout remain unchanged. They prevent accidental restoration of an operation-wide timeout.

### Fallback classification

A timeout-driven processing failure verifies together that:

- the final transcript equals the raw transcript,
- generated output is not adopted,
- the issue code is `request-timed-out`,
- the AI processing outcome is failed,
- the failure reason is `request-timed-out`.

A narrow result-conversion seam may be extracted if needed, but the implementation must avoid a broad `AppState` refactor.

### Import and retry history

History construction tests pass `.failed(reason: "request-timed-out")` and verify that the resulting history item stores `failed:request-timed-out` for:

- audio import,
- retry,
- resumed retry using the same builder.

Retry failures that do not produce a new outcome preserve the existing value.

### Diagnostic privacy

A timeout issue test uses synthetic transcript, prompt, credential, and response sentinels and verifies that none appear in user-visible or persisted diagnostic fields. Backend kind, bounded model ID, timeout, and stable issue code may appear.

### Integration and production verification

Deterministic unit tests verify the production `PostProcessingService` timeout policy. The existing Local Qwen integration target remains optional because it depends on the installed model, bundled server, and machine performance.

After unit tests pass:

1. Run the full test suite.
2. Run `test-local-ai-integration` when prerequisites are available.
3. Build and launch the production app using the repository's signed build workflow.
4. Verify a cold Local AI request continues beyond 20 seconds and can succeed within 120 seconds.
5. Verify a warm retry has lower latency and equivalent validation behavior.
6. Force a short timeout override and verify raw transcript preservation, `request-timed-out`, failed outcome persistence, no crash, and a successful subsequent Local request.
7. Inspect Pipeline History and Unified Log without exposing source text.

## Completion Criteria

The change is complete when:

- Local post-processing requests default to 120 seconds.
- Cloud post-processing requests remain at 20 seconds.
- A positive finite override applies to both backends.
- A real `URLError(.timedOut)` becomes `PostProcessingError.requestTimedOut`.
- Timeout preserves the raw transcript.
- Timeout records `request-timed-out` instead of a generic post-processing failure.
- Audio import and retry history retain the actual AI processing outcome.
- Meeting Summary behavior is unchanged.
- Unit tests and available integration tests pass.
- Cold and warm production verification succeeds where Local model prerequisites are available.
- Diagnostics contain no transcript or prompt source content.
