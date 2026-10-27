# Icon Menus and Preview Chevrons

## Native Menu Triggers

Penned uses the same native-control correction documented in Lurelia's read-only `Docs/Documentation.docc/MenuButtonFixes.md`:

```swift
Menu { /* existing actions */ } label: { /* existing custom icon */ }
    .menuStyle(.button)
    .buttonStyle(.borderless)
```

`pennedIconMenuStyle()` centralizes that combination in Penned's existing design system. All 18 standalone icon-bearing menu triggers use it. Labels, custom assets, dimensions, accessibility, and native menu hierarchies remain intact. Ordinary buttons, text-only pickers, and nested submenus are not replaced.

## Document Preview Cause

The toggle chevron inside a document preview is not a SwiftUI `Menu`. It is a WebKit pseudo-element. Light documents tint it using a CSS alpha mask. The live editor renders it correctly, but the preview's PDF export produced a solid square around the icon.

This was reproduced using the production `DocumentPreviewCache` and real WebKit assets on macOS. The captured composited image matched the reported square. The regression test checks the final preview's icon pixels, not a separately clipped export that can render differently.

The existing snapshot-only callout icon rasterization now supplies a shared local helper. Before PDF export, masked toggle chevrons are converted to transparent, tinted PNG backgrounds at their existing position and size. Their computed color and the actual open/closed asset are preserved. Unmasked dark chevrons remain unchanged. Snapshot decorations are reset when reusing the renderer so a previous theme cannot leak into the next capture.

Only previews containing actual toggle nodes, including referenced child documents, receive the `toggle-icon-presentation-v1` cache revision. Existing bad snapshots regenerate automatically. No document records, JSON, saved styles, gallery dimensions, or live editor hosting/loading code are changed.

## Files Changed

- `Vellix/Resources/VellixDesignSystem.swift`: shared native icon-menu styling helper.
- `Vellix/Documents/LibraryChrome.swift`: search-scope and creation menu triggers.
- `Vellix/Documents/HomeView.swift`: Home, Starred, and Folders menu triggers.
- `Vellix/Documents/DocumentBrowserView.swift`: document-options menu trigger.
- `Vellix/Spaces/SpaceViews.swift`: Space action-menu trigger.
- `Vellix/App/PadWorkspaceSidebar.swift`: sidebar Space action-menu trigger.
- `Vellix/App/PadWorkspaceView.swift`: workspace action-menu trigger only; layout and navigation are unchanged.
- `Vellix/App/VellixShellView.swift`: template action-menu trigger.
- `Vellix/Collections/CollectionViewSheets.swift`: view action and Add View menu triggers.
- `Vellix/Collections/CollectionKanbanView.swift`: collection view-switching menu trigger.
- `Vellix/Editor/InlinePropertyEditorSheet.swift`: property-type and property-value menu triggers.
- `Vellix/Editor/DocumentEditorView.swift`: More, selection-mode, and insertion menu triggers only.
- `Vellix/Documents/DocumentPreviewCache.swift`: snapshot-only masked-chevron conversion, reusing callout rasterization.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: structured toggle-node detection for scoped cache invalidation.
- `Vellix/Documents/DocumentPreviewContent.swift`: toggle-only snapshot revision.
- `Vellix/VellixTests/DocumentPreviewTests.swift`: real captured-pixel, open/closed, light/dark, renderer-reuse, and unchanged-record checks.
- `Scripts/test-icon-menus.mjs`: shared menu coverage and snapshot-boundary source checks.
- `Scripts/test-app-appearance.mjs`: updated the workspace view checksum for its single menu-style modifier; other lifecycle protections remain unchanged.
- `Docs/MenuButtonFixes.md`: this implementation and verification record.

## Verification

- Before correction, real captured light previews failed the square-background pixel checks; dark previews passed.
- After correction, 51 native tests across `DocumentPreviewTests`, `AppAppearanceTests`, and `PadWorkspaceTests` passed. Coverage includes open/closed chevrons, a reused renderer switching themes, unchanged document records, pending edits, live editor selection, and WebView ownership.
- 159 source checks passed across `test-icon-menus.mjs`, `test-app-appearance.mjs`, `test-sheet-style.mjs`, and `test-ipad-workspace.mjs`.
- Swift frontend parsing of all changed Swift files and `git diff --check` passed.
- One earlier appearance-test run failed three existing in-memory cache object-identity assertions. The final expanded run passed unchanged; cache retention behavior was not modified for this task.
- No iOS application build, simulator launch, or physical-device UI verification was performed for this change. Native menu pressed states and iPhone/iPad preview appearance still need a device check.
- Lurelia was read only. Its files were not modified.
