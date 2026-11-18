# Editor Interaction Fixes

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
