# Mobile Editor Interactions

The page-title, divider, and scroll behavior below applies to iPhone and iPad. The shared editor bundle owns slash-menu dismissal on both platforms; iPhone and iPad also position the picker around the keyboard. No document schema, repository, account, or synchronization behavior is changed.

## Behavior

- Page titles stay on one line. Pasted line breaks become spaces when editing. Existing records are not migrated or rewritten merely by opening a page.
- Inserting a divider replaces an empty paragraph at the caret, rather than appending below it. A following paragraph remains available for typing. Existing text, divider styles and Undo are retained.
- Tapping the lower half of a divider, or its following empty paragraph, explicitly focuses the text immediately after the divider. If no text block follows (including a reopened document ending in a divider), the tap creates one there. Existing following text is reused, repeated taps do not add blank lines, and locked documents and block-selection mode remain protected. This applies to both iPhone and iPad; Mac is unchanged.
- On iPhone and iPad, tapping the editor outside the slash menu dismisses it without inserting a block, removing `/`, moving the caret, or dismissing the keyboard. Escape also closes the picker without editing the document. Typing after the dismissed slash keeps the picker closed. Backspacing over `/` and typing it again opens the picker immediately, even at the same position. On iPhone and iPad, the picker moves above the caret or becomes scrollable when the keyboard leaves too little room below it.
- Slash insertion for Tabs, Infocards, and Fields uses a valid block boundary. A paragraph that contains only the slash command can be replaced; surrounding text is retained.
- Backspace in an empty paragraph directly after a quote removes that paragraph and places the caret at the end of the quote's last text block in one transaction. The next Backspace uses normal text deletion. Nonempty paragraphs, selections, composition and locked documents are not intercepted.
- Scrolling the document on iPhone or iPad does not automatically dismiss the keyboard. `DocumentEditorView.swift` opts the document scroll view out of automatic dismissal; the explicit dismiss button and intentional focus changes are unchanged. The [Code editor's Theme and Language pickers](CodeBlocks.md) also keep the keyboard open while opening and scrolling.

## Changed Files

- `Vellix/Editor/MobilePageTitle.swift`: shared iOS-only title binding that removes edited line breaks.
- `Vellix/Editor/DocumentEditorView.swift`: single-line title field, tap-away dismissal, and keyboard-aware slash-picker placement.
- `Vellix/Collections/CollectionKanbanView.swift`: single-line iOS entry-title composer; existing Mac branch retained.
- `Vellix/Collections/CollectionDocumentIntegration.swift`: iOS entry creation/rename fields use the title binding; Mac fields remain unchanged.
- `Vellix/Editor/MobileEditorInteractions.swift`: iOS-only JavaScript adapter using the existing TipTap instance, including mobile divider insertion when chosen from the shared slash picker.
- `Vellix/Editor/TipTapWebView.swift`: installs the adapter at document end; no second native slash-suppression state.
- `Vellix/Editor/TipTapEditorSession.swift`, `TipTapBridgeTypes.swift`, and `PennedMac/Editor/MacTipTapEditorSession.swift`: receive the shared picker state; the iOS host sends tap-away dismissal and uses the above-caret anchor.
- `penned-editor/src/editor.js`: validates slash choices against the current caret and owns dismissal. Regenerate the app's editor bundle with `npm run build` from `penned-editor`.
- `Scripts/test-mobile-editor-interactions.mjs`: directly exercises the shipping editor JavaScript and exact injected adapter using Node/JSDOM; also checks mobile-only source wiring.
- `Scripts/test-mac-isolation.mjs`: accounts for only the exact approved iOS adapter additions when comparing established host/session contracts against Mac copies.
- `Scripts/fixtures/mac-ios-source-lock.json`: updates only the five authorized existing iOS source hashes and documents why.
- `Docs/MobileEditorInteractions.md`: implementation and verification boundaries.

## Verification

Run source/JavaScript checks only:

```sh
node --test Scripts/test-mobile-editor-interactions.mjs Scripts/test-mac-isolation.mjs
git diff --check
```

No build, Swift compilation, application launch, or simulator run is part of these checks. UIKit title rendering, native tap hit-testing, physical iPhone/iPad keyboard behavior and persistence across an application relaunch still require device verification.
