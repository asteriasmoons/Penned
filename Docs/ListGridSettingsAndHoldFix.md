# List Grid Settings and Long Press

## Current iPhone and iPad Interaction

- Inserting a List Grid from Add or the slash menu opens **List Grid Settings**
  immediately, without focusing a cell. To reopen settings, tap a cell and use
  the `settingswavy` button to the left of **Bold**. It stays visible when the
  formatting controls scroll and is shown only while editing a List Grid.
- The sheet uses the same **Dismiss Keyboard** action as Labels. It hides the
  keyboard without closing the sheet. The document behind the sheet does not
  try to scroll a web caret into view.
- Neither tapping the container border nor holding the grid opens settings.
  A touch hold no longer opens Penned's block-action menu for a List Grid.
  Swipe horizontally across either column or the outer edge to select the
  entire grid, then tap **Delete** in the block selection bar. Deletion is
  undoable. Deleting the only grid in a document leaves an empty paragraph.
  Ordinary touches and genuine mouse context clicks retain their native or
  existing behavior, respectively. Mac keeps its existing insertion behavior.

`list-grid.js` resolves the current grid from the editor selection, including
grids inside tabs. `editor.js` sends that availability through the existing
formatting update, and `TipTapBridgeTypes.swift` decodes it.
`DocumentEditorView.swift` pins the button outside the scroll and calls the
existing settings command in `TipTapEditorSession.swift`. Saved document
structure, styling, and swipe deletion are unchanged.

## Earlier Changes

The hold behavior described below is historical and is superseded above.

## Cause

List Grid settings already wrote color attributes to the document, but the editor stylesheet painted fixed gray backgrounds and borders instead of consuming those attributes. Its general paragraph color rule also overrode the intended cell text color on dark documents. The column split used a percentage of the whole row even though the settings calculation excludes the gutter.

Grid holds previously ran separate touch and pointer timers. They did not make the cells non-editable while the hold was pending, and root-level text-selection styles lost to the editor's more specific `!important` rules. WebKit could begin native text editing before the block actions were presented.

## Behavior

- All four existing color settings paint the actual grid. The label and value use readable default ink and caret colors; inline text color marks are not removed. Existing saved colors are used as-is. Each row can use the default split appearance, both filled boxes, or both white outlined boxes.
- The label/value split divides the available width after the gap. The shared table resize calculation and its minimums remain in use. The iOS sheet shows the applied fraction returned by the grid, or restores its previous fraction and reports an error if the change fails. Restore Default still uses the saved default. Row controls remain in the same sheet.
- Appearance edits update the grid's node attributes, retain its rich-text cells, and use the existing save and undo path. Nested grids are resolved by the correct block ID as well as top-level grids.
- A List Grid touch can open block actions only through the stationary hold recognizer, not through a stray `contextmenu` event. Taps in the grid's active text-editing area and quick follow-up taps in the same cell stay with native text selection. Short taps still use the native caret and keyboard. Hold the grid border/gap, or a grid that is not being edited, to open block actions. A deliberate mouse right-click or control-click remains supported. Touch start/move remain passive for native scrolling, and other blocks are unchanged.

## Short Tap Correction

The first hold fix disabled the grid's editing host on every touch and canceled the normal tap, attempting to place the caret and focus the editor from JavaScript. That path did not reliably open the keyboard. `src/block-actions.js` now leaves short taps to WebKit and suppresses compatibility activation only for claimed holds. A fresh touch also clears an old hold if the native menu consumed its release. `src/list-grid.js` applies the non-editable wrapper only after the hold is recognized. The appearance and settings fixes are unchanged.

## Text Selection and Cell Layout

- `src/block-actions.js`: the old `contextmenu` fallback could open Settings without the hold timer recognizing a long press. Touch context menus no longer start block actions independently. Active-cell interactions and quick repeat taps bypass hold suppression, preserving native text selection. Moving the finger cancels a pending hold and releases its selection suppression.
- `src/list-grid.js`: derives the caret ink from the current cell via ProseMirror's editing-host attributes. A value cell gets dark ink against white, and a label cell uses the contrast color for its saved background. Leaving the grid restores the document caret color. This is needed because [iOS WebKit takes the caret color from the root editable element](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/ios/WebPageIOS.mm). The column resize command also measures the actual row and column gap instead of subtracting the former fixed padding.
- `src/tiptap.html`: label cells no longer force bold; explicit rich-text marks remain. Card padding and the gap are now 6 pixels, and each box uses 9 pixels of horizontal text padding with a 42-pixel minimum height. This gives both columns more usable text width without changing the saved split or removing the card border.

No builds or tests were run for these follow-ups. Rebuild the editor bundle before checking short taps, double-tap selection, a deliberate hold, caret contrast in both cells, and column resizing on device. No native settings or document data changes are required.

## Corner Radius

`penned-editor/src/tiptap.html` reduces the List Grid's outer radius from 18px to 8px and both label/value cell radii from 12px to 4px. This is an editor-only styling change; padding, gaps, borders, colors, saved settings, and gestures are unchanged. Rebuild the editor bundle to pick it up. No builds or tests were run.

## Compact Row Styles

In **List Grid Settings > Rows**, the small style icon next to delete replaces the Header switch. It opens **Default** (filled label, white outlined value), **Both Filled** (both use Left Box Background without a cell border), and **Both Outlined** (both use the white value style and Right Box Border). The selected option has a checkmark. New rows use Default, and previously saved header rows continue to show as Both Filled. The menu does not add another row of controls or force bold formatting.

- `penned-editor/src/list-grid.js`: stores the selected row style, round-trips it through editor HTML, and recognizes legacy `isHeader` rows. Style changes use the existing undoable attribute/save path and set caret ink for the actual cell fill.
- `penned-editor/src/tiptap.html`: uses the selected fill and outline style without changing the saved colors, padding, or corner radii.
- `Vellix/Editor/TipTapBridgeTypes.swift`: decodes the three row choices, falling back to the old header flag when needed.
- `Vellix/Editor/TipTapEditorSession.swift`: sends the selection through the document-scoped settings command and checks that the editor accepted it.
- `Vellix/Editor/DocumentEditorView.swift`: replaces the switch with the compact icon menu and prevents row indices from changing while a style change is in flight.

Cell contents, text gestures, publishing rules, and the Mac settings surface are unchanged. Rebuild the editor bundle with `npm run build` in `penned-editor`, then build the app. No builds or tests were run. Device checks remain for the three choices, an existing header row, undo, and reopening the document.

## Whole-Card Selection on iOS

`Vellix/Editor/MobileBlockSelection.swift` now registers the List Grid itself
as one block instead of registering the paragraphs in its cells. Swiping a
cell, tapping the grid in Select mode, or including it in a block range
selects and highlights the whole card. A grid inside a callout remains its
own target. Normal caret placement, text selection, and the Settings hold
are unchanged outside block selection.

This follow-up changes the iOS selection script only. No npm rebuild is
needed; the change takes effect with the next iOS app build. No builds or
tests were run.

## Wider List Grid on iOS

`Vellix/Editor/MobileBlockSelection.swift` widens top-level List Grids by
4 CSS pixels on each side using the existing editor gutter. Text margins,
saved column ratios, and grids inside other blocks stay unchanged. The
selection highlight follows the new card edges.

This adjustment needs an iOS app build, not a web editor bundle rebuild.
No builds or tests were run.

## Borderless Filled Headers

`penned-editor/src/tiptap.html` removes the value cell outline for Both
Filled rows; the label was already borderless. `Vellix/Documents/ListGridPreview.swift`
uses the same rule in native previews and thumbnails, and
`Vellix/Documents/DocumentPreviewContent.swift` refreshes cached List Grid
snapshots. The grid's outer border, Default and Both Outlined rows, and
saved colors are unchanged. Rebuild the editor bundle and app to apply this
change. No builds or tests were run.

## Files Changed

| File | Change |
| --- | --- |
| `penned-editor/src/list-grid.js` | Share saved appearance projection between HTML and the grid node view, keep touch locking out of saved content, resolve nested blocks, and return the applied layout. |
| `penned-editor/src/tiptap.html` | Consume saved colors and column ratios; correct default cell ink/caret contrast and suppress selection only during a held grid touch. |
| `penned-editor/src/block-actions.js` | Separate tap, scroll and hold for List Grid and keep the existing block-action token/menu. |
| `Vellix/Editor/TipTapEditorSession.swift` | Read back the actual column split and check the document/load generation. |
| `Vellix/Editor/DocumentEditorView.swift` | Reflect the applied split, guard stale settings actions and row indices, and preserve the existing sheet and controls. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Match the existing shared List Grid/block-action event types without adding a Mac settings sheet. |
| `Docs/ListGridSettingsAndHoldFix.md` | Document the fix, deployment boundary, and device checks. |

## Build Boundary

No builds, tests, or device checks were run. The generated app bundle was not hand-edited. Run `npm run build` from `penned-editor` to build and sync `VellixEditor.bundle`, then build the app. On device, verify automatic settings from both insertion menus, the pinned button in top-level and nested grids, keyboard dismissal, cell editing, and swipe/delete/undo.
