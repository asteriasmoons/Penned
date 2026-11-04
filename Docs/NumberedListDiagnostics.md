# Numbered-List Caret Diagnostics

The first supplied capture is analyzed in
[NumberedListTrailingBreak.md](NumberedListTrailingBreak.md). Diagnostics now
also include an `inline` array with child node types/sizes and newline-only
flags, and explicitly serialize the caret rectangle. These additions do not
log text and retain the `list-caret-v1` version and `PENNED-LIST` filter.

## Automatic Capture

The earlier Safari console expression was a manual read, not installed
diagnostics. Temporary automatic diagnostics now run in the actual iOS/iPadOS
document editor WebView in native Debug builds, including template editing.

In Xcode's debug console, filter for `PENNED-LIST`.

1. Build/run Penned's Debug configuration from Xcode on the affected device.
2. Confirm `PENNED-LIST native diagnostics enabled`, followed by a JSON record
   with `"event":"installed"` and `"version":"list-caret-v1"`.
3. Reproduce Return exiting item 4, Numbered List restoring it, tapping below
   item 4, and pressing Numbered List again.
4. Send the `PENNED-LIST` records from that sequence, especially `tap.before`,
   `number.before`, `number.after`, and the following frame/selection record.
   No manual Safari console expression is necessary.

These diagnostics are injected by native Swift. Regenerating the shared
JavaScript editor bundle is not required for this diagnostic addition. A new
native Debug build is required; Release/TestFlight builds do not enable it.

## Captured Evidence

- Model selection positions, ancestor node types, child indexes, and neighboring
  block types/counts distinguish an ordinary paragraph from a continuation
  inside item 4.
- Native DOM selection positions and caret geometry distinguish incorrect
  selection ownership from a visually displaced WebKit caret.
- Paragraph/list-item geometry, display, spacing, and pseudo-element styles
  identify placeholder layout effects. Placeholder text itself is not logged.
- Enter, Backspace, and native paragraph/deletion events capture the boundary
  transition before the final tap.
- Numbered List records its result and whether document/selection state actually
  changed. It invokes the existing command once and preserves its result/error.

No document text, titles, URLs, full HTML, full JSON, credentials, or account
data are recorded. Only bounded selection-local structure and geometry are
read; the document is not scanned. Capture is capped at 120 records per WebView
page. Post-event geometry is coalesced into a single animation-frame read.

## Files Changed

- `Vellix/Editor/MobileEditorInteractions.swift`: Debug-only diagnostic script,
  event observation, native-message reports, command observation, and cleanup.
- `Vellix/Editor/TipTapWebView.swift`: injects the script into the actual editor
  WebView and routes its reports directly to Xcode logging as `PENNED-LIST`.
- `Docs/NumberedListDiagnostics.md`: this capture guide and scope record.

The script does not set selection, focus the editor, prevent events, dispatch
document transactions, or modify formatting. Editing fixes from earlier turns
are unchanged. This is instrumentation, not a claim that the caret bug is fixed.

No builds, tests, launches, simulators, linters, or runtime verification commands
were run. Installation and device output remain unverified until the user runs
the Debug build. Remove the temporary script/injection/message route after the
underlying issue is resolved.
