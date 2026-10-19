# Daily Notes

## User Flow

Settings > Daily Notes stores one optional default template for the current Space.
Users can choose, change, or clear it. The list uses the existing template
thumbnail renderer. A renamed template keeps its selection by ID. Moving it to
another Space, deleting it, or making its root unavailable clears the old default.
Existing Daily Notes are never regenerated when this preference changes.

Calendar offers Create Daily Note or Open Daily Note for its selected day, marks
days containing notes, and includes an existing note in the day agenda. Without a
valid default, creation opens the template-selection sheet first. Creation commits
pending editor work before copying the current template and opening the result
through the existing document readiness/navigation path.

The editor title contains a permanent calendar/date button, such as 10-16-2026,
with an editable title suffix beside it. The button saves pending changes and
opens that calendar day. Repository title updates also retain the date prefix.

When editing a template, Add > Template Components contains Rating, Single
Select, Multi-Select, and Slider. This submenu is text-only and absent from ordinary
document editors. Tapping a template component opens its configuration sheet.
The sheet edits questions, ordered choices, limits, increments, and endpoint
labels, and provides move and delete commands. Generated notes answer the same
blocks directly instead of opening configuration.

## Persistence and Ownership

Migration `v18_daily_notes` adds a nullable `documents.dailyNoteDate` and the
`dailyNoteSettings` table. Historical migrations and existing record identities
are unchanged. No existing document is automatically classified as a Daily Note.

Dates are validated Gregorian civil keys (`yyyy-MM-dd`), not creation timestamps.
The title is derived from that key, so timezone changes do not move the note to
another date. Converting the key to a calendar navigation instant uses local noon.

A partial unique index on `(spaceID, dailyNoteDate)` for non-trashed documents
prevents duplicate active notes. Settings reference the Space and template with
foreign keys. Ownership triggers reject cross-Space template settings and dated
template/nested roots. Queries filter by Space in SQL; the central AppEnvironment
sets the repository scope with every Space change. Calendar's existing generation
checks discard stale asynchronous results when switching workspaces.

Daily Notes are ordinary persisted document trees with one date association on
their root. They use existing search, attachments, task indexing, collections,
snapshots, previews, and Trash rather than parallel storage systems.

## Template Generation

`DailyNoteRepository.createOrFind` performs lookup, template materialization,
deep cloning, and date assignment in one GRDB transaction. The existing copier
duplicates nested documents, collections and records, attachments, formatting,
appearance, task identities, and internal references. Copied attachment files are
removed if the transaction fails. Existing notes are returned unchanged.

New component/block IDs are generated for each copy. Configured option IDs remain
part of each copied definition; answers are reset in newly generated notes and
when a document is saved as a reusable template. Each note owns its own JSON.

`TemplateRepository.instantiate` refuses ordinary use of a template containing
interactive components, including components in its nested tree. The library and
search Use Template actions are disabled for those templates. The restriction is
recalculated after template saves and removed when the final component is removed.
Ordinary templates retain their existing instantiation behavior.

Same-Space normal document duplication clears the Daily Note association. The
existing whole-tree cross-Space transfer/copy retains it; a destination date
collision rolls the operation back rather than replacing either note.

Trashing a note hides its calendar association. Restoring it restores the same
association. If another active note already owns the date, restoration reports a
conflict and preserves both records without overwriting either. Permanently
deleting the conflicting note permits restoration of the original.

## Editor Contract

The TipTap block is a selectable `templateComponent` atom with these attributes:

```json
{
  "id": "independent-block-id",
  "definition": {
    "kind": "singleSelect",
    "label": "How was your day?",
    "minimum": 1,
    "maximum": 5,
    "step": 1,
    "minimumLabel": "",
    "maximumLabel": "",
    "choices": [{ "id": "stable-option-id", "label": "Great" }]
  },
  "response": null
}
```

Response is a number for rating/slider, an option ID for single select, or an array
of option IDs for multi-select. Swift and JavaScript validate definitions. Slider
responses snap to the configured increment; an unanswered slider can also select
its minimum directly. Configuration and response are distinct attributes.

Responses dispatch real ProseMirror transactions, participating in normal change
tracking, undo, native save, serialization, and previews. Choice taps flush a
snapshot immediately; slider inputs update through normal change tracking and
flush on release. The range DOM stays stable during dragging. Atom selection does
not make the range's ancestor draggable, and an active range gesture suppresses
ancestor block dragging without changing ordinary block gestures.

Template mode is sent through the existing editor bridge. Its controls open
configuration without recording answers. Read-only and block-selection modes do
not record responses. Labels and choices use textContent, not injected HTML.
Typography and colors inherit the document appearance; choices wrap to the
available width and follow existing alignment/indent attributes. Existing block
selection/copy/paste plus component move/delete controls remain available.

## Files Changed for This Feature

Paths below are relative to the Swift project unless prefixed with
`Vellix-backend/`, which refers to the sibling maintained editor project.
The workspace already contained other changes; this list describes Daily Notes
changes, not ownership of every current Git diff.

| File | Purpose |
| --- | --- |
| `Vellix/DailyNotes/DailyNoteRepository.swift` (new) | Civil dates, migration installer, scoped settings, atomic creation/lookup. |
| `Vellix/DailyNotes/TemplateComponent.swift` (new) | Shared native configuration/value types and validation. |
| `Vellix/DailyNotes/DailyNotesSettingsView.swift` (new) | Default-template selection, clearing, previews, and calendar setup callback. |
| `Vellix/DailyNotes/TemplateComponentEditorSheet.swift` (new) | Real component configuration, choice ordering, move, and delete controls. |
| `Vellix/Persistence/AppDatabase.swift` | Registers v18 after existing migrations. |
| `Vellix/Documents/DocumentRecords.swift` | Optional persisted civil-date association. |
| `Vellix/Documents/DocumentRepositories.swift` | Title protection, template restrictions, deep-copy answer reset, duplication, and restore conflict handling. |
| `Vellix/Documents/StructuredTemplateContent.swift` | Independent component IDs and optional answer reset during cloning. |
| `Vellix/App/AppEnvironment.swift` | Scoped repository ownership, pending-save-safe creation/opening, and template eligibility updates. |
| `Vellix/Calendar/CalendarModel.swift` | Scoped Daily Note lookup and stale-result-safe refresh/reset. |
| `Vellix/Calendar/CalendarView.swift` | Create/Open action, template setup sheet, and date markers. |
| `Vellix/Calendar/CalendarAgendaRows.swift` | Existing Daily Note row in each day agenda. |
| `Vellix/Spaces/PennedSettingsView.swift` | Daily Notes settings destination using the existing calendar asset. |
| `Vellix/App/VellixShellView.swift` | Disable ordinary Use Template for component templates. |
| `Vellix/Documents/HomeView.swift` | Apply the same restriction in template search. |
| `Vellix/Editor/DocumentEditorView.swift` | Template-only Add submenu, configuration presentation, date button, and editable title suffix. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Validated component configuration event decoding. |
| `Vellix/Editor/TipTapEditorSession.swift` | Configuration commands and model event forwarding through the existing bridge. |
| `Vellix/Editor/TipTapContentAnalyzer.swift` | Preserve nodes and index labels/selected answers for search and previews. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Render saved interactive fields in the native immediate preview. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Include Daily Note date/presentation revision in affected cache keys. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Calendar asset beside Daily Note snapshot titles. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Existing miniature thumbnail fallback supports component content. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Regenerated shipping editor with the new node and bridge. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Synchronized shipping component styling. |
| `Vellix/VellixTests/CalendarTests.swift` | Daily Notes repository/migration/ownership/round-trip coverage and historical-schema fixture helper. |
| `Vellix/VellixTests/SpaceEnvironmentTests.swift` | Pending template saves and native component bridge coverage. |
| `Vellix/VellixTests/SpaceTests.swift` | Historical-schema fixture compatibility and two missing `try` fixes needed to run the existing harness. |
| `Vellix/VellixTests/CollectionTests.swift` | Historical-schema fixture compatibility after adding the nullable document column. |
| `Scripts/test-collections.mjs` | Include new production Daily Notes types in the existing native headless harness. |
| `Vellix-backend/src/template-components.js` (new) | TipTap schema/NodeView, validated configuration, responses, gestures, and commands. |
| `Vellix-backend/src/editor.js` | Register the node, dispatch commands, refresh controls, and inherit appearance. |
| `Vellix-backend/src/structured-placeholders.js` | Forward template context through the established command wrapper. |
| `Vellix-backend/src/tiptap.html` | Responsive rating tiles, selectable chips, and slider styles. |
| `Vellix-backend/tests/template-components.test.js` (new) | Seven real-editor configuration, response, isolation, layout-attribute, and gesture tests. |
| `Docs/DailyNotes.md` (new) | Implementation and verification record. |

## Verification

- Native iOS simulator-target compilation succeeded with `xcodebuild`, arm64,
  Debug, generic iOS Simulator destination, code signing disabled. No app or
  simulator was launched.
- Existing native headless harness: 117 tests in 8 suites passed with
  `PENNED_FULL_APP_TESTS=1` and the real-editor exchange enabled. Coverage includes
  migration, reopened databases, independent responses, Space scoping, duplicate
  prevention, template eligibility, deleted/moved defaults, nested pages,
  attachments, collections, rollback, Trash/restore, and pending saves.
- A real Swift/GRDB-generated note was loaded into the shipping editor in
  headless system Chrome. Pointer/click/keyboard interactions saved rating 3,
  single Difficult, multi Creative/Tired, and slider 70. Returned editor JSON was
  saved by the production Swift repository, the SQLite database was reopened,
  and the same note retained all responses while the next date was unanswered.
- Browser checks passed at 320x840, 390x844, and 834x1112: all four blocks,
  real slider dragging, JSON save/reopen, no horizontal overflow, and no page
  errors. Phone and tablet screenshots were visually inspected. Browser plugin
  tooling was unavailable; installed Playwright used headless system Chrome.
- 93 targeted JavaScript editor tests passed, including all seven new component
  tests and existing callout, placeholder, collection, task, inline-property,
  caret, paragraph-gap, heading, and presentation-readiness regressions.
- The broader JavaScript suite ran 144 tests: 126 passed, 18 failed. Twelve
  block-removal tests still assume the old hold timing/target behavior; the
  current implementation uses a 500ms right-side gutter hold. Six table tests
  fail on zero-dimension serialization, an incomplete mock document, a stale
  slash-menu source assertion, and formula adjustment. Those implementations
  and tests were not changed for Daily Notes. These are not reported as passes.
- `git diff --check` passed in both projects. Shipping HTML matches maintained
  HTML, and shipping JavaScript matches the generated dist bundle.

Verification logs are in `/tmp/penned-daily-notes-build.log`,
`/tmp/penned-daily-notes-final-native-tests.log`,
`/tmp/penned-daily-editor-regressions.log`,
`/tmp/penned-daily-full-editor-tests.log`, and
`/tmp/penned-daily-browser-qa.log`.

Native sheets, the title date button, WKWebView touch/keyboard behavior,
VoiceOver, and process termination during an in-flight save still need runtime
checks on a physical iPhone/iPad. Disk reopen and explicit editor serialization
were tested; they are not claimed as a physical-device force-quit test.

Global saved styles, Apple Calendar's external events, existing callout behavior,
and unrelated menu/gesture/table implementations were intentionally left alone.

## Slider Insertion and Layout Correction

Inserting a component now leaves a collapsed text caret after it instead of
selecting the atom. An existing following text block is reused; otherwise a
normal paragraph with its own stable block ID is added in the same undoable
transaction. The loader retains that paragraph after components, so save/reopen
does not silently remove the typing destination.

A blank question stays blank, including in templates. Sliders no longer display
an invented "Slider" heading or "Not set" status. Saved numeric answers still
display normally. An invisible, accessible template-only button over the slider
opens its existing configuration without recording an answer. Read-only and
block-selection modes retain their existing protections. Slider blocks have a
6-point top margin and no extra container padding.

Files changed for this correction: `Vellix-backend/src/template-components.js`
(selection, blank labels, status, configuration hit target), `src/editor.js`
(retain the component's typing paragraph), `src/tiptap.html` (compact spacing
and hidden-status styling), and `tests/template-components.test.js` (insertion,
blank-label, configuration, undo/redo, and persistence regressions). The shipping
`VellixEditor.bundle/tiptap.bundle.js` and `tiptap.html` were regenerated/synced.
`Documents/ImmediateDocumentPreview.swift` matches the compact unanswered
presentation; `Documents/DocumentPreviewContent.swift` invalidates only previews
containing components with `template-component-presentation-v2`;
`VellixTests/DocumentLaunchTests.swift` covers that selective invalidation.
This document records the updated behavior. Existing configuration, colors,
answers, other block layouts, and unrelated previews are unchanged.

For this correction, 95 targeted editor tests and 118 native headless tests
passed. The two new editor regressions failed against the previous shipping
bundle and passed after the fix. Shipping-HTML Playwright checks in headless
system Chrome at 390x844 and 834x1112 confirmed collapsed insertion selection,
no selected atom, no fallback heading/status, a 6-point paragraph gap, working
configuration, real range dragging, response serialization/reopening, no
overflow, and no page errors. Screenshots were visually inspected. Browser
plugin tooling was unavailable. No Xcode build, app launch, or simulator launch
was performed for this correction; physical-device WebKit behavior remains a
runtime verification boundary.

## Compact Single and Multi-Select Choices

Single Select and Multi-Select share a scoped compact presentation: 30-point
minimum chip height, 4-point vertical and 12-point horizontal padding, bold
labels in both selected and unselected states, 6-point row/column gaps, and a
6-point top margin without extra component padding. Optional questions have a
6-point gap before the choices. Long labels can still wrap and grow vertically.
The existing document colors, outlines, selected treatments, configuration,
single/multiple selection rules, and response JSON are unchanged. Rating and
Slider styling and behavior are intentionally unchanged.

Files changed for this refinement:

| File | Reason |
| --- | --- |
| `Vellix-backend/src/tiptap.html` | Scope compact spacing and bold labels to the two choice component types. |
| `Vellix-backend/dist/tiptap.html` | Synchronize the maintained HTML used by editor tests. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Synchronize the HTML shipped by Penned. No JavaScript regeneration was needed. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Match compact choice spacing, padding, and bold text in immediate native previews. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Advance the component renderer revision to v3 so existing component thumbnails refresh; ordinary previews keep their keys. |
| `Vellix/VellixTests/DocumentLaunchTests.swift` | Assert that old v2 component thumbnails are invalidated without invalidating ordinary previews. |
| `Vellix-backend/tests/template-components.test.js` | Cover compact metrics, selected/unselected bold labels, unchanged Rating sizing, and serialized responses. |
| `Docs/DailyNotes.md` | Record the changed presentation and verification boundary. |

Verification for this refinement:

- The new regression failed against the previous HTML (20-point margin instead
  of 6) and passed after synchronization. All 102 targeted editor tests passed.
- All 118 native headless tests in 8 suites passed, including native preview
  compilation and preview cache revision checks.
- Installed Playwright with headless system Chrome loaded the actual shipping
  editor HTML at 320x840, 390x844, and 834x1112. Browser plugin tooling was not
  available. Page identity, meaningful content, absence of error overlays, and
  console/page error checks passed.
- Both select components measured 30-point chip height, font weight 700,
  6-point choice gaps, zero outer padding, and a 6-point paragraph gap at all
  three widths. The screenshot's seven choices wrapped into 3, 2, and 1 rows
  respectively without overflow. Phone and tablet screenshots were inspected.
- Real clicks selected/deselected multiple choices and replaced the single
  selection; JSON reload preserved both answers. Template clicks reopened
  configuration without mutating answers. Unbroken long labels wrapped without
  escaping the available width. Rating and Slider retained their prior metrics.
- `git diff --check` passed in both projects. Source, dist, and shipping HTML
  are identical. Logs: `/tmp/penned-select-chips-regressions.log`,
  `/tmp/penned-select-chips-native.log`, and
  `/tmp/penned-select-chips-browser.log`. Screenshots are under
  `/tmp/penned-select-chips-*.png`.

No Xcode build, native app launch, or simulator launch was performed for this
refinement. Native device rendering and WKWebView touch behavior still need a
physical-device check; Chrome results are not presented as iOS runtime proof.
