# Penned Spaces

## Ownership and Persistence

Spaces extend the existing GRDB/SQLite database. There are no separate databases,
SwiftData models, or replacement document/editor stores.

Migration `v16_independent_spaces` is appended after the existing migrations. It:

- Adds template Space ownership and backfills previously unowned content into
  Personal, preserving valid existing Space assignments and stable content IDs.
- Repairs parent ownership in folder and document trees, retaining content and
  detaching cyclic hierarchy edges rather than deleting records.
- Keeps collections attached to their actual containing documents. Entries remain
  nested documents, and fields, views, values, and Kanban configuration retain IDs.
- Adds ownership-required and relationship triggers for documents, folders,
  templates, collection membership, and event-note associations. Existing optional
  Swift fields remain compatible with legacy decoding; persisted ownership cannot
  be null or reference a nonexistent Space.
- Stores a migration/default Space reference in `spaceDefaults`.
- Rebuilds the event-note association table with preserved IDs and uniqueness on
  `(spaceID, eventKey)`, allowing independent notes for the same external event.
- Adds scoped lookup indexes and a persistent `attachmentCleanup` queue.

Whole-tree transfers use a transaction-local ownership-operation flag so related
rows can be updated together. Required ownership remains enforced. Full relational
validation and `PRAGMA foreign_key_check` run before the flag is reset and the
transaction commits. Any failure rolls the entire operation back.

Collections derive their Space from `collections.documentID`. Attachments,
snapshots, tasks, and task history retain their existing document relationships.
The global saved-style library has no Space owner and is not duplicated or deleted.

## Active Space and Navigation

`AppEnvironment` centrally configures the repository scopes. The active Space ID
is persisted under `penned.activeSpaceID`, restored and checked before the first
library refresh, and falls back to a valid non-archived Space. If restoration fails,
repositories receive an unavailable scope, not an unfiltered global scope, and live
startup reports the database failure.

Navigating between Home, Calendar, documents, folders, templates, Starred, Recents,
and Trash does not change the active Space. Native switchers and management sheets
reuse Penned's typography, colors, icon picker, forms, menus, and navigation.

Switching freezes editing, waits for tracked editor operations, commits title and
rich-text changes, and proceeds only after successful saves. A failed save retains
the outgoing Space and editor. Pending navigation is cancelled; old editors are
removed only after committing. Search, selection, sheets, collection observation,
preview presentation, and Calendar generations are reset before scoped content is
presented. Existing editor presentation-readiness behavior is retained.

New Spaces contain no sample documents, folders, collections, or templates. The
existing explicitly requested SwiftUI preview fixture remains debug-only.

## Isolation

Library, folder, template, task, search, and Trash queries filter by Space in SQL.
Direct navigation, property edits, snapshots, attachments, and collection mutations
validate ownership. Embedded page and collection references cannot resolve another
Space's content. Legacy same-Space collection references remain supported.

Internal maintenance repositories may be deliberately unscoped. In particular,
notification scheduling reads tasks across every non-archived Space independently
of the library's selected Space. Archived Spaces keep all content but do not schedule
reminders. Notification navigation resolves current ownership, safely switches
Spaces, and opens the existing document using its normal editor readiness gate.
Unavailable, archived, trashed, and deleted destinations are rejected safely.

Apple Calendar events remain external data and are not modified. Penned's task
agenda and event notes are Space-scoped. Note identity fallback matching includes
the Space. Transferring a note into a Space that already has a note for that event
is rejected atomically with a clear error; neither authored note is merged or lost.

## Move, Copy, Archive, Delete

- Move to Space transfers whole document trees, folder hierarchies and their pages,
  or complete editable template trees, including inactive/trashed descendants.
  Document identities, collections, values, tasks, attachments, and history remain.
- Copy to Space creates independent document, template, folder, collection, field,
  view, attachment, and snapshot records. Internal document/collection references,
  field filters, Kanban assignments, card order, and image paths are remapped.
  Task copies follow the existing independent-task behavior: fresh task/occurrence
  identities and fresh completion history, preserving schedule configuration.
- Borrowed files owned by a page outside the transferred hierarchy are copied into
  the destination's attachment ownership. Original owners and files remain intact.
  Asset references shared inside a copied hierarchy are remapped before presentation.
- References outside a moved hierarchy remain stored but cannot resolve across
  Spaces. A copied page reference without a copied target is detached by the existing
  structured-template copy logic, never linked back to an editable source page.
- Archive keeps all records and provides Restore. Archiving the active Space saves
  first and selects another valid Space, creating an empty Personal fallback only
  when necessary. Reminder reconciliation excludes archived Spaces and resumes on
  restoration.
- Delete requires an explicit destructive confirmation. Database deletion includes
  Trash, nested pages, collections, templates, event-note associations, tasks,
  completions, snapshots, FTS rows, and attachment records. Deleted cached editors
  and previews are removed. Other Spaces and global styles are retained.
- File cleanup is queued in the database transaction and performed after commit.
  Failed cleanup remains queued for retry, including after relaunch. Remaining
  document ownership and exact parsed global-style image paths are checked before
  deletion. Unsafe paths are retained rather than removed.

## Changed Files

- `Spaces/SpaceOwnership.swift`: migration, ownership guards, default ownership,
  integrity checks, and guarded transaction support.
- `Spaces/SpaceOperations.swift`: Space metadata, fallback, transfers, deep-copy
  asset/reference preservation, deletion, and cleanup recovery.
- `Spaces/SpaceViews.swift`: switcher, management, name/description/icon editor,
  archive/restore/delete controls, ordering, and transfer destination sheets.
- `Persistence/AppDatabase.swift`: registers migration v16 without editing v1-v15.
- `Documents/DocumentRecords.swift`: template ownership.
- `Documents/DocumentRepositories.swift`: scoped queries/writes, inherited ownership,
  template creation/instantiation, and reusable complete tree cloning.
- `App/AppEnvironment.swift`: persisted active scope, save-before-switch coordination,
  transfers/deletion/archive, notifications, and safe startup.
- `App/VellixShellView.swift`, `Documents/HomeView.swift`,
  `Documents/DocumentBrowserView.swift`, `Documents/FolderLibraryViews.swift`,
  `Calendar/CalendarView.swift`: native workspace navigation and transfer actions.
- `Search/DocumentSearchService.swift`: scoped FTS and template search.
- `Tasks/DocumentTaskRepository.swift`: scoped task reads and writes plus deliberate
  non-archived global scheduling queries.
- `Tasks/TaskNotificationsManager.swift`: lazy system-center initialization so disabled
  in-memory environments do not access a real notification center.
- `Calendar/CalendarEventNoteRepository.swift`, `Calendar/CalendarModel.swift`:
  independent associations and generation-safe workspace refresh.
- `Collections/CollectionRepository.swift`, `Collections/CollectionStore.swift`:
  ownership-checked references/mutations, snapshot remapping, and observation reset.
- `Collections/CollectionDocumentIntegration.swift`: tracks in-flight creation.
- `Documents/DocumentPreviewContent.swift`, `Documents/DocumentPreviewCache.swift`:
  scoped resolution, ownership-aware fingerprints, cancellation, cache cleanup.
- `Editor/TipTapEditorSession.swift`, `Editor/DocumentEditorView.swift`: pending-operation
  barriers and successful title/content capture before workspace changes.
- `Editor/TipTapWebView.swift`: platform guard for the existing iOS-only inline-media
  configuration; iPhone/iPad behavior is unchanged.
- `VellixTests/SpaceTests.swift`, `VellixTests/SpaceEnvironmentTests.swift`: persistence,
  ownership, transfers, cleanup, application state, Calendar, and navigation regressions.
- `VellixTests/FolderLibraryTests.swift`: expectations now account for required default
  ownership and Space-prefixed search locations.
- `Scripts/test-collections.mjs`, `Vellix.xcodeproj/project.pbxproj`: native test harness
  coverage and application/test target membership.

The rich-text table implementation, editor JavaScript/bundle, global document-style
implementation, existing appearance system, and external calendar data are unchanged.

## Verification

The native headless suite compiles production persistence, editor/application-state,
preview, task, and Calendar sources, with existing native preview helper declarations
extracted from production files. It does not replace the repositories or AppEnvironment
with mocks. Tests use temporary databases, files, and isolated preferences.

The most recent completed run before this document was written passed 100 tests in
seven suites. Coverage includes migration, empty creation, ownership enforcement,
disk reopening, active preference restoration, Home/Calendar/search isolation,
move/copy hierarchies, cross-root references, independent assets, collection integrity,
archiving/restoration, notification destination switching, pending and failed saves,
stale navigation, deletion, global-style image preservation, and cleanup failure/retry.

The final iOS app and test-target `build-for-testing` succeeded, without installing
or launching Penned. Xcode retains the existing legacy `NSCalendarsUsageDescription`
warning; the current full-access Calendar usage description is configured. Physical notification delivery, Apple Calendar
authorization, actual force-quit/relaunch on a device, and iPhone/iPad visual interaction
have not been verified by these headless tests. No CloudKit synchronization is claimed.

## Settings and Custom Space Images

The library's top-left image now opens `Spaces/PennedSettingsView.swift`. Settings
uses the supplied black, grouped-row layout and asset icons. Its Space name opens
a searchable bottom sheet with uploaded images, a selected checkmark, and Create
Space. Existing Templates, Folders, Space editing, and Space management are wired;
the other requested Settings destinations explicitly show "Not available yet".
The footer uses Penned branding and the real bundle version, not the reference
app's branding or an invented subscription status.

`Spaces/SpaceImage.swift` renders uploaded images or an initial when no image is
set. `SpaceViews.swift` accepts images from Photos and Files instead of the icon
library. Imports are cancellable and validated, orientation-corrected, and resized
to a maximum of 512 pixels off the main actor. Migration `v17_space_images` adds
the optional `spaces.iconImageData` BLOB; image saving and removal use existing
Space record persistence. No document or attachment identities are changed.
Images are deleted transactionally with their Space, without filesystem cleanup.
The v16 helper retains its original SQL column set so newer record fields do not
break older database upgrades. Legacy icon names remain stored but are no longer
used as Space images.

This follow-up also changes `Documents/LibraryChrome.swift`,
`Documents/DocumentRecords.swift`, `App/AppEnvironment.swift`,
`App/VellixShellView.swift`, and `Persistence/AppDatabase.swift`. `SpaceTests.swift`
adds image migration/removal coverage and extends disk-reopen coverage. These new
tests have not been run, and the new UI has not been built or launched. The
100-test run described above predates this Settings follow-up.
