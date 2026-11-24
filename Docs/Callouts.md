# Callouts

## Current Behavior

Use **Add Block > Content Blocks > Callouts > Icon** on iPhone or iPad, or
**Insert > Callouts > Icon** in the Mac inspector. Slash search offers
**Icon Callout** and **Plain Callout**. Plain keeps its existing rich text,
color action, resizing, and row layout. Its saved color is now an opaque fill
with contrasting default text, just like Grid Cards. Web clip source cards
keep their separate styling.

Icon Callout remains the existing `iconCallout` block, with no fixed height.
Its text wraps next to the left icon and can be edited and formatted in place.
Both callouts use the existing 12-point corners. Insertion opens **Callout
Settings**; tap the icon to reopen it. Settings can also edit an ordinary,
unformatted body. Formatted or mixed-content bodies remain editable in the
document without being flattened by the settings sheet.

## Optional Title, Collapse, And Icon Outline

This follow-up extends the existing Icon Callout instead of introducing another
block type. Existing nodes default to an empty title, Collapse Mode off, and an
expanded body, so neither optional feature changes old documents' layout.

### Settings And Presentation

- **Title (Optional)** is a plain-text field in the existing Callout Settings
  sheet. Empty/whitespace-only titles do not reserve a title row. When present,
  the title sits beside the left icon; the rich body sits beneath the title,
  aligned with its text column. Editing a title changes an attribute, not body
  paragraphs, lists, inline marks, attachments, or nested blocks.
- **Title Color** is a separate existing-style ColorPicker with an Automatic
  reset. Its automatic value follows the callout's effective text color.
- **Collapse Mode** is off by default. Enabling it adds a control at the right,
  opposite the icon, using the registered `chevup`/`chevdown` assets. It works
  with or without a title. Disabling it clears the collapsed state so content
  cannot remain inaccessible after removing the control.
- **Collapse Button Color** is another independent ColorPicker, shown when
  Collapse Mode is enabled. Automatic follows the icon color. There are no
  preset color buttons.
- When collapsed, the callout shows **only its icon, optional title, and expand
  control**. The body and all nested content are hidden, inert, and excluded from
  accessibility. The content remains in document JSON and is revealed again on
  expansion. There is no body excerpt in the collapsed header.
- Collapse updates only `collapsed` through a ProseMirror transaction. It does
  not replace the body. When collapsing the active body, selection moves to
  available outside text (or the whole callout when no outside text exists),
  and native focus is dropped so the control does not raise the keyboard. The
  existing height callback runs on the next animation frame. Read-only and
  selection-mode safeguards remain in place.
- Dismiss Keyboard clears both title and body focus and leaves the sheet open.
  The preview includes the title/color and live collapse control. Closing the
  sheet without Done retains the original saved settings.

### Outline And Contrast

The screenshot's bright cyan/pink pair can have weak luminance contrast despite
its different hues; thin anti-aliased outline artwork can look even fainter.
The inspected library-icon CSS does not deliberately reduce icon opacity.
[W3C Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast)
explains the light/dark contrast requirement and thin-edge anti-aliasing effect.
No exact contrast ratio is claimed for the screenshot's unknown saved hex values.

Icon Callouts now add a fine four-direction silhouette outline around the
transparent icon button's painted glyph, not a visible frame around the button.
Its dark/light color comes from the existing background-readable ink calculation.
The icon retains its selected color. This also supports custom imported images
without modifying the stored PNG, alpha cleanup, tint masks, library renderer,
or shared icon cache. The native settings glyph uses the same treatment. This
improves edge separation; it is not a claim that every arbitrary user palette
meets an accessibility contrast threshold.

### Persistence, Previews, And Exports

`title`, nullable `titleColor`, `collapsible`, `collapsed`, and nullable
`collapseColor` travel in the same block attributes and existing settings commit,
normalization, autosave, and CloudKit document path. No database migration or
sync protocol was added. Native thumbnail descriptors include the optional title,
colors, disclosure, and collapsed appearance. Search/plain-text extraction
includes the title. Existing attachment persistence and custom-icon imports are
unchanged. Older editing builds do not understand these new attributes; update
editing devices before relying on the new metadata across devices.

Markdown and Word include the title and preserve the full body even when the
interactive callout is collapsed. The PDF export clone expands the body and
removes its disclosure without changing the live document. The deployed public
reader/publishing-service contract was not changed in this task; the additional
title/collapse attributes are not yet part of that external publishing contract.

### Changed Files And Verification

- `penned-editor/src/icon-callout.js`: optional attributes, HTML round trips,
  rendering, and scoped disclosure event plugin.
- `penned-editor/src/editor.js`: passes existing selection/height callbacks and
  includes titles in plain-text extraction. Enter/list/toggle handlers unchanged.
- Maintained and shipped `tiptap.html`: conditional header grid, hidden-body rules,
  asset-shaped disclosure, colors, and silhouette outline. Existing nested-toggle
  alignment and legacy follower rules remain unchanged.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: synchronized only the Icon
  Callout module, factory options, and title extraction without a build.
- `Vellix/Editor/IconCalloutSettings.swift`: native fields, payloads, ColorPickers,
  draft preview, focus dismissal, and icon-outline preview.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: optional-color normalization and
  searchable title extraction.
- `Vellix/Editor/DocumentThumbnailLayout.swift`: title/disclosure and hidden-body
  fallback thumbnails.
- `Vellix/Export/DocumentMarkdownExport.swift`, `DocumentWordExport.swift`, and
  `DocumentExportScript.swift`: title-preserving complete-content exports.
- `Docs/Callouts.md`: this implementation and its limitations.

No builds, tests, compilation, linters, app launches, or simulators were run.
Only source review, resource synchronization, and whitespace checks were used.
Native sheet behavior, WebKit touch activation, nested collapse/reopen, physical
device appearance, PDF output, and cross-device delivery remain unverified.

Choose a Penned icon, a photo, or an image file. Library icons retain the
existing mask, tint, and asset renderer. Imported art retains its colors,
transparency, and proportions; a separate import step trims thin alpha
artifacts around the silhouette and stores the prepared PNG as a normal
document attachment. **Icon Color** works for both library icons and imported
images. Imported images keep their original colors unless a tint is set. Tint
fills the visible shape with the chosen color, using the image's transparency
to preserve its edges. Use **Original Colors** to remove the tint without
reimporting the image. **Text Color** sets the default text color for the
callout without changing explicit inline colors. Use **Automatic** to restore
background-based contrast. Each color is set through its picker, with no presets.
The existing icon/image and body-color settings travel with the block and render
in previews, PDF and Word exports, and the public reader. The new optional-header
publishing limitation is documented above. **Dismiss Keyboard** uses the same control as Heading Label Settings
on iPhone/iPad and leaves the sheet open. **Done** saves the draft; closing
without Done leaves the block's saved settings alone.

There is no database or sync-protocol change: the block saves the attachment
path in its attributes and CloudKit transfers the PNG via the usual attachment
record. Native previews and published reader source understand the block.
Existing Grid Cards are unchanged, and legacy `callout` JSON still opens as
[Grid Cards](GridCards.md), not as Icon Callouts.

### Source and Rollout

- Editor source: `src/icon-callout.js`, `grid-card.js`, `editor.js`,
  `attachments.js`, `callout-list-backspace.js`, and `tiptap.html`.
- Native editor and sheets: `IconCalloutSettings.swift`, `GridCardSettingsSheet.swift`,
  `HeadingLabelSettings.swift`, `TipTapBridgeTypes.swift`,
  `TipTapEditorSession.swift`, `MacTipTapEditorSession.swift`,
  `DocumentEditorView.swift`, `MacEditorPresentations.swift`,
  `MacInsertInspector.swift`, `MacFormatInspector.swift`, and
  `MobileBlockSelection.swift`.
- Persistence and rendering: `TipTapContentAnalyzer.swift`, `AttachmentMedia.swift`,
  `ImmediateDocumentPreview.swift`, `GalleryDocumentPreview.swift`,
  `DocumentPreviewContent.swift`, `DocumentThumbnailLayout.swift`, and
  `NestedPageThumbnail.swift`. `DocumentMarkdownExport.swift` preserves the
  text; `DocumentWordExport.swift` also includes the custom image and solid
  background. `DocumentExportScript.swift` flattens the image tint for PDF output.
- Publishing: `PublishingProjection.swift`, the publishing service's
  `contract.ts`, and editor `src/public-document.js` keep the private path
  out of public content and reference the published image through its media ID.

No builds or tests were run for this follow-up. Its maintained source and
corresponding embedded editor JavaScript/HTML were synchronized directly; no
editor build is required to pick up these included resources. Public reader
assets were not regenerated.
Update all editing devices before opening documents containing Icon Callouts.
Public publishing also needs the updated service and regenerated reader assets.

## Historical Implementation

The notes below describe the pre-Grid Cards implementation and its verification.

Existing icon callouts remain the `callout` node. Their IDs, icons, colors,
formatted content, icon picker, and saved JSON are not migrated or replaced.
Populated text aligns with the top of the entire icon button, not the icon glyph
inside it or the center of the multiline text column. Empty callouts retain their
existing centered, immediately editable caret. First-line measurements account for empty breaks,
font changes, and headings without modifying ProseMirror's document DOM. Wrapped
lines stay inside the text column and grow downward. Colors, borders, icon size,
and outer padding remain; both callout containers now use a 12-point corner radius.

`plainCallout` is a separate TipTap node with its own HTML class and parser.
It has a persistent color and formatted block content but no icon attribute,
icon picker, icon glyph, or reserved icon column. Its container uses the same
background, border, corner radius, and padding as the icon callout.

The native add menu offers Callout > With Icon / Without Icon. With Icon keeps
the existing picker. Without Icon opens the existing color controls, including
custom colors, before Add creates the block. Cancel inserts nothing. Its
background/border also has an accessible, visually transparent color button
that opens color-only controls without interfering with text editing. Read-only
and block-selection modes do not open those controls. Both variants are also
available as slash commands. Icon callouts retain their one-Return exit. In a
no-icon callout, Return adds a line inside the same paragraph; a second Return
on the new empty line removes that empty line and continues outside the callout.

When either callout type touches a page break, its page-edge inset is a 20-point
external margin, not extra padding inside its painted box. Its normal 8-point
internal padding, colors, corners, and empty-state alignment stay unchanged. The
same rule applies on both sides of a page break; other block spacing is unchanged.

## Files

- `Vellix-backend/src/editor.js`: independent node/schema, insertion with color,
  color requests, block selection, slash choices, and preserving existing icons
  and rich content when recoloring.
- `Vellix-backend/src/tiptap.html`: full-opacity icon mask, first-line alignment,
  centered empty caret, matching container corners, and transparent color hit target.
- `Vellix/VellixEditor.bundle/tiptap.html` and `tiptap.bundle.js`: synchronized
  shipping editor assets generated from the maintained source above.
- `Editor/DocumentEditorView.swift`: add-menu submenu and native color sheets.
- `Editor/TipTapBridgeTypes.swift`: the color-only picker event.
- `Editor/TipTapEditorSession.swift`: color requests and colored insertion.
- `Editor/TipTapContentAnalyzer.swift`: normalization, legacy ingestion, search
  text extraction, and recursive callout detection for previews.
- `Documents/ImmediateDocumentPreview.swift`: matching native preview containers,
  first-line alignment, full-opacity icons, and no-icon rendering.
- `Documents/DocumentPreviewCache.swift`: full-opacity snapshot glyphs.
- `Documents/DocumentPreviewContent.swift`: callout-only renderer revision so
  previously faded images are regenerated without invalidating unrelated pages.
- `Editor/DocumentThumbnailLayout.swift`: no-icon thumbnail container support.
- `VellixTests/VellixTests.swift`, `VellixTests/DocumentLaunchTests.swift`: native
  bridge, persistence, formatting, thumbnail, and cache regression coverage.
- `Vellix-backend/tests/callout-runtime.test.js`: seven executable editor checks.
- `Vellix-backend/tests/callout-layout.test.js`: first-line, empty-caret,
  large-type, non-mutating layout, and measurement-stability regression checks.
- `Vellix-backend/tests/callout-page-break.test.js`: external page-edge spacing
  for both variants and all three page-break markers, plus ordinary-block checks.

## Verification

Seven callout runtime tests passed. The complete JavaScript suite ran 106 tests:
100 passed, with six failures in the separate table tests (three zero-dimension
table checks, insertion routing, a stale source-shape assertion, and formula
reference adjustment). Table implementation and table tests were left unchanged.

The shipped editor HTML was exercised in headless system Chrome using Playwright
because the Browser plugin was not available. At 390x844 and 834x1112, checks
confirmed meaningful rendering, full icon opacity, matching container styles,
centered text, no overflow, no-icon color requests, actual text editing, and JSON
round trips without changing the original icon callout. No page errors occurred.
Screenshots are `/tmp/penned-callouts-phone.png` and
`/tmp/penned-callouts-tablet.png`.

Native Swift tests were added but not run. No Xcode build, Penned app launch, or
simulator launch was performed. Browser checks do not verify native iOS sheets,
menus, or WebKit rendering on a physical device.

### First-Line Alignment Update

The alignment correction passed 68 targeted JavaScript checks, including five
layout tests and the existing callout, block removal, collection, task, property,
and paragraph-gap regressions. Shipped HTML was also checked in system Chrome
at 390x844 and 834x1112: unchanged empty caret focus, immediate typing, populated
text alignment to the top of the whole icon box,
natural wrapping, deletion back to empty, Shift-Enter, font changes, large text,
JSON round trips, and 12-point corners on both variants passed without page errors.
The measured populated text-to-icon-box top difference was zero at both sizes;
the empty-state geometry remained identical to the preceding renderer. Reference-style
screenshots are `/tmp/penned-callout-alignment-reference-phone.png` and
`/tmp/penned-callout-alignment-reference-tablet.png`.

The native fallback top-aligns populated text with the icon box while retaining
the centered empty-state layout and the same corners. `callout-presentation-v5`
regenerates only affected preview images.
Native preview/cache tests were updated but not run; no native build or launch
was performed for this update.

### Page-Break Spacing Update

Both callout variants now use 20-point external margins beside a page break,
with their original 8-point internal padding. The maintained HTML and shipping
HTML match. The callout preview revision advances from v4 to v5; the native
cache regression includes v4 as an obsolete renderer revision.

All 73 targeted JavaScript tests passed, including the five new page-break
spacing checks. The block-action test harness now recognizes the existing
400ms block hold as well as the 550ms page-reference hold; production gesture
behavior was not changed.

Headless Chrome checks of the shipping HTML at 390x844 and 834x1112 confirmed
20-point external insets, unchanged callout dimensions and empty-caret geometry,
matching native page-break bridge coordinates, unchanged saved JSON, and actual
page-break insertion. No browser page errors occurred. These checks verify the
editor and its bridge geometry, not the native page-background rendering.
Swift tests, native builds, and app/simulator launches were not run.

### Template Guidance Alignment Update

No-icon callout guidance now contributes its actual wrapped height to the text
column. Its CSS ignores the placeholder plugin's estimated inline minimum height
and contains the floated guidance without moving the editable caret onto an
extra line. The existing flex container centers the resulting text column.
This prevents short prompts sitting at the top of a tall estimated paragraph,
including after toggling template placeholder mode. Icon callouts and placeholder
layout outside no-icon callouts are unchanged. Colors, opacity, corners, stored
guidance, and the page-break spacing rules are unchanged.

Changes are in maintained/shipping `tiptap.html`, `callout-layout.test.js`,
`callout-runtime.test.js`, and the callout-only preview revision in
`DocumentPreviewContent.swift` with its `DocumentLaunchTests.swift` coverage.
The renderer revision is now `callout-presentation-v6` so old images refresh.

All 85 targeted JavaScript checks passed. Browser-plugin-unavailable fallback QA
used headless system Chrome with the shipping HTML at 390x844 and 834x1112.
It verified short and multiline prompts, stale 120-point height estimates,
six placeholder-mode cycles, typing and clearing, width changes, large text,
newly authored guidance, reopening, and unchanged saved content without page
errors. Single-line prompt/caret centering was within one pixel. Existing icon
alignment and page-break browser suites also passed. Native Swift tests were
updated but not run; no native build, app launch, or simulator launch occurred.

### Placeholder Capitalization Update

Projected guidance no longer appends a paragraph-markup replacement on every
keystroke. `canonical()` already captures the current guidance for every save,
and leaving placeholder mode commits it to the existing guidance attributes.
Keeping the active paragraph intact avoids disrupting native capitalization
and composition state while preserving exact text case and formatting.

`renderIconElement` also skips unchanged role, label, background-image, and
hidden-state writes. Those writes were another source of paragraph replacement
in icon callouts. Icon appearance, callout layout, colors, and stored record
identities are unchanged.

Changed files: `Vellix-backend/src/structured-placeholders.js`,
`Vellix-backend/src/editor.js`, the generated shipping `tiptap.bundle.js`,
`Vellix-backend/tests/structured-placeholders.test.js`, and this document.
Four new tests cover both callout variants: uppercase typing without appended
metadata replacements, composition-tagged uppercase replacement, caret position,
formatting, serialization, mode changes, and undo/redo. All 89 targeted JavaScript
tests passed. Existing guidance-layout and icon-alignment browser checks passed.

Headless Chrome at 390x844 and 834x1112 verified Shift-uppercase typing, mixed
case, stable paragraph identity, focus/selection, and exact-case save/reopen for
both variants. Before the fix, the original paragraph was disconnected during
typing in all four cases; afterward it stayed connected. The Browser plugin was
unavailable. No native build or app/simulator launch was performed; the physical
iPhone keyboard itself remains unverified.

### Multiline Return and Whole-Callout Indentation

No-icon callouts use normal persisted hard breaks for Return, retaining inline
formatting, exact text case, and the existing template-guidance representation.
Two consecutive Returns at the end of a line exit the callout without leaving
an extra blank line in its box. A new empty callout also stays inside on the
first Return. Icon callouts, code/list editing, ordinary paragraphs, colors,
corners, and page-break spacing retain their existing behavior.

The editing toolbar's Indent/Outdent action now changes the no-icon callout's
outer indent rather than its inner text paragraph. Existing structural movement
moves the complete callout into a preceding sibling toggle and opens that toggle;
Outdent moves the callout back out. When already inside a toggle, double Return
exits only the callout and stays in the toggle. IDs, rich text, configuration,
and sibling content are preserved. Indented boxes use automatic available width
so all six supported indent levels remain inside the page.

Changed files: `Vellix-backend/src/editor.js` for the scoped keyboard handler and
whole-box indent target; `Vellix-backend/src/tiptap.html` for no-icon callout
width; `Vellix-backend/tests/callout-runtime.test.js` for focused Return,
indentation, nesting, guidance, readonly, undo/redo, and persistence coverage;
the synchronized shipping `VellixEditor.bundle/tiptap.bundle.js` and `tiptap.html`;
and this document. No native Swift, migrations, or user records were changed.

All 101 targeted editor tests passed, including 14 callout runtime tests.
The expanded tests exposed five failures against the previous shipping editor
and all passed after synchronization. Headless system Chrome/Playwright checked
the actual shipping HTML at 390x844 and 834x1112 with real keyboard typing:
single Return, continued typing, double-Return exit, six whole-box indent levels
without overflow, toggle nesting/outdenting, save/reopen, multiline template
guidance, and the unchanged icon-callout exit all passed without page errors.
Screenshots were visually inspected. The Browser plugin was unavailable;
physical iPhone/iPad WebKit and keyboard behavior remain unverified. No Xcode
build, app launch, or simulator launch was performed.

## November 23, 2026: Titled Layout and Icon Outline Color

### Reported Behavior and Cause

Titled icon callouts placed body content below the title's text column instead
of using the callout's left interior edge. The live editor explicitly assigned
the body to grid column 2, while the settings preview grouped title and body
inside a column beside the icon. The shared header/body gap also left too much
space, and the title inherited the body font size.

Icon visibility thickening used a background-derived contrast color in two
different renderers: CSS drop shadows in the live editor and SwiftUI shadows
in `IconCalloutGlyph`. That introduced a separately colored light/dark rim,
rather than thickening the selected icon color.

### Changes

- Titled callouts keep icon, title, and optional disclosure in a header row.
  The body now spans columns 1 through the last column, aligned to the existing
  left interior padding. Header/body spacing is 4px with no additional body
  padding. Untitled icon callouts retain their icon-beside-body arrangement.
- The live title uses 1.1em with the existing font and heavy weight. The native
  settings preview uses a rounded heavy 19-point title scaled with body text.
- The settings preview uses the same header/body organization and 4-point gap.
  Collapsing still hides the body entirely; no body-sized blank area is reserved.
- Library icon thickening uses `iconColor` in both renderers. Tinted custom
  images use `imageTint`. Untinted custom artwork has no added contrasting
  outline and retains its original pixels/colors.
- Color controls no longer display extra `Automatic` or `Original Colors`
  text rows. The existing `undo` asset supplies a compact reset button instead.
  Reset still clears the optional value; its explanation remains available to
  accessibility. The plain-callout height reset is labeled `Reset Height`.

Changed files: `Vellix/Editor/IconCalloutSettings.swift`,
`penned-editor/src/icon-callout.js`, `penned-editor/src/tiptap.html`, and the
shipping `VellixEditor.bundle/tiptap.html`/`tiptap.bundle.js`. The packaged
surface-color rule was synchronized mechanically without running an editor
build. No block types, saved attributes, Return/Enter handlers, nesting,
resizing, or collapse-state persistence were changed for this adjustment.

No builds, compilation checks, tests, app launches, or device runs were
performed. Earlier test results elsewhere in this document do not validate
this new layout or gesture adjustment.
