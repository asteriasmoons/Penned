# Document Fonts

## Hachi Maru Pop

The existing `DocumentFontStyle` catalogue now includes `hachiMaruPop`, titled
`Hachi Maru Pop`, with an `HH` picker bubble on iPhone, iPad, and Mac. It uses the
existing Codable `DocumentAppearance.fontStyle`, appearance save notifications,
style presets, and editor `setAppearance` command. There is no new persistence
store or content migration. Existing and newly typed content inherit the same
document CSS variable; applying rich-text marks does not change the saved font.

The supplied `HachiMaruPop-Regular.ttf` remains unchanged. Its actual PostScript
name is `HachiMaruPop-Regular`. It contains 7,537 glyphs at 1,000 units per em.

## Bold and Italic

Apple explicitly documents that SwiftUI does not synthesize missing bold or
italic font faces. Requesting `.bold()` or `.italic()` from a Regular-only font
is therefore insufficient for native titles and saved-content previews.

Penned bundles three synthetic companion faces derived from the supplied Regular:

| Face | Derivation |
| --- | --- |
| Bold | FreeType outline emboldening, 1/20 em (50 units at 1,000 units per em) |
| Italic | 12-degree oblique transformation of the original outlines |
| Bold Italic | Emboldening followed by the same oblique transformation |

The companions remain in the `Hachi Maru Pop` family and have distinct
PostScript names, proper Bold/Italic style metadata, and preserved character
maps and layout tables. Native font resolution explicitly names the corresponding
Regular, Bold, Italic, or Bold Italic PostScript face. The editor and public reader declare the same four faces
with `@font-face`, rather than depending on platform-dependent faux rendering.
`font-synthesis: none` prevents additional browser synthesis on top of these
prepared outlines. Heavy and intermediate weight requests choose the nearest
provided face; this is not a variable-weight font.

Existing ProseMirror bold/italic/underline/strike/code/text-color marks, their
combinations, and undo/redo commands are unchanged. No DOM transforms, text
copies, shadow/stroke overlays, gesture listeners, or new formatting commands
are used. Inline code and code blocks retain Hachi when it is selected; other
document fonts keep their existing code-font behavior. Hachi code is not
monospaced, because retaining the chosen typeface takes precedence.

Synthetic styles are not hand-designed Bold or Italic masters. FreeType notes
that acute intersections can be imperfect after emboldening; small-size and CJK
legibility still needs visual device review. Unsupported characters and emoji
use ordinary glyph fallback, not a replacement family chosen for Bold/Italic.

`Scripts/generate-hachi-fonts.py` documents the reproducible derivation. Its
resource-authoring dependencies are `fonttools` and `freetype-py`; neither is an
app dependency. Generated faces and the SIL Open Font License are included in
`Vellix/Fonts`, the editor's `src/fonts`, and the website's `public/fonts`.

## Page Opening Boundary

HTML assembly, script injection/replacement, document decoding/loading,
presentation readiness, editor ownership, and navigation were not changed.
The only WebView configuration addition is a `penned-font` URL scheme handler
that serves a fixed whitelist of bundled font files. Missing resources return
an error; there is no font-readiness gate added to page opening. CSS uses
`font-display: swap`. Existing isolated exports already wait for fonts before
capturing, and now use the same font resource handler.

## Files Changed

Paths in this table are relative to `/Users/asteriasmoons/Desktop/Vellix`.

| File | Purpose |
| --- | --- |
| `Vellix/Documents/DocumentAppearance.swift` | Persisted choice, HH label, native and CSS font resolution. |
| `Vellix/Documents/DocumentFontResources.swift` | Register the four family faces and serve whitelisted font resources. |
| `Vellix/Fonts/HachiMaruPop-SyntheticBold.ttf` | Derived Bold face. |
| `Vellix/Fonts/HachiMaruPop-SyntheticItalic.ttf` | Derived Italic face. |
| `Vellix/Fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Derived Bold Italic face. |
| `Vellix/Fonts/OFL.txt` | Original copyright and redistribution license. |
| `Vellix.xcodeproj/project.pbxproj` | Bundle the shared Fonts folder in both app targets. |
| `Vellix/Resources/LaunchInfo.plist` | Register all four iOS/iPadOS font resources. |
| `PennedMac/Resources/MacInfo.plist` | Register the shared macOS Fonts folder. |
| `Vellix/Editor/DocumentStyleSheet.swift` | HH picker, custom-font previews, horizontally scrollable font choices. |
| `PennedMac/Appearance/MacDocumentStyleControls.swift` | Matching Mac style-sheet picker and previews. |
| `PennedMac/Appearance/MacStyleWidgets.swift` | Mac inspector's HH font bubble. |
| `Vellix/Editor/TableEditorSheet.swift` | Render the table font bubble using the actual face. |
| `PennedMac/Editor/Controls/MacTableEditorSheet.swift` | Matching Mac table font bubble. |
| `Vellix/Editor/DocumentEditorView.swift` | Native document and linked-document title fonts. |
| `PennedMac/Editor/MacDocumentEditorContainer.swift` | Native Mac document title font. |
| `Vellix/Editor/NestedPageRow.swift` | Nested-page title and excerpt fonts. |
| `Vellix/Editor/PageCardView.swift` | Card title and excerpt fonts. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Cached native document title font. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Saved-content text, headings, captions, lists, code, and components. |
| `Vellix/Documents/ImmediateTablePreview.swift` | Table fonts and retained Hachi for code-formatted cells. |
| `Vellix/Documents/InlinePropertyPreview.swift` | Native inline-property text font. |
| `Vellix/Documents/InlineTextColor.swift` | Prevent inline-code preview marks from replacing Hachi. |
| `Vellix/Collections/CollectionKanbanView.swift` | Collection headings, columns, entries, counts, and chips. |
| `PennedMac/Collections/MacCollectionKanbanView.swift` | Matching Mac collection text. |
| `Vellix/Collections/CollectionSnapshotPreview.swift` | Collection and collection-entry first-frame text. |
| `Vellix/Collections/CollectionDocumentIntegration.swift` | Native collection-entry labels and values. |
| `PennedMac/Collections/MacCollectionDocumentIntegration.swift` | Matching Mac entry labels and values. |
| `Vellix/Collections/CollectionPropertySheets.swift` | Optional document font for reused property displays; sheet defaults unchanged. |
| `PennedMac/Collections/MacCollectionPropertySheets.swift` | Matching Mac reused property displays. |
| `Vellix/Calendar/CalendarAgendaRows.swift` | Document-linked calendar preview titles. |
| `PennedMac/Browser/MacCalendarDocumentPreview.swift` | Matching Mac calendar preview titles. |
| `Vellix/Tasks/TaskHistoryPageHeader.swift` | Task-page title and metadata font. |
| `Vellix/Editor/TipTapWebView.swift` | Register the font-resource scheme only. |
| `PennedMac/Editor/MacTipTapWebView.swift` | Same font-resource registration on Mac. |
| `Vellix/Export/DocumentExportRenderer.swift` | Same font resources in isolated PDF/image rendering. |
| `Vellix/Export/DocumentWordExport.swift` | Name Hachi in DOCX font metadata; font embedding remains outside the existing exporter. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Four font faces, deterministic styles, code-font override. |
| `Vellix/VellixEditor.bundle/vellix-tables.js` | Table font choice and compatible code formatting. |
| `supabase/functions/penned-publishing/contract.ts` | Accept the new document font without weakening other validation. |
| `supabase/functions/penned-publishing/visible-content.ts` | Accept Hachi in nested-page/card previews. |
| `Scripts/generate-hachi-fonts.py` | Reproducible font resource authoring. |
| `Docs/DocumentFonts.md` | Implementation, research, file inventory, and verification boundary. |

Additional editor project files in `/Users/asteriasmoons/Desktop/penned-editor`:

| File | Purpose |
| --- | --- |
| `src/tiptap.html` | Source counterpart of the shipping font CSS. |
| `src/vellix-tables.js` | Source counterpart of table font support. |
| `src/public-document.js` | Public reader font catalogue and code-font handling. |
| `esbuild.mjs` | Preserve font assets in future editor bundle generation. |
| `src/fonts/HachiMaruPop-Regular.ttf` | Unmodified original web font copy. |
| `src/fonts/HachiMaruPop-SyntheticBold.ttf` | Same derived Bold web font. |
| `src/fonts/HachiMaruPop-SyntheticItalic.ttf` | Same derived Italic web font. |
| `src/fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Same derived Bold Italic web font. |
| `src/fonts/OFL.txt` | Web-font license. |

Additional website files in `/Users/asteriasmoons/Penned-Site`:

| File | Purpose |
| --- | --- |
| `src/lib/public-document.ts` | Extend the current shared reader's font catalogue without rebuilding its vendor bundle. |
| `src/styles/reader.css` | Four public font faces and scoped code/property font behavior. |
| `public/fonts/HachiMaruPop-Regular.ttf` | Unmodified original web font copy. |
| `public/fonts/HachiMaruPop-SyntheticBold.ttf` | Same derived Bold web font. |
| `public/fonts/HachiMaruPop-SyntheticItalic.ttf` | Same derived Italic web font. |
| `public/fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Same derived Bold Italic web font. |
| `public/fonts/OFL.txt` | Public web-font license. |

## Delivery and Verification Boundary

No app or website builds, automated tests, simulator runs, or physical-device
checks were run. Work consisted of source inspection, current official-document
research, font metadata inspection, code changes, and font-resource generation.
Device verification still needs to cover font selection/reopen, typing,
Bold/Italic combinations with other marks, native previews, and PDF/image output.

The app bundle's HTML/CSS was updated directly, so no editor npm build is needed
to obtain these font changes when the app is next built. The editor source and
asset-copy script are also updated for future regenerations. Website and
publishing Edge Function changes are source-only and still need deployment
before public publishing accepts and serves this font. No database migration is
needed. DOCX names the family, but a recipient needs it installed because the
existing DOCX exporter does not embed fonts.

## iPhone Font Corrections (2026-10-28)

### Weight and Heading Resolution

The Bold authoring strength is now **50/1,000 units (1/20 em)**, up from the
rounded 31-unit result of 1/32 em. Regular, the previous 31-unit Bold, and
50-/62-unit candidates were rasterized for outline inspection at reading sizes.
The 50-unit choice makes the strokes substantially clearer while retaining open
`a`, `e`, `o`, and `p` counters and the rounded handwritten shapes in the sample;
the heavier candidate was more crowded. Both Bold files were regenerated with
`--bold-only`. Regular and Italic were not rewritten.

The editor already declares its headings at weight 800. No new rule making
additional blocks or heading levels bold was added. The weakness was not a
missing heading CSS declaration. Native titles and previews, however, requested
the explicit Regular PostScript face and then applied weight/italic modifiers.
That leaves face resolution dependent on trait matching instead of choosing the
already-generated file. Native requests now name the correct face directly;
rich-text preview runs resolve their base weight plus Bold/Italic marks together.
The web declarations explicitly map requested weights 600-900 to the prepared
Bold or Bold Italic face, retaining every existing element's weight declaration.
Actual face selection on the reported iPhone remains a physical-device check;
source inspection is not presented as a runtime font trace.

Bold resources keep their family, PostScript names, 700 weight metadata, Bold
and Italic trait flags, and 7,537-glyph coverage. Their internal version is
updated and their web URLs use `?v=2`, so the existing immutable asset cache
cannot keep serving the old outlines under the new declaration.

### Embedded Cards

The editor's card is a PNG generated by native `PageCardView`; it is not editable
DOM text that can inherit CSS. Its native renderer used the referenced child's
appearance, and its payload cache tracked child records and color scheme but
not the containing page's font. Consequently a Hachi parent could contain a
card whose title and excerpt were rendered using the child's conventional font.

`PageCardView` and `PageReferencePresentation` now accept the containing font.
When it is Hachi, the existing title and excerpt typography uses Hachi; other
parent fonts preserve the previous child-font behavior. The same context is
passed through native unplaced cards, immediate previews, both platform editor
sessions, and isolated export references. Changing the parent's font invalidates
only the card presentation payload as needed. The card miniature retains its
own child-page appearance, and no child record or saved font is modified.
The published reader has the matching Hachi-only card-copy inheritance rule.
Card geometry, colors, backgrounds, truncation, and gestures are unchanged.

### Home and All Docs Paragraph Previews

Both surfaces share `LibraryDocumentPreview` and `DocumentPreviewCache`, across
iPhone/iPad and Mac. Their native header/card artwork and WebKit body are
different render layers. The body previously awaited `document.fonts.ready`
before explicitly forcing its first offscreen text layout; that can finish
before the required font loads have been requested. A fallback-font PNG could
then persist because font-resource changes had no rendering-version component
in the key. The in-memory content lookup also accepted a cached record solely
by timestamp, even when appearance fields differed at that timestamp.

The offscreen Hachi snapshot now reapplies the *previewed document's* appearance,
forces font layout, and explicitly requests its four faces before capture.
This wait is confined to preview generation, not live page opening. Native
first-frame paragraph/list/heading/table runs also receive explicit fonts and
combined traits, rather than relying on an outer concatenated-Text modifier.
Cached content requires the same document record, and a Hachi-only rendering
revision replaces old fallback-font PNGs without invalidating other fonts.
The existing frozen first-frame behavior, preview sizes, and snapshot pipeline
remain in place; they were not replaced with a new preview system.

### Files Changed for This Correction

Paths below are relative to `/Users/asteriasmoons/Desktop/Vellix` unless the
project directory is stated explicitly.

| File | Correction |
| --- | --- |
| `Scripts/generate-hachi-fonts.py` | 1/20-em strength, Bold resource revision, and `--bold-only` option. |
| `Vellix/Fonts/HachiMaruPop-SyntheticBold.ttf` | Heavier Bold resource, shared by iOS/iPadOS/macOS. |
| `Vellix/Fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Matching heavier Bold Italic resource. |
| `Vellix/Documents/DocumentAppearance.swift` | Select exact native style faces. |
| `Vellix/Documents/InlineTextColor.swift` | Resolve the font and combined marks on each Hachi text run. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Pass existing heading sizes/weights and containing card font. |
| `Vellix/Documents/ImmediateTablePreview.swift` | Resolve cell base styles together with inline marks. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Hachi-only snapshot rendering revision. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Exact-record content matching and explicit offscreen Hachi font loading. |
| `Vellix/Editor/PageCardView.swift` | Hachi parent font for card titles/excerpts only. |
| `Vellix/Editor/PageReferencePresentation.swift` | Forward containing font to card PNG generation. |
| `Vellix/Editor/TipTapEditorSession.swift` | Track containing font in the existing card-payload cache. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Matching Mac payload-cache correction. |
| `Vellix/Editor/DocumentEditorView.swift` | Containing font for native unplaced cards. |
| `PennedMac/Editor/MacDocumentEditorContainer.swift` | Matching Mac unplaced cards. |
| `Vellix/Export/DocumentExportRenderer.swift` | Keep visual export references consistent with embedded cards. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Bold weight-range mapping and versioned resource URLs. |
| `Docs/DocumentFonts.md` | Findings, exact changes, and verification boundary. |
| `/Users/asteriasmoons/Desktop/penned-editor/src/tiptap.html` | Matching source CSS; shipping HTML was updated directly without a build. |
| `/Users/asteriasmoons/Desktop/penned-editor/src/fonts/HachiMaruPop-SyntheticBold.ttf` | Identical new Bold resource. |
| `/Users/asteriasmoons/Desktop/penned-editor/src/fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Identical new Bold Italic resource. |
| `/Users/asteriasmoons/Penned-Site/public/fonts/HachiMaruPop-SyntheticBold.ttf` | Identical new published Bold resource. |
| `/Users/asteriasmoons/Penned-Site/public/fonts/HachiMaruPop-SyntheticBoldItalic.ttf` | Identical new published Bold Italic resource. |
| `/Users/asteriasmoons/Penned-Site/src/styles/reader.css` | Matching face mappings, cache revision, and Hachi card-copy font. |

### Verification and Remaining Limits

Completed font-resource inspection: the generated files retain the same family,
expected PostScript names, 700 weight, correct Bold/Italic flags, and all 7,537
glyphs. SHA-256 hashes match for the new Bold/Bold Italic copies in all three
projects. Regular and Italic hashes remain unchanged:

- Regular: `a1460e0fb8608bca3cc74f91605ccdb84f62c9b9808061037b4f5ccaad489a17`
- Italic: `a3c84b085c43863f2148b817e56ce18eef7574b80885265ed76df05a6ac8c80f`

No app/website builds, automated tests, simulator runs, or device runs were
performed. Font specimen generation and inspection were resource-authoring
work, not an app rendering test. Device confirmation is still required for
the final small-size weight, combined marks, font changes/reopening, and
Home/All Docs snapshots. CJK intersections may still need visual review.
Website resources/CSS need deployment to become live. No further backend change
or database migration was needed for this correction.

Live document decoding, assembled HTML replacement, WebView ownership,
initialization scripts, persistence, text editing commands, and selection/undo
behavior were left untouched. The only live-session adjustment is font-aware
card presentation refresh through its existing metadata command.

Existing selection, gestures, keyboard handling, cursor behavior, editor
initialization, undo/redo, document save/loading logic, publishing ownership,
and unrelated worktree changes were intentionally left unchanged.

## Research

- [Apple: Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text): registration, PostScript names, trait limitations, and Dynamic Type.
- [Apple: CTFontCreateCopyWithSymbolicTraits](https://developer.apple.com/documentation/coretext/ctfontcreatecopywithsymbolictraits(_:_:_:_:_:)): matching existing family traits is not a dependable way to invent missing faces.
- [FreeType: Outline processing](https://freetype.org/freetype2/docs/reference/ft2-outline_processing.html): outline emboldening, affine transforms, and intersection limitations.
- [W3C: CSS Fonts Level 3, font synthesis](https://www.w3.org/TR/css-fonts-3/#font-synthesis): browser-synthesized weights/styles and controlling synthesis.
- [Original Hachi Maru Pop OFL](https://github.com/google/fonts/blob/main/ofl/hachimarupop/OFL.txt): bundling and derived-font licensing.
