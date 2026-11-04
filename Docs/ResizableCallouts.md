# Resizable Iconless Callouts

Only `plainCallout` has resize controls. Unmodified callouts retain their existing
full-width layout, padding, background, and nested content. Icon callouts do not
gain resize controls.

## Resizing and Insertion

The right-edge grab line uses the table resizer's existing hit area, touch
suppression, pointer capture, live DOM sizing, release, and cancellation lifecycle.
Both now call `VellixTables.trackHorizontalResize`. Dragging does not serialize or
replace callout content. Releasing commits a percentage width as one undoable edit;
cancelling restores the original display without committing it.

Shrinking a standalone iconless callout wraps that block in `plainCalloutRow`.
This is a dedicated block-flow container, not the retired `columns`/`column`
feature. Existing retired-column migration remains intact. Each child remains an
independent block with its existing ID, attributes, content, and nested page IDs.

The unused portion of a row is an unpainted insertion target, not a plus button or
menu. Tapping it places a temporary paragraph/caret in that row. Choosing Callout
without Icon through the ordinary insertion controls replaces the paragraph with
an independent callout using the remaining width. Native insertion sheets may
blur the WebView without losing that insertion target. Unused tap-created
paragraphs are excluded from saved snapshots and removed on selection departure.
Other insertion choices keep normal document flow outside the row.

### Insertion Context

Only an explicit tap on `.penned-callout-space` authorizes column insertion. The
caret-slot plugin tracks that paragraph's ID, mapped position, and owning row ID;
moving the selection outside it immediately invalidates the column target.
Ordinary paragraphs below a row never receive the row's remaining width. Gap
hit-testing does not create horizontal targets from vertical row boundaries.

The native color sheet captures the current insertion selection before opening,
both for normal document flow and for an explicitly selected column. While that
sheet owns the selection, blur cleanup preserves its temporary paragraph. Add
awaits the actual insertion before dismissing the sheet. Cancelling releases the
hold and cleans up unused paragraphs. A changed selection wins over the old sheet
bookmark, and loading another document invalidates the token entirely.

This corrects the original asymmetry where blur preserved row paragraphs but
deleted normal-flow insertion paragraphs, allowing the pending insertion to fall
back into an existing callout row. Column insertion now replaces only its empty
target paragraph and rejects a row with no remaining width rather than falling
back to a new 100-percent row child. Existing row children are not rewritten.
The empty caret paragraph is removed outside the undo history before the new
callout is inserted, so Undo restores the spare column without resurrecting an
untracked blank row cell. Redo restores the same callout and width.

Sibling widths are not recalculated from content. Resizing cannot take space
already assigned to another callout. Rows use a 12-point gap and wrap at narrow
container widths rather than overlapping; saved proportions are not changed by
viewport resizing. Double Return exits the whole row, preserving the existing
iconless-callout exit behavior. Deleting the final child removes the empty row.

## Persistence and Presentation

`plainCallout.attrs.widthPercent` stores the manually chosen width; missing or
null means the existing full-width default. `plainCalloutRow.content` stores the
adjacent blocks. Existing document JSON storage, revisions, undo history, assets,
template cloning, and CloudKit synchronization carry these without a migration.
Native immediate/gallery previews and thumbnail drawing understand the row.
The preview cache version changes so old stacked thumbnails are regenerated.

The publishing projection, server validator, and shared reader source accept rows
and callout widths. They require the normal publishing deployment and reader asset
refresh before the live website can show the new layout. Markdown and Word keep
all nested content using their existing recursive fallbacks; Markdown does not
represent horizontal layout.

## Build Boundary

No builds, tests, simulators, linters, or runtime verification were run. The editor
JavaScript changes are in `../penned-editor/src`; regenerate the shipped editor
with that project's existing `npm run build` before building Penned. This also
copies the updated table script and editor HTML into `VellixEditor.bundle`.
The shared reader source changes require the website's existing reader asset
generation step. Generated JavaScript bundles were not hand-edited.

Insertion-context regression cases are in `../penned-editor/tests/callout-runtime.test.js`.
They cover empty-column insertion, insertion below an unchanged row, switching
locations, ordinary row paragraphs, cancellation, and document reload. They were
added but not run.

The insertion-context fix changes `caret-slots.js`, `resizable-callouts.js`, and
`editor.js` in the editor source, plus that runtime test file. Native changes are
in `Vellix/Editor/DocumentEditorView.swift` and both `TipTapEditorSession.swift` and
`PennedMac/Editor/MacTipTapEditorSession.swift`, which expose the scoped native
sheet insertion lifecycle. This document records the behavior and source-only
verification boundary. No layout, table-resize, database, or sync changes are
part of the insertion-context fix.

## Changed Files

In `../penned-editor/src`:

- `editor.js`: schema registration, ordinary insertion routing, row exit, nested
  selection, and caret-slot integration.
- `resizable-callouts.js`: callout node views, persistent row structure, spare
  insertion targets, resizing, and empty-row cleanup.
- `callout-layout.js`: shared percentage validation and row width calculations.
- `vellix-tables.js`: extracts the existing captured-pointer drag lifecycle for
  use by both tables and callouts, retaining table width calculations.
- `caret-slots.js`: caret insertion/cleanup from the preceding caret request;
  retains a selected column target while native insertion sheets are open.
- `retired-column-content.js`: discards empty callout rows while keeping legacy
  column migration separate.
- `tiptap.html`: responsive row layout and live resizing styles.
- `public-document.js`: shared reading schema/rendering for persisted rows.

In the native project:

- `Vellix/Editor/TipTapContentAnalyzer.swift`: validates persisted callout width
  and removes empty structural rows without changing legacy column conversion.
- `Vellix/Editor/DocumentThumbnailLayout.swift`: row-aware thumbnail drawing.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: proportional, wrapping row
  preview layout shared by the native preview implementations.
- `Vellix/Templates/GalleryDocumentPreview.swift`: uses that row layout.
- `Vellix/Documents/DocumentPreviewContent.swift`: invalidates outdated previews.
- `Vellix/Publishing/PublishingProjection.swift`: projects row/width metadata.
- `Vellix/VellixEditor.bundle/tiptap.html`: mirrors editor stylesheet changes.
- `supabase/functions/penned-publishing/contract.ts`: accepts/validates row and
  width metadata on the publishing server.
- `Docs/ResizableCallouts.md`: structure, behavior, file inventory, and build
  boundary documentation.
