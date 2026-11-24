# Numbered-List Caret Diagnostics

The first supplied capture is analyzed in
[NumberedListTrailingBreak.md](NumberedListTrailingBreak.md). Diagnostics now
also include an `inline` array with child node types/sizes and newline-only
flags, and explicitly serialize the caret rectangle. These additions do not
log text and retain the `list-caret-v1` version and `PENNED-LIST` filter.

## Automatic Capture

The earlier Safari console expression was a manual read, not installed
diagnostics. The capture runs in iOS/iPadOS Debug editor WebViews, including
template editing, when enabled with the `-PennedListDiagnostics` launch argument.

In Xcode's debug console, filter for `PENNED-LIST`.

1. Add `-PennedListDiagnostics` under **Edit Scheme > Run > Arguments** and run the Debug build.
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

## Nested Calendar/Callout Checklist Follow-Up

The original `nearbyList` gate only recognized `orderedList`; it did not capture
the reported checklist Return sequence. It now recognizes `taskList`,
`bulletList`, and `orderedList`, including their actual nested selection paths.
The prefix and existing `-PennedListDiagnostics` opt-in are unchanged. Confirm
`"revision":"nested-list-return-v2"` in the installed record to distinguish the
new trace from earlier captures. No shared editor-bundle build is required for
the native-injected correction or diagnostics; the app needs its normal updated
native build when the user next runs it. None was run by the agent.

Capture one Return in the nested checklist, then one in the working top-level
checklist. The trace records:

- `key.before` / `input.before`: real key modifiers and native
  `insertParagraph` versus `insertLineBreak` intent, composition/cancellation,
  with correlated `returnID`, timestamp, and elapsed milliseconds.
- `path`, `ancestors`, and `native.*.ancestors`: schema ancestry and the real
  contentDOM wrappers, so `weekStrip > weekDayPanel > plainCallout > taskList >
  taskItem > paragraph` can be compared with the top-level working case.
- `calendar`: whether the caret's DOM is in chrome, an active day, a collapsed
  calendar, and whether that day matches the visible date. Date values are not
  logged.
- `inline` and `inlineTail`: bounded child types/sizes and newline flags without
  text. These distinguish a real hard break from a second paragraph or another
  checklist item even when the paragraph has many marked inline children.
- `nested-return.handled`: the scoped nested route ran the existing ordered
  editor keymaps; `expectsNativeInput` says whether a native insertion is expected.
- `nested-return.native-suppressed`: the native paragraph/line-break event for
  that already-handled key was consumed once, not applied as a second edit.
- `nested-return.skipped`, `nested-return.not-handled`, or
  `nested-return.native-unhandled`: a concrete safety rejection, a keymap decline,
  or an unusable native event. A missing `handled` record with a key/input record
  means the scoped route did not claim the event; compare its recorded ancestry,
  focus/composition/projection and native/model positions.
- `return.transaction` / `return.settled`: post-command structure and bounded
  step types/positions/slice-open-depths/top-level inserted node types. No step
  JSON or user text is included. Observation is limited to four document-changing
  transactions per Return and twelve step summaries, with a 350 ms settled read
  to include ProseMirror's deferred iOS work. This timer only reads diagnostics;
  it does not delay or perform an edit.
- `checklist.before/after/frame` and `bullet.before/after/frame`: the same command
  observation as the retained `number.*` events. The original command is still
  called once, with its result/error preserved.

Selection-only frame notifications no longer overwrite a queued meaningful
Return/input record. Timer and transaction observers are removed on destruction.
The user-supplied working trailing-line fix and the redesigned callouts are not
replaced by these diagnostics. The separate, production nested Return routing is
documented in [Editor Interaction Fixes](EditorInteractionFixes.md#nested-return-correction).

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
