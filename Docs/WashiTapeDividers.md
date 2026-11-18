# Washi Tape Dividers

## In the editor

- Choose **Add Block > Divider > Washi Tape**. The photo settings open as soon as the divider is inserted. You can also find it through the slash menu or the Mac Insert inspector.
- Choose **Search Unsplash**, **Photo Library**, or **Choose File**. The sheet previews your image in a long strip with straight top and bottom edges and notched ends. There are no preset patterns.
- Tap or click the tape in the unlocked editor to change its image or size. Under **Size**, **Thick** keeps the original height and **Thin** is 25% shorter. The preview updates immediately; both sizes keep the same width, image, tint, and notched ends. **Done** saves the draft; closing the sheet without saving leaves the tape unchanged. **Remove Image** leaves a plain tape strip.
- Select a divider block and tap **Style** in the selection toolbar. The **Divider Color** swatch is on the opening Select Style panel. On Mac it is under **Block Styles** in the Format inspector. It recolors Thin Line, Thick Line, Dotted Circles, and Four Circles directly. It fills plain Washi Tape and tints photo tape without replacing the photo. With multiple blocks selected, only the selected dividers are recolored. Page Break is a separate structural block and is not recolored.

## Storage and rendering

Washi Tape uses the existing `divider` node with style `washiTape`. An optional `color` belongs to the divider itself. A personal image is resized, encoded as PNG, and registered with the document's attachment store; the block saves its relative path. Unsplash images keep the remote photo URL and photographer credit, and the existing photo service records selection. No new API credentials or database migration are required.

Size is saved per tape as `tapeSize` (`thick` or `thin`). Existing dividers without a size still render at their original height. The Size picker does not create a second divider or import another copy of the image.

| Files | Change |
| --- | --- |
| `penned-editor/src/divider.js`, `editor.js`, `tiptap.html` | Divider attributes, shared rendering, the tape shape, insertion and tap routing, and selection color commands. |
| `Vellix/Editor/WashiTapeSettings.swift`, `PageCardStyle.swift` | Photo settings, upload preparation, and native tape preview; the existing remote-photo descriptor is shared with publishing. |
| `Vellix/Documents/DocumentAppearance.swift`, `Vellix/Editor/TextBlockConversion.swift`, `MobileEditorInteractions.swift` | Register the new divider style and route mobile insertion and taps without changing the other divider gestures. |
| `Vellix/Editor/DocumentEditorView.swift`, `TipTapEditorSession.swift`, `TipTapBridgeTypes.swift`, `SelectionStyleSheet.swift` | Present tape settings, save the image, and expose the color picker in Select Style. |
| `PennedMac/Editor/MacTipTapEditorSession.swift`, `MacEditorPresentations.swift`, `PennedMac/Inspector/MacInsertInspector.swift`, `MacStyleInspector.swift`, `MacFormatInspector.swift` | Connect the same tape settings and color command to the Mac editor and inspectors. |
| `Vellix/Attachments/AttachmentMedia.swift`, `Vellix/Editor/TipTapContentAnalyzer.swift`, `penned-editor/src/attachments.js` | Preserve divider data and recognize uploaded tape images in the existing document attachment and copy flows. |
| `Vellix/Documents/ImmediateDocumentPreview.swift`, `Vellix/Templates/GalleryDocumentPreview.swift`, `Vellix/Editor/DocumentThumbnailLayout.swift`, `NestedPageThumbnail.swift` | Render colored dividers and tape in native previews. Compact canvas thumbnails render local tape images or a shaped fallback for remote photos. |
| `Vellix/Publishing/PublishingProjection.swift`, `supabase/functions/penned-publishing/contract.ts`, `penned-editor/src/public-document.js` | Project and validate divider colors and tape images for published documents without exposing private attachment paths. |
| `Docs/EditorAddMenu.md`, `Docs/WashiTapeDividers.md` | Document the editor workflow and integration. |

### Size setting

| Files | Size change |
| --- | --- |
| `Vellix/Editor/WashiTapeSettings.swift`, `DocumentEditorView.swift`, `TipTapEditorSession.swift`, `PennedMac/Editor/MacEditorPresentations.swift`, `MacTipTapEditorSession.swift` | Add the live Size picker and save the chosen size through the existing settings bridge. |
| `penned-editor/src/divider.js`, `editor.js`, `tiptap.html`, `Vellix/Editor/TipTapContentAnalyzer.swift` | Preserve the size in document JSON and copied divider markup; apply the shorter height only to Thin tape. |
| `Vellix/Documents/ImmediateDocumentPreview.swift`, `Vellix/Templates/GalleryDocumentPreview.swift`, `Vellix/Editor/DocumentThumbnailLayout.swift` | Reflect the saved size in native previews and thumbnails. |
| `Vellix/Publishing/PublishingProjection.swift`, `supabase/functions/penned-publishing/contract.ts`, `penned-editor/src/public-document.js` | Carry Thin through the public renderer; missing size defaults to Thick. |
| `Scripts/test-mobile-editor-interactions.mjs` | Cover the Thick default, saving Thin, reopening settings, and preserving the image and tint. |

## Packaging

Run `npm run build` in `penned-editor` to regenerate the native editor bundle. For web publishing, also regenerate the [public reader assets](PublishingViewer.md) and deploy the reader and updated publishing function. This change has not been built, tested, or deployed.
