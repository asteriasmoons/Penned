# iPhone and iPad keyboard dismissal diagnostics

This is temporary, opt-in logging for the TipTap document editor. It does not
change keyboard behavior, focus handling, selection, or saving.
The shared Xcode scheme keeps it off for ordinary Debug runs. When enabled,
console output runs off the main thread; use the recorded timestamps to align
it with system messages rather than relying on console arrival order.

## Confirmed iCloud import cause

The captured dismissal began when background iCloud import preparation sent
`setEditable(false)` to the focused editor, then took a snapshot with
`suspend=true`. TipTap lost focus before UIKit hid the keyboard. The open
document did not need a content reload in that capture.

On iPhone and iPad, incoming changes now stay in the durable sync inbox while a
document is open or opening. iCloud still downloads and stages changes and
uploads local edits automatically. A local record with a competing staged
server revision waits for conflict handling; unrelated uploads still proceed.
Returning to the library automatically applies the inbox, even without a new
iCloud fetch. The existing save-before-import and recovery protections still
apply.

To verify on a device, type while an update arrives from another device. Check
that the caret and keyboard stay in place and no import-related editability
change appears in the trace. Close the document and verify that the incoming
change applies. Repeat with a competing edit to the same document and confirm
the local version is retained by the existing recovery flow.

## Capture an incident

1. In Xcode, open **Product > Scheme > Edit Scheme > Run > Arguments**. In the
   Debug configuration, enable the launch argument `-PennedKeyboardTrace`.
2. Run Penned on the affected device. Filter Xcode's console for
   `[PENNED-KEYBOARD]` and check for `trace.start` and `js.install`.
   `js.editor.missing` means DOM diagnostics are active but TipTap events are not.
3. When the keyboard disappears unexpectedly, note the `seq` on the matching
   `keyboardWillHide` line. Capture that line, its `history.begin` through
   `history.end` section, and the next two seconds, including `keyboardDidHide`.
   The history replays up to 127 preceding events with their original sequence
   numbers. Later JavaScript batches can contain earlier events.

## Read the timeline

| Look for | What it shows |
| --- | --- |
| `ui.dismissKeyboard`, `ui.endEditing`, `bridge.out command=blur` | An existing native dismissal request or bridge command. The `at=` field identifies the call site. |
| `js.dom.focusout`, `js.editor.blur`, `bridge.in kind=focus focused=false` | DOM focus left the editor, TipTap observed a blur, or native received the focus update. `responderInWK` on keyboard notifications shows whether UIKit still sees a first responder inside the WebView. |
| `js.mobile.selection.blur`, `js.mobile.divider.blur`, `js.editor.transaction` | Mobile selection or divider code explicitly removed focus, or TipTap handled a document/selection transaction. Check `source`, `mobile`, `composition`, and nearby input events; `input-window` means timing proximity, not confirmed origin. |
| `bridge.snapshot.begin suspend=true`, `bridge.out command=setEditable`, `sync.reloadAfterLibrarySync` | An editing suspension, editability change, or library sync reload. `sent_seq` ties a callback to its request. |
| `wk.host.*`, `wk.navigation.*`, `wk.processTerminated`, `ui.editor.disappear` | A host or visibility transition, WebView navigation/reload, or editor view teardown. Check whether `session`, `wk`, or JavaScript `page` changes. |

Use `wall_us` for native event time and `js_wall_us` for JavaScript event time,
not its native receipt time. `seq` orders native records; `jseq` orders events
within a JavaScript page. `doc` is a process-local token, not the stored document ID.

Share only lines with the diagnostic prefix. They exclude typed text, document
content, URLs, and bridge payloads. Other existing console output is not part
of this trace. Remove or uncheck the launch argument to turn it off.
