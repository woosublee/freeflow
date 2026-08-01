# PR #302 citation review fix

## Changed files

- `Sources/MeetingSummaryOutputValidator.swift`
  - Extracted the validator's localized/ISO date-evidence comparison into a shared helper and reused it in evidence repair.
  - Kept localized evidence such as `2026년 8월 15일` valid for `2026-08-15` during repair.
  - Normalized citation characters with source-range entries for every produced character, including lowercase expansions, while preserving repaired citations as exact source substrings.
- `Tests/MeetingSummaryOutputValidatorTests.swift`
  - Added localized-date repair/validation coverage.
  - Added Turkish `İ` normalization coverage that asserts the repaired citation equals the original source substring.

## RED / GREEN

- RED: `make test-transcription` failed at the new localized ISO due-date repair assertion; the repairer cleared the due date and made the summary unverified.
- RED: after the shared date matcher, the Turkish citation regression failed because source and candidate normalization did not match.
- GREEN: both regression cases pass after the targeted implementation.

## Tests

- `make test-transcription`
- `make test`
- `git diff --check`

## Commit and push

- Included in the commit pushed to `origin/fix/meeting-summary-reliability`.

## Explicitly excluded

No changes to Application Support, MCP, no-audio retry, test capture, raw-data safety, GUI/sign/install/deploy, or any other CodeRabbit comments.
