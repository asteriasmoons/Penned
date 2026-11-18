# Grid Cards

On iPhone and iPad, insert from **Add Block > Other Blocks > Grid Cards**.
On Mac, use **Insert > Other Blocks > Grid Cards**. The slash menu also
offers **Grid Cards**. A new card opens its settings; reopen them from the
card's icon. Edit the description directly in the document, using ordinary
rich-text paragraphs. [Callouts](Callouts.md) are separate blocks; adding them
does not change Grid Cards or the legacy Grid Card migration.

## Settings and Layout

- Choose an icon from the existing Penned Icons or SF Symbols library. The
  icon sits above the title, with no backing badge. Icon and title alignment
  can be left, center, or right without changing paragraph alignment.
- Icon Color and Background are separate custom pickers. Backgrounds use
  opaque RGB; changing either picker does not change the other color.
- Use Half Width / Full Width or drag the right edge of the preview to switch
  widths. Drag the bottom edge to set the height. The saved height is a
  minimum (100 to 1600 points), so longer content expands rather than clips.
- The settings preview uses the same local TipTap node and CSS as the
  document, with the existing icon mask and paragraph styles. Resize handles
  exist only in the sheet. **Done** saves settings to that card; closing the
  sheet without Done discards the settings draft.
- Consecutive half-width cards pair in order, up to two per row. Full-width
  cards and other content start a separate row. The layout creates no saved
  row objects, so neighboring cards stay independently selectable and editable.

## Compatibility

The legacy `callout` node loads as `gridCard`, with the same ID, icon,
icon tint, position, and rich-text children. Its initial width is full, and
it receives an opaque default background. Migration does not infer a title
or move text out of the description. Old HTML callouts can still be pasted.
The editor writes the new type through the existing document JSON save path;
there is no database migration. Standard `plainCallout` nodes are not converted.
Devices editing a document with saved Grid Cards need the updated editor bundle.

Grid Card titles are searchable. WebKit snapshots render the same nodes as
the editor, and the existing native preview and thumbnail fallbacks handle
saved Grid Cards. Markdown and Word retain the title and description.
The public reader source and publishing contract support the node; deployment
of the publishing service and regenerated reader assets is separate.

## Changed Files

- `penned-editor/src/grid-card.js`, `editor.js`, `tiptap.html`, and
  `callout-list-backspace.js`: card configuration, migration, markup, layout,
  settings bridge, and retained behavior for migrated numbered lists.
- `Vellix/Editor/GridCardSettingsSheet.swift`, `TipTapBridgeTypes.swift`,
  `TipTapEditorSession.swift`, `DocumentEditorView.swift`, and
  `TextBlockConversion.swift`: shared settings and preview, save integration,
  and mobile insertion and conversion menus.
- `PennedMac/Editor/MacTipTapEditorSession.swift`, `MacEditorPresentations.swift`,
  `PennedMac/Inspector/MacInsertInspector.swift`, and `MacFormatInspector.swift`:
  Mac settings, persistence, and insertion and conversion routing.
- `Vellix/Editor/MobileBlockSelection.swift`, `TipTapContentAnalyzer.swift`,
  `PageCardView.swift`, `DocumentThumbnailLayout.swift`, and `NestedPageThumbnail.swift`:
  independent card selection, title indexing, and thumbnail layout.
- `Vellix/Documents/ImmediateDocumentPreview.swift`, `DocumentPreviewContent.swift`,
  and `DocumentPreviewCache.swift`: native fallback and targeted snapshot refresh.
- `Vellix/Export/DocumentMarkdownExport.swift`, `DocumentWordExport.swift`,
  `Vellix/Publishing/PublishingProjection.swift`,
  `supabase/functions/penned-publishing/contract.ts`, and
  `penned-editor/src/public-document.js`: export and publication support.
- `Vellix/VellixEditor.bundle/tiptap.html` and `tiptap.bundle.js`: generated app
  editor assets. Use `npm run build` from `penned-editor` after future web changes.
- `penned-editor/tests/callout-runtime.test.js`, `grid-card-browser.mjs`, and
  `Vellix/VellixTests/VellixTests.swift`: migration, settings, independent IDs,
  layout, and persistence regression coverage.
- `Docs/Callouts.md` and `Docs/EditorAddMenu.md`: current menu and migration notes.

## Verification

Nine focused editor tests cover legacy migration, settings commits, undo/redo,
duplicate IDs, save/reopen, and unchanged iconless Callout behavior. The
Chromium fixture checks 390- and 920-point widths, mixed-height rows beside
existing Page Cards, icon geometry and tint, paragraph contrast, selection,
independent deletion, and the read-only live preview. A local publishing check
passed through the sanitizer and public renderer. The broader Callout run
reproduces 20 existing numbered-list and insertion-bookmark failures from the
prior bundle.

Swift source parsing and SDK checks do not verify native sheet gestures or
on-device WebKit behavior. No full Xcode build, device run, or publishing
deployment is part of this change.
