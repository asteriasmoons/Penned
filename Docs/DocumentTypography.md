# Document Typography

## Sizes (2026-10-29)

Document page titles use 24 points in native SwiftUI and 24 CSS pixels in web
rendering. Document content uses these CSS pixel sizes, mirrored in native
opening previews:

| Block | Size |
| --- | --- |
| Title (H1) | 24 |
| Subtitle (H2) | 21 |
| Heading (H3) | 18 |
| Subheading (H4) | 16 |
| Paragraph | 14, Regular |
| Caption | 12 |

Add, Convert, Toggle, slash menus and the Mac inspector use these names. Existing
H5/H6 are removed from Add, Convert, Toggle, slash and Mac controls, including the
Additional Headings submenus. Conversion targets and native creation commands
accept only H1-H4. Existing saved H5/H6 content remains readable without rewriting
documents or changing the loading/schema architecture. Slash labels and search
details are updated in source and the shipping JavaScript; the obsolete H5 item
is removed from both. The shipping edit is a bounded mechanical string update,
not a bundle build.

These sizes no longer shrink at the narrow-editor breakpoint. Existing heading
weights, explicit rich-text marks, fonts, spacing and editor interactions remain
intact. Caption CSS overrides the old relative inline size in already-shipped
editor JavaScript without rebuilding or editing that bundle. Export font-size
options still scale the visual export when explicitly selected by the user.

All four divider styles (thin line, thick line, dotted circles, four circles)
derive their color from the document's primary text color. The four circles are
fully opaque, both normally and when selected, including native opening previews.
The other styles retain their existing opacity and geometry, including the mobile
thin/thick line overrides.
Divider-specific selection decoration no longer replaces that hue with cyan.

## Files Changed

- `Vellix/VellixEditor.bundle/tiptap.html`: shipping editor heading/body/caption sizing and divider color inheritance.
- `../penned-editor/src/tiptap.html`: matching maintained editor styles so subsequent builds retain the changes.
- `../penned-editor/src/caption.js`: serialize the caption's explicit 12px size.
- `Vellix/Editor/DocumentEditorView.swift`: 24-point mobile page titles, including daily-note/task pages, and named Add/Toggle/text-style controls.
- `PennedMac/Editor/MacDocumentEditorContainer.swift`: 24-point Mac page and task-page titles.
- `Vellix/Tasks/TaskHistoryPageHeader.swift`: matching default task-page title size.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: matching heading/body/caption preview sizes, ordered-list numbering, and solid four-circle dividers.
- `Vellix/Documents/ImmediateTablePreview.swift`: matching 14-point table body text, retaining header/cell formatting.
- `Vellix/Documents/DocumentPreviewCache.swift`: matching 24-point snapshot page titles.
- `Vellix/Documents/DocumentPreviewContent.swift`: version preview keys so cached older typography is regenerated naturally.
- `Vellix/Export/DocumentExportScript.swift`: 24px visual-export page titles and 21px subtitles; body/divider styling comes from the shared shipping editor styles.
- `/Users/asteriasmoons/Penned-Site/public/viewer-assets/editor.css`: matching public-reader content sizes and divider colors.
- `/Users/asteriasmoons/Penned-Site/src/styles/reader.css`: matching 24px published page titles and 21px subtitles on narrow and wide layouts.
- `Vellix/Editor/TipTapBridgeTypes.swift`: shared style display names and compatible native slash-menu labels.
- `Vellix/Editor/TipTapEditorSession.swift`: reject obsolete H5/H6 insertions and block conversions before sending mobile commands.
- `PennedMac/Editor/MacTipTapEditorSession.swift`: matching Mac command guards.
- `Vellix/Editor/TextBlockConversion.swift`: named conversion/toggle choices restricted to H1-H4 and guards against obsolete native creation commands.
- `PennedMac/Inspector/MacFormatInspector.swift`: named format controls.
- `PennedMac/Inspector/MacInsertInspector.swift`: the six named insert styles, including Subheading.
- `../penned-editor/src/editor.js`: matching slash-menu labels and searchable size/legacy-level descriptions.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: corresponding shipping slash-menu labels, with the obsolete H5 item removed.
- `Docs/DocumentTypography.md`: size contract, file list and verification limits.

## Verification Boundary

Source inspection only. No builds, tests, compiler/bundler commands, app launches
or simulator checks were run. Device/browser visual verification remains.
Website source changes are not deployed. Document JSON, persistence, page-opening
HTML assembly, selection logic and WebView ownership are unchanged.
