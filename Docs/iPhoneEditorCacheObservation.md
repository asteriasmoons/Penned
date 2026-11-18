# iPhone Editor Cache Observation

## Why the First Tap Stalled

The iPhone Home recents trace showed that the first tap accepted the request,
loaded the document, and received the JavaScript layout acknowledgment within
969 ms. The native WebView still reported zero bounds. The existing frame check
could neither request a snapshot nor arm its 750 ms fallback.

The second tap, about 6.8 seconds later, replaced the opening request. The same
editor session and load generation then received nonzero native bounds. The
second request reused the already-loaded document and selected it after the
layout fallback confirmed readiness. The trace did not show a failed lookup,
bridge error, or timeout.

## Change

The compact deck in [VellixShellView.swift](../Vellix/App/VellixShellView.swift)
now uses a private `CompactEditorDeck` with
`@ObservedObject var cache: DocumentEditorCache`, following the existing
`PadEditorDeck` pattern in [PadWorkspaceView.swift](../Vellix/App/PadWorkspaceView.swift).
It receives the existing cache instance and the current selected ID. It still
renders the same editor content in a `ZStack`, keyed by document ID, with the
same opacity, hit-testing, and accessibility rules.

When [DocumentEditorCache](../Vellix/Editor/DocumentEditorCache.swift) inserts a
model into its published `modelsByDocumentID`, SwiftUI now updates the deck
directly and reads the new `preparedModels` list. This lets the prepared editor
mount and receive native layout even while selection is still pending. Before
the change, this deck read the cache through `AppEnvironment` without observing
cache changes, so it could miss the insertion until another environment update.

This change is limited to the compact deck. The iPad and split-view decks,
readiness checks, snapshot and fallback requirements, timeout handling,
navigation, loading, caching, and opening diagnostics are unchanged.

## Verify on iPhone

Using the existing [opening diagnostics](DocumentOpeningDiagnostics.md), filter
the Debug console for `[Penned Document Open]`. Open a document whose editor is
not already retained, such as the first document opened after relaunch. Tap it
once and check that the same request UUID reaches nonzero `native-webview-layout`,
`frame-confirmed`, and `navigation-selected` without being superseded by a
second request. A transient zero-bounds event during initial layout is fine;
the WebView must eventually receive nonzero bounds on that same tap. Confirm
that the editor visibly opens.

This is a native view change. It does not require regenerating the TipTap
bundle. First-tap behavior after the change still needs on-device verification.
