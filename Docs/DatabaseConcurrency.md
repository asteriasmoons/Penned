# Database Concurrency and CloudKit Recovery

The November 15, 2026 iPhone reports were described as a GRDB non-reentrant
access trap reached from `LibrarySyncEngine.validateLocalContext()`. GRDB
7.11.1 permits ordinary overlap between a WAL reader and a writer. This trap
means an access re-entered a GRDB scheduling context that didn't permit it, not
that a background write simply happened to be in progress. The upstream
callback that put the original ownership read in that context is not confirmed.

The temporary `unsafeReentrantRead` check was removed. It can borrow the
current connection and transaction, or read outside the normal snapshot.
Penned also changes the connection's SQL library scope, so borrowing it across
workspace scopes is unsafe even when the caller only intends to read.

## Database Rules

- Start a top-level read with `AppDatabase.read`, or use `readAsync` to wait
  for a GRDB reader without blocking an actor. Both use a normal read
  snapshot. GRDB still manages parallel readers and a single writer.
- Inside a read or write closure, pass the supplied `Database` to SQL
  helpers. Do not call a repository entry point that opens another access,
  switch library scope, run async work, wait on another queue, or let the
  connection (including cursors) escape the closure. A nested access through
  Penned now throws before reaching GRDB; an uncaught write error rolls back.
- `write` continues to commit authored rows, the local journals, and derived
  task, tag, and preview descriptors in a single transaction. `writeMetadata`
  still skips derived-index updates. The lease is checked after admission and
  again before commit. SQLite gets a short busy timeout; the app does not
  replay arbitrary repository closures that may have side effects.
- Transaction callbacks may use the supplied connection for transaction-local
  work. They must not synchronously call UI, repository, or sync entry points.
  Post-commit UI events and journal wakeups are delivered asynchronously.

## CloudKit Rules

- Journal edits, editor and workspace transitions, foreground, push, and manual
  requests feed the same coalesced sync drain. Delegate events are awaited
  serially. The delegate does not start another fetch or send.
- Validate the live account before CloudKit transfers and the local binding
  using GRDB snapshots and again in the transactions that stage, apply, or
  acknowledge records. Ignore callbacks from retired engine instances.
- Stage downloaded records and assets durably before advancing the checkpoint.
  Incoming application can wait in the inbox while a workspace transitions
  or a document is protected by an active editor. The actual apply still uses
  the editor-protection snapshot on the main actor, with no suspension between
  checking protection and applying the transaction.
- A failed delegate operation fences off later checkpoints for that engine.
  A recoverable failure retries from the last durable checkpoint with backoff.
  The SQLite outbox is authoritative: final outgoing eligibility checks both
  mutation ID and staged conflicts in one read, and acknowledgments clear only
  the exact mutation sent. CloudKit and SQLite cannot commit atomically, so an
  interrupted pass may refetch or resend. Existing merge, tombstone, and
  duplicate-handling rules still apply.
- Temporary SQLite busy/interruption, transient CloudKit/network failures, and
  missing or temporarily inaccessible assets keep work queued. Ownership,
  integrity, and removed-zone failures are not retried blindly on launch. The
  known legacy ownership pause still has its existing targeted recovery.

## Console

Filter Xcode for `[PENNED-CRASH-LOGS]`. A nested call includes `access`,
`site`, and `nestedIn`. For sync, look for `phase=stageIncoming`,
`applyInbox`, `checkpoint`, `prepareOutgoing`, or `acknowledgeOutgoing`.
`workRetained`, `retryScheduled`, and `recovered` track a temporary failure;
`syncPaused` indicates a non-retryable error. Logs contain error types and
numeric codes, not SQL, arguments, document data, paths, or account IDs.

Sources: [pinned GRDB database reader](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/Core/DatabaseReader.swift),
[CloudKit delegate ordering](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8),
and [CloudKit checkpoint contract](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate).

There is no schema or wire-format change and no editor bundle change.
Existing pagination, descriptor backfill, search, and preview paths are
unchanged. Large inbound transactions can still contend for the writer and
take time to apply. No builds, tests, or live sync operations were run.
