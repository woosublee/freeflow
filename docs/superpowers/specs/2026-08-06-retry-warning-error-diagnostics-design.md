# Retry Warning Lifecycle and Post-processing Diagnostics — Design

## Context

When a completed note contains a persisted warning from post-processing, dismissing its warning banner records the dismissal against the note's current retry generation. Starting retranscription increments that generation before the new transcription or cleanup has produced a result. The note still carries the previous persisted warning at that moment, so its warning banner becomes eligible and appears immediately.

This makes an earlier cleanup failure look like a failure of the new retranscription attempt. In particular, a previously stored timeout message can be shown immediately even though the Local AI request has not had time to reach its 120-second default timeout.

The current compact warning banner also omits `QuillUserIssuePresentation.detailsRows`. Existing structured diagnostic metadata, such as model, Local AI backend, and HTTP status, is therefore unavailable in the place where a completed note's post-processing warning is shown. Several generic `post-processing-failed` paths are not further classified for user-facing copy.

## Goals

1. Do not show a dismissed warning from a prior attempt while retranscription is in progress.
2. Keep a dismissed warning hidden when the user merely revisits the same note.
3. Show a warning when the new retranscription attempt actually produces a new failure, including when its code matches a prior failure.
4. Explain post-processing failures with bounded, actionable cause information rather than generic cleanup-skipped copy whenever the application can safely classify the cause.
5. Show model, Local AI backend, effective timeout, and safe HTTP metadata in the warning banner's expandable details.
6. Preserve the Local AI 120-second default, Cloud 20-second default, and valid explicit timeout override policy from v0.1.35.
7. Keep persisted diagnostics free of transcript text, prompts, request/response bodies, credentials, and private file paths.
8. Keep existing persisted user-issue records readable.

## Non-goals

- Change post-processing retry behavior, model selection, or Local AI server lifecycle.
- Add a retranscription-attempt timeline or a separate error-history screen.
- Expose raw error descriptions or provider response text.
- Change the existing transcript fallback policy: a failed cleanup continues to retain the original transcript.
- Alter warning behavior for unrelated meeting-summary or recording errors.

## Root Cause and Corrected Warning Lifecycle

### Current sequence

```text
Dismiss warning at retry generation N
  ↓
Dismissal stored for (note ID, warning code, N)
  ↓
Start retranscription
  ↓
Increment retry generation to N + 1
  ↓
Existing note still contains the old persisted warning
  ↓
Dismissal lookup no longer matches
  ↓
Old warning banner renders immediately
```

### Corrected sequence

```text
Dismiss warning at retry generation N
  ↓
Revisit note without retrying
  ↓
Dismissed warning remains hidden

Start retranscription
  ↓
Retry is marked in progress
  ↓
Existing warning is suppressed only while that retry is in progress
  ↓
New result is saved
  ├─ success: saved status has no warning → no banner
  └─ new failure: saved status has the new warning → show banner
```

`AppState.retryingItemIDs` already identifies an in-progress retry. The Note Browser warning-banner condition will additionally require that the note is not in this set. The dismissal store and retry-generation behavior remain unchanged: a new failure after retry remains eligible to be shown, while an old dismissal remains effective when no retry is active.

No old issue record is cleared at retry start. This avoids mutating durable history before the replacement result is available and keeps retry failure recovery intact.

## Safe Post-processing Diagnostics

### Persisted context

`QuillUserIssueContext` will gain optional, backwards-compatible fields:

- `postProcessingFailureReason`: a bounded application-owned reason enum;
- `requestTimeoutSeconds`: the effective request timeout when the reason is timeout.

The fields are optional. Existing version-1 records without them decode and retain their current generic presentation. The record schema version remains unchanged because the additional Codable fields are optional and do not alter existing fields.

### Bounded failure reasons

The application maps internal post-processing errors into a finite set of safe categories. The exact enum names may follow existing Swift naming conventions, but the user-visible meanings are:

| Internal condition | User-visible cause |
| --- | --- |
| `URLError(.timedOut)` mapped to `PostProcessingError.requestTimedOut` | Cleanup request timed out |
| Safe context-budget rejection | Transcript is too large for cleanup |
| Missing or malformed completion envelope | Model response could not be read |
| Empty completion output | Model returned no cleanup text |
| Non-success HTTP result not already mapped to authentication, configuration, or rate limit | Cleanup request failed at the service |

Existing specialized issue codes remain authoritative for authentication, configuration, rate limiting, Local AI runtime/model failures, and output-guard rejections. Unknown transport failures continue to use the existing generic safe fallback rather than exposing an unbounded underlying error.

### Presentation

`QuillUserIssueRecord.presentation` uses the bounded reason to select more specific localized cleanup copy. For example:

- timeout: cleanup did not respond before the configured limit;
- oversized input: cleanup could not safely fit the transcript in the selected model's context;
- empty output: the model returned no usable cleanup text;
- unreadable response: the model response could not be read.

The warning-banner layout will render the shared expandable details view. Details may contain only structured metadata already approved for display:

- operation (`Transcript cleanup`),
- bounded failure reason,
- effective timeout when present,
- model ID,
- Local AI backend marker,
- HTTP status and allowlisted provider code when present.

The raw transcript, prompt, request JSON, response body, authorization token, source error description, and filesystem paths are never persisted or displayed.

## Components and Data Flow

### `PostProcessingService`

At the conversion from `PostProcessingError` to `QuillUserIssueError`, resolve the safe failure reason and, for a timeout, retain the effective `URLRequest.timeoutInterval`. Continue using the request endpoint model ID, so Local AI timeouts identify the actual selected Local model.

### `QuillUserIssue`

Add optional context fields, their Codable keys, and a finite failure-reason enum. Extend presentation generation to choose localized copy based on the post-processing operation and safe failure reason. Extend details-row generation with localized labels and values for the failure reason and timeout.

### `QuillUserIssueView`

For `.warningBanner`, include the existing shared `detailsView` beneath the compact title/body section. `.full` and `.inline` presentation styles retain their existing details behavior.

### `NoteBrowserView`

Keep decoding the note's persisted issue as it does today. Suppress the transcript warning banner whenever `appState.retryingItemIDs` contains the current note ID. Once retry finishes, reload the saved history item and render only its newly saved status.

### `AppState`

Continue incrementing retry generation so a genuinely new failure, including one with the same issue code, is visible after retry. Do not change the persisted note status when retry begins. The success and failure history replacement paths remain the single source of truth for what displays after the retry finishes.

## Testing Strategy

Tests are written before production changes.

### Warning lifecycle

1. A dismissed warning remains hidden when the note is revisited without retrying.
2. With an old warning record present, an in-progress retry suppresses that banner.
3. A successful retry replaces the warning status and leaves no banner.
4. A failed retry produces a visible warning after retry completion, including when its issue code equals the prior warning's code.
5. The dismiss behavior remains isolated to the note and warning occurrence/retry generation as existing behavior requires.

Where direct SwiftUI interaction coverage is impractical, extract or extend a small display predicate and test it deterministically; retain source-contract coverage for the Note Browser wiring.

### Diagnostics classification and presentation

1. Each bounded post-processing reason maps to the expected structured record and localized Korean/English copy.
2. A Local timeout records `request-timed-out`, the selected model, Local AI marker, and `120` seconds with no valid override.
3. A valid timeout override records the override value rather than the default.
4. Cloud timeout retains the existing 20-second default.
5. Details rows include only approved bounded values.
6. Synthetic transcript, prompt, credential, response-body, and local-path sentinels do not occur in encoded records, banner text, or details rows.
7. Legacy version-1 records without the new optional fields remain decodable and use generic compatible copy.

### Regression verification

Run the focused post-processing, user-issue, Note Browser UI contract, and AppState retry tests, then run `make test`. Run the optional Local AI integration target only if the current machine has the required bundled server and Quality Qwen model prerequisites.

## Acceptance Criteria

- Clicking retranscription never immediately re-shows a previously dismissed warning while the new attempt is running.
- Returning to a note after dismissing its warning does not re-show that same warning without a new retry result.
- A new retry failure displays after completion, even if it has the same classification as the prior failure.
- Timeout, context-budget, empty-output, malformed-response, and service-request cleanup failures have bounded and specific user-facing explanations.
- Timeout details identify the actual model and effective timeout, including Local AI's default 120 seconds when applicable.
- The existing Local/Cloud timeout policy and raw-transcript fallback behavior remain unchanged.
- Existing persisted history remains readable.
- No sensitive source or raw provider data enters persistence or UI.
- Focused tests and `make test` pass.
