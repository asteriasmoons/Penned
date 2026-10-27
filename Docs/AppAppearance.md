# Application Appearance

Implemented 2026-10-18 for Penned's existing iPhone and dedicated iPad interfaces.

## Preference and Application Boundary

`PennedAppearancePreference` provides Light, Dark and System. The one local
preference is `penned.applicationAppearance`, stored in UserDefaults through
`@AppStorage`. Missing or invalid values fall back to Dark. There is no onboarding,
account-specific copy, document preference, CloudKit setting or Supabase setting.

`VellixApp` applies `pennedApplicationAppearance()` around the existing library
and recovery UI. This uses `preferredColorScheme`: Light/Dark force their chosen
scheme, while System supplies nil and follows the system. The Debug and Release
target's old `UIUserInterfaceStyle = Dark` settings were removed; the application
preference supplies the existing-installation Dark default instead.

Sheets use the same modifier and preference. The old hard-coded Dark overrides
were removed from account settings, collection/property sheets, Space settings,
the native style-name alert and other sheet content. Native menus, alerts,
pickers, keyboards and navigation inherit the enclosing presentation's scheme;
there are no global UIKit appearance-proxy changes.

The appearance modifier does not add an identity, change a workspace key, reset
navigation, reopen a library, select a tab or change a document identifier.

API references: [SwiftUI preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
and [UIKit dynamic colors](https://developer.apple.com/documentation/uikit/uicolor/init(dynamicprovider:)).

## Settings

- iPhone: Settings > Appearance & Sound.
- iPad: Settings > General Settings > Appearance.

Both routes display the same `PennedAppearanceSettingsView`, use the same storage
key and apply the selection immediately. Options use the existing frosted fields,
rounded black-weight typography, existing custom icons and purple checkmark.
Selection is also exposed through accessibility selected traits and stable
`appearance-light`, `appearance-dark` and `appearance-system` identifiers.

## Semantic Colors and Shared Surfaces

The existing `VellixSurface` remains the shared application palette. `Color.penned`
uses native dynamic UIColor/NSColor providers, rather than copying light/dark
branches into individual views. Roles cover workspace and sidebar backgrounds,
paper/elevated surfaces, primary/secondary/tertiary/control/disabled text, input
tints, separators, selections, toolbars, shadows and status/action accents.

Dark values retain the existing black/charcoal surfaces and established accent
values. Light uses white and light neutral/lavender surfaces, dark ink, stronger
purple/teal/status accents and softer shadows. Secondary control labels retain
their previous dark opacity but receive readable semantic ink in Light.

The shared frosted material keeps its pigment, Liquid Glass, frost layers,
blur radii and geometry. Its common field tint now resolves by appearance. The
native sheet backdrop implementation, light UIBlurEffect and 35% backdrop
intensity remain unchanged. Group backgrounds still use the existing native
row geometry owner, without an independent forced Dark environment. Reduced
Transparency renders the material's tint without its glass/cloud layers.

Literal colors remain where they describe user-chosen content, image artwork,
contrast over a fixed colored badge, or physical shading. They are not used to
force an application screen to remain Dark.

## Default and Custom Documents

The existing saved representation remains `DocumentAppearance`. `.plain` is
unchanged: no theme ID, #343434 backdrop, #242424 paper, #F7F7F7 text and rounded
font. Missing appearance JSON decodes to that same plain appearance.

`resolved(for:)` produces a **display-only copy**. For a plain Light document it
resolves a #F4F1F8 backdrop, white paper and #211D29 default text. Dark uses the
existing saved defaults. System uses the effective SwiftUI color scheme. Default
fields in an older saved plain record follow exactly the same resolution as a
new document with no appearance record.

Resolution is per property, not based solely on whether an appearance JSON string
exists. A named/custom `themeID` preserves its saved values. For an appearance
without a theme ID, a non-default or explicitly marked surface is also recognized
as custom and retains its saved paper/text defaults. This protects legacy black
surfaces with white typography. Typography-only changes retain custom fonts and
text colors while their default background/paper fields follow the app. Covers and other
appearance metadata are not discarded or rewritten.

The optional Codable `customizedFields` set distinguishes new explicit color
choices, including choosing the old default white text deliberately. The existing
text-color picker marks that choice. Backdrop and paper editing already use the
existing explicit custom layout/theme representation. Old records need no schema
migration or write on launch. No existing document is rewritten to add this set.

There is one unavoidable legacy ambiguity: an old record that exactly matches
the historical plain defaults cannot reveal whether someone explicitly selected
those exact same document-level values. Such records follow the application, as
required for existing default documents. Non-default legacy values, explicit
themes and rich-text formatting are preserved. New explicit text choices are
tracked, removing that ambiguity going forward.

Default-surface detection compares the rendered solid color/effect, not unused
gradient direction, image-blur metadata or the inactive secondary solid color.
Redundant legacy metadata therefore does not accidentally freeze a default page.

The existing Style Gallery now includes Default Appearance. Choosing it explicitly
returns the document to `.plain` (and removes its custom cover through the existing
style-definition flow). That user action restores automatic theme presentation;
switching the app theme never invokes the reset or save action.

## Editor Integration

`DocumentEditorView` reads the effective color scheme and renders a resolved copy
of its raw `localAppearance`. It never assigns that resolved copy to local saved
state or to `model.updateAppearance`. Existing native titles, page surfaces,
collection overlays and separators receive presentation colors without changing
their dimensions, padding, scrolling or control placement.

`TipTapEditorSession` keeps its raw current appearance and the current application
scheme separately. A live scheme change resolves the raw appearance and sends the
existing `setAppearance` command. The command also supplies the document surface
scheme and the interface scheme separately: a black custom document can keep dark
document defaults while a tag suggestion menu uses the light application palette.

The maintained editor source has a presentation-only `appearance.js` module.
It updates root CSS variables and color-scheme metadata, not the ProseMirror
document. Default body/headings, secondary text, links, caret, selections, dividers,
code/block borders, collection surfaces, default table headers and suggestion
menus use the appropriate variables. Existing custom toggle assets get a
current-ink mask in Light rather than an inverted image. Dark keeps its previous
toggle rendering and default cyan links.

Explicit node attributes, text marks, highlights, cell fills, cell text colors,
callout colors and blockquote colors are not transformed or recolored. SwiftUI's
immediate preview also respects explicit text-color and highlight marks.

Theme updates do not call setContent, loadHTMLString, load a document, reset the
presentation state, detach a WebView or flush a save. Page-reference thumbnail
metadata refreshes only when needed for theme-dependent referenced pages.

`TipTapWebView.swift`, `DocumentEditorCache.swift`, `PadWorkspaceModel.swift` and
`PadWorkspaceView.swift` are byte-for-byte unchanged by this implementation.
Source contracts pin those boundaries, and the existing late-update/teardown
ownership regression tests still pass.

## Previews and Caches

`DocumentPreviewContent.cacheKey(for:)` adds a Light/Dark presentation suffix only
when the document or a referenced child has theme-dependent default fields.
The base content key and stored records are unchanged. Fully custom documents
without theme-dependent children retain the same cache key in both modes.

The gallery passes its effective scheme to immediate fallback rendering,
presentation-image caching and the existing WebKit preview renderer. Native
headers, page backgrounds, embedded collections, tables, nested thumbnails and
WebKit body text resolve the same document appearance. A changed default key
replaces the old visible presentation instead of reusing the wrong-theme image.
Custom snapshots are not inverted or recolored.

No document preview component, dimensions, 20% clipping, width, alignment,
spacing, responsive column calculation or gallery navigation was replaced.
Only disposable preview files can be regenerated; appearance changes do not save
document JSON, create history revisions or update custom style definitions.

The preview cache accepts the existing optional editor-loader test boundary so
headless tests can load the real bundle. Production keeps the same default loader.

## Files Changed

Paths below are relative to the Vellix repository unless marked as editor source.
Each listed file changed for appearance or its verification only.

| Files | Reason |
| --- | --- |
| `Vellix/Resources/PennedAppearance.swift` (new) | Preference, effective-scheme resolution, native dynamic-color helper and root modifier. |
| `Vellix/Resources/VellixDesignSystem.swift` | Extend the existing semantic palette; preserve Dark and add Light values. |
| `Vellix/VellixApp.swift`, `Vellix.xcodeproj/project.pbxproj` | Apply the preference; remove forced Dark in both build configurations; register the new test file. |
| `Vellix/Spaces/PennedAppearanceSettingsView.swift` (new), `PennedSettingsView.swift`, `Vellix/App/PadSettingsView.swift` | One shared appearance-selection page and both existing Settings routes. |
| `Vellix/Resources/PennedSheetStyle.swift`, `PennedSheetSectionBackground.swift`, `PennedFrostedCard.swift` | Scheme-aware sheet/field presentation and Reduced Transparency fallback, with existing geometry and blur recipe retained. |
| `Vellix/Documents/DocumentAppearance.swift` | Pure default resolution, backward-compatible explicit-choice metadata and document semantic colors. |
| `Vellix/Editor/DocumentEditorView.swift`, `TipTapEditorSession.swift`, `TipTapBridgeTypes.swift` | Live presentation update through the existing bridge, plus readable application-owned editor controls. |
| `Vellix/Editor/DocumentStyleSheet.swift`, `StyleNameAlert.swift` | Theme-aware styling UI and thumbnails, explicit text-choice tracking, Default Appearance action and inherited alert scheme. |
| `Vellix/Documents/DocumentPreviewContent.swift`, `DocumentPreviewCache.swift`, `LibraryDocumentPreview.swift`, `ImmediateDocumentPreview.swift`, `ImmediateTablePreview.swift`, `InlinePropertyPreview.swift` | Presentation cache keys and matching fallback/WebKit/native preview palettes; preserve explicit formatting. |
| `Vellix/Editor/NestedPageThumbnail.swift`, `PageReferencePresentation.swift` | Resolve nested previews and supply their intended color scheme. |
| `Vellix/App/PadWorkspaceSidebar.swift`, `Vellix/Documents/LibraryChrome.swift`, `HomeView.swift`, `DocumentBrowserView.swift`, `FolderLibraryViews.swift` | Semantic workspace, sidebar, gallery surroundings, folder and navigation colors only. |
| `Vellix/Spaces/SpaceImage.swift`, `Vellix/Accounts/AccountSettingsView.swift` | Scheme-aware fallback Space icon and inherited Account Settings appearance; no account logic changes. |
| `Vellix/Calendar/CalendarAgendaRows.swift`, `CalendarView.swift`, `CalendarEventDetailSheet.swift` | Calendar accent, selected-label contrast, dividers and presentation inheritance. |
| `Vellix/Tags/TagBrowserView.swift`, `TagEditorIntegration.swift` | Semantic tag-browser/selector surfaces and readable controls. |
| `Vellix/Collections/CollectionDocumentIntegration.swift`, `CollectionPropertySheets.swift`, `CollectionViewSheets.swift`, `CollectionKanbanView.swift`, `CollectionSnapshotPreview.swift` | Remove forced Dark; theme default collection surfaces without changing saved column/option colors. |
| `Vellix/Editor/CardBackdropSheet.swift`, `CardPhotoSearchSheet.swift`, `InlinePropertyEditorSheet.swift`, `PageCardEditorSheet.swift`, `TableEditorSheet.swift`, `TaskEditorSheet.swift` | Adapt shared tool/sheet text, borders, selected states and placeholders without resizing controls or changing actions. |
| `Vellix/VellixTests/AppAppearanceTests.swift` (new), `PadWorkspaceTests.swift` | Preference/model/preview/palette tests and actual live WebKit regressions. |
| `Scripts/test-app-appearance.mjs` (new), `test-sheet-style.mjs`, `test-collections.mjs` | Appearance boundary contracts, theme-aware sheet assertions retaining material/geometry checks, and existing native harness registration. |
| `../Vellix-backend/src/appearance.js` (new), `editor.js`, `tiptap.html`, `vellix-tables.css`; `tests/appearance.test.js` (new) | Maintained WebKit presentation source and real-editor theme tests. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js`, `tiptap.html`, `vellix-tables.css` | Regenerated/copied matching editor assets. Other bundle assets were not replaced. |
| `Docs/AppAppearance.md` (new) | Implementation, verification results, limits and device checklist. |

Search, Daily Notes, template components, attachment sheets, Space management,
library/sync settings, empty/loading/error states and other shared surfaces were
included in the color/override audit. Views already using native semantic colors
or `VellixSurface` inherit the new palette without unrelated edits. Authentication,
ownership, GRDB schema/repositories, CloudKit mappings and Supabase behavior were
not changed.

## Automated Verification

The existing macOS Swift/WebKit harness loads the actual production Swift files
and bundled TipTap editor, not a substitute editor.

- Focused appearance/preview/workspace run: 49 tests in three suites passed.
- Application/preview tests cover preference persistence for all three values,
  missing/invalid defaults, System resolution, semantic text/accent contrast,
  legacy plain records, custom themes and values, explicit white text, resetting
  to plain, unchanged GRDB records/history, actual default/custom preview pixels,
  and separate cache reuse. Default Light/Dark previews retain identical dimensions.
- Actual WebKit tests verify live default text colors, preserved unsaved JSON and
  selection, unchanged HTML load count and host ownership, custom document colors
  with an independently light interface, and both existing stale-host regressions.
- Native Settings test captures a hosted macOS SwiftUI page and checks painted
  controls and distinct palettes. It is not physical-iOS material verification:
  native Liquid Glass and app-asset compositing are not reliable in this headless
  bitmap capture and are not treated as final screenshots.
- Source contracts: all 146 application appearance/iPad workspace/shared-sheet
  checks passed. These cover both Settings routes, presentation inheritance,
  custom assets, protected lifecycle code and unchanged gallery layout contracts.
- Relevant editor JavaScript suites: all 42 tests passed, including four new
  appearance tests and existing formatting/readiness/callout/collection/task cases.
- Account/authentication harness: all 62 tests passed in the broader contract run.
- Broader native run: 253 tests ran; 252 passed. The existing
  `pixelsMustBeConfirmedAfterTheCurrentLayoutBeforeAPageCanOpen` test has two
  failing expectations about native-region readiness. That test exercises the
  unchanged `DocumentPresentationState`, whose current implementation explicitly
  avoids waiting for offscreen native overlays. It and the protected readiness
  behavior were not weakened or rewritten for theming.
- Broader editor run: 241 tests ran; 235 passed. Six existing table cases fail:
  three zero-sized-table serialization/expansion expectations, a stub document
  without addEventListener, a source assertion that Table must be the first slash
  item (Collection currently precedes it), and a formula-adjustment expectation.
  Those table implementations were not changed as part of appearance work.

The iOS Debug Simulator target builds with code signing disabled. Existing actor
isolation and deprecated Text-concatenation warnings remain; this is not a
warning-free build. No simulator was booted and no physical app was installed or
launched for this feature. There is no claim of real-device appearance, rotation,
keyboard or touch verification from these automated results.

## Physical Device Checklist

1. On both iPhone and iPad, choose Light, Dark and System; quit/relaunch and verify
   the chosen option persists, including while signed out or switching accounts.
2. In System, change device appearance while the app and a default document stay
   open. Confirm native chrome, default body/title, gallery and visible sheets update.
3. Type unsaved text, select a range, scroll down, switch appearance, then verify
   text, selection/caret, undo history and the outer document scroll position.
4. Open old plain documents and new ones; verify readable text, links, placeholders,
   lists, toggles, tasks, tables, code, properties, collections and attachments.
5. Open explicitly black, cream, pink, image-backed and named-theme documents in
   both modes. Verify saved colors/fonts/covers and explicit formatting are unchanged.
6. Choose Default Appearance in the existing Style Gallery; confirm the document
   resumes following the application without changing its content.
7. Switch gallery modes and tabs; confirm default previews update but custom
   previews do not recolor, resize or lose content.
8. On iPad, toggle docked/overlay sidebars, change tabs, rotate and resize the
   window/Stage Manager. Confirm no blank editor, lost edits or navigation reset.
9. Inspect menus, confirmations, alerts, popovers, account/email sign-in, calendar,
   tags, folders, Space settings, templates and Library & Sync in both modes.
10. Check large Dynamic Type, VoiceOver selection announcements, increased contrast
    and Reduced Transparency. Verify frosted surfaces on actual iOS; do not use
    the macOS bitmap capture to judge Liquid Glass compositing.

Explicit user-selected colors can intentionally have low contrast. The theme
system preserves them rather than silently altering document formatting.
