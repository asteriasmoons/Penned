# Inline Text Color

## Behavior

- iPhone and iPad use the existing keyboard formatting bar. Its paintbrush appears only while editing with a focused, nonempty text selection. It remains outside the horizontal icon scroller so it is immediately visible.
- The custom Text Color sheet offers Solid and Gradient modes, a visible Color Picker button, swatches, hex entry, RGB sliders, a selected-text preview, and Apply. The Color Picker button opens the existing full picker used for card colors, including its grid/spectrum/sliders. Both Gradient Start and End also open this picker directly. Picker edits target the captured solid/start/end draft color; they do not alter the document until the outer Apply. Gradients retain presets, swap, and an angle control. Default Text Color removes only the inline color, retaining other formatting. Closing without applying leaves the document unchanged.
- The document owns the sheet independently of the keyboard bar. Opening the sheet can blur the WebView without discarding the selected range. Closing normally returns focus to that range; leaving the document never refocuses an inactive editor.
- The ProseMirror plugin owns the range and issues an opaque token. Safe edits before the selection map its positions; selected-text edits, document replacement, locking, or block-selection mode revoke or reject stale requests. Native requests are additionally checked against the document and load generation.
- Mac exposes **Selected Text Color** in the right sidebar's **Format** tab, directly below Inline Formatting. Change Text Color opens inline Solid/Gradient controls, a selected-text preview, the existing custom Palette/Spectrum/RGB/hex pickers, gradient angle/swap, Apply, Cancel, and Default Text Color. Each gradient endpoint has its own picker. These controls change only the selected text, not the document-wide text color in Style.
- Sidebar focus does not disable an eligible Mac text range. The bridge reports focus-independent `canColorText` separately from the mobile brush's focus-gated `hasTextSelection`. Mac requests opt into selection tracking: choosing different text in the editor revokes the old token and closes its draft. Blur and native picker focus alone do not revoke it. Request identity, active document/ownership and load/request generations protect tab changes, locking, closing the inspector, and delayed bridge replies.
- Only the selected, schema-eligible text receives the color. Existing bold, italic, links, inline code and document hierarchy survive. Inline atoms and code blocks whose schema forbids marks are not recolored.
- Solid and gradient colors persist as `textStyle` marks in normal document JSON. They participate in existing snapshots, autosave, synchronization, HTML copy/paste, undo and redo. No database migration or separate color store is needed.
- Native document/table previews render the same colors. Table formulas still display calculated results. Mac uses the shared editor marks and save/undo path, without adding a bottom toolbar or gestures. The retained iPad WebView ownership/lifecycle and iPhone/iPad picker UI are unchanged by the Mac addition.

## Gradient Angle Rendering: 2026-10-27

The angle remains in the existing `textStyle.gradient` mark. No new saved-data
format, native request, selection token, or publication setting is introduced.

- CSS angle conventions apply throughout: 0 degrees runs bottom to top, 90 left
  to right, 180 top to bottom, and 270 right to left.
- The sheet and Mac inspector retain `InlineTextColorSample`, which measures the
  actual preview dimensions and projects the gradient through its text mask.
  The angle is not calculated as though every text sample were a square.
- The existing TipTap extension owns a second ProseMirror plugin for visual
  gradient layout. A contiguous gradient within one text block uses one shared
  two-dimensional color field, including wrapped lines and bold/italic runs.
  Separate text blocks retain independent gradient fields.
- Actual text ranges are measured read-only. ProseMirror creates inline
  decorations for the visual fragments, with the matching gradient crop and
  angle. No block is moved, converted to an inline-block, or imperatively styled.
  Block backgrounds and block-selection highlights are not replaced.
- Paint-only transactions do not change document JSON or enter undo history.
  Content edits discard obsolete paint spans until the next layout pass; the
  ordinary mark rendering remains the fallback. Unchanged geometry does not
  dispatch another paint transaction.
- Layout refreshes on document edits, root resize, font readiness, and native
  document-level appearance changes. It does not observe and rewrite the same
  editable DOM. Observers, frames, and the scoped presentation stylesheet are
  cleaned up with the ProseMirror plugin view.
- The standalone `text-gradient-paint.js` editor asset stays inert. No gradient
  script is injected into the native HTML. The separate published-reader painter
  is unchanged by this editor correction.

The native page-opening incident and its confirmed loader cause are recorded in
[Editor Pages Not Opening](EditorPageOpening.md).

## Changed Files

Paths below are relative to the Vellix repository unless otherwise stated.

| File | Reason |
| --- | --- |
| `Vellix/Editor/DocumentEditorView.swift` | Conditional existing paintbrush asset, open action, document-owned presentation and navigation cleanup. The observer chain is split into five bounded opaque expressions without changing modifier order or the retained editor root. |
| `Vellix.xcodeproj/project.pbxproj` | Explicit app source entries for the three inline-color files, shared model membership for Mac, and Mac-only membership for its new inspector. Matching synchronized-folder exceptions prevent duplicate compilation; mobile UI files stay out of the Mac target. |
| `Vellix/Editor/InlineTextColorSheet.swift` | Custom solid/gradient sheet, visible full-picker access for solid and both gradient endpoints, draft controls, preview, Apply/reset and inline failures. Reuses `CardThreeModeColorPicker` unchanged. |
| `Vellix/Editor/InlineTextColorPresentation.swift` | Stable mobile sheet ownership and dismissal on editor lifecycle/selection-mode changes. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Backward-compatible focus-gated selection, focus-independent eligibility, active token and inline-color decoding. |
| `Vellix/Editor/TipTapEditorSession.swift` | Begin/apply/end commands with document/generation checks and safe focus restoration. |
| `PennedMac/Inspector/MacDocumentInspector.swift` | Supplies the active workspace to the Format inspector for scoped color actions. |
| `PennedMac/Inspector/MacFormatInspector.swift` | Places the selected-text color section below inline formatting in the right sidebar. |
| `PennedMac/Inspector/MacTextColorInspector.swift` | Mac inline Solid/Gradient controls with existing custom color pickers, preview, angle/swap, Apply/Cancel/default and lifecycle cleanup. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Mac begin/apply/end bridge with focus-independent eligibility, token-scoped cleanup, and document/load/request generation checks. |
| `Vellix/Documents/InlineTextColor.swift` | Validated shared color values and a rich-text preview renderer retaining existing marks. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Reuses the shared rich-text renderer for solid and gradient text. |
| `Vellix/Documents/ImmediateTablePreview.swift` | Retains inline marks in cell previews without changing formula display or table layout. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Installs the actual runtime extension and bridge hooks in the shipping artifact. |
| `../penned-editor/src/text-color.js` | Maintained TipTap mark, held selection, gradient geometry/decorations, validation, transactions and commands. |
| `../penned-editor/src/editor.js` | Registers the extension and reports selected-text state; routes color commands before early-return handlers. |
| `Scripts/install-text-color-hooks.mjs` | Mechanically replaces the existing factory, including minified factory bindings, using constructors from the shipping ProseMirror runtime. Defaults to `penned-editor`; `PENNED_EDITOR_SOURCE` can override the source directory. No compiler or bundler. |
| `../penned-editor/src/text-gradient-paint.js` and `Vellix/VellixEditor.bundle/text-gradient-paint.js` | Inert compatibility assets; comments reference the confirmed HTML-loader failure. Never injected by the native hosts. |
| `Scripts/test-text-color.mjs` | Shipping-editor regressions for mobile and Mac sidebar focus/selection behavior, plus native source/target integration checks. |
| `Scripts/test-mac-native.mjs` | Includes the shared color model in its existing headless native test module; not executed because compilation is prohibited. |
| `Scripts/test-mac-editor-navigation.mjs` | Keeps the no-bottom-toolbar regression aligned with the Format inspector's new workspace parameter. |
| `Vellix/VellixTests/SpaceEnvironmentTests.swift` | Native decoder and canonical repository persistence regressions; added but not executed. |
| `Docs/InlineTextColor.md` | Behavior, file inventory and verification boundaries. |
| `Docs/MacWorkspace.md` | Records where Mac selected-text colors live and their verification boundary. |

## Verification

### Current Correction

No tests, source-check commands, compiler, bundler, app build, simulator, or app
launch are authorized for the 2026-10-27 correction. The existing AST installer
is used only as a mechanical edit to place the maintained factory into the
shipping editor bundle; the normal editor build has not been run.

The corrected runtime still requires physical iPhone/iPad and Mac confirmation:
angle changes in the preview and applied text, wrapped and mixed-format text,
partial selections, typing, table-cell text, undo/redo, reopening, and normal
page startup. Earlier test results below are historical, not verification of
this new layout plugin.

### Earlier Feature Verification

Previously executed without building or launching an app:

```sh
node Scripts/install-text-color-hooks.mjs
node --test Scripts/test-text-color.mjs Scripts/test-task-history.mjs Scripts/test-mobile-editor-interactions.mjs Scripts/test-block-swipe-selection.mjs Scripts/test-phone-gallery-loading.mjs Scripts/test-mac-editor-navigation.mjs Scripts/test-mac-document-scrolling.mjs Scripts/test-ipad-workspace.mjs
```

The combined suites pass 172 JavaScript/JSDOM and source checks. The 27 inline-color checks exercise selection visibility, partial text, sheet/sidebar blur and range retention, cancellation, solid/gradient JSON and HTML round-trips, other marks, subsequent typing, nested containers, table cells, mixed ranges, stale tokens, mapping, validation, undo/redo and Mac rendering. They also validate both Mac color modes after blur, deliberate reselection invalidation, sidebar placement/custom picker reuse, native document/request guards, explicit Xcode source membership and unchanged mobile visibility rules. The project file passes `plutil -lint`; the maintained JavaScript passes `node --check`.

The Swift tests and native Mac test harness were not run. No Swift compilation, app build, simulator or native UI launch was performed. Mac runtime verification remains necessary for real WKWebView/AppKit focus transitions, custom color popovers, inspector/tab switching, visual gradients and undo/autosave. Physical iPhone/iPad verification remains necessary for selection-menu timing, sheet presentation/dismissal, keyboard restoration, visual gradients, swatch sizing, and gradient rendering in saved previews.
