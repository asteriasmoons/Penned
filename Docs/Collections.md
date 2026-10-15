# Penned Collections

## Architecture

Collections use the existing GRDB database and document hierarchy. Migration
`v13_document_collections` adds five tables without changing or resetting existing
documents:

- `collections`: identity, containing document ID, independent name, selected view, creation date.
- `collectionEntries`: membership and manual ordering of real nested documents.
- `collectionFields`: stable field IDs, type, shared configuration, and schema order.
- `collectionValues`: one value per entry document and field, with ownership checks.
- `collectionViews`: named Table/Gallery/Kanban views, order, and independent configuration JSON.

A collection does not create its own document. Its entries are real nested documents
under the page containing the collection. Multiple collections may share that page
without sharing their memberships or field schemas. The containing page stores an atomic `collection`
node at its actual rich-text position. That node stores IDs only; document titles,
covers, field values, filters, and views are not copied into editor JSON.

The collection name opens configuration, never a separate collection page. Entry titles/cards open their
actual documents using the existing editor and navigation. Collection fields are a
native SwiftUI section beneath the title and above the existing editor, not movable
rich-text blocks. Existing inline properties remain separate and unchanged.

Migration `v14_embedded_collections` preserves legacy collection IDs, view IDs,
field IDs, values, and entry document IDs while moving ownership to the containing
page. Generated-only wrappers are moved to recoverable Trash; wrappers with authored
content remain ordinary pages with their writing and normal children preserved.
Foreign keys are checked before the migration commits. No user database is reset.

## Behavior

- Add Collection is available in the formatting insertion menu and slash menu.
- Creation names the collection and first view and selects Table, Gallery, or Kanban.
- Views can be selected, added, renamed, duplicated, reordered, deleted, and switched
  between Table, Gallery, and Kanban. The final view cannot be deleted.
- Each view stores its own visible-field order, filters, AND/OR mode, prioritized
  sorts, Gallery column count, cover visibility, and compact-card setting.
- Table columns have fixed managed widths and horizontal scrolling. They use a
  CSS-grid component, not the existing rich-text table engine or its resize controls.
- Gallery cards use the entry documents' actual covers. Missing covers have an
  image placeholder; inaccessible image files fall back to that placeholder.
- Gallery content and its centered add-entry icon scroll inside a transparent,
  unframed region capped at 420px. The header and following document content stay
  outside that region. Short galleries shrink naturally; edits preserve scroll position.
  Content subtly fades only at edges with more content to scroll into view.
- New entry documents use Penned's normal plain appearance, not the containing
  page's font, ink, backdrop, paper, theme, or cover. Each entry is independently styled
  through its own paintbrush menu. Migration `v15_independent_collection_entry_styles`
  resets existing page styling only when it still matches the containing page, ignoring
  cover settings for that comparison. Actual covers and independently edited styles remain intact.
- Native sheets edit Text, Number, Select, Multi Select, Date, Checkbox, URL, and
  Email values. Number bounds/steps and date/time settings reuse inline-property
  definitions. Select options reuse the existing option editor and color picker.
- Every field has a selectable icon using Penned's shared icon picker. Defaults are
  type-specific; chosen icons persist and appear in page fields, configuration, and table headers.
- Covers are managed only through the existing paintbrush/Styles menu. There is no
  additional Add Cover control in the anchored field section.
- Shared-field/option renames retain IDs and values. Removing assigned options or
  changing incompatible types requires explicit consent and clears only affected
  values/filters. Field deletion removes its values and view references, not pages.
- Entries can be renamed, duplicated, reordered, opened, and moved to Trash.
  Restoring them restores their collection membership and values. Moving an entry
  outside its collection is blocked rather than silently discarding its fields.
- Document/template tree copies create independent collections, fields, values,
  and views. Views inside each copy still share that copy's documents. Cover files
  are copied to the new document's attachment ownership.
- Collection edits update template dirty state through the existing editor cache.

## Loading and Scrolling

Only collections for the active document are observed. Table/Gallery projections
fetch document metadata and values, not full rich-text bodies. Entry editors and
thumbnails are not prewarmed for every collection row. Explicit normal page
references still resolve their documents.

Sorting prepares numeric/date keys once per entry. Table rendering starts with
100 entries and Gallery rendering with 40, with working Show More controls. Covers
are lazy images served through a cached, bounded, downsampled image scheme handler.
The latest page-end padding, top scroll clamp, and bottom overscroll remain unchanged.

Document selection owns Collections observation and seeds the cached editor session
directly. SwiftUI view disappearance does not clear the selected page's data. Lookup
also follows persistent collection IDs in document blocks, including legacy container
associations. Payload generation reloads missing snapshots from the repository instead
of returning an empty presentation simply because the cache was cleared.

## Native Kanban

Kanban is a native SwiftUI collection presentation embedded at the existing collection
atom's exact position. The editor reserves a transparent host and reports its bounds;
`DocumentEditorView` overlays `CollectionKanbanView` there. No Kanban cards or columns
are rendered in HTML. Switching back to Table/Gallery clears that native region.
Multiple collection blocks report independent bounds. Native content measurement
shrinks short boards and caps taller boards at 560 points, with a vertical SwiftUI
ScrollView for additional groups. Columns never scroll horizontally.

Every view's existing `configurationJSON` contains its column IDs/names/colors,
column order, collapsed states, document-to-column assignments, and per-column card
order. Existing saved JSON decodes with defaults for the new fields, preserving all
previous filters, sorts, and Gallery settings. No database reset or additional table
is required. Initial boards have one neutral Unassigned column, not example tasks
or automatically alternating colors. Newly created Table/Gallery entries appear
there until assigned. Reordering columns materializes prior implicit assignments
so existing cards never jump into a different group.

Columns have independent colors using Penned's existing full native color picker
and optional RGB hex input. Header chevrons persist collapse state; header and footer
plus controls open an inline title composer. Empty columns remain header-sized.
Dark cards show configured visible fields using shared values and stable select
option colors. Tags open existing value editors; titles open actual documents.
Card context menus provide entry editing/deletion, property editing, move-to-column,
and accessible up/down ordering. Drag/drop supports the same moves and ordering.
Saved sorting takes precedence over manual ordering; clear sorts before reordering.
Filters use the same AND/OR and typed operators as the other views.

Column placement belongs to the individual view, just like filtering and sorting;
it does not implicitly overwrite a Category or other document field. Editing titles,
properties, covers, or deleting/restoring documents still updates the shared data
used by all views. Duplicate views reuse the same documents. Copying a document or
template remaps assignments/order to the newly copied document IDs. Duplicating an
individual entry keeps its column, shared field values, and adjacent card position.
Column deletion
requires another destination and moves cards there without deleting any document.
The last column is protected. Mutations load current settings inside one database
transaction; stale settings sheets cannot overwrite newer board mutations.

Kanban changes are scoped to collection presentation and its bridge. Existing editor
blocks, rich-text tables, inline properties, page-end spacing, top scroll clamp, and
bottom overscroll are unchanged.

### Kanban File Changes

- Added `Vellix/Collections/CollectionKanbanView.swift`: native board, inline composer,
  card interactions, column management, and shared color-picker integration.
- Updated `CollectionModels.swift`: Kanban kind, backward-compatible configuration,
  and filtered/sorted/manual-order grouping of real entry summaries.
- Updated `CollectionRepository.swift`: transactional column/card commands, atomic
  entry creation/assignment, stale-setting protection, and copy remapping.
- Updated `CollectionStore.swift`: native-host-only bridge projection for Kanban.
- Updated `CollectionPropertySheets.swift`: expose the existing wrapping chip Layout;
  inline properties and their editors are unchanged.
- Updated `DocumentEditorView.swift`, `TipTapBridgeTypes.swift`, and
  `TipTapEditorSession.swift`: native placement/height bridge and overlay lifecycle.
- Added backend `src/native-collection-regions.js`; updated `src/collection-node.js`
  and `src/editor.js` for transparent hosts, bounds reports, and native resizing.
- Updated `Vellix/VellixTests/CollectionTests.swift` and backend
  `tests/collection-runtime.test.js` with persistence/integrity/placement regressions.
- Rebuilt backend `dist/tiptap.bundle.js` and synchronized
  `Vellix/VellixEditor.bundle/tiptap.bundle.js`; no rich-text table source changed.

## Files

Created:

- `Vellix/Collections/CollectionModels.swift`: records, typed values, filters, sorting.
- `Vellix/Collections/CollectionRepository.swift`: migration, transactional CRUD, ownership, copies.
- `Vellix/Collections/CollectionStore.swift`: live snapshots, projection, template-change callback.
- `Vellix/Collections/CollectionPropertySheets.swift`: value/schema sheets and shared chips.
- `Vellix/Collections/CollectionViewSheets.swift`: view management, visibility, filtering, sorting.
- `Vellix/Collections/CollectionDocumentIntegration.swift`: creation, entry actions, anchored fields.
- `Vellix/Collections/CollectionCoverSchemeHandler.swift`: actual document cover loading/cache.
- `Vellix/Collections/CollectionMigration.swift`: safe legacy wrapper/ownership migration.
- `Vellix/Resources/VellixSymbolCatalog.swift`: complete symbol library, categories, search, OS availability.
- `Vellix/Resources/SFSymbolCatalog.json`: generated Apple catalog metadata, not exported glyph images.
- `Scripts/sync-sf-symbol-catalog.mjs`: deterministic regeneration from the installed Apple SF Symbols app.
- `Vellix/VellixTests/CollectionTests.swift`: real repository, persistence, copying, cover tests.
- `Scripts/test-collections.mjs`: headless tests using the production persistence/domain sources.
- `Docs/Collections.md`: architecture and verification report.
- Backend `src/collection-node.js`: embedded interactive Table/Gallery renderer and bridge actions.
- Backend `tests/collection-runtime.test.js`: editor integration and interaction regression tests.

Modified:

- `Vellix/Persistence/AppDatabase.swift`: additive migration and change notifications.
- `Vellix/App/AppEnvironment.swift`: shared Collections store, template dirty-state integration,
  metadata-only collection-entry prewarming policy.
- `Vellix/Documents/DocumentRepositories.swift`: real-entry hierarchy/copy integration, cover ownership,
  optional metadata loading, and guarded entry moves.
- `Vellix/Editor/DocumentEditorView.swift`: insertion option, collection sheets, live bridge payloads,
  anchored fields, collection navigation; existing sizing/scroll limits are retained.
- `Vellix/Editor/DocumentEditorCache.swift`: refresh stale title/cover/style metadata when opening pages.
- `Vellix/Editor/TipTapEditorSession.swift`: request routing, queued payloads, resolution, explicit page links.
- `Vellix/Editor/TipTapBridgeTypes.swift`: typed collection bridge requests.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: collection-document reference/remapping support.
- `Vellix/Editor/TipTapWebView.swift`: cover URL-scheme registration.
- `Vellix/Editor/DocumentStyleSheet.swift`: optional direct cover-editor entry point.
- `Vellix/Editor/InlinePropertyEditorSheet.swift`: expose the existing option editor for reuse; inline behavior unchanged.
- `Vellix/Editor/NestedPageThumbnail.swift`: expose the existing theme-cover cache for reuse; rendering unchanged.
- `Vellix/Resources/VellixAssetIconLibrary.swift`: namespaced system icons alongside existing assets.
- `Vellix/Resources/VellixDesignSystem.swift` and `Vellix/Documents/LibraryChrome.swift`: render selected system/asset icons consistently.
- `Vellix.xcodeproj/project.pbxproj`: CollectionTests membership; production sources use the existing synchronized folder.
- Backend `src/editor.js`: collection node, insertion, slash option, and bridge commands.
- Backend `src/tiptap.html`: styles scoped to Collections, including horizontal touch scrolling.
- Generated backend `dist/tiptap.html`/`dist/tiptap.bundle.js` and native
  `Vellix/VellixEditor.bundle/tiptap.html`/`tiptap.bundle.js`: rebuilt/synchronized editor resources.

## SF Symbols

The shared picker has a separate Penned Icons / SF Symbols library menu and its own
category dropdown. The bundled Apple metadata contains all 9,524 names (including
variants and localized names), all 32 Apple category definitions, and an Other Symbols
category for names Apple does not classify. Search spans the entire SF library and
includes Apple's keywords. Newer symbols remain visible with their minimum OS version,
but cannot be selected on an unsupported OS. Only viewed symbols are rendered.
Glyphs use public `Image(systemName:)`, `UIImage(systemName:)`, and AppKit equivalents;
no private catalog APIs or glyph exports are used at runtime. Editor icons are rendered
through the existing native icon bridge, with namespaced CSS variables preventing
collisions between asset names and system names.

Regenerate with `node Scripts/sync-sf-symbol-catalog.mjs`; an alternate Apple metadata
directory may be supplied as the first argument. This is the complete installed
catalog, not a hand-selected subset. Future Apple releases require regenerating metadata.

## Verification and Boundaries

Run the headless repository tests with `node Scripts/test-collections.mjs`. They use
the existing local GRDB checkout; `PENNED_GRDB_PATH` can specify another checkout.
The runner builds a temporary macOS test module from real production sources and
never launches Penned or a simulator.

The app was compiled with the iOS SDK and code signing disabled, without launching
or installing it. Focused editor tests cover Collections plus inline properties,
paragraph insertion, caret tracking, headings, and tracked-task behavior. Browser
checks use real repository-generated payloads at 390px and 1024px, including covers,
horizontal scrolling, filtered views, real document IDs, and long-title bounds.

Native sheets, keyboard interactions, photo-library import, and iPhone gesture
behavior still need the user's on-device test pass. No actual iPhone verification
is claimed. Penned's inspected persistence remains local SQLite; there is no existing
CloudKit document synchronization to extend, and no CloudKit synchronization claim.

The Kanban pass compiles for the iOS app target. Its headless persistence/domain suite
passes 31 tests, and the focused editor suite passes 50 tests, including native host
placement, multiple hosts, resizing, and Table/Gallery switching. The generated backend
bundle and bundled native editor have identical SHA-256 hashes. All simulators were
shut down during this pass; no simulator was booted and no app was installed or launched.
Native Kanban screenshot fidelity, drag/drop gestures, and keyboard behavior remain
unverified on an actual iPhone/iPad. Earlier browser checks above concern Table/Gallery,
not a browser-rendered substitute for the native Kanban view.

The unavailable-collection regression was checked against a read-only copy of the
connected iPhone's real database. The production migration and repository recovered
the same collection, entry IDs, and values in an isolated test database. No files
were written back to the phone. Supply `PENNED_COLLECTION_RECOVERY_DATABASE` to the
headless test runner for this additional real-data recovery check.

## Collection Previews and First-Frame Presentation

The collection title no longer includes an entry count in Table or Gallery. Kanban
uses the same 18pt bold document font/ink and unframed view selector. Column counts
remain because they describe the individual column, not the collection title.

The old preview renderer received the document JSON but not its collection data.
It therefore photographed the unresolved collection message. It also keyed previews
only by document/child content, so changing collection values did not refresh that
photograph. The renderer now receives real repository snapshots before capture.
Native Kanban is composited into the read-only capture at its actual host width;
this does not mutate saved document JSON or replace the interactive native board.

Preview fingerprints include shared fields, values, view configurations, entry
titles/covers/styles, column colors, ordering, assignments, and collapsed states.
Existing database notifications refresh these dependencies. Outdated render jobs
are rejected before and after capture. The v10 preview directory ignores old broken
images; only disposable preview files change, not user records or attachments.

At startup, the existing editor cache receives collection payloads before loading
each prepared document. Collection entries still do not create full editors per
table row or Gallery card. Recent-page preview metadata and cover images are warmed
before Home renders. On a cache miss, the native saved-content renderer can display
Table, Gallery, and Kanban directly from persisted data without a WebKit dependency.

When a page is opened, its saved body is visible immediately while the existing live
editor prepares beneath it. The cover uses the existing synchronous decoded image
cache while its full-resolution image finishes. The live body accepts interaction
only after its own document is loaded, current metadata/appearance are supplied,
fonts and first-viewport images settle, and required native Kanban views report
layout with acknowledged host heights. Generation checks reject stale completions.
No fixed reveal delay or spinner was added. Already interactive editors stay visible
during ordinary edits. This is presentation preparation, not a second editable copy
of the document or a new persistence system.

### Files in This Pass

- `Vellix/Documents/DocumentPreviewContent.swift` (new): repository-backed metadata
  projection and stable collection-aware fingerprints.
- `Vellix/Collections/CollectionSnapshotPreview.swift` (new): native read-only Table,
  Gallery, Kanban, and anchored entry-field rendering using real shared values.
- `Vellix/Editor/DocumentPresentationState.swift` (new): generation-safe readiness
  state, including native block/view identity checks.
- `Vellix/Documents/DocumentPreviewCache.swift`: load collection metadata before
  capture, composite native boards, observe dependencies, and invalidate v9 images.
- `Vellix/Documents/LibraryDocumentPreview.swift`: associate images with their exact
  fingerprint and request a replacement when collection dependencies change.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: render actual collections and
  entry fields in immediate previews; expose the saved body for editor preparation.
- `Vellix/Collections/CollectionModels.swift`: Codable metadata snapshots for stable
  preview encoding; no database schema change.
- `Vellix/Collections/CollectionStore.swift`: share the existing payload projection
  with startup and snapshot rendering instead of maintaining separate serializers.
- `Vellix/Collections/CollectionKanbanView.swift`: align header typography/controls
  and allow startup snapshot metadata while the active store watches another page.
- `Vellix/App/AppEnvironment.swift`: share the existing repository and seed current
  collection payloads before displaying a prepared document.
- `Vellix/Editor/DocumentEditorCache.swift`: provide metadata during existing editor
  preparation, preserving the current hierarchy and editor reuse policy.
- `Vellix/Editor/TipTapEditorSession.swift`: prepare presentation, reject stale
  completions, register field icons, and wait for native layout acknowledgments.
- `Vellix/Editor/DocumentEditorView.swift`: retain saved content until presentation
  is ready, measure hidden native boards, and reuse decoded covers immediately.
- `Vellix/VellixTests/CollectionTests.swift`: metadata/fingerprint/readiness tests
  and opt-in native render checks with persisted fixture data.
- `Scripts/test-collections.mjs`: include production preview/readiness sources and
  extract existing native rendering helpers for headless verification.
- Backend `src/collection-node.js`: remove counts from collection titles only.
- Backend `src/presentation-ready.js` (new) and `src/editor.js`: supply current
  metadata/appearance and wait for fonts, visible image decoding, and layout.
- Backend `tests/presentation-ready.test.js` (new) and
  `tests/collection-runtime.test.js`: readiness and count-free title regressions.
- Backend `dist/tiptap.bundle.js` and native
  `Vellix/VellixEditor.bundle/tiptap.bundle.js`: rebuilt/synchronized resources.
- `Docs/Collections.md`: implementation details and verification boundaries.

### Verification for This Pass

- iOS app target compiled with signing disabled; no app installation or launch.
- 38 headless native collection/presentation tests pass. Optional ImageRenderer
  exports were inspected for Table, Gallery, and vertical Kanban with repository
  fixtures, a real imported cover, and property chips. These are macOS native
  renders, not proof of iPhone layout or gestures; the temporary test module does
  not contain the app's compiled custom icon assets.
- 53 focused editor tests pass, covering Collections, presentation readiness,
  inline properties, empty-space paragraph insertion, caret tracking, tracked
  tasks, and heading spacing.
- The full backend suite reports 93 passes and 6 failures in the separate rich-text
  table tests: three empty-dimension expansion cases, an incomplete mock document
  event API, a slash-menu source-order assertion, and formula reference adjustment.
  These table sources were not edited in this pass; the full suite is not green.
- Actual iPhone/iPad cold-launch timing, saved-to-live visual transition, native
  keyboard/gesture behavior, and on-device memory pressure remain unverified.
  No instantaneous-launch performance measurement is claimed.

Rich-text table resizing/formulas, inline properties, editor scroll boundaries,
page styling/inheritance, schema migrations, document identities, and the icon
catalog were intentionally left unchanged in this pass.

## Stable Launch Frames and Prepared Navigation

The previous preparation pass still allowed a visible change from a native saved
preview to a WebKit snapshot. It also prepared every normal document's WKWebView at
launch. The following pass removes that swap and bounds speculative editor work.

Library previews now select one decoded bitmap for the current content fingerprint
and keep it while that library presentation is visible. Completed snapshot jobs
persist their accurate result without changing an already-visible card. Real edits
still change the fingerprint and replace the entire card image, so this does not
freeze outdated values. Returning from a document begins a new library presentation
and picks up completed snapshots before that screen is drawn.

The first-screen persisted preview images are decoded during existing bootstrap.
When no valid image exists, the existing saved-content renderer is rasterized once
and retained, instead of displaying live approximate content and morphing it later.
An accurate WebKit snapshot is generated for later presentations. This cache-miss
image remains a read-only approximation; it is not claimed to be a pixel-identical
editor. PNG files are atomically replaced so termination cannot leave half a cache
image. No preview directory version bump or user-data migration is required here.

Only one eligible recent root document is warmed at startup. Previously opened
editors remain cached, and their pending edits are not discarded or evicted. New
document requests prepare that actual document on demand. Successful saves also
schedule preview regeneration directly, in addition to the existing collection and
document dependency notifications.

Opening a document is now a pending navigation request. The current Home, library,
or document stays visible and usable while the target prepares offscreen at the
same layout width it will use when opened. The selected document changes only when
the current request is ready. A newer request, changing destinations, deletion, or
returning to the library cancels the older request. Preparation errors retain the
current screen and use the existing error presentation. A 12-second failure timeout
prevents a failed preparation from leaving an indefinitely pending request; this is
not a minimum reveal delay. Already-ready pages open immediately.

Presentation readiness now requires a successful public WebKit snapshot callback
after the matching document, metadata, fonts, visible images, and native Kanban
layout acknowledgments are ready. A JavaScript animation frame alone no longer
marks the page ready. Generation checks reject stale frame callbacks. Both compact
and split-view layouts host prepared editors at their eventual display dimensions.
The earlier saved-body layer remains an offscreen preparation fallback rather than
something the user should see replaced as a document opens. No scaled library
thumbnail is stretched over the actual editor, and no splash screen or spinner was
added.

The previously empty system launch-screen configuration now uses a black named
color matching Home. Dark appearance, which the app already enforced at runtime,
is also declared in launch metadata. This prevents a system-selected light launch
background preceding the dark app. No logo or artificial launch delay is introduced.

### Files in the Launch Follow-Up

- `Vellix/Documents/DocumentPreviewPresentation.swift` (new): stable preview-frame
  selection and immediately decoded, atomic PNG persistence helpers.
- `Vellix/Editor/DocumentEditorWarmupPolicy.swift` (new): one-page startup policy,
  excluding archived, trashed, template, and nested documents from speculation.
- `Vellix/Documents/DocumentPreviewCache.swift`: predecode first-screen images,
  retain presentation bitmaps, and atomically persist completed snapshots.
- `Vellix/Documents/LibraryDocumentPreview.swift`: freeze the chosen rendering for
  each content/presentation key; background capture no longer changes that image.
- `Vellix/App/AppEnvironment.swift`: bounded bootstrap, pending navigation,
  cancellation/errors, explicit after-save regeneration, and repository-based
  parent navigation when a parent has not already been warmed.
- `Vellix/Editor/DocumentEditorCache.swift`: forward successful saves to the existing
  preview service while preserving parent-thumbnail and template notifications.
- `Vellix/App/VellixShellView.swift`: prepare hidden split-view editors in the same
  detail space where they will appear; compact editor reuse remains intact.
- `Vellix/Editor/DocumentPresentationState.swift`: separate content/layout readiness
  from confirmation of a current-generation WebKit frame.
- `Vellix/Editor/TipTapEditorSession.swift`: confirm pixels with WebKit before
  publishing presentation readiness.
- `Vellix/Editor/TipTapWebView.swift`: notify the session when native bounds are
  available, including a page whose initial host had zero-sized bounds.
- `Vellix/VellixTests/DocumentLaunchTests.swift` (new): stable-frame, PNG persistence,
  bounded preparation, and frame-generation regressions.
- `Vellix/VellixTests/CollectionTests.swift`: require frame confirmation in the
  existing native Kanban presentation-state tests.
- `Vellix/VellixTests/VellixTests.swift`: assert pending navigation and explicitly
  prepare nested editors in tests that exercise their editing behavior.
- `Scripts/test-collections.mjs`: include the production policy/presentation helpers
  and headless launch tests.
- `Vellix.xcodeproj/project.pbxproj`: test-target membership for DocumentLaunchTests.
- `Vellix/Resources/LaunchInfo.plist` and
  `Vellix/Assets.xcassets/PennedLaunchBackground.colorset/Contents.json` (new): black
  system launch background and existing dark appearance from launch. The Xcode
  project merges this launch metadata with its existing generated Info.plist keys.
- `Docs/Collections.md`: follow-up design, changed-file record, and boundaries.

The headless suite passes 44 tests across two suites, including the six new launch
regressions. The iOS app and test targets compile with signing disabled using
build-for-testing; the app-hosted iOS tests are not run. The packaged Info.plist was
checked for UILaunchScreen.UIColorName = PennedLaunchBackground and
UIUserInterfaceStyle = Dark. The named color is opaque black, using Apple's
[documented launch background setting](https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uicolorname).
These checks do not prove physical-device launch timing or visual transitions. No app or simulator is
launched for this pass. Rich-text tables, editor commands, persisted document JSON,
collection ownership, property values, and the generated editor bundle are unchanged.

## Cold Inline-Property Preview Parity

The saved-content renderer previously displayed only `InlinePropertyDefinition.value`.
Select and Multi-select actually persist their selections as stable option IDs plus
the option definitions, often with an empty `value`. The native cold preview therefore
showed labels without their selected chips. It also displayed raw civil-date strings.
Opening a document could use an accurate WebKit rendering, but a later cache miss
returned to this incomplete cold renderer. This was a display-path mismatch; this
fix does not rewrite property values or require opening a document to resolve them.

Cold previews now render selected options and colors, wrapping Multi-select chips,
localized civil dates with the existing calendar asset, checked/unchecked controls,
number prefixes/suffixes, link labels/icons, plain text, and empty placeholders.
The native row mirrors the editor's existing 43/57 column proportions, 13pt page
font, 44pt minimum controls, pill shapes, and colors. Consecutive property rows use
the editor's compact spacing instead of ordinary paragraph spacing.

Documents containing inline properties, including referenced child content, gain
a targeted renderer revision in their preview fingerprint. Unrelated documents keep
their existing cache keys. Locale and time-zone identity are included for the affected
previews so formatted dates cannot reuse an obsolete language or time-zone rendering.
Stable first-frame image selection, atomic cache persistence, and prepared navigation
are unchanged. A cache miss can now draw property values directly from persisted JSON
before any editor or background WebKit snapshot exists.

Files in this pass:

- `Vellix/Editor/InlineProperty.swift`: read-only selection and typed display helpers,
  retaining civil-date parsing and the existing persisted schema.
- `Vellix/Documents/InlinePropertyPreview.swift` (new): type-aware native preview row
  and synchronous proportional layout, with no editable state or mounted editor.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: use the typed property row and
  compact consecutive-property spacing in saved document/body/nested previews.
- `Vellix/Collections/CollectionPropertySheets.swift`: parameterize the existing chip
  flow spacing; Collections retain their default 4pt spacing, inline chips use 6pt.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: structured recursive inline-node detection.
- `Vellix/Documents/DocumentPreviewContent.swift`: targeted renderer/locale fingerprint
  revision without invalidating unaffected document images.
- `Vellix/VellixTests/DocumentLaunchTests.swift`: six regressions for stored selections,
  civil dates, the other types, real SQLite reopen, targeted invalidation, and native
  chip rendering/wrapping at phone/tablet content widths.
- `Scripts/test-collections.mjs`: compile the production inline preview in headless tests.
- `Docs/Collections.md`: root cause, changed-file record, and verification boundaries.

The headless suite passes 50 tests, including a real close/reopen of a SQLite fixture
without any editor. Native ImageRenderer exports at 320pt and 720pt were inspected;
pixel checks verify blue, purple, and gold option content and narrower multi-line
wrapping. The temporary headless test bundle does not include compiled app icon assets;
production rows reference the same existing numcal/link/checkwavy assets as the editor.
No Penned app or simulator is launched. The actual iPhone force-quit/relaunch sequence
and exact UIKit/WebKit rasterization remain unverified on device. Inline editing,
document persistence, collection values, startup/navigation policy, and backend editor
resources are intentionally unchanged.
