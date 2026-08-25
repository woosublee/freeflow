# Upstream Selective Integration Design

**Date:** 2026-08-25

**Status:** Approved for implementation planning

## Context

Quill last integrated upstream FreeFlow through `v1.2.1` at commit `ce32cd5`. Upstream `main` has since advanced by nine commits to `4c6a557` through three pull requests:

- `#293` — maintenance checks, repository templates, and test coverage
- `#296` — release workflow dependency and credential hardening
- `#297` — transcript text processing extraction and regression tests

Quill has diverged substantially from FreeFlow. It has a different product identity, a self-signed official release path, Sparkle appcast generation, Google Calendar OAuth build credentials, stricter release ordering, a sharded test suite, local AI support, transcript language detection, and a stronger instruction-execution guard. A direct content replacement or isolated cherry-pick would either discard those capabilities or make future upstream synchronization harder.

## Goals

1. Preserve Git ancestry by merging `upstream/main` rather than manually copying all changes.
2. Accept upstream additions by default and exclude or reshape them only when they conflict with Quill behavior or architecture.
3. Apply upstream release workflow security improvements to every equivalent Quill workflow.
4. Reuse Quill's existing CI and test structure instead of introducing a weaker parallel structure.
5. Add missing transcript parser and sanitizer regression coverage without weakening provider compatibility, language detection, or the existing instruction-execution guard.
6. Keep the current `main` working tree and its unrelated untracked design documents untouched during implementation.

## Non-goals

- Changing Quill's release version or creating a release.
- Triggering any release workflow, moving a tag, or publishing GitHub assets.
- Migrating from Make and direct `swiftc` builds to Xcode or Swift Package Manager.
- Replacing Quill's self-signed release strategy with upstream notarization.
- Removing Sparkle, calendar integration, local AI, or existing transcript metadata.
- Broad refactoring unrelated to the three upstream pull requests.

## Integration Strategy

Implementation will occur in a dedicated worktree and branch. The integration uses a real merge from `upstream/main` so the next synchronization starts from `4c6a557` rather than rediscovering these changes.

The three implementation commits are:

1. **Merge upstream and resolve structural conflicts**
   - Merge `upstream/main` with a merge commit.
   - Prefer upstream additions when they do not remove Quill behavior.
   - Resolve conflicts in `.gitignore`, `Makefile`, `PostProcessingService`, `TranscriptionService`, `AppContextServiceTests`, and `LLMCooldownManagerTests`.

2. **Adapt maintenance and release hardening for Quill**
   - Adapt repository templates and `AGENTS.md` to Quill.
   - Integrate static validation into Quill's existing Make and CI structure.
   - Harden all equivalent release workflows while preserving Quill release contracts.

3. **Adapt transcript text core and regression coverage for Quill**
   - Preserve Quill normalization, language metadata, and provider compatibility.
   - Extract directly testable pure transcript parsing and sanitization helpers where doing so reduces duplication.
   - Port only missing upstream test cases into Quill's existing test layout.

The separately committed design document is preparatory documentation and is not counted as one of these three implementation commits.

## Acceptance Rules

Upstream changes are accepted unless one of these conditions applies:

- The change replaces `Quill`, `com.woosublee.quill`, or Quill asset names with FreeFlow values.
- The change removes self-signed releases, Sparkle appcast generation, calendar OAuth credentials, stable release ordering, local AI, transcript language metadata, or existing tests.
- The change narrows Quill's existing verification scope.
- The change rejects a provider response format that Quill intentionally supports without a tested compatibility policy.
- The change duplicates an existing Quill abstraction or test instead of extending it.

When an upstream implementation cannot be retained verbatim, its intent and regression coverage should still be preserved through the closest existing Quill path.

## Repository Maintenance Changes

### Issue and pull request templates

Adapt and retain:

- `.github/ISSUE_TEMPLATE/bug.yml`
- `.github/ISSUE_TEMPLATE/feature.yml`
- `.github/ISSUE_TEMPLATE/config.yml`
- `.github/pull_request_template.md`

Requirements:

- Replace FreeFlow branding with Quill.
- Keep templates in English.
- Preserve warnings against attaching credentials, real transcripts, audio, screenshots, selected text, clipboard contents, private URLs, and identifying diagnostics.
- Keep blank issues available because `woosublee/quill` does not currently have GitHub Discussions enabled; do not retain the upstream Discussions link.
- Make verification checkboxes match commands that exist in Quill after this integration.

### Dependabot

Retain `.github/dependabot.yml` for GitHub Actions updates only.

- Schedule weekly updates.
- Use the `Asia/Seoul` timezone.
- Keep the open pull request limit small to avoid maintenance noise.

### AGENTS.md

Retain and rewrite `AGENTS.md` as a repository-level maintenance guide for Quill.

It must describe:

- Quill's direct `swiftc` and Make architecture.
- The current Quill source and test layout.
- The sharded test workflow.
- `self-signed-release.yml` as the official release path.
- `release.yml` as the reserved notarized path.
- Sparkle, `Quill.dmg`, Google Calendar OAuth, and stable release ordering as protected contracts.
- Privacy rules for transcripts, audio, screenshots, selected text, credentials, provider responses, and local files.
- The requirement to use synthetic fixtures and avoid live AI calls in tests.

It must not copy FreeFlow-specific repository paths or grant agents unconditional permission to publish releases, tags, or external content.

## Build and CI Changes

Quill already has a broader sharded test workflow in `.github/workflows/tests.yml`. The new upstream `.github/workflows/check.yml` will not remain as a second full test workflow because that would duplicate CI and weaken the existing test topology.

Instead:

### Makefile

Add these common targets while preserving all existing targets:

- `validate`
  - Validate `Info.plist` and entitlements with `plutil`.
  - Parse repository shell scripts with `bash -n`.
  - Parse GitHub YAML files.
- `check`
  - Run `validate` and the existing complete `test` target.

The existing test shards, full-source runners, build metadata, native Whisper, llama.cpp, Sparkle, and localization targets remain unchanged unless wiring a new focused test requires a minimal addition.

A new upstream-wide `swiftc -typecheck -warnings-as-errors` command will only be retained if it can reuse Quill's real compile flags and dependencies without creating a parallel build definition. Otherwise Quill's existing compilation paths remain authoritative.

### GitHub Actions

Extend `.github/workflows/tests.yml` with a repository validation job rather than retaining `.github/workflows/check.yml`.

The validation job will:

- Run `make validate`.
- Run `git diff --check` for pull request changes.
- Remain read-only with `contents: read`.
- Participate in the existing aggregate success job so skipped or failed validation cannot be hidden.

## Release Workflow Hardening

Apply the security improvements consistently to:

- `.github/workflows/dev-release.yml`
- `.github/workflows/manual-release.yml`
- `.github/workflows/release.yml`
- `.github/workflows/self-signed-release.yml`
- `.github/workflows/tests.yml`

### Dependency pinning

- Pin `actions/checkout` to the upstream-approved `v7.0.1` commit SHA.
- Set `persist-credentials: false` on every checkout.
- Pin `softprops/action-gh-release` to the upstream-approved `v3.0.2` commit SHA wherever it is used.
- Preserve existing pinned actions such as `actions/cache` unless the upstream range explicitly updates them.

### Scoped Git authentication

Workflows that create or move tags must not rely on checkout-persisted credentials.

Only the tag push step will:

1. Receive `${{ github.token }}` through an explicit environment variable.
2. Install a temporary repository-local HTTP authorization header.
3. Push the required tag.
4. Remove the authorization header through a shell trap.

No credential may remain configured for later build, signing, release, or cleanup steps.

### Build tool installation

Quill's Makefile creates DMGs with the system `hdiutil` tool and does not use `create-dmg` or `fileicon`. Release workflows must not install those unused Homebrew packages or inherit the upstream `aws/tap` workaround.

### Protected Quill release contracts

The integration must retain tests or add assertions for all of the following:

- `CODESIGN_IDENTITY=Quill` in the official self-signed path.
- Google Calendar OAuth client ID and secret passed to both app and DMG builds.
- Sparkle appcast generation and EdDSA signing.
- Both `Quill.dmg` and `appcast.xml` in official stable releases.
- Existing version and build metadata from `version.mk`.
- Stable release preflight and latest-release verification.
- The shared stable-release concurrency group.
- Manual prereleases remaining outside Sparkle automatic updates.
- The notarized workflow remaining available for a future transition.

Existing workflow contract tests in `BuildMetadataTests.swift` and `ManualReleaseWorkflowTests.swift` should be extended before creating redundant test executables.

## Upstream Test Coverage Adaptation

Upstream's unified `TestMain.swift` runner is not adopted because Quill already has a larger sharded and full-source test topology.

For each upstream test file, compare cases against existing Quill tests and port only missing coverage:

- `LLMCooldownManagerTests.swift`: merge the add/add conflict by retaining Quill cases and adding missing upstream boundary cases.
- `ShortcutCoreTests.swift`: add missing matcher or session cases to existing shortcut tests.
- `ModelConfigurationTests.swift`: add missing model and think-tag cases to the existing configuration tests.
- `SemanticVersionTests.swift`: add missing ordering and parsing cases to the existing update/version tests.
- `AppContextServiceTests.swift`: do not restore the deleted standalone runner unless necessary; move missing cases into current AppContext tests.
- `TestSupport.swift`: reuse existing Quill assertion conventions rather than adding a second general-purpose support layer unless a shared helper clearly eliminates duplication.

All fixtures must be synthetic and deterministic. Tests must not call live providers or include real user data.

## Transcript Text Processing Design

### Parser boundary

Introduce or adapt a pure parser that returns both transcript text and provider language metadata. The service layer remains responsible for applying `TranscriptTextNormalizer` and resolving `SpokenLanguage`.

Required behavior:

1. A valid JSON object with a string `text` field returns that text and optional `language`.
2. Hallucination filtering receives the original JSON segment metadata.
3. A normal non-empty UTF-8 plain-text response remains supported.
4. Empty or invalid UTF-8 responses produce a typed invalid-response error.
5. After trimming whitespace and an optional UTF-8 BOM, a payload whose first character is `{` or `[` but which fails JSON parsing produces a typed invalid-response error instead of being pasted as transcript text.
6. A valid JSON value without a string `text` field produces a typed invalid-response error so provider error envelopes cannot become transcript text.

Only a leading `{` or `[` marks a failed payload as malformed JSON. Braces elsewhere in ordinary dictated plain text remain supported.

### Hallucination filtering

Retain Quill's deliberate exclusion of the overly broad `"you"` phrase from the upstream allowlist. Genuine one-word `You.` dictation must remain preserved even when segment metadata reports a high no-speech probability. Other stock hallucination phrases keep the metadata guard and are suppressed only when the first segment reports `no_speech_prob >= 0.1`.

### Output sanitization

Move directly testable output cleanup into a pure helper when this can replace private duplication in `PostProcessingService`:

- Post-processed transcript: trim, remove one pair of wrapping quotes, and map exact uppercase `EMPTY` to an empty string.
- Verbatim translation: trim and remove wrapping quotes, but preserve literal `EMPTY`.
- Command mode: trim only and preserve quotes.

### Instruction-execution detection

Keep `InstructionExecutionDetector` as the authoritative implementation. Do not replace it with the simpler upstream detector.

Retain:

- Korean and Spanish assistant preambles.
- Leading punctuation and filler normalization.
- Existing token overlap behavior.
- Output-language behavior already covered by Quill tests.

Port upstream examples only when they add coverage not already present.

## Conflict Resolution

Expected conflicts and resolution rules:

- `.gitignore`: retain all existing Quill ignores and normalize the final newline.
- `Makefile`: retain Quill's complete build/test system; add only compatible validation and new focused test wiring.
- `Sources/PostProcessingService.swift`: preserve current backend, retry, and guard changes; route private sanitization through the tested pure helper if introduced.
- `Sources/TranscriptionService.swift`: preserve language metadata, normalization, timeout handling, chunking, and provider behavior; extract only pure response interpretation.
- `Tests/AppContextServiceTests.swift`: keep Quill's deletion and relocate missing upstream cases into current tests.
- `Tests/LLMCooldownManagerTests.swift`: union the non-duplicate regression cases.

Automatically merged workflow files still require semantic review even when Git reports no textual conflict.

## Verification Plan

### Focused verification

After maintenance and workflow changes:

- Run build metadata and release workflow contract tests.
- Run `make validate`.
- Confirm YAML parsing and `git diff --check` behavior.

After transcript changes:

- Run the new transcript core tests.
- Run existing instruction-execution detector tests.
- Run transcription and post-processing regression tests.

### Final verification

Run:

```bash
make validate
make test
git diff --check
make ARCH="$(uname -m)" CODESIGN_IDENTITY=Quill
```

Then run a local code review at medium effort before proposing a pull request.

Release workflows, tags, releases, signing-secret access, and workflow dispatches are not executed during verification.

## Success Criteria

The integration is complete when:

- `upstream/main` through `4c6a557` is present in branch ancestry.
- All expected merge conflicts are resolved according to this design.
- Quill's product identity, release strategy, Sparkle compatibility, OAuth credentials, local AI, transcript normalization, and language detection remain intact.
- Upstream workflow hardening is applied to every equivalent Quill workflow.
- Missing upstream regression coverage is integrated without duplicating Quill's test architecture.
- `make validate`, `make test`, `git diff --check`, and the signed local app build pass.
- The original `main` checkout and its unrelated untracked files remain unchanged.
- No tag, release, workflow dispatch, push, or pull request is created without separate authorization.

## Rollback

Implementation occurs in an isolated worktree, so abandoning the integration does not alter `main`. Maintenance/release and transcript adaptations remain separate commits so either area can be reverted independently after the merge. No persistent data migration or settings migration is introduced.
