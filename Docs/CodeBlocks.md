# Code Blocks

Insert from **Add Block > Code Block** (the `addwavy` button on the keyboard
formatting bar), the `/code` menu, or the Mac Insert inspector. Tap a block
to open the Code sheet. On iPhone and iPad, swipe sideways on the embedded
viewer to select the block, or tap it when block selection is already active.
Vertical scrolling still scrolls the viewer. The purple checkmark saves the
draft. The paintbrush and code buttons select the theme and language;
Copy puts only the raw code on the clipboard and shows a brief confirmation
banner without dismissing the keyboard. Opening or scrolling either picker
does not dismiss the keyboard. `keyboardclose` appears beside Copy
only when the iOS code keyboard is visible.

## Editor and persistence

The existing TipTap `codeBlock` node retains its stable block ID, language,
and raw text children. It gains a `theme` attribute and a read-only node
view. Old code blocks keep their text and default to Auto. The existing
inline `code` mark and its toolbar button are unchanged. In document view,
code text, highlighted tokens, and line numbers use monospace regardless of
the page font. Native document previews also use monospace for code blocks.
The WebKit bridge
updates the matching block in one undoable transaction. It rejects a stale
draft if the saved block changed, and does not dismiss the sheet until the
document is saved through `DocumentRepository.saveEditorJSON`. Code, settings,
and position travel with the existing document JSON; there is no database
migration or separate sync record.

The native sheet uses UIKit `UITextView` (iPhone and iPad) and AppKit
`NSTextView` (Mac), with a TextKit gutter based on actual visible line
fragments. Wrapped continuations do not add line numbers. Both native and
embedded viewers wrap long lines without horizontal scrolling. Native
highlighting uses debounced UTF-16 token ranges from a private JavaScriptCore
queue. Both platforms batch foreground color changes in `NSTextStorage`
without replacing code or resetting selection. Pending colors are not applied
while the input method is composing text. UIKit draws the themed selection
behind the code without changing text attributes; AppKit uses its native
selection attributes. The shared editor does not rely on AppKit-only
temporary layout attributes, and the UIKit container height is explicitly a
`CGFloat`. In-document theme and language previews are temporary until
confirmed. The editor does not execute code or fetch a grammar from the network.

The shared catalog has 18 distinct palettes plus Auto, which picks Aura or
GitHub Light according to the current interface appearance. It has 35
grammar-backed languages plus Plain Text and Other. HTML and XML use Prism's markup
grammar; Shell supports shell scripts and command transcripts. Plain Text and
Other do not guess a grammar. Palettes were adapted from the original themes
and the [CodeMirror theme catalog](https://github.com/uiwjs/react-codemirror);
language definitions come from [Prism](https://prismjs.com/index.html#supported-languages).

## Files

- `penned-editor/src/code-block.js`, `editor.js`, and `tiptap.html`: the
  wrapped read-only node view, insertion, native bridge, and theme styling.
- `penned-editor/src/code-block-catalog.json` and `code-syntax.js`: the shared
  menus, palettes, and bundled grammar engine.
- `penned-editor/esbuild.mjs`, `package.json`, and `package-lock.json`: package
  the pinned grammar dependency and its license alongside the editor bundle.
- `Vellix/Editor/CodeBlockConfiguration.swift`, `CodeBlockEditorSheet.swift`,
  and `CodeBlockTextEditor.swift`: the sheet, menus, TextKit surfaces, and
  native highlighting.
- `Vellix/Editor/TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`,
  `TipTapWebView.swift`, and `DocumentEditorView.swift`: iOS bridge, loading,
  save, and presentation integration. The corresponding `PennedMac/Editor`
  session, WebView loader, and presentations use the same block and sheet.
- `Vellix/Documents/DocumentPreviewContent.swift`: refreshes cached snapshots
  that contain the old Code Block presentation.

## Build and Verify

If `VellixEditor.bundle` predates Code Blocks or the web editor source changes,
run `npm run build` from `penned-editor` to regenerate the bundle with the
updated schema, syntax script, and catalog. The Swift-only TextKit fix does
not require a bundle rebuild.

The read-only typography fix changes `tiptap.html` only in the web editor;
it does not need a new JavaScript bundle. The native preview cache key was
bumped only for documents containing code blocks.

The updated editor source passed source-only type checking against the iOS
and macOS SDKs in Swift 5 language mode. Full Xcode target builds and runtime
checks were not run for this fix.

For the Code Block selection and keyboard changes, the Node selection suite,
Chromium touch checks, and Swift syntax checks passed. The regression covers
selecting a nested Code Block without selecting its callout, toggling selection
by tap, and opening the Code sheet on a normal tap. The browser touch check
also confirms that a vertical swipe scrolls without selecting. The native
keyboard behavior has not been verified on an iPhone or iPad.

On iPhone and iPad, insert two blocks with different languages and themes.
Paste code containing tabs, long unbroken lines, blank lines, and a final
newline. Check the gutter and vertical scrolling, copy the exact text, change
themes with the keyboard open, and save. Reopen both blocks, relaunch Penned,
and confirm that the content and each block's settings still match.
On iPhone, iPad, and Mac, also select text across wrapped lines and switch
themes to verify the selection, syntax colors, and raw code stay intact.
