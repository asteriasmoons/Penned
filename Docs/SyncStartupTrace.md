# iPad Sync Startup Trace

Dashboard was already older on the iPad before the update. The iPad's retained
CloudKit payload confirms that it prepared the two-card revision for upload
after the updated app launched. This trace is for finding what made that old
body sendable: an existing dirty record, a launch-time write, an editor save,
or a sync conflict that put the old body back in the outgoing queue.

## Physical iPad Run

Use your existing iCloud account, Penned library, and physical iPad. The Mac
you already use supplies the newer copy. Use a newly created disposable
document, not Dashboard or a document you need. The trace logs only the
specified document's metadata; normal library sync still runs.

1. Create a disposable document on the Mac, add a couple of blocks, and
   confirm that version appears on the iPad. Record the document's UUID:
   **Copy Deeplink** in the share sheet gives you a link with the UUID after
   `penned://document/` and before `?`.
2. Take the iPad offline (Wi-Fi and cellular off) and force-quit Penned.
   On the Mac, add several blocks to the disposable document and let that
   edit upload. Do not edit the stale copy on the iPad.
3. In Xcode's **Vellix > Edit Scheme > Run > Arguments**, add the launch
   argument below. Use a USB connection and install over the existing Debug
   app without deleting it or clearing its data. Reconnect the iPad just
   before running the new build, while Penned is still force-quit, so startup
   can reach the account and CloudKit. Leave the disposable document unopened
   and let Penned sync automatically for at least a minute. Do not press
   Sync Now on the iPad for this capture.

   ```text
   -PennedSyncTraceDocumentID <test-document-uuid>
   ```

4. Filter the console for `[PENNED-SYNC-TRACE]`. If Xcode misses startup, copy
   `Library/Application Support/Vellix/PennedSyncTrace.log` from the app's data
   container. Collect it before the next traced launch, which replaces it.
   Remove the launch argument when finished.

## Read The Sequence

- `db.beforeMigration`: persisted live body, outbox (including dirty flag
  and mutation token), inbox, acknowledged baseline, and latest snapshot.
- `db.commit`: what changed and which Swift write or migration committed it.
  `editor.selectRequested`, `editor.load`, `editor.bridgeUpdate`,
  `editor.bridgeSnapshot`, and `editor.saveAttempt` identify an editor write.
- `cloud.incoming` and `sync.decision`: whether the current server body arrived
  and how the import handled it. `cloud.uploadCandidate`,
  `cloud.staleUploadBlocked`, `cloud.uploadPrepared`, `cloud.uploadBatch`,
  and `cloud.acknowledgment` distinguish eligibility, staging, submission to
  the engine, and server acknowledgment. Match the mutation tokens between them.

The trace watches a single document on iOS Debug builds. It emits timestamps,
sequence numbers, block counts, abbreviated hashes, and source locations, not
document text, titles, raw CloudKit tokens, or account identifiers. The local
file keeps the first 1,500 events. A clean run on the current source shows how
the current safeguards handled that run; it does not prove the old build's
first offending write. No editor bundle rebuild is needed for these hooks.
