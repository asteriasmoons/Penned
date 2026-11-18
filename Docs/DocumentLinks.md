# Document Links

## Editing and Selection

- Select text and tap the Link icon in the formatting bar to set or remove
  its URL without changing the wording or other inline formatting. Put the
  caret inside an existing link to edit that whole link.
- The inline Link action opens a floating URL box above the keyboard with
  **Remove**, **Save**, and close. The URL field is focused for pasting or
  typing, and a temporary editor decoration keeps the chosen text visible
  while that field has focus. Closing the box discards the draft URL.
- **Add Block > Links & Files > Link** inserts URL text, custom Link Text,
  or a Rich Link. Bare web addresses are prefixed with HTTPS. A website can
  still be linked when it does not provide preview metadata.
- Rich Links have Small (thumbnail and title), Regular (horizontal preview
  with description and website), and Card (vertical preview) layouts. Consecutive
  Cards flow into two-column rows; Small and Regular remain full-width. Each
  Card stays independently selectable and editable. The
  **Layout** picker appears only for a single selected Rich Link and applies
  changes immediately. Small stays a single row; all three layouts align with
  the document content. Page-break spacing stays outside the preview border.
- **Actions** can edit, open, copy, reload, and convert a selected link as
  appropriate. To turn a text block into a Rich Link, it must contain one
  link spanning the entire block; conversion never discards unrelated text.
- The horizontal block toolbar shows labels below its icons and keeps Delete
  fixed at the trailing edge. **Style** opens heading and paragraph shortcuts,
  lists, and indentation. **More** shows Title, Subtitle, Heading, Subheading,
  Paragraph, and Caption; the ellipsis shows inline formatting, alignment, and
  System, Serif, Mono, and Round font choices. Fonts are stored on selected text
  blocks, not on the document appearance. Swipe down on either panel's grabber to
  return to Style, or swipe down from Style to close it without clearing the
  selection. Copy, Cut, Duplicate, and Group use the existing
  commands. Tapping a link in block selection selects it instead of opening it.
- Style commands are bound to the selection that opened the panel. A changed
  selection or reloaded document invalidates pending taps. A temporary library
  import pause keeps the existing selection when its document is unchanged.
  A mark toggle adds the mark to all selected eligible text unless all of it
  already has that mark, in which case it removes it.

## Persistence and Metadata

Clickable text and custom Link Text use the existing [TipTap link mark](https://tiptap.dev/docs/editor/extensions/marks/link).
Rich Links use a `richLink` block with a stable ID, URL, layout, metadata,
and the original text. Conversion to text preserves the original wording and
inline styling, and retains preview information for conversion back. Link
edits use the same document JSON, undo history, snapshots, and sync as other
blocks. The editor rejects stale selections and unsupported URL schemes.

Penned retrieves up to 512 KiB of website HTML in an ephemeral native session.
The editor parses it in an inert template, without running page scripts, and
uses [Open Graph](https://ogp.me/), Twitter, and standard HTML metadata for
the title, description, site, image, and favicon. Preview image URLs are
saved with the block; the images still depend on the website being available.
New Rich Links require an updated editor bundle. The public reader and
publishing contract have local support; publishing deployment is separate.

## Files

- `penned-editor/src/document-links.js`, `editor.js`, and `tiptap.html`:
  link schema, metadata parser, editing, conversion, opening, and card styles.
- `Vellix/Editor/DocumentLinks.swift`, `DocumentLinkSheets.swift`,
  `TipTapEditorSession.swift`, and `TipTapBridgeTypes.swift`: metadata fetch,
  URL and document guards, Link sheet, and layout picker.
- `Vellix/Editor/DocumentEditorView.swift` and `MobileBlockSelection.swift`:
  formatting bar, Add Block, contextual toolbar, and link selection gestures.
- `Vellix/Editor/SelectionStyleSheet.swift` and `TextBlockConversion.swift`:
  the Style panels and shared block conversion menu.
- `penned-editor/src/block-font.js`: allowed block font values and rendering.
- `Vellix/Editor/TipTapContentAnalyzer.swift`, `DocumentThumbnailLayout.swift`,
  and `Vellix/Documents/ImmediateDocumentPreview.swift`: searchable titles and
  preview fallbacks. `PennedMac/Editor/MacEditorPresentations.swift` opens links
  from the shared renderer on Mac.
- `Vellix/Export/DocumentMarkdownExport.swift`, `DocumentWordExport.swift`,
  `Vellix/Publishing/PublishingProjection.swift`,
  `supabase/functions/penned-publishing/contract.ts`, and
  `penned-editor/src/public-document.js`: Rich Link export and reader support.
- `Vellix/VellixEditor.bundle/tiptap.html` and `tiptap.bundle.js`: regenerated
  editor assets. `penned-editor/tests/document-links-browser.mjs` and
  `Vellix/VellixTests/VellixTests.swift`: browser and native regression cases.

## Verification

The Rich Link regression checks two-column pairing and reflow, paragraph
alignment, compact Small height, and external page-break spacing in editing,
selection, and read-only modes at 390 and 834 points. It verifies that all four
fonts render and persist, that text-style changes retain the URL, block ID,
font, inline marks, and alignment, and that list conversion followed by
formatting does not publish an empty selection.

The browser fixture covers selected-text editing, standalone insertion,
metadata parsing, conversion in both directions, all three layouts,
selection-mode taps, opening, and JSON reload at 390 and 834 points. The
Grid Cards browser fixture, seven formatting-state tests, and local
publishing sanitizer/reader smoke check also pass.
The Vellix Debug build passed for the iOS Simulator destination. The native
swipe interaction was not exercised on a running simulator or device.
