# Grouping into nested pages

Grouping used to save a child page and delete the source blocks without
placing a reference in the parent editor. When all body blocks were grouped,
the editor recreated its required empty paragraph, while the child appeared
separately underneath. Deleting the paragraph could only recreate it again.
The same command also put all selected text into the child's title field.

## Behavior

- The child starts with an empty title, without a suggested title or
  placeholder text in the title field. All selected content stays in its body.
- Grouping inserts a real nested-page reference at the end of the parent's
  body, before unselected trailing editing lines, then removes the source
  selection. Grouping the whole body no longer needs an empty starter block.
- The command checks that the original document and selection still match
  before deleting anything. Undo of the source deletion still leaves the
  created child in place, as it did before.
- Reopening older parents places previously unplaced pages and discards a
  lone empty, unformatted starter when it can be replaced by a reference.
  Reopening older children clears a long title only when it still matches the
  combined text of their multi-block body. Titles that no longer match are
  left alone.

## Files changed

- `penned-editor/src/editor.js`: Stamps the grouping request, installs the
  reference, and saves the result of the existing block deletion command.
- `penned-editor/src/page-reference-node.js`: Shows no title for a blank
  child while keeping its open button accessible.
- `Vellix/Editor/TipTapBridgeTypes.swift`: Carries the grouping token and
  body without a generated title.
- `Vellix/Editor/TipTapEditorSession.swift` and
  `PennedMac/Editor/MacTipTapEditorSession.swift`: Complete grouping in the
  originating document and use the shared recovery path on open.
- `Vellix/Editor/PageReferenceLifecycle.swift`: Coordinates child creation
  and reparenting, and repairs identifiable legacy grouping artifacts.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: Recognizes the old combined
  body title without treating every long title as generated.
- `Vellix/Documents/DocumentRepositories.swift`: Supports explicit blank
  titles for this workflow without changing other creation defaults.
- `Vellix/Editor/DocumentEditorView.swift` and
  `PennedMac/Editor/MacDocumentEditorContainer.swift`: Keep blank title fields
  editable without substituting Untitled.

No builds or tests were run. Run `npm run build` in `penned-editor` to sync
the bundle before building the app. Device checks remain for grouping all
blocks, grouping existing nested pages, undo, and reopening an older group.
