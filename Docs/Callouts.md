# Callouts

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
