# Freeze While Adding a Collection to a Template

## Symptom and Cause

The app became unresponsive while adding a collection in the template editor,
but the collection was present after restarting. The inspected save path has
a queue deadlock after the database commit, consistent with that behavior.

1. `CollectionCreateSheet.create()` captures/saves the editor, creates the
   collection, resolves its editor block, then captures/saves the resolved page.
   `resolveCollection` also posts a document snapshot for immediate persistence.
2. `DocumentEditorModel.captureAndSave()` reaches `saveCurrentContent()` on the
   main actor. That method synchronously waits for `penned.editor.persistence`
   so prior queued saves and the required flush complete in order.
3. `DocumentRepository.saveEditorJSON` calls `AppDatabase.write`. After the
   transaction commits, that method posted change notifications synchronously
   from whichever thread performed the write.
4. `LibrarySyncEngine` observes `.pennedCollectionsChanged` on `.main`.
   Notification delivery can therefore wait for main while main is waiting
   for the persistence queue. Task/calendar main-queue observers expose the
   same class of problem when task changes are present.

The wait cycle is:

```text
main actor -> synchronous persistence flush -> database commits
     ^                                            |
     |                                            v
     +----------- main-queue notification observer +
```

The write is committed before the blocking notification is posted. A restart
can therefore show saved content despite the previous UI freeze. The code-level
cycle is confirmed by inspection; no device stack sample or runtime reproduction
was collected, so the exact moment of this reported hang remains unverified.

Apple documents synchronous notification delivery in
[Communicating with Objects](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaFundamentals/CommunicatingWithObjects/CommunicateWithObjects.html)
and discusses synchronous main-thread queue waits in
[Understand and eliminate hangs from your app](https://developer.apple.com/videos/play/wwdc2021/10258/).

## Correction

`AppDatabase.write` still performs and commits its transaction synchronously.
For a background write, its existing change notifications are now submitted
as one asynchronous main-queue block, allowing the persistence queue to return
without waiting for a main-queue observer. Main-thread writes keep their existing
synchronous notifications.

Task, tag, and collection notifications retain their existing order and flags.
Only notifications are deferred, not the database write. Ordered saves, required
flushes, revisions, task/tag reconciliation, and CloudKit change records are
unchanged. Observers still receive the same notification names and scoped database
object, after commit. This also removes the same wait cycle from other synchronous
editor/template flushes using this persistence path.

No collection or document is deleted, recreated, or reset. The existing collection
creation sheet, template permissions, editor JavaScript, and synchronization
implementation remain unchanged.

## Files Changed

- `Vellix/Persistence/AppDatabase.swift`: defers background-write notifications
  to main without blocking the writer; retains synchronous main-thread behavior.
- `Vellix/VellixTests/CollectionTests.swift`: regression cases for a template
  collection save while main is deliberately unavailable, subsequent notification
  delivery, retained template/collection data, and unchanged synchronous delivery
  for main-thread writes. The deadlock check uses a bounded wait so regression
  failures do not permanently hang the test runner.
- `Docs/TemplateCollectionFreeze.md`: this cause, change, and validation record.

## Validation Boundary

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. Regression cases were added but not executed. Device confirmation of
the reported freeze is still required.

This is native Swift only. Rebuild the native app to include it; `npm run build`
and JavaScript bundle regeneration are not required. The user's completed list
work and document-cover layout were left unchanged.
