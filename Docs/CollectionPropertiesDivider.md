# Collection Properties Divider

Collection entry documents now show a thin native divider beneath their properties, including the Add Field control, before the editable document body. It matches the existing title divider's width, one-point thickness, document text color, and opacity for each platform and appearance.

## Files Changed

- `Vellix/Editor/DocumentEditorView.swift`: adds the divider to the existing collection-properties section for both plain and themed documents on iPhone and iPad.
- `PennedMac/Editor/MacDocumentEditorContainer.swift`: adds the matching divider after collection properties on Mac.
- `Docs/CollectionPropertiesDivider.md`: records this change.

The divider appears only on collection entry documents. Ordinary documents, property editing, caret behavior, saved document content, and web-editor rendering are unchanged. This is native document chrome, like the title divider, not an inserted document block.

No builds, tests, simulators, launches, or automated verification commands were run, as requested.
