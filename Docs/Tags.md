# Document Tags

## Connected Workflow

Type `#` and a name in an editable text block. The nearby, keyboard-accessible
suggestion menu offers existing tags and an explicit Create action. Accepting a
choice inserts an `inlineTag` atom. Typing a space, canceling, using a URL
fragment, or typing inside code does not silently create a tag. Names support
letters, combining marks, numbers, hyphens, and underscores, up to 80 Unicode
scalars. Composed Unicode and capitalization variants share one catalogue entry
within a Space. The first spelling remains the display name.

Tap a tag for a compact native bottom sheet with Go to Tag, Swap Tag, and Turn
into Text rows, each using Penned's existing icon assets. Swap opens the searchable
native selector within that same sheet, retaining the editing bookmark until
selection or dismissal. Go to Tag navigates after the sheet finishes dismissing.
Locked documents offer only Go to Tag. Replacement affects only the bookmarked
occurrence. Plain-text conversion retains `#name` and marks. Editing bookmarks
map through intervening ProseMirror transactions and are discarded on document
load; stale requests cannot remove unrelated content. Native tag mutations are
serialized and participate in the existing persistent-operation tracking.

All Tags is accessible from Home, the sidebar, and Settings > Tags. One shared
browser handles All Tags and selected-tag results. It uses the existing library
search control, FTS tokenizer, rich `LibraryDocumentPreview` cards, two-column
layout, and document context menus. Tag chips toggle filters; multiple filters
are ANDed at the root-document/tree level. Keyword/title search further filters
the resulting documents, including their eligible nested pages.

The native tag interface uses black-weight rounded system fonts. Its title and
search begin directly below the compact navigation bar, without an empty native
large-title region. Each selected chip contains its own remove icon. Tag-result
cards omit favorite stars; normal library cards and saved document styles remain
unchanged.

Routine WebView load checks return before publishing state, resolving attachments,
or sending bridge commands when the document is already loaded or identically
queued. This prevents a nil tag-request reset from recursively invalidating the
WebView, flooding bridge logs, and dismissing a tag action during a view refresh.
Changed queued content, different documents, and forced loads still reset state.

The card button opens a document normally. Its separate count button opens the
matching-block sheet. Counts are distinct blocks, not occurrences; counts above
50 display `50+`. In qualifying documents, the sheet includes the union of blocks
containing any selected tag. A block matching several tags appears once. With no
filters, all tagged blocks are included. The sheet renders actual block content,
query-tag highlights, current page breadcrumbs, and the root's thumbnail and
metadata. Lists are lazy and update after committed content/lifecycle changes.

## Source of Truth and Storage

The document's canonical JSON is authoritative. Each inline tag stores its own
stable occurrence `id`, display `name`, and an optional `tagID` hint. The derived
index resolves names in the document's owning Space; it never trusts a foreign
Space's copied hint. No parallel document body or independently editable tag
association store is introduced.

Migration `v19_document_tags` adds:

- `documentTagRecords`: UUID, Space FK, display/normalized names, creation date,
  and unique `(spaceID, normalizedName)`.
- `taggedBlocks`: document/block composite key, document-order ordinal, and
  actual text/tag runs for block previews.
- `documentTagOccurrences`: document/occurrence composite key, tag FK, block FK,
  plus a tag/document/block lookup index.
- `tagDocumentChanges`: a dirty-document queue populated by insert, relevant
  update, and delete triggers. Existing structured tags are backfilled; ordinary
  historical hashtags are not converted.

`AppDatabase.write` reconciles the tag index in the same transaction as document
changes and task indexing. A failed write rolls everything back. Notifications
are posted after commit. This covers normal saves, snapshots, cloning,
templates, Daily Notes, Space moves/copies, and raw repository lifecycle writes.

Trash and archived/template ancestors are excluded at query time without
destroying the retained content needed by restoration. Permanent deletion uses
cascading foreign keys. Nested results aggregate under their actual root and
retain the source page ID. Parent changes update roots/breadcrumbs; page-reference
order determines sibling page order. Unused tag records remain reusable with
zero document counts. Catalogue queries and native navigation are Space scoped.

Canonicalization repairs duplicate node IDs without changing valid IDs. The live
editor maps preexisting positions through transactions so a paste before its
source receives new IDs instead of stealing the source's navigation target.
Existing copy/template infrastructure already generates independent node IDs.

## Exact Block Navigation

Selecting a block validates its current document/block/occurrence association,
commits relevant pending edits, and opens the source page using the existing
presentation-readiness path. A fresh request UUID also supports already-open
documents and repeated navigation to the same block.

`tagLocate` finds the real ProseMirror node by ID, temporarily reveals collapsed
toggle ancestors, reveals horizontally clipped table content, waits for fonts
and a layout frame, and returns actual DOM coordinates. Toggle reveal is view
state, not saved attributes; its normal toggle control still works. The native
resolver waits for the real WebView frame and outer ScrollView content size,
converts coordinates, and clamps the offset around Penned's existing top
controls. It uses layout/KVO callbacks, not arbitrary delays or text estimates.
Pending targets remeasure when width changes.

The arrival highlight is a ProseMirror decoration/CSS animation, cleared on
completion or pointer interaction. It never changes saved formatting. Unavailable
targets report a recoverable error. Navigation does not focus a typing caret or
leave the old keyboard/caret driving the scroll position.

## Files for This Feature

This workspace already contained other changes. This inventory describes tagging
edits only, not ownership of every current Git diff.

| File | Reason |
| --- | --- |
| `Vellix/Tags/DocumentTagRepository.swift` (new) | Models, validation, v19 installer, transactional index, scoped catalogue/filter/block queries and target validation. |
| `Vellix/Tags/TagBrowserView.swift` (new) | All Tags/results, filters, existing preview cards, independent count badges and matching-block sheet. |
| `Vellix/Tags/TagEditorIntegration.swift` (new) | Native contextual actions, selector, mutation queue and layout-driven block scrolling. |
| `Vellix/Persistence/AppDatabase.swift` | v19 registration, atomic reconciliation/notification, user-facing tag errors. |
| `Vellix/App/AppEnvironment.swift` | Scoped tag repository, destination/filter state, save-safe browsing and exact target handoff. |
| `Vellix/App/VellixShellView.swift` | Route Tags and use Penned's existing hashtag asset in its sidebar row. |
| `Vellix/Documents/HomeView.swift` | All Tags library entry. |
| `Vellix/Spaces/PennedSettingsView.swift` | Connect the existing Tags settings row. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Validate/decode tag requests. |
| `Vellix/Editor/TipTapEditorSession.swift` | Tag command bridge, request state/reset and native WebView access for coordinate conversion. |
| `Vellix/Editor/DocumentEditorView.swift` | Attach the native tag integration to the existing editor. |
| `Vellix/Editor/TipTapContentAnalyzer.swift` | Stable-ID repair, ordered page references and tag-aware plain text/FTS. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Render inline tags, preserve marks and recognize tag-only populated callouts. |
| `Vellix/Documents/ImmediateTablePreview.swift` | Keep inline tag text in immediate table previews. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Include tags in thumbnail text. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Invalidate tag-containing previews for the new renderer only. |
| `Vellix/Search/DocumentSearchService.swift` | Shared FTS-backed ID query for tagged document keyword/title filtering. |
| `Vellix/Tasks/DocumentTaskRepository.swift` | Retain tag text in existing native task summaries. |
| `Vellix/VellixTests/DocumentTagTests.swift` (new) | Persistence, migration, counts, filtering, ownership, hierarchy, copies, templates, rollback, SQLite reopen and real editor exchange. |
| `Vellix/VellixTests/TagBridgeTests.swift` (new) | Event validation, pending saves, nested/repeated target routing and Space changes. |
| `Scripts/test-collections.mjs` | Include the tag domain and native tests in the established headless harness. |
| `Scripts/test-document-tags.mjs` (new) | Swift/GRDB-to-shipping-editor-to-reopened-SQLite round trip without a simulator. |
| `Vellix.xcodeproj/project.pbxproj` | Add test membership exceptions, keeping tests out of the application target. |
| `Vellix-backend/src/document-tags.js` (new) | Inline node, suggestions, bookmark mapping, ID repair, undoable actions, exact lookup and temporary highlighting. |
| `Vellix-backend/src/editor.js` | Register tagging, preserve tags/marks through supported block conversions, protect tag-only content during page breaks, and temporarily reveal toggle views. |
| `Vellix-backend/src/tiptap.html` | Inline/suggestion/highlight styling using Penned's accent; no Add-menu changes. |
| `Vellix-backend/tests/document-tags.test.js` (new) | Actual bundled-editor insertion/actions/serialization/history/navigation and regression checks. |
| `Vellix-backend/dist/tiptap.bundle.js`, `dist/tiptap.html` | Generated editor artifacts. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js`, `tiptap.html` | Synchronize the two shipping editor artifacts; other bundle resources are retained. |
| `Docs/Tags.md` (new) | Implementation, file inventory and verification boundary. |

## Verification

### Tag Browser and Reload Follow-up

- The headless macOS harness passes 156 tests in 12 suites. Two new regression
  tests cover 100 unchanged load checks with no publications or attachment
  re-resolution, preserving an open tag request, and clearing it for changed,
  different-document, or forced loads.
- Swift source parsing and whitespace checks pass for the modified files.
- No simulator or Penned application was launched for this follow-up. Native
  title positioning, typography, and sheet appearance still require on-device
  visual confirmation; source checks do not establish rendered layout.

### Original Feature Verification

- Generic iOS device Debug compilation with code signing disabled; no simulator
  destination, simulator process, or application launch is used.
- 154 native tests in 12 suites pass, including the real editor/SQLite exchange.
  All 14 new bundled-editor tests pass. The full JavaScript suite runs 220 tests:
  214 pass and the six table failures listed below remain.
- Native headless macOS harness exercises the real Swift models, GRDB migrations,
  repositories, bridge decoding and navigation state. The complete round trip
  exports a real repository document, edits it in the shipping TipTap bundle,
  saves returned JSON using `DocumentRepository`, reopens SQLite, and verifies
  two remaining journal blocks, combined filters and surviving exact targets.
- New bundled-editor tests cover explicit creation/reuse, case normalization,
  swap/plain-text marks, undo/redo, stale bookmarks, cancelled suggestions, plain
  hashtag/code compatibility, copied IDs, page breaks, block conversions, table
  cells and nonpersistent collapsed-toggle navigation.
- Installed Playwright with headless system Chrome checks the shipping editor
  at 320, 390, 834 and 1280 points wide, using real native icon data and a
  Swift-generated fixture. It exercises suggestions, tag actions, Backspace/undo,
  JSON reopen, an exact target after 100 paragraphs, and horizontal table reveal,
  checks overflow/errors, and
  captures phone/tablet screenshots. Browser plugin tooling was unavailable.
- The complete JavaScript suite also exposes six existing table-test failures:
  three zero-dimension cases, an incomplete mock `document.addEventListener`, an
  outdated assertion that Table is the first slash item (Collection already is),
  and a formula row-adjustment assertion. These standalone table tests do not
  install the tag extension. Table implementation/tests are intentionally not
  rewritten as part of tagging.

Verification logs: `/tmp/penned-tag-build.log`,
`/tmp/penned-tag-native-exchange.log`, `/tmp/penned-tags-all-editor-tests.log`,
and `/tmp/penned-tag-browser-qa.log`. Browser screenshots are under
`/tmp/penned-tag-browser-qa/`.

Native sheet gestures, actual WKWebView keyboard/selection behavior, VoiceOver,
iPhone/iPad outer-scroll integration, and process termination during an in-flight
save still need physical-device runtime verification. A compilation or Chrome
check is not presented as proof of those native interactions. No simulator is
booted, launched or run for this task.

Existing attachment storage/players, calendar/Daily Notes behavior, callout
appearance, table domain logic and unrelated menus are intentionally preserved.
