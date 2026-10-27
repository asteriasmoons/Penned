# Mobile Editor Interactions

These changes apply only to iPhone and iPad. No Mac implementation, shared editor bundle, document schema, repository, account, or synchronization behavior is changed.

## Behavior

- Page titles stay on one line. Pasted line breaks become spaces when editing. Existing records are not migrated or rewritten merely by opening a page.
- Inserting a divider replaces an empty paragraph at the caret, rather than appending below it. A following paragraph remains available for typing. Existing text, divider styles and Undo are retained.
- Tapping the lower half of a divider, or its following empty paragraph, explicitly focuses the text immediately after the divider. If no text block follows (including a reopened document ending in a divider), the tap creates one there. Existing following text is reused, repeated taps do not add blank lines, and locked documents and block-selection mode remain protected. This applies to both iPhone and iPad; Mac is unchanged.
- Tapping outside the slash menu dismisses it without removing `/`. Continuing the same literal slash does not reopen the menu. A new slash can still open it.
- Backspace in an empty paragraph directly after a quote removes that paragraph and places the caret at the end of the quote's last text block in one transaction. The next Backspace uses normal text deletion. Nonempty paragraphs, selections, composition and locked documents are not intercepted.

## Changed Files

- `Vellix/Editor/MobilePageTitle.swift`: shared iOS-only title binding that removes edited line breaks.
- `Vellix/Editor/DocumentEditorView.swift`: single-line title field and tap-away slash-menu dismissal layer.
- `Vellix/Collections/CollectionKanbanView.swift`: single-line iOS entry-title composer; existing Mac branch retained.
- `Vellix/Collections/CollectionDocumentIntegration.swift`: iOS entry creation/rename fields use the title binding; Mac fields remain unchanged.
- `Vellix/Editor/MobileEditorInteractions.swift`: iOS-only JavaScript adapter using the existing TipTap instance, schema, command bridge and transactions. Kept outside the generated editor bundle so backend bundle synchronization cannot erase it.
- `Vellix/Editor/TipTapWebView.swift`: installs that adapter at document end and receives mobile slash-suppression messages. Hosting, cached ownership, attachment, loading and teardown are unchanged.
- `Vellix/Editor/TipTapEditorSession.swift`: native dismissal and suppression state, reset on WebView navigation.
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
