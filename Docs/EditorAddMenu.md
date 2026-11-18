# Editor Add menu and page icons

## Separate Conversion Menu Parity

The Conversion Menu now exposes the Add menu's complete category/item set:
Headings (Text/Label), Text Blocks, Content Blocks (Icon/Plain Callouts,
Blockquote, Table), Links & Files, Nested Content (Page/Card), Code Block,
Other Blocks (List Grids, Fields, Tabs, Infocards, Grid Cards), Collection,
Toggle, Lists, Properties, and all Divider styles plus Page Break. Template
Components appear in template editing. Add and Convert remain separate menus
and actions; the Add menu itself is not changed.

There are no source-type allowlists or per-target disabled conversion options.
Commands operate on the selected blocks, or the paragraphs covered by a held
text selection, using the loaded editor schema and defaults. The entire
replacement transaction is checked before dispatch. Invalid schema structures
or stale asynchronous selections still report errors rather than corrupt data.

Existing Page <-> Card conversion updates only that child's `cardStyleJSON`:
the document ID, body, descendants, attachments, and parent relationship remain.
Converting other blocks to a nested Page/Card reuses the existing grouped-child
creation/rollback path and replaces only the still-matching selected sources.
Page converts back to a plain reference by clearing its card presentation.

Rich content is carried into container blocks. When a target cannot own content
(such as a divider, page break, or collection), the source content remains beside
the new block rather than being silently deleted. Nontext references are retained
when flattening a container into text. Links and Files use the existing editor
and importer; unchanged source blocks are removed only after successful apply,
not when the picker opens. Canceling leaves the source intact. Child-page
references are not deleted as a side effect of link/file conversion.

Implementation is native-injected through `TextBlockConversion.swift`, with
typed bridge requests, existing model lifecycle/persistence, and existing native
link/file sheets. No editor bundle rebuild is required. Files changed:
`TextBlockConversion.swift`, `TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`,
`DocumentEditorView.swift`, and `DocumentRepositories.swift`; the Mac session's
shared-event switch recognizes the new bridge case. This does not redesign the
Mac Insert inspector. No opening, rendering, Enter, drag-selection, or preview
pipeline changes are included. Source review only; no builds/tests/device runs.

The iPhone/iPad keyboard Add menu now has a **Headings** submenu (Title,
Subtitle, Heading, Subheading) and a **Lists** submenu (Checklist, Bullet
List, Numbered List). The insertion commands are unchanged. Toggle keeps
its existing submenu. **Nested Content** contains Page and Card, and
**Divider** contains Page Break alongside the divider styles, including
[Washi Tape](WashiTapeDividers.md).
On iPhone and iPad, adding a [List Grid](ListGridSettingsAndHoldFix.md)
opens its settings automatically. To reopen them, tap a cell and use
**List Grid Settings** immediately to the left of **Bold** in the formatting bar.

The formatting bar's **Add Block** menu also groups these items:

- **Text Blocks:** Paragraph, Caption
- **Content Blocks:** Callouts (Icon, Plain), Blockquote, Table
- **Links & Files:** Link, File

**Link** opens the [link editor](DocumentLinks.md) for a standalone URL,
custom link text, or Rich Link. The other items keep their existing actions.

**Other Blocks** includes [Grid Cards](GridCards.md).
[Callouts](Callouts.md) offers the new Icon block and the existing Plain block.
The Mac Insert inspector has the same Callouts submenu, and the slash menu
offers both callout types by name.

Custom page icons are no longer shown or editable in the app. Page
thumbnails, covers, generic tab glyphs, and icons for folders, callouts,
properties, and collections are unchanged. Stored legacy icon values
remain readable for database and sync compatibility. Existing published
versions are not rewritten.

## Files changed

- `Vellix/Editor/DocumentEditorView.swift`: Groups Add choices, removes the
  settings shortcut and Page Icon entry, and removes the page-header picker.
- `PennedMac/Editor/MacDocumentEditorContainer.swift` and
  `PennedMac/Editor/MacEditorPresentations.swift`: Remove the Mac header
  control and its picker sheet.
- `Vellix/App/PadWorkspaceSidebar.swift` and
  `PennedMac/Workspace/MacWorkspaceModel.swift`: Use a generic document
  glyph on document tabs instead of their saved icons.
- `Vellix/Documents/DocumentBrowserView.swift`,
  `Vellix/Search/SearchView.swift`, and `Vellix/Search/DocumentSearchService.swift`:
  Remove custom page icons from document cards and search results.
- `Vellix/Export/DocumentExportRenderer.swift` and
  `Vellix/Export/DocumentExportScript.swift`: Omit page icons from exported
  titles while preserving collection field icons.
- `Vellix/Publishing/PublishingDocumentBuilder.swift` and
  `Vellix/Publishing/PublishingVisibleContent.swift`: Omit page icons from
  new publications and their nested-page previews.

The original menu and page-icon update did not change the web editor bundle.
The later Grid Cards update includes a regenerated bundle; see its own
verification notes.
