# Editor Interaction Fixes

## Calendar Expansion Callback Context

The Calendar NodeView returned `update(nextNode) { ... }` and, when the collapsed
attribute changed, called `this.options.reportHeight?.()`. ProseMirror invokes
that method as `this.spec.update(...)` (installed `prosemirror-view/src/viewdesc.ts`),
so `this` is the returned NodeView object, not the Calendar extension. That object
has no `options`: accessing `reportHeight` throws before the update returns and
before the height refresh can be scheduled. This is a definite source-level bug
that interrupts collapse/expand processing; the exact device failure has not
been independently captured in a runtime trace.

Change only the NodeView update callback to `update: nextNode => { ... }`, retaining
the extension's lexical context so its existing animation-frame height callback
can run and ProseMirror can finish updating the child views. Do not remove the
height report, force a reload, reconstruct calendar content, or reset saved
collapse state. Keep the centered grid header and adjacent right-hand controls.

Add `calendarDiagnostic` stages `collapse-request`, `collapse-result`, and
`collapse-blocked` around the existing click handler. They report the requested
state, transaction acceptance, DOM/accessibility state, or locked/detached guard;
they contain no title or content. Preserve edit-lock behavior and existing click
handling rather than introducing unproven gesture changes.
These stages use the existing debug console prefix `PENNED-CALENDAR` with no
additional diagnostic launch argument required.

Updated maintained `src/week-strip.js`, the matching shipped bundle callback and
click diagnostics, this page, and CalendarBlocksImplementation.md. No builds,
tests, compilation, linters, simulators, or app launches; source and whitespace
review only. Successful physical-device expansion remains to be confirmed.

## Calendar Header Centering and Button Spacing

The flex header gave each item a 16 px gap (8 px in narrow calendars), separating
collapse from the next-week arrow and shifting the title left because there were
two controls to its right but only one to its left. Replace that header layout
with grid tracks: 72 px on the left, a shrinking title, and two adjacent 36 px
right-hand controls. Equal 72 px side reservations center the title within the
calendar, with no added gap between collapse and next. The title fills only its
own track, retaining truncation in narrow calendars rather than overlapping
buttons. Remove the old flex sizing and narrow-header gap override.

Updated maintained and shipped `tiptap.html` styles only, plus this page and
CalendarBlocksImplementation.md. Arrow glyphs remain 21 px, tap targets remain
36 px, title weight remains 900, and date overlays remain 20%. No JavaScript,
navigation, title editing, collapse persistence, or content behavior changed.
No builds, tests, compilation, linters, or app launches; source/whitespace review
only. Device appearance remains unverified.

## Calendar Header Visual Refinement

Reduce all three navigation/disclosure glyphs from 30 px to 21 px while keeping
their 36 px tap targets. Header order is now previous arrow, editable title,
collapse/expand, next arrow. Set only the calendar title to Black weight (900),
leaving date text customization unchanged. Reduce the extra date-bubble black
overlay from 30% to 20% for active and inactive dates; keep the selected-date
selector restricted to the calendar's own chrome so it cannot darken nested
Heading Labels. Preserve existing glass material, navigation, saved collapse
state, and the Return fixes. Updated maintained Calendar source/styles, shipped
JavaScript/styles, and this page plus CalendarBlocksImplementation.md. No builds,
tests, compilation, linters, or app launches; source/whitespace review only.

## Direct-Owner Return for Toggles and Callouts

The supplied `nested-list-return-v2` capture confirms
`doc > weekStrip > weekDayPanel > toggleItem > taskList > taskItem > paragraph`.
Return attempt 1 leaves the checklist at one item while increasing that item's
paragraph count from two to three. Its transaction contains two paragraph
fragments with open depth 1, matching the toggle handler's ordinary paragraph
split rather than the checklist's two-level item split.

`ToggleItem.Enter` searched all ancestors and used a too-permissive
`$from.depth < childDepth` check. The toggle therefore claimed Return from an
inner checklist before its own keymap could run. Change this to direct ownership:
`$from.depth !== childDepth` returns false. Direct toggle summary/body Return is
preserved; nested lists, callouts, tables, and other containers keep their own
handlers, inside or outside a calendar.

Make the Plain Callout's remaining clipped-source Return shortcut explicitly
check its immediate parent as well, before any callout-specific handling. Its
intentional direct-paragraph hard break is preserved. Ordinary Plain Callouts,
Icon Callouts, and Grid Cards keep their existing direct-parent container split;
none may claim a paragraph owned by a nested list item. No callout layout/schema
was reconstructed, and no stored paragraphs, marks, reminder settings, or IDs
were rewritten.

The working trailing-line tap/toolbar correction and existing diagnostics remain
unchanged. The preceding mobile routing patch was not sufficient for the new
toggle-only case; this correction fixes ownership in the shared keymap itself.
The earlier callout-only runtime failure is not independently proven to share
this same cause, so no claim of complete device validation is made.

Changed maintained `penned-editor/src/editor.js`, synchronized only the two
corresponding handlers in shipped `Vellix/VellixEditor.bundle/tiptap.bundle.js`,
and updated this existing fixes page. No builds, compilation, tests, linters,
app launches, or simulators were run. Verification is limited to source review
and whitespace checks.

## Calendar Glass Scope and Nested Checklist Return

November 21, 2026 follow-up. The user's device comparison shows checklist Return
working at document level but failing inside a callout inside a Calendar/Week
Strip. The user had not run the preceding editable-title/collapse changes when
reporting this, so those untested changes are not assigned as the cause.

### Heading Label Darkening

Confirmed source cause: `.penned-week-strip .penned-label-glass-material::after`
matched every glass material below a calendar, including Heading Labels in its
day content. Its extra 30% black background therefore leaked onto those labels.
The shared CSS glass material and native `BubblyIconMaterial` were inspected;
neither contains that extra flat black layer. Their normal glass highlights and
edge shading were not removed or redesigned.

Scope the extra layer through the calendar's direct chrome/day-strip/date-button
children to the selected date bubble only. Scope its stacking rule the same way.
Keep inactive-date darkening local to the existing date-button background. Labels
and navigation icons now retain the original glass material without the extra
calendar overlay. Apply matching selectors in maintained and shipped HTML/CSS.

### Nested Return Correction

The working `trailingNumberedLine` / `separateTrailingNumberedLine` correction
remains intact, including its existing checklist/bulleted-list support. It uses
relative list/item ancestors, not a fixed document-root depth, and its tap and
toolbar actions were not removed or replaced. It addresses an already-present
trailing blank line; it does not own the Return key that may create that line.

The inspected `weekStrip` / `weekDayPanel` nodes do not define a Return shortcut
for daily content. The generic container split is direct-parent scoped, so a
paragraph owned by `taskItem` does not match it. The redesigned ordinary Plain
Callout returns control to normal keymaps; its hard-break shortcut applies only
to direct paragraphs in clipped-source callouts. The standard checklist shortcut
uses `splitListItem`. Thus no calendar-specific handler that deliberately inserts
this bad line was established from source inspection.

Installed ProseMirror source deliberately defers iOS Return handling to native
DOM-change interpretation, with an additional delayed keymap fallback. That
leaves the nested contentDOM path dependent on WebKit's DOM split/reconciliation.
The comparison establishes the nesting-dependent failure; the exact mutation or
callback on the physical device still needs a fresh trace. The correction owns
the nested operation at the model/keymap boundary instead of changing the
callout layout, removing isolation, or replacing the previously working fix:

- In the mobile host's existing interaction script, recognize a collapsed
  paragraph caret directly owned by a checklist/bullet/numbered item inside a
  callout inside a Week Strip. Find ancestors relative to the actual selection.
- Require editability, no block-selection mode, no composition/protected
  placeholder, focus in the editor, an available non-inert paragraph, identical
  paragraph text in the DOM/model, and a native caret mapping to the same model
  position. Mismatched pending native input is left to the existing pipeline.
- For an unmodified real Return key, run the same ordered `handleKeyDown`
  keymaps through the public `EditorView.someProp` API. The existing checklist
  command owns the split, attributes, marks, and undo transaction. Other keymaps
  retain their normal opportunity to handle Return; no synthetic DOM key event,
  hand-built list reconstruction, document-wide rewrite, or private engine state
  mutation is used.
- Only after a keymap reports handling that real key, stop propagation to the
  outer ProseMirror keydown listener so it cannot also arm its deferred fallback.
  Do not prevent the keydown's native default, which ProseMirror documents as
  problematic for iOS keyboards. Consume only the following cancellable native
  `insertParagraph`/`insertLineBreak` insertion for that already-handled key.
  This prevents a second native split after the model transaction.
- Clear that one-key ownership on input/key release/pointer/composition changes
  and editor destruction. Shift+Enter, ordinary callout paragraphs, top-level
  lists, other containers, read-only content, and unmatched events keep their
  existing behavior. A keymap declining the event leaves the normal path intact.

The routing is synchronous; there is no added input delay or retry timer.
Software-keyboard streams lacking a usable Return keydown, noncancellable input,
or model/native-caret disagreement fall back rather than risking duplicate edits
or lost input. Those cases are explicitly covered by the expanded diagnostics
instead of being represented as runtime-confirmed successes.

### Diagnostics and Delivery

The existing opt-in Debug `PENNED-LIST` trace now includes checklists and bullets,
schema and native DOM nesting, paragraph inline tails, native input type, Return
correlation/timestamps, bounded transaction-step metadata, and a settled read.
Look for `nested-return.handled` followed by
`nested-return.native-suppressed`. `nested-return.skipped` identifies native-text,
caret, or paragraph safety mismatches; `nested-return.not-handled` and
`nested-return.native-unhandled` distinguish declined keymaps/unusable native
events. No document contents are logged. See
[Numbered List Diagnostics](NumberedListDiagnostics.md#nested-calendarcallout-checklist-follow-up)
for the existing launch argument and capture details.

Changed: maintained `penned-editor/src/tiptap.html`, shipped
`Vellix/VellixEditor.bundle/tiptap.html`,
`Vellix/Editor/MobileEditorInteractions.swift`, this fixes page,
`Docs/NumberedListDiagnostics.md`, and `Docs/NumberedListTrailingBreak.md`.
No editor-bundle JavaScript, shared glass component, list/callout schema, database,
navigation, drag-selection, or trailing-line-fix logic was changed in this
follow-up. The interaction correction is injected by the native mobile host.

Sources: [ProseMirror iOS Return dispatch](https://github.com/ProseMirror/prosemirror-view/blob/master/src/input.ts),
[EditorView.someProp](https://prosemirror.net/docs/ref/#view.EditorView.someProp),
[W3C input intent/cancellation](https://www.w3.org/TR/input-events-2/).
No builds, tests, compilation, linters, app launches, or simulators were run.
The targeted implementation and diagnostics have not been device-verified.

## Calendar Title and Remembered Content Collapse

Replace the generated date-range heading with a directly editable calendar title
(default **Calendar**). Place a glass asset disclosure immediately to the left
of the existing `chevright` button: `chevup` collapses, `chevdown` expands.
The title and date bubbles remain visible when collapsed; the day's content and
the divider beneath those bubbles are hidden together, without retaining their
empty height. The block stores `title` and `collapsed` in its own JSON attributes,
so its state survives normal saving/reopening and uses existing synchronization.
Week navigation preserves the collapsed state and every date's authored content.

Content panels remain mounted, clipped and inert rather than removed/rebuilt.
The title owns its input/keyboard/composition events; body Enter behavior, drag
selection, native navigation, and previews are unchanged. Maintained source and
the shipped editor resources were updated without running a build or tests.
See [Calendar Blocks Implementation](CalendarBlocksImplementation.md#implemented-header-and-collapse-controls--november-21-2026)
for file details, persistence, event handling, sources, and verification limits.

## Optional Scroll to Top, Selection Scrolling, and Retained Previews

Updated November 21, 2026. Source implementation only; no builds, compilation,
tests, simulator sessions, or app launches were performed.

### Optional Sticky Scroll-to-Top Button

**Before:** Documents had no optional pinned control for returning to their top.

**Implementation:** Settings > General Settings > Editor now contains a
**Scroll to Top Button** toggle on iPhone and iPad. It uses the same persistent
`@AppStorage` key as the editor, with a default of `false`, including existing
installs that have no saved preference. It does not change document content or
CloudKit records. The shared settings view also works in the existing desktop
settings route.

When enabled, an `upwavy` asset button stays at the lower right, above the editor
toolbars, and is available only in the document that owns editor presentation.
It uses Penned's existing dark glass chrome. On UIKit it drives the already
located outer `UIScrollView` to `-adjustedContentInset.top`, preserving horizontal
offset. No new per-scroll SwiftUI state publication is added on iPhone/iPad.
The non-UIKit path uses `ScrollPosition.scrollTo(edge: .top)`. Reduce Motion is
respected. The action does not focus the editor, move the caret, clear selection,
reload content, or change navigation.

**Expected:** No new button until the option is enabled. Once enabled, a single
tap scrolls the active document to its actual top, including its native header.

### One-Finger Scrolling From an Unselected Area

**Before and cause:** The outer document `ScrollView` was disabled whenever
selected-block count was nonzero. Injected CSS also set `touch-action: none`
across the entire active selection surface. Additionally, `beginPending` used
the previous selected block as a vertical-drag anchor even when the new touch
started on an unselected block. These independently prevented normal scrolling
while selecting.

**Implementation:** Remove the blanket native scroll disable. Restrict
`touch-action: none` to selected block surfaces and their descendants. Seed a
vertical selection-resume anchor only when the gesture starts on a selected
block. An unselected-origin vertical gesture now follows the existing pending
gesture's cancellation path without preventing its native scroll.

CSS alone is insufficient protection for the outer native scroll view:
WebKit's own touch-action handling governs its scroll views, not arbitrary
ancestor UIKit scroll views. `MobileBlockSelectionScrollGate` therefore provides
a failure dependency for the outer scroll pan only while an active editor has
selected blocks. It performs one read-only DOM hit test per contact to identify
a selected origin. Selected-origin contacts reserve the pan for the existing
editor selection handlers. For unselected origins, the gate follows the
existing JS pending direction thresholds: vertical movement releases native
scrolling; horizontal movement reserves the contact for swipe selection.
It does not cancel editor touch delivery or prevent other recognizers, and
multitouch releases the gate. A failed/unanswered hit test releases the native
pan, bounded by a 200 ms fail-open deadline if the web process is unresponsive;
this is not a document-opening timeout or readiness condition.

The JS drag thresholds, range construction, finger tracking, direction changes,
selection painting, zero-selection dismissal, and
`MobileBlockSelectionScrollDriver` are unchanged. In particular, the existing
upward/downward range extension and native edge-autoscroll driver were not
rewritten. The gate uses weak editor/WebView references and rejects inactive
editors; off-mode contacts do not perform a DOM query.

**Expected:** Swipe vertically from an unselected block or unselected space to
scroll without losing the existing selection. Start on a selected block to
extend the selection up/down as before. Horizontal swipe selection remains
available. Physical-device gesture arbitration, especially in an attached
debugger, still requires user verification; it has not been runtime-confirmed.

### Keep the Last PNG Until Its Replacement Is Ready

**Before and cause:** Record-driven cards rejected their retained bitmap whenever
the revision key or library presentation epoch changed, recreated the image view
with `.id(presentationKey)`, and could assign a failed/nil result over a good
image. Summary-driven cards rejected differently keyed persisted PNGs entirely
and cleared their snapshot when switching to full-record regeneration. This
allowed a gray card surface or live fallback to replace the prior PNG while the
new snapshot was still being generated.

**Implementation:**

- Introduce `retainedPresentationImage(documentID:spaceID:)` as a display-only
  last-known-good PNG lookup. It reuses the existing primed directory/image
  lookup, validates the Space scope, and does not insert an old bitmap under a
  new content key. Existing exact-key APIs remain the freshness authority.
- Summary cards still synchronously resolve current persisted/primed images for
  their first visible frame. On an exact-key miss, they can immediately paint
  the prior PNG while continuing the existing body-load/regeneration flow.
  A stale display image cannot suppress regeneration.
- Retain a same-document snapshot across revision/epoch changes and pass it into
  the record-backed view during regeneration. Do not replace a valid snapshot
  with nil or force image-view identity changes for each content revision.
- Track document ID, Space ID, color scheme, and cache instance for view-held
  images and full records. Ignore cancelled/superseded async results. The
  persisted display fallback can show the last rendered theme until the current
  scheme's image is ready; it is never considered a current-scheme cache hit.
- Keep the existing separate preview renderer, content verification, blank-image
  rejection, serialized capture queue, descriptor keys, PNG format/directory, and
  atomic write implementation. PNG encoding/writing now runs at utility
  priority off the main actor. Recheck generation and content key after the
  write, before publishing the replacement.
- Publish the bitmap only after successful persistence. Keep old files until the
  replacement is safely written; retain the filename-based pruning comparison
  that protects the newly written PNG from `/private` URL aliasing. Clear the
  fallback lookup after replacement/pruning and explicit document removal, then
  publish `contentRevision` so visible cards resolve the new PNG.

**Expected:** Revisiting Home or regenerating an edited document's card keeps its
previous PNG visible until the new valid image is available. Failed, cancelled,
or obsolete generation does not clear a good displayed snapshot. Cold-launch
first-frame cache priming and body-free exact-cache hits remain connected. A
document that has never had a valid PNG, or whose cache was removed by the OS,
still needs its existing initial-generation/live-fallback path; there is no old
image to retain in that case. No caches or user data were deleted for this work.

### Files Changed

- `Vellix/Spaces/PennedEditorSettingsView.swift`: shared preference and settings toggle.
- `Vellix/Spaces/PennedSettingsView.swift`: Editor settings route.
- `Vellix/App/PadSettingsView.swift`: the same Editor settings route on iPad.
- `Vellix/Editor/DocumentEditorView.swift`: pinned button, native scroll-gate attachment,
  and removal of the selection-wide scroll lock.
- `Vellix/Editor/MobileBlockSelection.swift`: selected-origin gesture ownership and CSS.
- `Vellix/Editor/MobileBlockSelectionScrollGate.swift`: outer-native-pan arbitration;
  selection behavior remains owned by the existing JS implementation.
- `Vellix/Documents/LibraryDocumentPreview.swift`: retained-image presentation and
  stale-result/identity protection in both card paths.
- `Vellix/Documents/DocumentPreviewCache.swift`: display fallback, background PNG
  writing, and publish-after-persist sequencing.
- `Docs/EditorInteractionFixes.md`: this behavior/cause/implementation reference.

Editor mounting/readiness, parent-return rendering fixes, document loading,
navigation, undo, autosaving, database synchronization, preview cache keys, and
the generated editor bundle are intentionally unchanged. Selection JS is
injected natively, so this work requires no editor-bundle generation step.

### References and Verification Limits

- [W3C Pointer Events: touch-action and supported direct manipulation](https://www.w3.org/TR/pointerevents/latest/#determining-supported-direct-manipulation-behavior):
  gesture-start origin/ancestor policies matter; changing them mid-contact is
  not a reliable way to take over a scrolling gesture.
- [Apple: UIScrollView touch cancellation](https://developer.apple.com/documentation/uikit/uiscrollview/cancancelcontenttouches):
  a native scroll view can cancel content tracking and start its own pan.
- [WebKit: native ancestor gestures and touch-event deferral](https://bugs.webkit.org/show_bug.cgi?id=227311)
  and [WebKit: touch-action pan restrictions](https://bugs.webkit.org/show_bug.cgi?id=199618):
  the native ancestor boundary needs explicit handling rather than relying on
  page CSS alone.
- [Apple: gesture failure dependencies](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:))
  and [Apple: recognizer prevention rules](https://developer.apple.com/documentation/uikit/uigesturerecognizer/canprevent(_:)):
  reserve the enclosing pan without replacing its delegate or consuming editor
  input.
- [Apple: scrolling to an edge](https://developer.apple.com/documentation/swiftui/scrollposition/scrollto(edge:)):
  the non-UIKit scroll-to-top action uses the existing platform scrolling API.

Only source/diff inspection and whitespace checks were performed. Actual gesture
feel, toolbar clearance with different keyboards, first-frame card appearance,
and generation timing remain unverified on a physical device. No claim of
measured performance or completed device validation is made.

## Selection Copy Confirmation

The selection toolbar and its Actions sheet share the same Copy handler.
`TipTapEditorSession.copySelectedBlocks` waits for the existing JavaScript/native
clipboard success result. `DocumentEditorView` increments a copy-specific trigger
on the active editor's `.sensoryFeedback(.impact(weight: .heavy, intensity: 1),
trigger:)` modifier and shows the existing three-second, accessible status banner:
**Selected blocks were copied**. Failed copies, empty selections, and callbacks
from a different load or inactive editor do not announce success. Copy contents,
selection, Cut, and other clipboard behavior remain unchanged. No builds/tests.

### Haptic Research Follow-Up

The old helper created an unattached, short-lived `UIImpactFeedbackGenerator`
with `init(style:)`. Its presence in source did not prove feedback was felt on
the user's device; the precise reason for absent feedback was not observed.
Copy now bypasses that helper and uses Apple's documented view-associated
SwiftUI feedback API. The copy-specific revision changes on every successful
copy, even if the banner text is unchanged; no second UIKit haptic is sent.
The general bridge helper for unrelated events is intentionally unchanged.

Apple documents that feedback requests are system-controlled, require supported
hardware, foreground operation, and enabled system haptics. iPads do not provide
the iPhone-style device haptics; Apple Pencil Pro feedback is a different device
capability. The banner remains available regardless of haptic capability.
No app can guarantee physical feedback when the system suppresses it. No builds,
tests, app launches, or physical-device haptic confirmation were performed.

Sources: [Playing haptic feedback](https://developer.apple.com/documentation/applepencil/playing-haptic-feedback-in-your-app),
[SwiftUI impact weight/intensity](https://developer.apple.com/documentation/swiftui/sensoryfeedback/impact(weight:intensity:)),
[deprecated unattached UIKit initializer](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:)),
[hardware support](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics).

## Dotted Divider Visibility

Increase only the repeating dotted divider from a 1 px diameter to 2 px in
maintained/bundled editor CSS and its native fallback preview. Match thumbnail
dots at 2 points instead of 1.5. Keep the existing 5-unit repeat spacing, colors,
opacity, divider layout, nesting, and selection behavior. Four Circles, line
dividers, and Washi Tape are unchanged. No preview caches or persisted document
attributes are changed. No builds or tests were run.

## Complete Conversion Menu

The separate Conversion Menu now mirrors all Add Block categories and options,
including Nested Content Page/Card and the missing List Grids, Fields, and Tabs.
All options have conversion handlers rather than falling back to Paragraph or
being disabled by the previous text-only allowlist. Existing nested pages switch
between Page and Card presentation without replacing their document or contents.
Rich container content is retained; leaf targets keep content adjacent where it
cannot fit inside the target. Link/File flows use their existing native UI and
do not remove sources on cancel. The underlying schema and stale-request checks
remain enforced. See [Editor Add Menu](EditorAddMenu.md#separate-conversion-menu-parity)
for behavior, implementation files, and source-only verification limits.

## Trace-Confirmed Editor Lifetime Correction

The supplied `[Penned Render]` capture shows the returning parent's new native
host claiming the existing WebView, followed by an old host release with
`ownsHost=false`. Rendering observation activates at `1794977085948`, is canceled
by `editor-view-disappeared` at `1794977085964`, and the replacement reaches the
window at `1794977085974`. No block probes or viewport pulse execute in that
capture. The document remains loaded/ready; the trace does not establish the
cause of every missing text layer.

- `DocumentEditorView.swift`: Replace the navigation-bar helper's conditional
  whole-editor branches with one modifier whose visibility value changes. The
  cached editor's structural identity stays stable. Ignore shared disappearance
  cleanup while the document still owns presentation, including cancellation of
  the opening-surface trace; retain local drag-driver teardown and ordinary cleanup
  when selection, Space, or settings ownership actually changes.
- `AppEnvironment.swift`: Seed render diagnostics at the existing selected-ID
  transition, before SwiftUI updates. Preserve the previous document and parent
  IDs instead of depending on a replacement view's `onAppear(from: nil)`.
  Navigation, loading, request cancellation, and readiness behavior are unchanged.
- `TipTapWebView.swift`: Pass container identity and actual store ownership to
  diagnostic layout callbacks. An outgoing host cannot drive the active host's
  layout observation.
- `TipTapRenderRecovery.swift`: Remove the unsuccessful programmatic scroll pulse.
  The monitor is now read-only and Debug-only. Actual host claims/layout attach
  its enclosing scroll observer and arm bounded visible-layout/block probes;
  stale outer-scroll references are ignored. Retained status belongs to the cached
  session monitor, and explicit route fields are no longer overwritten by absent
  activation metadata.

Expected: parent/child navigation reuses the same editor subtree and WebView,
without old-view cleanup shutting down its replacement. `[Penned Render]` should
now include `visible-layout-settled`, `dom-probe-result`, and `block-render` events.
`editor-disappearance-ignored` identifies an outgoing callback while the document
still owns presentation. No scroll/redraw workaround remains. Physical-device
resolution of the partial-text symptom is not yet confirmed.

See [Parent Return Rendering](ParentReturnRendering.md) for evidence, primary
sources, and the updated capture instructions. No builds, tests, compilation,
app launches, or editor-bundle rebuilds were run; this correction is native-only.

## Rendering Diagnostics API Compatibility (2026-11-17)

- `TipTapRenderRecovery.swift`: Both completion-handler JavaScript probes now use
  `callAsyncJavaScript(_:arguments:in:in:completionHandler:)`, matching the
  existing editor bridge. The `contentWorld:` label belongs to the async/await
  overload; combining it with a trailing completion closure caused the reported
  extra-closure and result-type-inference errors.
- Diagnostic inset formatting uses `NSCoder.string(for:)` in place of the renamed
  `NSStringFromUIEdgeInsets` function. Probe scripts, callbacks, readiness checks,
  navigation, and viewport recovery behavior are unchanged.
- Source review and whitespace checks only; no builds, tests, or app launches.

## InfoCard Visibility and Partial Block Rendering Follow-Up

- InfoCard Settings adds independent **Hide Title**, **Hide Description**, and
  **Hide Divider** toggles. All default off; title/description text remains
  stored. The divider option removes its real border. The schema, serialization,
  node view, Swift settings payload/sheet, and native fallback previews agree.
  See [InfoCards](InfoCards.md) for bundle synchronization and behavior details.
- Rendering diagnostics now inspect block and text surfaces separately, including
  the heading-label tile and editable text span visible in the supplied screenshot.
  New **`block-render`** events compare model text counts, DOM text counts, sampled
  text rectangles, computed text/fill/font styles, clipping, and intentional hide
  flags. Native clipped viewport sampling replaces the old first-six-only view.
  See [Parent Return Rendering](ParentReturnRendering.md) for limits and analysis.
- Files: `penned-editor/src/information-card.js` and `src/tiptap.html` implement
  persisted visibility; `TipTapBridgeTypes.swift` and `DocumentEditorView.swift`
  wire the controls; `ImmediateDocumentPreview.swift` and
  `GalleryDocumentPreview.swift` respect hidden headers;
  `TipTapBlockRenderDiagnostics.swift` and `TipTapRenderRecovery.swift` implement
  the expanded read-only probe and per-block logs. These three docs are updated.
- No builds, tests, compilation, or device runs. The InfoCard web feature requires
  an editor bundle rebuild/sync, not performed under the no-build instruction.
  The additional native-injected diagnostics do not require that web bundle step.

## Parent Body Blank After Returning From a Child (2026-11-17)

**New evidence:** The previous native-container remount did not solve the issue.
The user observed a blank parent for about 25 seconds; a small scroll then made
the content appear immediately. Scrolling immediately on return also revealed
it immediately. Grandchild -> Child was already fast.

**Earlier attempt, now superseded by the trace-confirmed correction above:** Remove the unsuccessful host-identity change. Keep the
same WebView and container, and trigger the actual enclosing-scroll viewport
update path after a retained editor becomes visible and its layout settles.
Move its outer scroll offset by at most one physical pixel, then restore the
original offset on a following display frame. Do not touch offsets during a
gesture, active editing, or block selection. Skip restoration if ownership,
offset, scroll range, or interaction changed. No reload, JSON injection, undo
reset, new readiness requirement, or navigation timeout is introduced.

**Diagnostics:** `[Penned Render]` is enabled automatically in Debug on both
iPhone and iPad. Each activation has a render UUID and correlates with the
existing opening request. It records back-navigation targets, native attachment,
visibility/clipping, layout, readiness, DOM metrics, JavaScript frame callbacks,
the programmatic refresh, and the first real user scroll. Scroll observation is
bounded to 60 seconds, including the reported 25-second failure window.

The source and WebKit research support a stale exposed-rectangle/rendering
hypothesis, not a confirmed diagnosis of the device's internal compositor.
The new correction has not been run on a device. Full findings, primary sources,
event names, safeguards, and log interpretation are in
[Parent Return Rendering](ParentReturnRendering.md).

## Library Page Layout Follow-Up (2026-11-17)

These changes are native page-layout corrections, not document-opening or
editor changes. Daily Notes' normal 12-point content inset is the reference.

| Behavior before | Cause in source | Fix and expected behavior |
| --- | --- | --- |
| Home search overlapped the Space/settings button and options button. | `HomeView.body` pulled the scroll content upward with a `-48` top padding. The compact shell also requested large-title navigation even though Home has no title. | Use 12-point top padding and inline navigation on Home. Search starts below the buttons without reserving a blank large-title row. |
| All Docs search overlapped Back, Select, and options, with an unwanted title. | `DocumentBrowserView.body` applied the same negative offset only to `.all`, while the shell requested a large title. | Use the same 12-point top inset as Daily Notes, leave the ordinary All Docs navigation title empty, and use inline navigation. Explicitly named galleries retain their names; Daily Notes and other browser content are unchanged. |
| Home linked to a duplicate Spaces page. | `libraryLinks` included another `.spaces` route alongside the existing settings and Space picker routes. | Remove only Home's Spaces row. Space switching, creation, management, and existing documents remain available and unchanged. |
| Templates had a gray body behind its rows. | The iPhone branch in `TemplatesView` used `PadWorkspaceBlurSurface` instead of the solid page background used by the other library pages. | Reuse `PadWorkspacePageBackground`, which is black in the phone and iPad workspaces. Template rows, actions, preview images, and desktop fallback are preserved. |
| All Tags had a large heading below Back, pushing search and results down. | `TagBrowserView` placed a large-title `Text` inside the scrolling content and left the navigation title blank. | Move the compact title to the top-right toolbar without a glass capsule. Search is now the first scrolling row, at the normal 12-point inset. Selected-tag titles still update; the iPad workspace, which hides the native navigation bar, retains a compact right-aligned content heading. |
| Settings subpages showed doubled back-button chrome. | The common settings destination toolbar wraps `SettingsBackButton` in automatic system glass even though the custom button already draws its own circular surface and border. The system navigation back button was already explicitly hidden. | Hide only the shared toolbar background on the custom back item. Keep the custom asset, its own chrome, dismiss action, hidden system back button, destination titles, and other toolbar actions such as Space management's Edit button. Account Settings keeps its existing standalone header. |

### Files Changed

- `Vellix/Documents/HomeView.swift`: normal search inset and removal of the
  duplicate Spaces link.
- `Vellix/Documents/DocumentBrowserView.swift`: normal browser inset and no
  title for the ordinary All Docs page.
- `Vellix/App/VellixShellView.swift`: inline Home/All Docs navigation and the
  shared Templates page background; remove the now-unused Templates blur flags.
- `Vellix/Tags/TagBrowserView.swift`: compact top-right title, without the
  redundant large scrolling heading on the phone.
- `Vellix/Spaces/PennedSettingsView.swift`: suppress the extra system glass
  behind the settings destination's custom back button.
- `Docs/EditorInteractionFixes.md`: this explanation and verification limits.

No preview decoding, PNG generation/persistence, cache keys, cache pruning,
library pagination, document loading, editor readiness, selection, gestures,
autosaving, database, or CloudKit code changed. No new async work, timers, or
services were introduced. No builds, tests, or device runs were performed;
layout on a physical device remains unverified.

### Launch Freeze: Discussion Only

No launch, debugger, entitlement, or sandbox settings were changed. The project
currently disables `ENABLE_USER_SCRIPT_SANDBOXING` for the Vellix target's Debug
and Release configurations. That is build-script sandboxing, not the running
app's sandbox. The uncommitted project changes also add a Generate Icon Library
build phase with `alwaysOutOfDate = 1`, no declared outputs, and a call to
`Scripts/generate_icon_library.sh`; it is eligible to run on every build. This
does not establish a cause for a freeze after the app appears.

The shared Run scheme uses Debug with LLDB. Its keyboard trace argument is
disabled; there are no explicit enabled Address/Thread Sanitizer settings in
that shared scheme. User-local Xcode settings and other apps were not audited.
Before proposing configuration changes, establish whether the delay is in
Xcode's build/attach stage or inside the running app after its loading screen
appears. No startup performance target is claimed.

References: [Apple's toolbar shared-background API](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))
and [User Script Sandboxing in Apple's build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference).

## Document Opening, Selection, and Focus Follow-Up

The iPhone screenshots showed a selection rectangle over the divider, stray
native selection handles after selection, a caret beside the callout rather
than in an editable line, and the exact Paste alert text. The earlier opening
trace confirmed a separate, zero-bounds mount failure; the
[compact shell cache observation](iPhoneEditorCacheObservation.md) and
[`[Penned Document Open]` tracing](DocumentOpeningDiagnostics.md) remain in place.

| Behavior before | Cause or failure path in source | Fix and expected behavior |
| --- | --- | --- |
| Some documents could fail to open after web content was already ready. | A nil WebKit snapshot cleared the frame owner and set a bridge error before the existing 750 ms fallback could run. A returned error could also remain on an already-loaded cached session. The JS layout step could wait for media that had not downloaded. | A missing snapshot leaves the existing fallback armed for the same generation, after valid web layout, input revision and nonzero bounds. Reopening an already-loaded session can clear an old error and retry presentation without reloading the document or replacing live content. Only visible, available images participate in the initial decode wait; other images continue loading normally. No changes to request timeouts, database loading, or cache ownership. |
| A collapsed toggle could leave a callout visible. | The generic indent could leave callouts as visually indented siblings rather than toggle children. The previous fallback only covered the first sibling. | True children hide with the toggle. A view-only decoration also aligns and hides a contiguous run of older indented siblings, including callout rows, without migrating or deleting saved content. |
| Divider selection looked like another line or a box and could leave native handles visible. | The iOS selection decoration painted the full touch target and WebKit could also select the atom. The selected row and the divider's saved color are separate. | Draw selection feedback on the actual line, dots, circles, or tape; keep the saved color and shape intact. Prevent native click-to-select on dividers and clear native ranges when leaving block selection. The larger touch target and the existing tap-below-divider action remain. Page-break selection is a narrow marker rather than a large rectangle. |
| Outdenting a divider could remove it instead of moving it. | The move deleted first, then used a generic insert that could produce no step at a schema boundary. The fallback could target a different text/list selection. | Preflight exact ProseMirror removal and reinsertion before applying either to the outgoing transaction. An illegal destination leaves the divider untouched. Successful moves retain its ID, color, style and tape image. |
| Tapping between a plain callout and page break could set a gap cursor or jump to another block. | The generic DOM coordinate lookup could resolve near the atomic page boundary instead of the visible gap. | Map stationary taps in that seam directly to the page-break node boundary. Reuse the existing real-paragraph caret slot; a moving touch remains a scroll. No changes to how Enter works inside callouts. |
| Returning from another app could reopen the keyboard or editing UI. | The active editor's UIKit/WebKit responder and pending caret work were not cleared on resign-active. | Resign only the selected editor's web responder and title focus and clear pending caret/paste work as the app leaves the foreground. Returning requires a fresh edit action. The document remains open. |
| Blockquote settings could appear on Home or when entering a document. | A published sheet request was left stored, and an inactive cached view could act on it. The web color control handled any touch end as an activation. | Match a stationary press, consume the request once, require the selected and ready document, and dismiss/clear on leaving the editor. Explicit blockquote settings still open normally. |
| Tab taps could fail or a temporary panel could look like the saved default. | Tab buttons had competing touch-release and synthesized-click paths, the pressed button was rebuilt on every active tab change, and transient view disappearance reset navigation. | A short press released on the same tab switches only that panel. A stationary 550 ms hold opens settings once; releasing it or receiving a follow-up pointer click does not switch tabs. Moving away or canceling the pointer cancels the gesture. The buttons stay mounted during panel switches. The node view still resets to the saved default on document close or reload. Explicit default changes remain saved. |
| The Paste alert could appear after Undo. | The alert treated a missing or stale paste responder as an opening/bridge failure. The code allowed an earlier asynchronous paste attempt to finish after history or lifecycle changes. The screenshot alone does not show what initiated Paste. | Validate the pasteboard and foreground responder, prefer a responder already active, and invalidate pending paste on Undo, Redo, deactivation, or backgrounding. An unavailable clipboard/responder no longer raises the global editor alert. Actual Paste still uses UIKit and keeps rich content support. |
| Text selection in callouts was hard to see. | Selectors could miss direct text or the selected-inline decoration. | Apply a high-contrast callout text highlight both to native selection of direct text and descendants and to the ProseMirror text-range decoration. Block-selection paint is separate. |
| Empty selection could leave UI or gesture state behind; dragging was treated as scrolling. | The native scroll view and browser pan could own the same touch stream; remaining selection formatting or a native range could persist after the selection cleared. | With blocks selected, reserve the native/WebKit pan for selection and keep the existing edge auto-scroll driver. Use the actual vertical travel direction, up or down. Clearing the final selection clears its formatting target, stops edge tracking, exits selection mode, and removes any native selection left behind. Ordinary browsing still scrolls when selection is off. |

Technical references: [ProseMirror selection and exact replacement APIs](https://prosemirror.net/docs/ref/),
[WKWebView snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)),
[HTML image decoding](https://html.spec.whatwg.org/multipage/embedded-content.html#dom-img-decode-dev),
[Pointer Events gesture ownership](https://www.w3.org/TR/pointerevents/latest/),
[SwiftUI scroll controls](https://developer.apple.com/documentation/swiftui/view/scrolldisabled(_:)),
[CSS selection painting](https://www.w3.org/TR/css-pseudo/#selectordef-selection),
[SVG fill and stroke geometry](https://www.w3.org/TR/SVG2/painting.html),
and [UIKit pasteboard and responder actions](https://developer.apple.com/documentation/uikit/uipasteboard).

Device verification is still required. Check the formerly failing documents,
then confirm that choosing a divider color preserves each shape before, during,
and after selection. Check outdent and Undo on nested dividers, drag both ways
with an active selection, select actual callout text, and type into the gap above
a page break. Check tab browsing and long press, then reopen against the saved
default. Check app switching, return to Home, and intentional Paste after Undo.
The maintained editor sources need to be synchronized into the app's bundle
before web changes can be evaluated on device.

## Active Editor Ownership and Selection Follow-Up

| Behavior before | Cause or failure path in source | Expected behavior after the change |
| --- | --- | --- |
| An inline property sheet could appear after going Home. | The editor deck keeps cached editor views mounted. Opacity and hit testing do not control SwiftUI sheet presenters. Inline property requests were stored in a replaying model publisher, and its subscriber did not require the active editor. | Only the selected document owns editor sheets, dialogs, and file import. The bridge rejects UI requests from cached, loading, or departing documents; presentation bindings also check ownership. Losing the selected document clears transient requests. Inline property requests are delivered once without replay, and their dismiss callback cannot focus a hidden editor. |
| Returning Child → Parent → Home, then tapping Parent could take you back to Child. | The parent could replay `nestedPageToOpen` when its subscriber attached again, including after a current-value publication that its receiver tried to clear synchronously. This was a source-level redirect path, not confirmation of which event fired on the phone. | A nested link is a one-shot callback to the workspace, not cached model state. Only the current parent can open its direct child, with no other opening pending. Back navigation blocks new editor requests while saving and verifies the same document still owns navigation before returning. Library taps, readiness, timeouts, and prepared WebViews are unchanged. |
| Divider selection was barely visible, and the inline property highlight extended into empty space. | The divider used a shadow on subpixel marks. Properties used the generic block outline, including their tap padding and page-edge spacing. | A contrasting outline follows the width of the actual divider motif, without drawing a line over it or changing its color. Washi tape is marked inside its clipped edges. A property uses tighter insets and excludes page-edge padding without shrinking its touch target. |
| Indented callout text clipped on the right. | The generic block rule set each identified paragraph to 100% width before adding its margin. | Indented text wraps at the remaining width inside the card. The callout's own width, paragraph formatting, and resize controls are preserved. |
| Tapping below a callout at the page edge could produce a noneditable caret or jump. | The old gap lookup could miss a tap arriving on a descendant of the block next to the break. Generic hit-testing could then send it to a different ProseMirror position. Web and native scroll could also both attempt a caret reveal. | For either half of the real page-break band, the editor checks the break's actual DOM and model position before generic gap lookup. It places the caret in a real paragraph on the tapped side. On iOS only the native scroll view reveals that caret. Unused tap-created paragraphs still do not persist; Enter handlers are unchanged. |
| Callout selection could target only the text and be hard to see. | The mobile block index exposed its text paragraphs as separate targets, and native selection painted only the text range. | Plain and Icon Callouts are each one selectable block. A native range inside one callout selects the whole callout on iPhone/iPad, with an adaptive fill, contrasting text, and a visible edge. A caret tap still lets you type. Saved colors and the regular icon pipeline are unchanged. |
| Selection mode could remain visible with zero blocks. | The selected count and mode arrived separately, and a selection presentation could outlive a selection. | One mobile event carries both values. Zero forces mode off, clears an old text range on exit, and dismisses the toolbar, Style, Actions, and link-layout controls. A tap on empty editor space also clears the selection. Drag thresholds, direction tracking, and auto-scroll are unchanged. |

Implementation references: [SwiftUI sheet item bindings](https://developer.apple.com/documentation/swiftui/view/sheet%28item%3Aondismiss%3Acontent%3A%29),
[Apple's explicit navigation state guidance](https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack),
[ProseMirror text selection and DOM positions](https://prosemirror.net/docs/ref/),
[WebKit Custom Highlights](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/), and
[CSS flex sizing](https://www.w3.org/TR/css-flexbox/#min-size-auto).

No builds or tests were run. On device, verify the child/parent/home reopen sequence,
Home after a property sheet, text wrapping and selection inside nested callouts,
typing on both sides of a page break, and deselecting the last block. The web changes
require synchronizing the editor bundle before device verification.

## Adaptive Selection Color

- **Before:** A single purple tint and outline were used for blocks regardless
  of their fill; callouts always switched to dark purple and white.
- **Cause:** The selection CSS did not have the block's rendered background or
  the paper behind transparent blocks. The old fill could blend into the block
  or alter a custom text color unnecessarily.
- **Fix:** On iPhone and iPad, the editor resolves the selected block's color
  and composites translucent surfaces over their backdrop. The callout fill
  is a tint or shade of its own color. The outline is chosen against the
  selected surface and its surroundings. The algorithm targets at least 3:1
  for solid-surface outlines and 4.5:1 for callout text, keeping configured
  callout ink when it still meets that target. Mixed surfaces such as photos,
  gradients, and native collection boards use a two-tone edge, with no veil
  over the artwork. Only the selected DOM gets temporary paint styles, and
  colors are batched and cached while selection is active. Nothing is saved.
- **Expected:** Selecting adjacent blocks with different fills can produce
  different highlights. Deselection restores each block's original appearance.
  The selection targets, toolbar behavior, drag tracking, and auto-scroll are
  unchanged. Mixed artwork is not sampled pixel by pixel.

Reference: [W3C contrast requirements for selection indicators](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)
and [WCAG relative luminance and contrast](https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio).

## Plain Callout, Divider Alignment, And Selection Toolbar

- **Plain Callout:** Replaced the separate color-only sheet, inline resize
  handle, and hard-break Enter behavior with the Icon Callout surface,
  settings flow, and paragraph splitting. Plain has no icon or icon gutter.
  Place the caret in its text, then tap Settings to the left of Bold in the
  formatting bar. Tapping the padding does not open settings. The contextual
  selection-bar Settings shortcut remains available. On insertion, the settings
  sheet opens just as for Icon Callout, with the same keyboard and color controls,
  plus Grid Card's preview handles and Half Width / Full Width choices.
  Height is a minimum, so text can still grow. Existing width percentages,
  rich content, web clip sources, and legacy rows are not rewritten.
  Native previews and the publishing projection also read the new settings.
- **Toggle nesting:** A full-width Plain Callout uses the same available body
  width as Icon Callout and does not add a second basic indent for an older
  stored offset. Older sibling callouts share the toggle's inset and collapse
  state until the first unrelated block. Explicit half/custom widths are
  preserved. The editor maps these display flags across ordinary typing and
  recalculates them on structural edits and toggle state changes.
- **Dividers:** Actual toggle children use the toggle body's text column, not
  a second basic inset. A legacy indented divider immediately after a toggle
  uses the same column and follows the toggle's open state. Higher indents
  remain relative to that column. Divider color and shape are untouched.
- **Selection:** A zero count closes the selection toolbar, Style overlay,
  Actions sheet, and pending link-layout controls, then resets the native
  selection mode. The bridge only clears the web mode if it is still empty,
  so a new selection is not canceled by an older message. No drag gesture
  or auto-scroll tracking code changed.

## Sticky Typing

**Before:** Typing could pause even when the edit only changed one character.

**Cause in source:** The task plugin updated its document-wide item index,
checked for duplicates, and compared all tracked task metadata for ordinary
text edits. Typing inside a task rebuilt its controls. Tabs, Fields, and
InfoCards also repeated appearance work when only their child text changed.
These were identifiable sources of work on the input path, not device timing
measurements.

**Fix:** The task plugin uses the existing closed inline-edit classifier:
plain text changes skip indexing, ID reconciliation, and task snapshot
comparison. The index is refreshed from the actual document before the next
structural operation. Task controls update when their markup changes; active
task state is compared before sending it to Swift. Tabs, Fields, and InfoCards
skip unchanged chrome updates. The existing text checkpoint times, autosave,
task metadata handling, and structural validation are unchanged.

**Expected:** Typing no longer performs that work for each character. Actual
task, tab, and card changes still render and save normally.

## Reminder Scheduling

**Before:** Tapping a task's schedule could enter editing and put the caret
in that task, even if the document was not being edited.

**Cause:** The schedule control explicitly set a text selection before opening
its sheet. On touch devices, suppressing mouse focus alone did not reliably
prevent WebKit from focusing the editor.

**Fix:** The control uses the tapped task's ID and data directly, without moving
the selection. A non-editing tap handler blocks native touch/mouse focus,
recognizes a stationary touch, and preserves click and keyboard activation.
On iPhone/iPad, the native sheet takes over from the WebView responder once;
its keyboard does not trigger the document caret-reveal logic.

**Expected:** Opening, configuring, or dismissing a reminder does not start
document editing or move the caret to the task.

## Tabs Default and Reopening

**Before:** Viewing another tab or adding a tab could change which tab opened
after closing the document.

**Cause:** The visible panel and saved default shared the `activeTab`
attribute. Panel navigation wrote that attribute and sent a document snapshot.
A cached WebView can also outlive its document screen.

**Fix:** `activeTab` is the saved default; ordinary tab taps switch only
the node view's temporary panel. They refresh visible layout, including native
overlays, without a document transaction. Adding a tab leaves the default
alone. Only the default control, or deleting/repairing an invalid default,
changes it. The temporary panel is cleared on document close, deactivation,
or content load. The panel is also applied after its DOM mounts, so a saved
default other than the first tab is shown on initial load.

**Expected:** Browse tabs while a document is open. Reopening starts on the
saved default, even from the WebView cache. Earlier versions overwrote the
stored default; this change cannot infer a previously lost choice.

**Tap versus hold:** The tab bar owns a single pointer sequence per press.
Switching occurs on release, after checking the original button and movement
tolerance. A 550 ms hold opens settings and consumes the release and follow-up
click; keyboard button activation does not use the hold timer. Moving beyond
the press tolerance, pointer cancellation, rebuilding the tab list, and closing
the document clear the timer.
The explicit border and formatting-bar settings actions are unchanged.
Try fast taps between tabs, holding an inactive tab and lifting after the sheet
opens, and scrolling from a tab without triggering either action. The
[Pointer Events specification](https://www.w3.org/TR/pointerevents/#event-click)
explains why canceling pointer-down alone does not block a follow-up click.

## Divider Selection and Indentation

**Before:** Formatting indentation treated the selected divider as an
attribute-only block; it could not follow page references into a toggle, and
the divider's full-width CSS masked its indentation.

**Cause:** The structural indent/outdent command only handled page
references, and divider margins reset the generic indentation.

**Fix:** Selected dividers use the existing structural move rules. Indent
moves a divider immediately after a toggle into that toggle's body (all toggle
styles share the same node). Outdent moves a directly nested divider after
its parent toggle. Otherwise the command adjusts its existing indent
attribute. The editor now offsets and narrows the divider by that amount.
The node ID, style, and tape image are kept throughout the move.

**Expected:** Swipe to select a divider and use the style panel's Indent or
Outdent action. A nested divider follows its toggle's disclosure state.

## Settings and Dismiss Keyboard

**Before:** Settings relied on holding labels, Fields, InfoCards, or tabs,
or tapping the invisible color surface on a plain callout. These controls
could compete with text and block selection.

**Cause:** Blocks ran their own pointer/touch recognizers or layered a
click target over the editor. Settings availability was not shared by the
formatting bar.

**Fix:** The existing formatting bridge now reports the nearest supported
block containing the caret or text selection. On iPhone/iPad, the same pinned
`settingswavy` control left of **Bold** opens settings for Labels, Fields,
InfoCards, Plain Callouts, Tabs, and List Grids. Nested controls target the
innermost supported block. Tabs retain their border shortcut; their hold
timer, the label/Fields/InfoCard settings holds, and the old plain callout
overlay are removed. On Mac, Labels and Plain Callouts use the Format
inspector; iOS-only sheets were not added to Mac.

The iOS sheets use the shared **Dismiss Keyboard** button in the header's
right-side actions. Labels, Tabs, List Grid, and Icon Callout retain it.
Fields, InfoCards, Plain Callout, Grid Card, Washi Tape, its Unsplash
search, and task scheduling now have it. Text fields with explicit SwiftUI
focus clear that focus before resigning the active responder. The button
does not dismiss the sheet or submit its data.

**Expected:** Tap editable text, then tap the settings icon. There is no hold
to time, and dismissing the keyboard leaves the sheet open.

## Settings From the Selection Bar

**Before:** The formatting bar could open settings under the caret, but the
iPhone/iPad block-selection bar offered no contextual settings action.

**Cause:** Its formatting payload described block styles and selected links,
not which selected block owned a settings sheet.

**Fix:** The same `settingswavy` icon appears immediately to the right of
**Style** when a whole block, or a block selected inside a container, resolves
to one existing settings sheet. Mixed block types always hide the icon.
Selecting two separate settings owners also hides it, even when the blocks
have the same type. Selecting same-type child blocks inside one settings
owner is supported. The editor checks the target block and selection token
again when the button is tapped.

The selection shortcut uses the existing sheets for Labels, Fields, InfoCards,
Tabs, List Grids, both kinds of Callout, Grid Cards, blockquotes, Washi Tape,
code blocks, tables, tasks, file attachments, inline properties, links,
collections, nested page cards, and template components in template-editing
mode. Blocks without a sheet do not get the button. Tables use the existing
cell context or the first cell if none is active. For sheets that save outside
block-selection mode, tapping Settings exits that mode automatically without
focusing the text editor. Link settings retain the selection because the link
editor validates it when saving; rich-link **Layout** is still available.
Closing a property sheet opened this way does not resume text editing.

**Expected:** Select a settings-enabled block or select inside it, then tap
Settings next to Style. No gesture or manual switch back to text mode is
required. Mixed or ambiguous selections do not show a gear.

## Link in the Formatting Bar

**Before and cause:** The inline link button appeared in a separate leading
slot only when the editor reported a linkable selection.

**Fix:** The existing link asset is always in the formatting row, immediately
after **Strikethrough**. It opens a compact floating URL box above the
keyboard, with **Remove**, **Save**, and close. The URL field takes focus and
the held text stays highlighted in the document. The existing link token
still validates the original text before applying a URL. Without linkable
text or an existing link, the button is visible but disabled. The standalone
Add Link and block-link sheets are unchanged.

**Expected:** Select text, tap **Link**, and enter the URL to make that text
clickable. With the caret in an existing link, the same action edits it.

## InfoCard Disclosure

**Before:** Tapping the disclosure could put the editor into typing mode.

**Cause:** The button blocked propagation and some mouse focus, but not the
default touch activation of the editable WebView.

**Fix:** The disclosure uses the same non-editing tap handler as the reminder
button. The saved collapsed flag still updates. When an existing selection
would be hidden by closing the body, its model position moves to the
description without explicitly focusing the editor.

**Expected:** Expand and collapse with the keyboard closed. The title,
description, and card contents are preserved.

## Caret Jumping to Document End

**Before:** A tap near part of the document could send the caret to the end
instead of leaving the hit to the editor.

**Cause:** Decorative SwiftUI page backgrounds accepted taps and explicitly
called `focusDocumentEnd`; the gesture did not use the tap's position.

**Fix:** Page backgrounds are drawing-only. Normal caret placement stays with
the editor; the explicitly placed end-of-document tap zone retains its
end-focus action.

**Expected:** Tapping document text no longer competes with an end-focus
gesture on the page shell.

## Deleting List Items

**Before:** Deleting the selected leading text of a list item could leave an
empty bullet, number, or checkbox.

**Cause:** Deletion targeted a paragraph inside a row. The schema could
replace a missing required paragraph or recreate a required final list item.
Checklist items were not covered by the existing row special case.

**Fix:** Explicit Delete on the leading text block removes the owning list item,
including its content. A separately selected continuation after that paragraph
still deletes on its own. If every row is selected, the list wrapper is
removed too. Overlapping deletion ranges are consolidated and applied in
reverse order in one undoable transaction. A document left empty gets a plain
paragraph rather than a ghost marker. Cut and Group as Page do not remove
unselected row descendants that were not copied to the destination.

**Expected:** Delete removes the row and its marker. Remaining list rows and
their numbering stay intact, and Undo restores the removed content.

## InfoCard Text and Block Selection

**Before:** A second tap in InfoCard text could target the whole card instead
of leaving text selection to WebKit.

**Cause:** The ancestor card's capture listener handled editable child
surfaces too, and the general hold action could intercept taps in card text.

**Fix:** Editable title, description, and body content do not arm the
ancestor card as a block target. An existing text selection inside the card
is not promoted by a repeat tap. The generic hold handler leaves these text
surfaces alone. Card chrome remains available for whole-card selection.

**Expected:** Select text inside either visible part of the card normally;
use the outer card surface when selecting the whole block.

## Vertical Block Range Dragging

**Before:** Small upward motion could run selection toward the top, while
dragging down did not reliably advance the selected range.

**Cause:** The scroll driver ran anywhere in the viewport after a small drift.
Its latched direction filtered subsequent manual hit tests. At a scroll
boundary it could jump directly to the first or last block.

**Fix:** Deliberate vertical movement extends the range by actual finger
position, independently of the prior scroll direction. Direction changes can
accumulate across touch samples. Native autoscroll starts only within 48
points of the edge in the direction of travel, pauses away from that edge,
and uses the same hit testing rather than selecting the entire page at a bound.

**Expected:** Swipe to select, then drag up or down to extend or shrink the
range. A small drift during the horizontal swipe does not trigger autoscroll.

## Verification and Rollout

No builds, tests, or device runs were performed. The causes above are based
on code inspection; responsiveness and gesture timing remain to be verified
on a device. The generated editor bundle was left untouched. Regenerate it
with `npm run build` in `penned-editor` before building the native app.

## Files Changed

- `penned-editor/src/editor.js`, `divider.js`, and `tiptap.html`: contextual
  settings, toggle-aware divider indentation, and removal of obsolete chrome.
- `penned-editor/src/document-tasks.js` and `editor-control-activation.js`:
  defer task-wide work during typing and handle touch activation without focus.
- `penned-editor/src/heading-label.js`, `minimal-fields.js`,
  `information-card.js`, and `block-actions.js`: remove legacy settings
  recognizers and keep text/control touches out of generic holds.
- `penned-editor/src/tabs.js`: separate visible panel from saved default and
  reset temporary navigation.
- `Vellix/Editor/MobileBlockSelection.swift` and
  `MobileBlockSelectionScrollDriver.swift`: list-row deletion, InfoCard hit
  routing, and edge-limited range scrolling.
- `Vellix/Editor/DocumentEditorView.swift`, `TipTapBridgeTypes.swift`, and
  `TipTapEditorSession.swift`: pin settings to the bar, hand off keyboard focus,
  reset cached tabs, remove the page-shell end-focus target, and route
  validated selection-bar requests to the existing sheets.
- `penned-editor/src/attachments.js`, `template-components.js`, and
  `vellix-tables.js`: reuse attachment/component configuration and open the
  table sheet at the selected table without making it first responder.
- `Vellix/Editor/InlineProperty.swift`: distinguish settings opened through
  block selection from property editing that should return to text entry.
- `Vellix/Editor/TaskEditorSheet.swift`, `GridCardSettingsSheet.swift`,
  `WashiTapeSettings.swift`, and `CardPhotoSearchSheet.swift`: reuse the sheet
  keyboard action.
- `PennedMac/Inspector/MacFormatInspector.swift`,
  `PennedMac/Editor/MacTipTapEditorSession.swift`, and
  `MacDocumentEditorContainer.swift`: replace the desktop settings gestures
  and reset temporary tabs on close.
- `Docs/HeadingLabels.md`, `InfoCards.md`, `EditorTypingPerformance.md`, and
  `BlockSwipeSelection.md`: point to the current interactions.

## November 22, 2026: Craft-Style Hold and Drag

See [CraftDragAndDropImplementation.md](/Users/asteriasmoons/Desktop/Vellix/Docs/CraftDragAndDropImplementation.md) for the complete implementation, video/manual-test requirements, native gesture ownership, stacked previews, real container insertion, edge scrolling, Page/Card transfers, transactional undo/redo, file list, and diagnostics.

The new mobile reorder recognizer uses a two-second hold for both individual blocks and existing selections. Immediate swipe selection, vertical range extension, and unselected-area scrolling retain their existing handlers. Page/Card transfers commit both document bodies and ownership changes together before source removal is applied onscreen. Healthy cached destination editors receive a prefix delta rather than a full document replacement.

Filter new diagnostics with `[Penned Drag]`. Existing document-opening and render diagnostics are unchanged. No builds, compilation checks, tests, or device runs were performed for this implementation. The two small packaged-editor hooks were synchronized mechanically without rebuilding the bundle; the earlier build guidance above describes earlier changes, not validation of this addition.

## November 23, 2026: Hold Versus Swipe Selection (Superseded Attempt)

The user confirmed this attempt did not fix the physical-device issue. The
coordinated UIKit/DOM replacement below supersedes its ownership claims.

### Before and Source Findings

The physical-device report was that holding and pulling selected blocks entered
or extended selection instead of lifting. Two competing selection entry paths
were confirmed in source: native callout text selection could promote itself
to block-selection mode without a swipe, and vertical selection resume had no
hold-duration boundary for an already-selected surface. The native reorder
recognizer also lacked a prevention override for other WebKit recognizers.
Source inspection cannot establish which specific WebKit recognizer won the
reported device contact; the new diagnostics distinguish those stages.

### Implemented Ownership Rules

- The native recognizer and injected controller use one shared two-second hold
  duration. Each eligible contact begins with pending ownership.
- A quick accepted swipe or selected-surface vertical movement claims selection
  and explicitly releases the matching native hold via a token-scoped message.
  A late arm reply refuses to take an already active selection gesture.
- Once lifting claims reordering, selection input handlers cannot take that
  contact back. A still-pending selection gesture cannot turn into a vertical
  range gesture after the hold duration has elapsed, even if a lift reply fails.
- The duration check applies only before selection starts. An established
  upward/downward drag-selection can continue past two seconds normally.
- Native text-selection promotion is blocked while a touch selection gesture
  or reorder hold is pending/owned. Holding a callout is not an alternative
  entry into block-selection mode.
- The hold recognizer cannot be silently prevented by WebKit-owned recognizers
  while it is evaluating a stationary contact or dragging. It still fails on
  early movement and retains normal system/navigation cancellation behavior.
- Text-selection suppression is scoped to the held block and cleared on
  handoff/cancellation. It starts only after the existing 320ms quick-swipe
  window, so ordinary cursor taps do not receive a text-selection override.
  It is not applied permanently to the document.

The range-selection algorithm, hit testing, direction changes, selection edge
scrolling, `MobileBlockSelectionScrollDriver`, and
`MobileBlockSelectionScrollGate` were not rewritten or retuned. Existing
horizontal and vertical movement thresholds remain unchanged. Document-opening
readiness, document loading, transfer persistence, and preview caching are
unchanged in this follow-up.

### Diagnostics and Validation

Filter `[Penned Drag]`. New meaningful events include `arm-accepted`,
`arm-rejected`, `hold-completed`, `hold-rejected`, `lift-rejected`,
`gesture-owner-selection`, `gesture-owner-reorder`,
`hold-released-to-motion`, `contact-reset-without-drop`, and
`gesture-script-failed`. Native events include elapsed time, owner, armed state,
recognizer state, editor readiness/editability, and selected-block count. JS
rejections include a specific reason. No document text or titles are logged.

Changed code: `MobileBlockDragGesture.swift`, `MobileBlockDragAndDrop.swift`,
`MobileBlockSelection.swift`, and `TipTapEditorSession.swift`. The callout visual
changes from the same request are documented in [Callouts.md](/Users/asteriasmoons/Desktop/Vellix/Docs/Callouts.md).

The prevention/state handling follows Apple's public
[prevention API](https://developer.apple.com/documentation/uikit/uigesturerecognizer/canbeprevented(by:))
and [recognizer state machine](https://developer.apple.com/documentation/uikit/about-the-gesture-recognizer-state-machine).
No builds, compilation checks, tests, simulators, or app launches were run.
Physical-device gesture arbitration and visual acceptance remain unverified.

## November 23, 2026: Coordinated Gesture Ownership Replacement

The custom timer recognizer is replaced by `UILongPressGestureRecognizer`, with
the same approximately two-second hold for one block or an existing selected
group. A single DOM contact record joins native and JS identity and routes that
contact to selection, scrolling, reordering, a dedicated control, or cancellation.
UIKit recognizes the hold before asynchronous preview preparation. Intentional
WebView touch cancellation at lift is not mistaken for cancellation of the
native drag. Early release/cancellation cannot turn into block selection.

Confirmed conflicts corrected:

- More-specific forced `user-select: text !important` no longer defeats hold
  suppression. Effective style is reported when the reservation is applied.
- Native callout text ranges no longer promote themselves to block selection.
- Only a committed left swipe starts gesture-driven selection; precommit motion
  does not prematurely claim ownership. Immediate vertical movement on a selected
  surface retains the working range engine. Late movement after stationary hold
  reservation cannot newly enter selection.
- The native selection gate does not recognize on stationary touch. Unselected
  vertical movement yields to scrolling. Active range-selection duration is not
  capped; its range math, hit testing, direction tracking and scroll driver remain.
- Page/Card, attachment, legacy gutter, calendar-header, shared editor-control
  and Tab hold paths consult the shared policy. Dedicated Tab button switching
  and settings holds remain outside block reordering.
- Token-scoped cleanup and released-token tombstones reject stale callbacks.
  Lift, finish and cancellation remain ordered across asynchronous bridge calls.

`[Penned Drag]` logs are automatic in ordinary Xcode development runs. There is
no launch argument, scheme edit, environment variable, setting or Web Inspector
step. Initial contact, block identity/selection, exact arm rejection, ownership,
selection-entry source, native competition/state, computed suppression, JS
lift response and termination are forwarded to the console. Logs are scoped to
gesture activity rather than typing, rendering or every drag frame.

The full lifecycle, event reference, file list, research sources, preserved
functionality and old `armed=false`/1,196 ms diagnostic are documented in
[CraftDragAndDropImplementation.md](/Users/asteriasmoons/Desktop/Vellix/Docs/CraftDragAndDropImplementation.md).
Existing drag previews, insertion indicators, haptics, target validation, real
nested transfers, native drag autoscroll, transactions, undo/redo and persistence
are retained. Document opening, caching, previews and unrelated UI are unchanged.

No builds, compilation checks, tests, device runs or app launches were performed.
This replacement is implemented, not yet confirmed successful on the iPhone.

## November 23, 2026: Document Loading Regression in Gesture Cleanup

The user reported looping logs, documents not opening, and the library alert
"A JavaScript exception occurred" after the gesture ownership replacement.

### Confirmed Source Error

The new `MobileBlockSelection.command` lifecycle hook calls
`PennedBlockDragAndDrop.cancelForLifecycle` before `setContent` and when making
the editor read-only. That cleanup must also work before any finger contact.
However, `releaseHold` contained these conditions:

```js
if (contact?.token === args.token && !contact.nativeRecognized)
if (interaction?.nativeToken === args.token && interaction.owner === 'pending')
```

When the objects are null and no token was supplied, optional chaining returns
`undefined`. Since the requested token is also `undefined`, the equality succeeds
and the next expression dereferences a null object. Optional chaining on the
first expression does not guard the subsequent expression.

The source-level failure path is:

1. `TipTapEditorSession.load` sends `setContent`.
2. `tiptapCommand` invokes `MobileBlockSelection.command` before reaching its
   content-replacement branch.
3. The new lifecycle hook enters `cancelContact` and then `releaseHold` without
   an active contact/token. The null dereference rejects the JavaScript command.
4. `finishDocumentLoad` records the bridge error and clears `loadedDocumentID`.
5. The opening observer reports the bridge error rather than presenting the
   document. Subsequent SwiftUI WebView updates schedule another `load`; with
   no loaded document ID, the same-document no-op guard cannot stop that attempt.

This establishes a concrete load failure and a source-supported repeat path.
The screenshot does not contain the repeating console lines, so it cannot prove
which specific logger was repeating or rule out another independent exception.

### Targeted Correction

- `releaseHold` now requires a real `contact` or `interaction` before comparing
  its token and accessing its other properties.
- `cancelContact` returns successfully without logging or changing editor/plugin
  state when there is neither a live gesture nor a token to release. Real token
  releases, stale-token rejection, waiter cancellation, active-drag cleanup and
  their diagnostics remain in place.
- The native error path is unchanged. Genuine JavaScript errors are still
  reported; no catch-and-ignore behavior or retry suppression was added.

Changed implementation: `Vellix/Editor/MobileBlockDragAndDrop.swift` only.
This page and `Docs/CraftDragAndDropImplementation.md` document the regression.
The script is injected by `TipTapWebView` from Swift, so no editor source or
packaged JavaScript bundle change is needed for this correction.

Document opening, readiness requirements, navigation, timeouts, caching,
previews, content persistence, and selection/scrolling algorithms are unchanged.
No builds, compilation checks, tests, simulators or app launches were run.
Validation is source/diff inspection only; reopening documents and the absence
of the reported console loop remain to be confirmed on the physical iPhone.

## November 23, 2026: Pointer Input and Native Hit-Test Arming

The next physical-device trace established a separate failure: 16 native
contacts all attempted to wait for a DOM contact; none logged `dom-contact-start`
or a successful arm/lift. Four explicitly timed out with
`dom-contact-not-delivered`. Meanwhile pointer-based block handlers did receive
input. Selection was also blocked because its start path required the same
missing contact record. The earlier null-cleanup correction fixed a different
source error; it could not restore this missing input dependency.

### Correction

- `MobileBlockSelection.swift`: a single Pointer Events sensor, with TouchEvents
  only as a compatibility fallback, feeds the existing range engine through an
  event-local coordinate/identity adapter. Document-level pointer continuation
  survives inline DOM replacement. Native pan classification reuses existing
  binding and blocked-control rules. No selection-range math was rewritten.
- `MobileBlockDragAndDrop.swift`: the shared pointer stream establishes contact
  before individual handlers. Native arming directly hit-tests its physical
  coordinates instead of waiting 1,750 ms for `touchstart`. Native-first and
  pointer-first delivery join one record; release/cancellation and stale-token
  protections remain. Container chrome can resolve a complete real block node,
  not merely its text, without making structural wrappers draggable.
- `MobileBlockDragGesture.swift`: WebKit input-delivery recognizers may operate
  simultaneously; prevention targets pan/long-press actions. Early movement
  explicitly fails the pending hold at the existing movement tolerance.
- `MobileBlockSelectionScrollGate.swift`: an eligible initial left swipe can
  reserve the native pan before selection mode is active. Selected vertical
  motion retains the existing range behavior; unselected vertical motion yields
  normal scrolling. The existing thresholds and lookup timeout are retained.

Whole blocks and selected groups still use the existing full-node move pipeline:
content, marks, attributes, descendants and relative order are preserved by that
pipeline. Native text dragging was not substituted for block dragging. Existing
previews, insertion indicators, haptics, nesting/transfers, transactions, undo,
autosaving and selection autoscroll are retained. No document-opening, readiness,
navigation, cache, preview persistence, schema or database changes were made.

Automatic diagnostics retain `[Penned Drag]`. Added/updated identifiers include
`controller-installed source=pointerdown`, `native-hit-test-contact`,
`contact-input-joined`, `contact-input-rejected`, and `selection-contact-start`.
Existing arm, ownership, selection-entry, lift, cancellation and drop outcomes
remain. These distinguish missing delivery from actual block hit-test/ownership
rejection without logging document text.

The detailed evidence, sources, architecture and expected device sequences are
in [CraftDragAndDropImplementation.md](/Users/asteriasmoons/Desktop/Vellix/Docs/CraftDragAndDropImplementation.md),
"Selection and Lift Both Failed Without Touchstart". Research includes WebKit's
Pointer Events documentation, the W3C Pointer Events contract, Apple's recognizer
coordination/priority documentation, and WebKit's native touch-transport source.
The trace proves missing controller contact, not the exact WebKit internal cause.

No builds, compilation checks, tests, simulators or app launches were run.
Source review is not confirmation that selection and dragging now work on the
physical iPhone; that behavior remains to be checked there.

## November 23, 2026: PluginView Recreation Broke Selection and Drag Arming

The next trace supplied the actual arm rejection:
`native-contact-outside-editor`, with no contact ID and `owner=none`, despite
the native scroll gate recognizing a left swipe in the editor. Investigating
the startup lifecycle revealed a concrete code error, rather than a need to
change hold duration or selection-range behavior again.

### Cause

`TipTapWebView` injects `TextBlockConversion.script`, whose valid
`editor.registerPlugin(plugin)` call reconfigures ProseMirror's plugin list.
ProseMirror then destroys and recreates its PluginViews. The drag controller's
PluginView destructor cleared both `view` and `editor`, but its replacement
restored only `view`. Tiptap's `onBeforeCreate` does not run again for this
operation. The controller therefore retained a null editor reference.

Its `root()` returned undefined, rejecting real input before contact admission
and causing native arming to label it as outside the editor. Selection also
depended on that contact, so both selection and dragging were blocked. The
earlier trace proved missing controller contact, not missing raw WebKit input;
the previous input-delivery diagnosis missed this lifetime error.

### Correction and Scope

`MobileBlockDragAndDrop.swift` now captures the owning editor and restores both
editor/view references every time its PluginView is created. The root comes
directly from that live ProseMirror view. Arm failures distinguish an unavailable
runtime from an empty hit test, a busy drag, or a genuinely outside-editor hit.
Automatic `[Penned Drag]` diagnostics add `controller-view-destroyed`; replacement
`controller-installed` messages report `accepted=true` and
`reason=editor-reference-bound` when initialized.

This follow-up changes only that implementation file and these two existing
documentation pages. No conversion-plugin registration was removed. Selection
math, continuous range tracking, scrolling, hold timing, whole-block/group moves,
undo, persistence, document opening/readiness, caching and preview generation
were not changed.

The full failure path, sources and diagnostic sequence are documented in
[CraftDragAndDropImplementation.md](/Users/asteriasmoons/Desktop/Vellix/Docs/CraftDragAndDropImplementation.md),
"Startup Plugin Registration Cleared the Drag Runtime". Upstream Tiptap and
ProseMirror behavior was researched online and cross-checked against both local
dependencies and the actual shipped bundle.

No builds, compilation checks, tests, simulators or app launches were run.
The source error is corrected; successful selection and dragging still require
physical-iPhone confirmation.

## November 23, 2026: Stale Pointer Entries Rejected Later Selection

The next device trace confirms the lifecycle correction: controller replacement
retains `accepted=1 reason=editor-reference-bound`, and 14 of 16 native contacts
arm successfully. The remaining two hit a dedicated control or no selectable
block. Neither is the previous missing-editor-reference rejection.

Selection still fails later in this trace. The adapter retains an old pointer
after its terminal event fails to reach the tracking path. A subsequent physical
single-finger contact is rejected as `additional-dom-touch`. Four later native
contacts classify left swipes, but JavaScript produces no corresponding new
selection contact. Its contact Map incorrectly contains old and new pointers.

Implemented corrections:

- `MobileBlockSelection.swift`: a browser-designated primary `pointerdown`
  starts a fresh pointer sequence and retires stale Map entries before counting
  contacts. Cached adaptation runs once per event. Genuine secondary fingers
  still trigger the existing multi-touch safety rules.
- `MobileBlockDragAndDrop.swift`: a new native token cannot inherit the previous
  bound interaction's identity, start time or transient selection gesture. That
  stale contact is released while existing selected blocks are preserved.
- Automatic `[Penned Drag]` events `input-sequence-rebased` and
  `native-contact-rebased` identify these recoveries, without per-frame logging.

The user confirmed this capture contains swipes/shorter holds, not stationary
holds of at least two seconds. It therefore does not validate or disprove the
completed lift path. Arming succeeded; no lift was captured. The two-second hold
and existing movement tolerance were not changed to compensate for selection.

The full evidence and W3C primary-pointer reference are in
[CraftDragAndDropImplementation.md](/Users/asteriasmoons/Desktop/Vellix/Docs/CraftDragAndDropImplementation.md),
"Stale Pointer Sequences Blocked Left Swipes". This follow-up changes the two
named implementation files and these two reports only. Range-selection math,
direction tracking, scrolling, full-block/group transactions, undo, persistence,
document opening/readiness and previews are unchanged.

No builds, compilation checks, tests, simulators or app launches were run.
Selection restoration and a completed two-second drag still need iPhone
confirmation; successful native arming alone is not reported as working drag
and drop.

## Calendar Nested Caret and 1.5-Second Move Hold

Scope of this follow-up is limited to the calendar block inside documents and
the move-hold duration. The standalone Calendar screen, restored block selection
and all other drag-and-drop logic are intentionally unchanged.

- `MobileEditorInteractions.swift`: add a mobile, calendar-only single-click
  caret reconciliation for editable nested text. The calendar already explicitly
  targets blank-background insertions, but nested text depended entirely on
  native caret placement. The new handler maps the tap through ProseMirror,
  verifies that it belongs to the same visible date panel and tapped text block,
  and synchronizes focus/model/native caret only when they disagree. It cannot
  choose another date's text or append a paragraph. It ignores controls, links,
  protected text, hidden/collapsed content, composition, text ranges, block
  selection, and active block dragging. No touch/hold recognizer or Enter
  handler is added or changed. Successful recovery uses the existing
  `calendarDiagnostic` bridge with stage `nested-text-caret`, without text content.
- `MobileBlockDragAndDrop.swift`: change only the shared `holdDuration` constant
  from `2.0` to `1.5` seconds. The native recognizer's `minimumPressDuration` and
  the JavaScript `HOLD_MS` both derive from it, so individual and selected-group
  move holds use the same 1.5 seconds. No other drag thresholds or logic change.

The caret recovery uses existing Tiptap `setTextSelection`, ProseMirror coordinate
mapping and `EditorView.focus`, without a timer, reload or document replacement.
The exact cause of the intermittent native caret failure has not been confirmed
by a device trace; this is a scoped correction of invalid/mismatched placement.
No editor source/bundle, Calendar screen, database, persistence, preview, or
navigation changes were made. No builds, compilation checks, tests, simulators
or app launches were run. Runtime cursor behavior still needs device confirmation.
