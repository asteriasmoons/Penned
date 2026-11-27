# Document Block Preview Coverage

## Scope and Evidence

This audit traced the live editor registrations in `penned-editor/src/editor.js`
and their node modules, then compared those nodes with the native document,
template, card, spread, and miniature rendering paths. It corrects missing native
presentations and shares those presentations between preview surfaces.

Source coverage is not a physical-device visual certification. No builds,
compilation checks, tests, simulators, app launches, or browser sessions were run.
The editor source/bundle, widget implementations and dimensions, database schema,
CloudKit, and persistent PNG storage/key/pruning implementation were not changed.

## Preview Surfaces Traced

| Surface | Rendering path after this change |
| --- | --- |
| Home, All Docs, library galleries, template gallery thumbnails | `LibraryDocumentPreview` retains the existing persistent WebKit PNG and native `ImmediateDocumentPreview` fallback. |
| Full template preview | `GalleryDocumentPreview` retains its page/background layout but uses `ImmediatePreviewBlocks` instead of its separate, incomplete block implementation. |
| Template body preview | `GalleryDocumentBodyPreview` uses the same shared block renderer. |
| Immediate document/body preview | `ImmediateDocumentPreview` / `ImmediateDocumentBodyPreview` use the shared block renderer. |
| Pages-style nested cards | Existing `PageCardView` and `DocumentPreviewCache.cardSnapshot` use the corrected native fallback until the canonical capture is available. |
| Sticky-note cards | Existing `cardSnapshot(... hidesPageSurfaces: true)` path uses the corrected native fallback; sticky-note framing remains unchanged. |
| Open-page spreads | Existing `ImmediateOpenPagePreview` renders shared native blocks and preserves its two-page measurement/cropping behavior. |
| Nested Page rows and native-to-WebView page-reference thumbnails | `NestedPageThumbnail` now receives the real document/cache and observes the existing preview cache. It prefers the cached presentation image, then an already-cached card snapshot, and defers uncached capture. |
| Calendar document rows on iPhone/iPad/Mac | Same document-aware miniature path. This is distinct from the Calendar block inside a document. |
| Template search/Home rows and Daily Notes template pickers on iPhone/iPad/Mac | Same miniature path when a resolved template document is present. |
| Uncached/JSON-only miniatures | `DocumentThumbnailLayout` remains a bounded first-page structural fallback, with explicit coverage added for previously omitted blocks. |
| Appearance-only card-style samples | Intentionally retain decorative empty-paper/sticky/spread samples; these are style choices, not previews of a saved document. |

The canonical bitmap renderer already loads the actual editor schema, native
collection images, owned attachments, fonts, nested-page references, and widget
resources. It remains the highest-fidelity representation. That renderer, its
capture identity checks, and its separate noninteractive WebView were inspected
but not modified.

## Block Inventory and Coverage

The table groups variants that share one persisted node type. Structural child
nodes are listed explicitly so their content is not mistaken for unsupported
standalone blocks. All rows use the live editor in the canonical PNG path.

| Block/node family | Native document/template/card fallback | Uncached miniature fallback |
| --- | --- | --- |
| `paragraph`, `caption`, regular `heading` levels 1-6 | Existing inline styling, alignment, fonts and placeholder guidance retained in the shared renderer. | Existing text-length-based marks. |
| Heading Labels on `heading` | Existing `HeadingLabelTile` settings renderer retained. | Existing native label Canvas symbol retained. |
| `text`, `hardBreak`, `inlineTag` | Existing `InlineTextPreview` handles text, line breaks, tags and inline marks inside their owning blocks. | Existing inline-text extraction. |
| Bold, italic, underline, strikethrough, code, links, highlights and text colors | Existing inline mark renderer retained; nested blocks now receive their owning container's ink color. These are marks, not additional block nodes. | Structural text at miniature scale; canonical bitmap contains the actual marks. |
| `bulletList`, `orderedList`, `listItem` | Existing recursive list rendering and numbering retained. | Existing list markers and recursive content. |
| `taskList`, `taskItem` | Checked and skipped/crossed states distinguished. Existing task metadata supplies reminder and recurrence labels without creating or completing tasks. | Existing checkbox/crossed marks retained. |
| `toggleItem`, including heading toggles | Existing disclosure and open/closed child selection retained. Descendants use the shared renderer. | Existing collapsed/open traversal retained. |
| `blockquote` | Saved-color strip, rounded neutral container, border and inset now match the editor's structure. | Existing bounded container marks. |
| `plainCallout`, `plainCalloutRow` | Existing color/minimum-height and row sizing retained. Container ink now reaches its nested blocks. | Plain-mode settings corrected; nested children now recurse instead of flattening to text. |
| `iconCallout` | Custom/library glyph retained. Title, title color, disclosure color, collapse state, and full-width body beneath a title are now represented. | Existing icon/title/disclosure marks plus recursive visible content. |
| `gridCard`, legacy `callout` | Existing full/half width, saved height, alignment, icon and color presentation now also used by template previews. | Existing grid-card sizing and pairing retained. |
| `divider`, legacy `horizontalRule` | Existing thin/thick line, dotted, four-circle and Washi Tape paths retained. | Tiny-dot alias and quarter-scale dot sizes corrected; Washi Tape path retained. |
| `pageBreak` | Top-level page splitting retained; nested breaks have an explicit separator instead of vanishing. | Existing page-break mark. |
| `listGrid`, `listGridRow`, `listGridLabel`, `listGridValue` | Existing `ListGridPreview` retains the grid's own row/cell styling. Child nodes are rendered through that owning block. | Existing list-grid surfaces, text, widths and guidance retained. |
| `table`, `tableRow`, `tableCell`, `tableHeader` | Cell/header styling, widths, spans and saved formula results retained. New measured-cell layout supports structured nested blocks rather than extracting only text; available viewport width clips overflow instead of forcing 320 points. | Explicit table cells/borders/fills added; bounded structural representation. |
| `tabs`, `tabPanel` | Full saved container/header/tab-bar settings and the persisted active panel now shared with template previews. Mixed half-width children in the visible panel use shared grouping. | Tab bar added; only the saved active panel is traversed. |
| `minimalFields`, `minimalRecord`, `minimalRecordTitle`, `minimalField`, `minimalFieldLabel`, `minimalFieldValue` | Existing accent/divider/label treatment now shared with templates. Numeric range argument order corrected; hidden record titles, saved value color/size and field spacing honored. | Title/label inline content no longer disappears; structural children recurse. |
| `informationCard`, `informationCardTitle`, `informationCardDescription`, `informationCardBody`, `informationCardLabel` | New saved-style card presentation with title/description, labels, body, border/padding/radius, divider visibility and collapse state. Inline child text no longer falls through an empty recursion path. | Title/description/body and collapse/visibility handling added. |
| `weekStrip`, `weekDayPanel` (document Calendar block) | New title, navigation glyphs, seven date bubbles, saved colors/font weight, selected-date behavior, collapsed state, divider and selected panel's nested content. Hidden date panels are not flattened together. | Seven-bubble structure, selected color and only the visible selected-date content added. |
| `linkedCalendarEvent` | New saved event title, calendar name, local date/time, time zone, all-day and unavailable presentations. No Calendar permission request or event mutation is introduced. | Event title/metadata and accent mark added. |
| `codeBlock` | New palette-aware monospaced numbered-line presentation. CRLF is treated as one line break. Canonical WebKit PNG supplies the full Prism syntax coloring. | Existing code marks remain bounded and monospaced. |
| `inlineProperty` | Existing `InlinePropertyPreview` and property-type formatting retained. | Existing property marks retained. |
| `richLink` | Existing metadata/image/layout renderer now also used by template previews, including adjacent card grouping. | Existing rich-link structural presentation retained. |
| `attachment`: image, video, audio, PDF and file/card modes | Existing `AttachmentBlockPreview` retained. Unavailable attachment data now leaves a named/type card rather than silently omitting the block. | Local image path now reaches the image mark, enabling actual artwork when available; other modes retain structural cards. |
| Web clips on `plainCallout.clipSource` | Existing source image/title/date/tag/body treatment now shared with templates. | Existing source-card representation retained. |
| `pageReference`: Page and Card | Existing row/card presentation and reference resolution retained. The row miniature now prefers document-backed snapshots. | Existing page reference mark; no recursive document import. |
| `collection` | Existing collection snapshot and entry fields retained. | Explicit collection structure added instead of an empty atom. Full entry data requires resolved collection metadata. |
| `templateComponent`: rating, single-select, multi-select, slider | Existing definition/response renderer now shared; controls remain noninteractive. | Existing chips/slider marks retained. |
| `moodBar`, `countdown`, `calculator` | Existing native widget views reused without edits. Countdown's latest expanding-row layout and the 192-point frame remain intact. | Existing native widget symbols retained. |
| `doc` and structural wrappers | Page-level or owner-level traversal. They do not need a second independent UI. | Recursive traversal with existing depth/node/page bounds. |

## Main Corrections

### One Native Block Renderer

`ImmediatePreviewBlocks` is now module-visible and is used by both native
document and template previews. The duplicate gallery block/helper implementation
was removed. It had no rich-link or grid-card branch, stripped Tabs to panel
content, reduced Minimal Fields to plain labels, and did not display new Calendar
atoms. This change prevents those two native paths from continuing to drift.

Full template previews pass an unlimited per-level block limit, preserving their
previous full-document behavior. Immediate bitmap fallbacks retain a 96-block
per-level budget, 32-table-row budget, and 16-level nesting guard. The existing
small-thumbnail builder keeps its 256-node/first-page bound. This does not load
the whole library or remove the library's pagination/descriptor optimizations.
Its new table and tab-bar traversal is also bounded. Callout, Information Card,
and Calendar content inherit their saved text colors, and their saved background
colors are painted opaquely rather than as a faint generic container wash.

### Structured Containers and Nested Content

`StructuredBlockPreviews.swift` holds read-only Calendar, linked-event,
Information Card and code presentations. Calendar and Information Card children
re-enter the same block renderer as top-level content. Collapsed containers do
not reveal their hidden body, unrelated date panels, or inactive tab panels.

The table fallback now measures the actual cell views, distributes extra height
across row spans, and places merged cells at their saved column widths. Nested
widgets, callouts, calendars, and other structured content are rendered as blocks
inside cells rather than disappearing into plain-text extraction.

### Document-Aware Small Thumbnails

`NestedPageThumbnail` accepts an optional real document and existing preview
cache. Its observed child prefers `cachedPresentationImage`, then calls
`cardSnapshot` in cache/request-only mode. Existing native/PNG snapshots are reused;
if absent, the improved structural image stays visible and the record joins the
existing deferred queue. It does not synchronously render a full document inside
each tiny row, create another cache, or create an interactive editor. Existing
Space checks, queue serialization and recursive-render guards remain. Cache
publications update the thumbnail independently of its parent's equatable check.

The document/cache are passed from nested rows, the bridge thumbnail generator,
Calendar rows on both platforms, Home/search template rows, and Daily Notes
template selectors. Pure appearance samples and unresolved JSON-only templates
retain the structural fallback; they are not represented as fake saved records.

## Cache, Performance and Integrity Protections

- No cache-version bump, bulk invalidation, database migration, or eager library
  scan. Existing PNGs are retained until their usual replacement is available.
- PNG filenames, keys, validation, pruning, cold-launch priming, capture identity
  checks, serial capture queue, and the separate WebKit renderer are unchanged.
- No change to widget source, shared widget dimensions, Calculator, Mood Bar or
  Countdown implementation. Previews reuse those views instead of copying them.
- No editor JS/bundle edits, focus/selection/drag handlers, document-opening
  changes, autosave transactions, navigation destinations, or CloudKit changes.
- Preview controls are read-only. The new Calendar view computes presentation
  from saved attributes and never inserts date panels or changes selection.
- Linked event blocks display the saved event snapshot; unavailable calendar
  content is not invented. Missing attachment bytes are not fabricated or used
  to bypass ownership checks.

## Files Changed

| File | Reason |
| --- | --- |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Shared native block dispatch; container/title/collapse/ink coverage; task metadata; Minimal Fields settings corrections; configurable rendering bounds. |
| `Vellix/Documents/StructuredBlockPreviews.swift` | New read-only Calendar, linked event, Information Card and code presentations. |
| `Vellix/Documents/ImmediateTablePreview.swift` | Measure actual structured cells, preserve spans and respect available width. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Optional cache/request-only card lookup for miniatures; existing callers keep their original native fallback behavior. |
| `Vellix/Templates/GalleryDocumentPreview.swift` | Reuse the shared renderer; remove duplicate incomplete block/helper implementations. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Explicit missing-family structural coverage, nested callout traversal, real attachment image paths and divider proportions. |
| `Vellix/Editor/NestedPageThumbnail.swift` | Observe/reuse existing snapshots when real document context is provided. |
| `Vellix/Editor/NestedPageRow.swift` | Supply document/cache context to the miniature. |
| `Vellix/Editor/PageReferencePresentation.swift` | Supply the same context for bridge-generated thumbnails. |
| `Vellix/Calendar/CalendarAgendaRows.swift` | Supply context for iPhone/iPad Calendar document rows. |
| `PennedMac/Browser/MacCalendarDocumentPreview.swift` | Same Calendar row coverage on Mac. |
| `Vellix/DailyNotes/DailyNotesSettingsView.swift` | Resolve template-picker miniatures through the existing cache. |
| `PennedMac/Settings/MacDailyNotesSettings.swift` | Same template-picker coverage on Mac. |
| `Vellix/Documents/HomeView.swift` | Supply resolved template document/cache when available. |
| `Vellix/Search/SearchView.swift` | Same template-result thumbnail context. |
| `Docs/BlockPreviewCoverage.md` | Inventory, implementation details, limits and verification record. |

## Validation and Remaining Limits

Static source/reference and whitespace/diff review were performed. The
`penned-editor` worktree and the live editor bundle remain unchanged, so no npm
bundle rebuild is needed for these native changes. No build or test was run.

Pixel-level parity on actual iPhone/iPad/Mac screens remains unverified. Native
fallbacks use native layout rather than WebKit, so glass effects, syntax-token
colors, exact font metrics, remote images and very narrow container geometry may
differ until the canonical bitmap replaces the fallback. Code fallback has the
saved theme and line numbering but is not a second Prism implementation.

A 37-by-48 thumbnail shows only a tiny first-page crop. Its structural fallback
is intentionally not a readable full-document facsimile: complex merged tables
are simplified, collection entry data requires resolved metadata, and off-page
blocks are clipped rather than packed into an inaccurate miniature. Document-
backed thumbnails now prefer actual rendered content wherever that context is
available. JSON-only/unresolved templates cannot display unavailable linked
document/collection/remote-media data.

Uncached miniature captures use the existing deferred queue and remain deferred
while editing is active. The structural fallback remains visible during that
time. Existing larger-card native snapshot generation still has its existing
cost; device scrolling/startup timing was not measured.
Previously cached images can retain their older appearance until normal
regeneration. This audit does not claim every preview is visually identical or
that physical-device verification has occurred.
