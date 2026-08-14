# Remaining Note Asset Store Migration Design

## Context

Issue #314 introduced `NoteAssetStore` as an instance-owned boundary for note audio and transcript files. It migrated the call sites that were not pinned by exact-source-text tests, while leaving the most safety-sensitive paths in `AppState` unchanged.

Those remaining paths include imported-audio storage, stopped-recording adoption and copying, audio-only persistence failure cleanup, cloud/history deletion cleanup, startup trimming, and stopped-transcription completion cleanup. Four test suites currently protect these paths partly by matching exact helper names, signatures, and call-site text:

- `AudioImportFileCopyTests`
- `CombinedRecordingNormalStopIntegrationTests`
- `AppStateCloudTranscriptionCleanupSourceTests`
- `AppStateRecordingJournalIntegrationSourceTests`

Changing the storage boundary without first replacing those assertions would either break tests for textual reasons or encourage updating assertions to mirror the new implementation without proving the safety behavior. Issue #324 completes the storage boundary by converting those contracts to behavior first and then migrating the call sites.

## Goal

Make `NoteAssetStore` the single production boundary for storing, adopting, loading, and deleting note audio and transcript assets while preserving current ownership, ordering, recovery, and user-facing behavior.

## Scope

- Replace exact call-site-text assertions in the four named suites with behavioral coverage wherever the behavior can be exercised deterministically.
- Retain only narrow, documented structural checks for invariants that cannot be reproduced without disproportionate UI, recorder, filesystem-race, or OS security-scope machinery.
- Migrate remaining audio and transcript operations in `AppState` to its instance-owned `NoteAssetStore`.
- Remove obsolete static save/delete helpers after all production and test callers have moved.
- Preserve current storage paths, file names, history metadata, cleanup ordering, failure behavior, and journal ownership rules.

## Non-goals

- No recording durability or journal format change.
- No cloud transcription, history archive/recovery, Retry, or Meeting Summary workflow extraction.
- No public `NoteAssetStore` redesign beyond the smallest operations required by current call sites.
- No user-facing copy or UI change.
- No source-test migration outside the four named suites unless a directly adjacent assertion blocks the same asset call site.

## Architecture

### One asset boundary

`AppState` remains responsible for deciding when an asset should be stored, adopted, or removed. `NoteAssetStore` owns path construction and filesystem mutation.

```text
AppState / existing workflow
             │
             ▼
       NoteAssetStore
       ├─ save imported audio
       ├─ adopt or save stopped recording
       ├─ save/load transcript
       └─ delete audio and transcript assets
```

The migration does not introduce a second store, global override, or service locator. Every operation uses the `NoteAssetStore` derived from the originating `AppState` storage layout.

### Imported audio

Imported audio retains its existing asynchronous and security-scoped flow:

1. `AppState` resolves the transcription choice and captures the originating storage dependencies on the Main Actor.
2. The security-scoped source is accessed and copied outside synchronous UI work.
3. `NoteAssetStore` selects the unique destination and saves the file.
4. If later transcription or history persistence fails, cleanup removes only the asset created for that job when it is safe and unreferenced.

The store must not make security-scope lifetime implicit. If the current helper owns `startAccessingSecurityScopedResource` and `stopAccessingSecurityScopedResource`, either the migrated operation retains that explicit lifetime or receives a narrow access collaborator that tests can observe.

### Stopped recording

A stopped recording can already be the promoted canonical WAV in the final audio directory. That case remains an adoption, not a copy:

1. Recognize that the source URL already belongs to the destination audio directory.
2. Return its existing file name and URL without copying.
3. Otherwise save it through `NoteAssetStore` using the existing naming behavior.

This preserves the recording-journal finalizer contract and avoids duplicate files.

### Asset cleanup

History, cloud-transcription, and startup cleanup preserve the existing transaction order:

1. Snapshot the assets associated with entries that will be removed.
2. Perform cloud cancellation, checkpoint invalidation, history mutation, or other required preceding state changes in their existing order.
3. After the relevant mutation succeeds, ask `NoteAssetStore` to remove audio and transcript assets.
4. Preserve an asset if another surviving history entry references it.
5. Continue independent cleanup after an individual best-effort deletion fails, without broadening the deletion set.

`AppState` may still compute reference sets and sequencing. The store performs the filesystem operations but does not infer history ownership from global state.

### Audio-only persistence failure

The failure path preserves the ownership distinction:

- Journal-owned or promoted files are retained when the existing contract requires recovery preservation.
- A newly copied file can be deleted only when the failed operation introduced it and no history entry references it.
- Failure cleanup never deletes a broader directory or a file whose ownership is ambiguous.

## Data Flow

### Audio import

```text
selected source URL
  → captured NoteAssetStore/security-scope access
  → asynchronous save
  → transcription/history work
  → success keeps asset
     failure removes only newly created safe asset
```

### Stopped recording and audio-only persistence

```text
finalized recording URL
  → already canonical? adopt unchanged
  → otherwise save via NoteAssetStore
  → persist history
  → on failure apply journal/reference ownership guard
  → delete only newly copied unreferenced audio
```

### History and cloud cleanup

```text
entries selected for removal
  → snapshot audio/transcript names
  → cancel/invalidate/mutate in existing order
  → derive surviving references
  → NoteAssetStore best-effort deletion
```

## Error Handling

- Audio and transcript save failures retain existing user messages and history outcomes.
- Cancellation remains cancellation and is not remapped to a generic storage failure.
- Deletion failure does not trigger wider cleanup or deletion of original/journal files.
- Best-effort cleanup may continue with the next independent asset after one failure, matching current behavior.
- Filesystem paths and private error details are not added to durable user metadata or public diagnostics.
- Ambiguous ownership always favors preservation.

## Testing

### AudioImportFileCopyTests

Replace exact helper-signature and call-site assertions with behavior that uses temporary source and destination directories. Verify that:

- the imported bytes reach the expected stored file,
- naming and collision behavior remain compatible,
- failure leaves no falsely reported saved asset,
- and security-scope access lifetime is balanced through a narrow observable collaborator if direct OS behavior cannot be deterministic.

Keep only a narrow structural assertion if needed to prove the import path does not perform synchronous filesystem copying on the Main Actor. It must describe the async boundary rather than freeze an exact helper call.

### CombinedRecordingNormalStopIntegrationTests

Use a real promoted WAV in the final audio directory and an observable copy operation. Verify that:

- the returned URL and file name are unchanged,
- bytes remain intact,
- and no copy operation occurs.

Add the non-promoted companion path to prove an external finalized file is saved through the store.

### AppStateCloudTranscriptionCleanupSourceTests

Move cleanup behavior to a testable collaborator or existing storage-safety harness. With temporary audio/transcript files and recorded cloud/history dependencies, verify:

- both asset kinds are deleted after the required preceding operations,
- shared surviving references are preserved,
- single-delete, clear, and trim paths use the same cleanup behavior,
- and a deletion error does not expand the deletion set.

Retain source scanning only for a transition-order invariant that cannot be driven through the available API, and document why.

### AppStateRecordingJournalIntegrationSourceTests

Exercise persistence failure with temporary journal-owned, newly copied, and shared files. Verify that:

- newly copied unreferenced audio is removed,
- journal-owned audio is preserved,
- shared audio is preserved,
- and cleanup failure does not hide the original persistence outcome or delete additional assets.

### Store and propagation coverage

Extend `NoteAssetStoreTests` for any minimal operation added to support adoption, imported saves, or grouped deletion. Add AppState-level isolation coverage proving two storage layouts never cross-read or cross-delete assets.

## Implementation Sequence

1. Inventory every exact assertion in the four suites and classify it as behavior, narrow structural invariant, or redundant coverage.
2. Add failing behavioral tests for imported audio storage.
3. Migrate import storage to `NoteAssetStore` and remove its exact call-site assertions.
4. Add failing promoted/reused and copied stopped-recording tests.
5. Migrate stopped recording and audio-only persistence paths.
6. Add failing history/cloud cleanup and reference-preservation tests.
7. Migrate delete, clear, trim, startup, and completion cleanup paths.
8. Remove obsolete static helpers and any source markers that existed only as block boundaries.
9. Run focused suites, `make check-test-wiring`, `make test`, a production build, and `/code-review medium` exactly once.

## Delivery

Implement in the dedicated `worktree-issue-324-note-asset-store` worktree. Keep the PR limited to issue #324 and close it from the PR body. After merge, mark #324 complete in roadmap #321. Keep #317, #318, #319, #320, and #326 open unless implementation evidence requires an explicit scope update.
