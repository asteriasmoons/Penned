# Editor Typing Performance

## Root Causes In Source

1. **ProseMirror transactions.** Both the block ID assigner and tag extension
   indexed almost every block on every edit. The tag assigner then resolved
   every old ID against the new document, even when the edit was ordinary text.
   On iPhone/iPad the selection plugin also remapped every bound DOM gesture
   host's position. Tab and field validity checks walked the document even when
   no block had been added or removed.
2. **Layout and bridge messages.** The existing height gate skipped some
   height reads, but caret and update callbacks still requested page-break and
   native-collection geometry work each frame. The iOS caret message caused
   a synchronous UIKit layout before checking whether scrolling was needed.
   Swift also logged each bridge message and walked document payloads for
   callout summaries. In Debug, iPad host/layout probes and numbered-list
   diagnostics could produce additional layout, JSON, and file I/O work.
3. **Autosave after a pause.** WebKit sent a whole nested JS object. Swift
   normalized and canonicalized it, built text statistics, then scanned for
   references and attachments on the main actor. Only after another native
   delay did the persistence queue get the save. Some incoming-document
   analysis also ran after taking the shared database writer.

These paths are present in source. An earlier Safari trace showed expensive
layout and a long MutationObserver callback in a large document; it did not
identify which callback was responsible. No post-change timing is claimed.

## Implementation

- `penned-editor/src/incremental-nodes.js`, `editor.js`, `document-tags.js`:
  Recognize closed replacements of text inside one textblock, including
  deletion. Those edits keep block identity without rebuilding the ID indexes.
  Structural changes still run the full reconciliation; tag ID preservation
  uses a position lookup rather than repeatedly searching the document.
  Formatting publishes at most once per frame, and slash/tag detection reads
  a bounded suffix of the current paragraph.
- `penned-editor/src/tabs.js`, `minimal-fields.js`, `list-grid.js`: Run block
  validity checks for structural changes, not for typing within a valid block.
- `MobileBlockSelection.swift`: Resolve gesture host positions when touched
  instead of remapping every host on ordinary text edits. Active gestures and
  structural edits keep their existing selection mapping and DOM reconciliation.
- `penned-editor/src/caret-tracking.js`, `editor.js`,
  `native-collection-regions.js`, and `DocumentEditorView.swift`: Drive surface
  measurements from geometry/structure changes, measure only actual page
  breaks and native collections, and omit same-line mobile caret scroll
  messages. Explicit reveals and changed visual lines still report.
- `TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`,
  `MacTipTapEditorSession.swift`, and `penned-editor/src/editor.js`: The editor
  reuses normalized unchanged blocks when building a checkpoint. It sends a
  text-only checkpoint after 500 ms of quiet or at a four-second deadline
  during continuous editing, also flushing pending text on blur or page
  visibility loss. The native app opts into the string payload at load time.
  It enqueues that snapshot without repeating structural scans; older bundles,
  mixed edits, and explicit operation snapshots keep their existing payload
  and reconciliation paths. Load/reset drops the previous JS timer. A stale
  native save completion cannot replace a newer checkpoint, and a failed
  autosave retains pending text for the next save or flush.
- `DocumentRepositories.swift`: Analyze autosave input before taking the
  shared writer. Re-read the stored row and preserve omitted metadata inside
  the write transaction. Search, descriptors, journaling, and the concurrency
  rules in `AppDatabase` are unchanged.
- `TipTapWebView.swift`, `MacTipTapWebView.swift`: Remove per-message logging.
  The iPad layout/host probe and list diagnostics are opt-in Debug arguments
  (`-PennedEditorRenderTrace` and `-PennedListDiagnostics`).

## Tabs Settings

In the editable document, tap the Tabs container border or use **Tabs Settings**
next to **Bold** when the caret is in the panel. A tab tap switches panels
without changing the saved default. Holding a tab does not open settings.
The optional header does not select the block, and tapping inside the panel
still edits text.
The purple outline was the whole-block selection highlight; deliberate block
selection still shows its highlight.

See [Editor Interaction Fixes](EditorInteractionFixes.md) for the follow-up
changes to task, tab, Fields, and InfoCard work during typing.

The sheet's **Dismiss Keyboard** button uses the shared Labels control and
keeps the sheet open. The title, description, and tab names stay local to the
sheet while typing. Previously each character triggered a WebKit command,
document snapshot, and native save processing. Changed fields now use the
existing bridge and autosave path when focus leaves the field, when the user
dismisses the keyboard or sheet, or when the app becomes inactive. Drafts
also flush before tab actions that depend on their values, such as Duplicate.
Only the sheet handles its keyboard; the underlying editor skips caret
reveal and keyboard frame updates while Tabs Settings is open.

## Standard Xcode Debug Runs

The shared Vellix scheme leaves `-PennedKeyboardTrace` unchecked. Run normally
with Xcode and the debugger attached; breakpoints and normal error/crash logs
remain available. Enable that argument only for a keyboard incident capture.
It instruments DOM input, selection, and TipTap transactions, so a capture is
not a baseline for typing performance. When enabled, its native console
output is ordered on a background queue and reuses the bridge's decoded body.
These Debug configuration changes do not require rebuilding the editor bundle.

## Expected Impact And Verification

The biggest improvement should be near the end of long documents: ordinary
typing no longer runs the ID and gesture work proportional to the number of
blocks. Same-line input should generate fewer WebKit-to-native calls and less
native layout. The database writer should spend less time on each autosave.
Large snapshots still have to be serialized in WebKit. Layout, rich tables,
large structural edits, and an in-progress IME composition can still cost time.

Regenerate the shared editor with `npm run build` from `~/Desktop/penned-editor`
and build the native app with that bundle. No build or test was run here.
Regression sources `penned-editor/tests/inline-text-edit.test.js` and
`caret-tracking.test.js` cover the classifier and caret coalescing.
`NumberedListDiagnostics.md` documents how to opt into the list probe.
