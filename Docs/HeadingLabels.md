# Heading Labels

**Add Block > Headings > Title, Subtitle, Heading, or Subheading > Label**
inserts an editable heading with label presentation. **Text** inserts the
ordinary version. An existing heading can switch presentation in its selection
style controls. Place the caret in the label and choose **Heading Label
Settings** immediately left of **Bold** on iPhone/iPad, or in the Mac Format
inspector. There is no settings hold.

Ribbon, Pill, Framed, Rectangular, Scalloped, Plaque, and Banner are independent
of Filled, Glass, Textured, and Outline. Label settings include font, alignment, four surface and
text colors, a border thickness of 0 (hidden) through 6 (existing labels default
to 1), and an optional independently tinted icon from Penned's icon picker.
On iPhone and iPad, the keyboard button in the sheet header hides the keyboard
without saving or closing the sheet. Done saves the draft and closes the sheet.
Turning an icon off remembers the icon. Switching to Text retains the heading
ID, level, inline content and dormant label configuration.

**Convert Selection** groups options like Add Block: **Headings**, **Text
Blocks**, **Content Blocks**, **Other Blocks**, **Lists**, **Toggle**, and
the applicable code and divider options. Under **Headings**, each level offers
**Text** and **Label**. **Keep Level as Label** converts selected headings
without changing their levels. **Text Blocks** includes Paragraph and Caption.
**Other Blocks** includes Infocards and Grid Cards. Converting to an Infocard
puts heading text in its title or paragraph/caption text in its description;
converting to a Grid Card keeps the source text in its body. Conversion uses
whole text blocks, including text outside a partial selection, and does not
replace a block when the enclosing container cannot accept the new type.

The configuration is stored on the heading as `attrs.label`. Saves preserve
omitted metadata by stable heading ID. Snapshots and recovery store the same
document JSON. Snapshot history excerpts use the heading text, not its
appearance metadata. Existing three-way sync merges independent heading fields when
it has a shared baseline and keeps competing revisions for recovery otherwise.
No storage migration is required.

Native settings, document and gallery fallback previews, and nested-page
miniatures use `HeadingLabelSettings.swift` for the label tile.
The TipTap editor and public reader share the heading renderer and CSS from
`penned-editor`. Publishing projects only validated active label metadata, and
the reader keeps the original HTML heading and table-of-contents entry.
For Framed labels, the fill and outline use the same stepped perimeter. The web
renderer clips only the fill and uses a non-scaling SVG stroke for the border.
The native preview draws the same perimeter and leaves room for the stroke.

## Plaque and Banner

Select **Plaque** or **Banner** in Shape. Plaque has a flat center, stepped
shoulders, and curved ends. Banner has a V-shaped notch at both ends. Both use one perimeter border
that follows the fill exactly. Plaque has no separate outer outline; Banner
has no stitching. Border color and thickness work as usual, including 0
for no border. Background and text stay editable.

Both shapes support Filled, Glass, Textured, and Outline. All new labels start
with the same pale lavender palette and plain Filled style. Changing Shape
or Style never changes a label's colors. Older labels that saved Plaque or
Banner under Style are read as that Shape with Filled, keeping their saved
colors and border settings.
The shape ends are computed from the tile's measured size and font size,
so wider labels extend the center instead of stretching the ends.
Plaque uses matching circular arcs in SwiftUI and SVG. Each native outline
is one closed path through every edge, so the fill, glass and border stay
aligned and Banner keeps both notches in the settings preview.
Plaque has a little more padding on all sides. Banner has extra vertical
padding without changing its horizontal spacing. The native and web renderers
use the same spacing values.

Shape, Style, and Font use custom dropdowns with Penned's existing frosted
material and chevrons. Only one opens at a time. The dropdown shows up to
three choices and scrolls inside the list for the rest.

- `Vellix/Editor/HeadingLabelSettings.swift`: shared defaults, native paths, and dropdowns.
- `penned-editor/src/heading-label.js`, `scalloped-label.js`, and `tiptap.html`:
  shared editor/reader metadata, measured paths, and a single unclipped stroke.
- `Vellix/Documents/DocumentPreviewContent.swift`: refresh affected cached previews.
- `supabase/functions/penned-publishing/contract.ts` and
  `Penned-Site/src/scripts/public-reader.ts`: validate both shapes and measure their paths in the reader.

No builds or tests were run for Plaque, Banner, or the dropdowns. The generated
app bundle and reader assets were left untouched.

## Scalloped

Choose **Scalloped** in the existing Shape picker. Round scallops run along
all four edges, including the corners. The renderer fits a whole number of
round arcs to each side instead of stretching a preset rectangle. The fill,
Glass or Textured material, and border follow the same closed path. Wrapped
text stays centered inside the tile, and the Alignment setting still places
the tile to the left, center, or right of the document.

Choosing Scalloped changes only the shape; it does not add a color, texture,
or decoration. Existing label styles, colors, icons, and border thickness
remain editable.

| Files | Scalloped change |
| --- | --- |
| `penned-editor/src/scalloped-label.js`, `heading-label.js`, `tiptap.html` | Generate one measured perimeter for the material clip and SVG stroke without editing the heading text. |
| `Vellix/Editor/HeadingLabelSettings.swift` | Add the picker option and matching native preview path. |
| `penned-editor/src/editor.js`, `Vellix/Documents/DocumentPreviewCache.swift`, `Vellix/Export/DocumentExportScript.swift` | Repaint the path at the final preview or export dimensions. |
| `supabase/functions/penned-publishing/contract.ts`, `penned-editor/scripts/export-public-reader.mjs`, `Penned-Site/src/scripts/public-reader.ts` | Accept the saved shape for publishing and resize the same vector in the reader. |
| `penned-editor/tests/heading-label-browser.mjs` | Add coverage for all four Scalloped finishes and check that clipping and stroke use identical circular-arc data. |

## Glass and Textured Finishes

**Glass** uses the full, opaque Background color selected in Label Settings.
Native previews pass that same color into Lunixia's `BubblyIconMaterial` as its
tint and layer the material over the solid fill. The editor and public reader
use the same solid base and tint, with CSS backdrop blur in place of SwiftUI
Liquid Glass. A stronger reflection along the top and deeper shading at the
bottom add definition without making the selected color translucent.

**Textured** uses a narrow range of lighter and darker shades of the selected
Background color, preserving its hue and saturation. Cyan gets cyan grain,
pink gets pink grain, and neutral colors stay neutral. The seeded tile supplies
only opacity, never black or white ink: it blends lighter flecks over a slightly
darker base. The 384 px tile repeats at 192 CSS px in the editor and public
reader and at 2x scale in native previews. The grain stays within the chosen
shape; text, icons, and the border are not textured. Cached document previews
with Textured labels are regenerated for this rendering change.

## Implementation Map

| Files | Purpose |
| --- | --- |
| `penned-editor/src/heading-label.js`, `editor.js`, `block-actions.js`, `tiptap.html`, `public-document.js` | Heading attributes, insertion and selection commands, settings targeting, and the shared editor/public design. |
| `Vellix/Editor/HeadingLabelSettings.swift`, `TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`, `DocumentEditorView.swift`, `SelectionStyleSheet.swift` | Native settings, icon picking, menu entries, and edit/save integration. |
| `PennedMac/Editor/MacTipTapEditorSession.swift`, `MacEditorPresentations.swift`, `PennedMac/Inspector/MacInsertInspector.swift`, `MacFormatInspector.swift` | Equivalent Mac controls and bridge behavior. |
| `Vellix/Editor/TextBlockConversion.swift`, `SelectionStyleSheet.swift`, `MobileBlockSelection.swift`, `PennedMac/Inspector/MacFormatInspector.swift`, `penned-editor/src/editor.js` | Group the conversion choices and apply them through the existing text and block selection paths. |
| `Vellix/Editor/TipTapContentAnalyzer.swift`, `Vellix/Documents/DocumentRepositories.swift` | Normalize supported heading metadata and preserve it when older saves omit it. |
| `Vellix/Documents/ImmediateDocumentPreview.swift`, `DocumentPreviewContent.swift`, `DocumentPreviewCache.swift`, `Vellix/Templates/GalleryDocumentPreview.swift`, `Vellix/Editor/DocumentThumbnailLayout.swift`, `NestedPageThumbnail.swift` | Render labels in native fallbacks and thumbnails, invalidate stale snapshots, and preserve tinted icons in cached PDF-based previews. |
| `Vellix/Documents/LibraryDocumentPreview.swift`, `Vellix/Templates/TemplatePreviews.swift` | Guard iPad-only preview modifiers so the shared previews compile on Mac. |
| `Vellix/Publishing/PublishingProjection.swift`, `supabase/functions/penned-publishing/contract.ts` | Include and validate active label presentation without changing the publication schema or heading levels. |
| `penned-editor/src/label-grain-light.png`, `esbuild.mjs` | Store the shared grain alpha mask; embed it for WKWebView and copy it into the app bundle for native previews. |
| `Vellix/Export/DocumentExportScript.swift`, `Vellix/Documents/DocumentPreviewCache.swift` | Rasterize the colored grain tile for WebKit's PDF compositor. |
| `penned-editor/scripts/export-public-reader.mjs`, `Penned-Site/vendor/penned-reader/`, `public/viewer-assets/`, `Vellix/VellixEditor.bundle/` | Package the editor and reader CSS, renderer, texture tiles, and selectable icon catalogue. |
| `penned-editor/tests/heading-label-browser.mjs`, `Penned-Site/tests/reader-rendering.test.ts`, `Vellix/VellixTests/LibrarySyncTests.swift` | Cover browser interaction and presentation, public heading semantics, and native document lifecycle. |
| `Vellix/VellixTests/AccountTests.swift`, `AppAppearanceTests.swift`, `VellixTests.swift` | Add missing imports and align an existing bridge assertion with the current event signature so the simulator test target compiles. |

## Rebuild and Publishing

Run these from the `penned-editor` checkout as separate steps:

```sh
# Rebuild the editor and sync Vellix/VellixEditor.bundle.
npm run build

# Regenerate the public reader and copy its CSS and texture assets.
node scripts/export-public-reader.mjs --site "$HOME/Penned-Site" --app "$HOME/Desktop/Vellix" --reuse-symbols
```

The app bundle rebuild does not update the public website. Export and deploy the
reader to update published labels. Deploy the updated publishing function
before publishing Scalloped, Plaque, or Banner labels. No document or database migration is
required. Documents published before label metadata was supported still need
a fresh publication update to include it.
