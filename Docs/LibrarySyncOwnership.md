# iCloud sync and legacy Template Mode links

The Mac sync inbox contained a legacy Template Mode record pointing to an
ordinary document in the same Space. The template gallery already recognizes
that link: the template ID is `template-mode-<document ID>` and the ordinary
document has no `templateID` backlink. The final sync ownership check expected
every template root to have a backlink. It rejected that record and rolled
back the import transaction, leaving the batch in the inbox.

- `Vellix/Spaces/SpaceOwnership.swift`: Recognizes the same legacy link as
  the template gallery. Cross-Space roots and incorrect template backlinks
  still fail. No record is moved or converted into a template document.
- `Vellix/VellixTests/LibrarySyncTests.swift`: Adds a sync round-trip
  regression for the legacy link and checks the document stays ordinary.

The live Mac database was inspected read-only; nothing was changed in the
library or CloudKit. No builds or tests were run. No editor bundle rebuild is
needed for this fix.

## Why the Mac still showed older pages

A read-only comparison of the connected iPhone and Mac found the same
Penned library ID and iCloud account on both. The Mac inbox had drained,
but the iPhone was still paused on the same Space validation error. It
had 11 incoming records waiting and 584 local changes queued, including
38 document updates and 42 document tombstones. The old template-root
rule flagged one mismatch in the iPhone's waiting batch; the corrected
rule flagged none. Both devices' live data was left unchanged.

## Automatic recovery

An old pause used to stop engine startup before the app could apply the
fixed validator. The iOS and Mac apps now revalidate the saved inbox on
startup for this exact legacy pause. After successful validation, they
clear that pause and refresh the fetch checkpoint without clearing the
upload queue or recreating the existing CloudKit zone. Normal foreground,
edit, and push triggers continue to sync without a settings action.

- `Vellix/Sync/LibrarySyncEngine.swift`: Serializes startup with other
  requests, validates the saved inbox before resuming, and automatically
  retries temporary startup failures with backoff. Once running,
  CloudKit's engine retains its existing retry handling.
- `Vellix/Sync/LibrarySyncStore.swift`: Identifies and clears only the old
  ownership pause, without changing queued changes.
- `Vellix/Sync/LibrarySyncImport.swift` and
  `Vellix/Spaces/SpaceOwnership.swift`: Distinguish new invalid ownership
  relationships from the historical pause. Genuine validation failures
  still stop sync.
- `Vellix/VellixTests/LibrarySyncTests.swift`: Covers retaining queued
  edits and not clearing unrelated pauses or removed-zone protection.

Install the updated native builds over the existing apps. The fix does
not require **Retry Sync**, **Sync Now**, a restore, or a database reset.
User-selected pauses and account or data-safety failures are not bypassed.
Live automatic recovery and cross-device queue drain remain unverified.
