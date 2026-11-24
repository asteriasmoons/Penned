# Craft-Style Block Drag and Drop

Implementation date: November 22, 2026.

Current contact-sequence correction: November 23, 2026. The latest device trace
confirms that PluginView rebinding survives startup and native arming succeeds.
It also exposes stale pointer entries blocking later selection. New primary
pointer sequences and new native contacts now retire stale prior contact state.
Selection commitment and a completed two-second lift still require device
confirmation; the original implementations below did not achieve them.

## Evidence and Scope

This implements the interaction described in the original [video analysis](/Users/asteriasmoons/.codex/visualizations/2026/08/06/019fd6d0-51ad-7a32-9270-1d41e2c44863/CraftDragAndDropVideoAnalysis.md) together with the user's subsequent manual confirmations. The two-second hold, noncontiguous selections, collapsed/empty container drops, edge scrolling, and Page/Card transfers come from those additional confirmations, not assumptions about the original recording.

This is an iOS editor integration, shared by the iPhone and iPad document surfaces. It does not replace the calendar, previews, document-opening architecture, editor schema, or existing selection system. It does not add cross-window or independently opened-document dragging. A Page and its Card presentation use the existing `pageReference` node and therefore share the same nested-document drop behavior.

**Validation boundary:** No builds, compilation checks, tests, simulator runs, or app launches were performed. Implementation and integration were inspected in source; actual touch arbitration, visual appearance, haptic strength, responsiveness, persistence, and undo/redo still require physical-device validation. This report is not a claim that every interaction has been proven on hardware.

## Before

Penned had a working position-based block selection registry, including noncontiguous selections and vertical range extension, plus native edge scrolling for selection. Those mechanisms select blocks; they do not implement the complete hold/lift/reparent/transfer experience in the reference. The legacy right-gutter block-actions hold could also win before a two-second reorder hold.

Nested Pages/Cards store their bodies in separate document records. Merely moving their DOM or inserting a reference would not transfer selected content. Saving the destination and deleting the source in separate database operations would create a failure window. A full-body replacement in a retained destination WebView could also invalidate the mapping of its earlier undo history.

## Interaction and Gesture Ownership

`MobileBlockDragGesture` now subclasses UIKit's `UILongPressGestureRecognizer`,
attached to the existing outer document `UIScrollView`. UIKit recognizes a
two-second, single-finger hold with ten-point movement tolerance. There is no
custom sleep task deciding when the native recognizer enters `.began`.

The injected controller maintains one contact record: identity, source block,
initial selection membership, native token, timing, and exclusive owner. Its
window-capture pointer input runs before individual block handlers. A small input
adapter presents pointer coordinates/identity to the existing touch-shaped range
engine; it does not synthesize DOM events or install two competing input sensors.
Only environments without Pointer Events use the old TouchEvent sensor.

Native arming immediately hit-tests its physical contact coordinates. It joins a
delivered pointer contact, or creates a native-token-scoped contact which later
pointer delivery can join. It does not wait for `touchstart` or start another hold
timer. Released native tokens cannot attach themselves to later taps. A release
also cancels a native-only contact even if no DOM event was delivered.

| Contact intent | Owner and behavior |
| --- | --- |
| Committed left swipe | Selection; existing selection range logic receives the contact |
| Immediate vertical movement from an already selected surface | Selection; existing up/down range extension and autoscroll continue |
| Vertical movement from an unselected area | Scroll; native document scrolling remains available |
| Stationary hold recognized by UIKit | Reorder; one block or the initially selected group lifts |
| Short release without movement | Normal tap; cursor/control interactions remain available |
| Canceled or unrecognized hold | Cancellation; cannot enter block selection |
| Tab buttons, inputs, media/resize/task controls, text multitaps or an existing focused text range | Dedicated control/text interaction, not reorder |

The 320 ms quick-motion window is an admission boundary, not a time limit on an
active selection drag. Precommit swipe movement is tracked without claiming
selection ownership. Only full swipe/range commitment hands the native hold to
selection. Once selection commits, its duration is not capped and its range
calculations, hit testing, directional tracking and autoscroll are unchanged.
The native selection scroll gate no longer recognizes a selected block merely
because it was touched: actual range/swipe movement is required. Its existing
DOM lookup now uses the selection controller's existing binding/blocked-target
rules. It can reserve an initial left swipe before selection mode is on. This
matters because canceling a PointerEvent is not a substitute for arbitrating the
enclosing native scroll view. Unselected vertical motion still releases the pan.

UIKit owns a recognized reorder before JS prepares its preview. UIKit's
intentional cancellation of WebView touch delivery does not cancel that reorder.
Release during asynchronous lift preparation waits for that lift response before
finishing or canceling it. Native tracking, not DOM touch delivery, continues to
drive the floating preview, insertion target and edge scrolling after lift.

Public failure dependencies and prevention decisions coordinate native gestures;
the implementation does not identify or disable private WebKit classes. Those
decisions are logged and still require confirmation on the user's iOS version.

## Lift, Preview, and Selection

The injected `PennedBlockDragAndDrop` extension uses the existing `PennedBlockSelection` registry and selected records. It does not introduce a second stored selection model.

Dragging moves complete ProseMirror nodes, not a native text drag or selected
text fragment. Holding container chrome can also resolve a real schema `block`
node (including Calendar) when the selection registry represents its interior
as smaller units. Schema-only wrappers, such as a date panel or table row, do
not become independently movable blocks. This does not change selection units.

An individual block can lift without selection mode. Holding a selected surface uses the entire current selection, including noncontiguous records, sorted by their model positions. Redundant ancestor/descendant ranges are reduced to their outermost moved units so a descendant is never moved twice.

List first paragraphs resolve to their complete list/task row, preserving the marker, row attributes, and descendants. A toggle title resolves to its whole toggle. When list rows leave their list, they retain a proper list wrapper rather than becoming invalid top-level `listItem` nodes. Newly required wrappers receive their own IDs; moved blocks retain their IDs.

The source stays in its original layout at 25% opacity throughout active dragging. A floating clone follows the finger. Multiple units use a compact layered stack and a count badge. Preview-only HTML IDs are remapped, SVG references remain local to the clone, and 2D canvas pixels are copied when available. None of these elements are serialized to the document.

Existing blur handling removes unused tap-created caret paragraphs. Lift finishes that cleanup before recording movement positions and resolves the held units by identity if their positions shifted. This avoids dragging with positions captured before the existing caret cleanup.

## Destinations and Insertion Indicator

There is one purple insertion line. Its location comes from a schema-valid insertion boundary, and its horizontal inset comes from the actual destination content slot.

The destination index includes the document root and existing containers with compatible block content: toggles, plain/icon callouts, Grid Cards, blockquote bodies, editable field/panel bodies, active calendar panels, Information Card bodies, and other compatible slots. It excludes structural registries such as a Tabs panel list or table row from arbitrary block insertion.

- Empty containers can accept content without an existing child serving as a hit target.
- Empty space above, below, and between blocks can resolve to actual insertion boundaries.
- Expanded toggles accept individual and multiple units at the indicated position.
- Collapsed toggles accept a body insertion and expand in the same committed transaction.
- Collapsed compatible Information Card/calendar content resolves through its real body slot and opens its owning container on commit.
- A container within any moved source range is not a destination, preventing editor-tree cycles.
- Page/Card destinations are validated natively before receiving a valid-target indicator and feedback. Validation checks Space ownership, document availability, and nested-document cycles; the final transaction checks again.

The final drop resolves the current finger point again, maps the indicated boundary through source removal, checks schema compatibility, inserts the immutable node trees there, and validates the resulting document. It does not simulate reparenting with an `indent` style.

Returning to the grabbed unit's original insertion boundary is a no-op, including for a noncontiguous selection. Other moves that produce an identical document do not create an undo event. A stacked preview never permanently merges or groups blocks.

## Haptics and Automatic Scrolling

Each change to a valid destination key requests native selection feedback. The native recognizer retains and prepares a `UISelectionFeedbackGenerator`; it does not create and immediately discard a generator for each destination. Repeated frames at the same destination do not repeatedly buzz. Leaving a valid destination resets the feedback identity, so returning to it can provide feedback again.

Native `CADisplayLink` scrolling uses the existing outer document scroll view. It uses 64-point edge zones inside the unobscured document viewport, increasing speed toward the edge, up to 850 points per second. It stops away from the edge, at a scrolling boundary, on release, or on cancellation. Clamping cannot move an overscrolled page in the opposite direction.

The finger is retained in window coordinates. Each update converts it back into WebView coordinates after native scrolling, keeping the preview attached while content moves beneath it. Position and destination updates are coalesced with at most one outstanding move evaluation. Selection range autoscrolling stops when reorder lifting succeeds; the two scroll drivers do not run together.

## Same-Document Integrity and Undo

Source removal and insertion share one ProseMirror transaction. Existing placeholder guards are honored, required source-container filler content is preserved, and exhausted list wrappers are removed safely. Existing nodes, marks, custom settings, and descendant trees are reused.

The transaction is bounded by the existing history API. A same-document move is one undoable action rather than a sequence of partially saved deletions and insertions. Normal editor update/autosave, task/tag indexes, and persistent preview descriptor maintenance remain connected.

## Page/Card Transfers

Dropping onto the middle of a nested Page or Card transfers content into its associated document **before existing content**. A lone empty default paragraph in an otherwise empty destination is replaced by the moved content.

1. The source editor prepares but does not apply its removal transaction. Other document-changing transactions are temporarily rejected while persistence is pending.
2. Existing editor transaction filters are checked before committing database changes.
3. Dirty retained destination content is captured/saved first. A clean cached destination is not unnecessarily saved over newer persisted content.
4. The source's current body is captured/saved through its existing lifecycle.
5. The repository compares the persisted source against that expected body.
6. Both document bodies, moved nested-page ownership, folder relationships, and exclusively moved attachment ownership are updated in **one existing `AppDatabase.write` transaction**, using the supplied GRDB connection throughout.
7. The existing database layer reconciles task, tag, search, preview-descriptor, and synchronization changes. There are no new tables, migrations, CloudKit record formats, or global locks.
8. Only after commit does the source editor apply its prepared removal transaction.
9. A healthy retained destination receives only the changed prefix, outside its own undo history. Its unchanged tail nodes, selection mapping, and earlier history remain intact. A missing, uninitialized, or rejected runtime uses existing full hydration as recovery.

Moved Page/Card identities are retained; their owned child documents are reparented rather than copied or trashed. Original child folder IDs are recorded for undo. Shared attachment references continue using the existing same-Space resolver and document-deletion ownership safeguards; exclusive attachment records follow the moved content. No media files are rewritten as part of a transfer.

If persistence fails or ownership/content comparisons fail, the source stays intact. A Page-validation callback that never returns is bounded by a two-second wait on release and does not commit a transfer. This is a new drag-operation bound, not a change to document-opening timeouts.

## Cross-Document Undo/Redo and Conflict Safety

A custom registered ProseMirror history step associates the source action with its native transfer checkpoint. Undo/redo from the source editor first applies the inverse/forward database transfer, then accepts the corresponding editor history transaction. Each checkpoint retains the destination's before/after body and moved ownership information.

Undo/redo is deliberately refused if the destination body changed after the relevant transfer, or ownership changed. It reports the conflict instead of overwriting newer content. Earlier ordinary edits in a retained destination remain separately undoable; the transferred prefix is not inserted as an unrelated destination-only undo action that could delete content without restoring its source.

These transfer checkpoints live alongside the source editor's in-memory undo history. They are not a new persistent cross-device undo system. Ordinary document data is persisted atomically, but application restart does not retain this new undo journal beyond the lifetime of its editor history.

If persistence succeeds but the source WebView cannot acknowledge/apply the committed transaction, the session records that failure and hydrates the committed source checkpoint through its existing load path. This is an exceptional consistency recovery, not the ordinary drag path. Such a WebView recovery can reset transient editor history/state and needs device-level exercise.

## Performance Boundaries

- No timers, full-document serialization, database reads, or layout scans run for each keystroke as part of this feature.
- Idle plugin work consists of constant-sized state/transaction checks.
- Touch arming resolves a local model path and existing selected records instead of scanning every block on every touch.
- Destination indexes and previews are created only after lifting.
- During movement, hit testing examines the hit element's ancestor containers, not every document node. Child-boundary lookup is binary; fragments and validity results are cached for the immutable drag source.
- Pure block-content schemas use a uniform compatibility check instead of repeatedly matching the entire document at every insertion boundary.
- A Page target performs one off-main ownership validation per drag/target pair. Body serialization and transactional persistence occur on drop, not on every move.
- PNG generation, cache keys, PNG persistence, preview pruning, and the separate thumbnail renderer were not modified.

## Diagnostics

Filter Xcode for **`[Penned Drag]`**. Native logs include a timestamp, document ID, drag/transfer token, event name, and available count/depth/position fields. They do not include titles, document bodies, or user text.

Meaningful events include:

- `lift`, `destination`, `drag-cancelled`
- `drop-original-position`, `drop-committed`, `drop-rejected`
- `page-validation-accepted`, `page-validation-rejected`
- `transfer-request`, `transfer-filter-rejected`, `transfer-committed`, `transfer-rejected`
- `transfer-failed`, `transfer-editor-rejected`, `transfer-acknowledgment-failed`
- `transfer-checkpoint-recovery`, `destination-prefix-applied`, `destination-prefix-bridge-failed`
- Native `arm-bridge-failed`, `lift-bridge-failed`, `move-bridge-failed`, and `finish-bridge-failed`

Drag gesture tokens and durable transfer tokens are distinct. A lift token identifies finger tracking; a new transfer token identifies the Page/Card transaction and subsequent undo/redo. The transfer-request timestamp connects those stages.

## Files Changed

- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/MobileBlockDragAndDrop.swift`: new injected ProseMirror/DOM controller, structural moves, previews, target validation, source history marker, and destination prefix application.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/MobileBlockDragGesture.swift`: new native two-second recognizer, feedback generator, lifecycle cancellation, and outer-scroll-view edge scrolling.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/MobileBlockSelection.swift`: exposes existing record lookup and gesture cancellation; installs the additional extension. Existing selection thresholds/range logic are not replaced.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/TipTapWebView.swift`: injects the new mobile controller before editor creation.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/DocumentEditorView.swift`: attaches the recognizer beside the existing selection gate and stops competing selection scrolling on lift/deactivation.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/TipTapEditorSession.swift`: native validation, haptic routing, transfer callbacks/checkpoints, cache adoption, acknowledgment recovery, and diagnostics.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Editor/DocumentEditorCache.swift`: drains dirty destination saves and updates affected retained editors/metadata without replacing the cache.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/Documents/DocumentRepositories.swift`: ownership validation and atomic transfer/undo/redo using the existing connection, save, and indexing contracts.
- `/Users/asteriasmoons/Desktop/penned-editor/src/editor.js`: passes existing ProseMirror classes to the injected extension.
- `/Users/asteriasmoons/Desktop/penned-editor/src/block-actions.js`: gives iOS touch holds to reordering while preserving mouse actions.
- `/Users/asteriasmoons/Desktop/Vellix/Vellix/VellixEditor.bundle/tiptap.bundle.js`: mechanically synchronized the same dependency hook and legacy-hold handoff. No editor build was executed; other existing bundled changes were retained.
- `/Users/asteriasmoons/Desktop/Vellix/Docs/EditorInteractionFixes.md`: links this implementation and its validation boundaries.
- This report.

## Sources

The implementation follows the project's installed ProseMirror APIs. The public [ProseMirror Step contract](https://github.com/ProseMirror/prosemirror-transform/blob/master/src/step.ts) documents registered invertible/mappable custom history steps. The [history implementation](https://github.com/ProseMirror/prosemirror-history/blob/master/src/history.ts) explains how steps and position maps are retained for undo/redo. Apple's [gesture failure-dependency API](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:)) supplies the recognizer coordination mechanism.

Those sources support the implementation choices; they do not establish Craft's private implementation. The intended user-facing behavior comes from the supplied recording and the user's confirmed follow-up observations.

## Earlier November 23 Follow-Up: Superseded Attempt

The following describes the first follow-up, not the current replacement. The
user subsequently confirmed it did not fix the physical-device behavior. Its
claims about exclusive native ownership and text suppression were incomplete.

The initial device run reported selection instead of lifting. The ownership
handoff is now explicit: quick swipe/range movement claims selection and ends
the pending native hold; reaching the shared two-second hold claims reordering
and blocks selection entry for that contact. A late native arm cannot take over
an active selection gesture. A failed/late lift cannot fall back into a new
selection after the hold boundary.

This does not time-limit active drag-selection. The pending-contact time check
does not run once the selection gesture is active, so extending selection up or
down remains on its original algorithm and can continue for longer than two
seconds. Existing selection thresholds, target hit testing, and selection
autoscrolling remain unchanged.

Native callout text-selection promotion no longer competes with a pending
hold/swipe. WebKit-owned recognizers cannot silently prevent an otherwise
eligible pending hold; early movement still releases ordinary scrolling and
selection. Local text-selection suppression, temporary ownership, and scroll
display links are cleaned up on cancellation.

Additional `[Penned Drag]` events identify arming, the completed hold, rejected
conditions, and the interaction that won. Native logs include elapsed time,
armed state, owner, and editor readiness/editability. Rejection reasons are
forwarded from JavaScript without logging content.

See [EditorInteractionFixes.md](/Users/asteriasmoons/Desktop/Vellix/Docs/EditorInteractionFixes.md)
for the full follow-up. No builds, compilation checks, tests, device runs, or
app launches were performed for these corrections; successful hardware behavior
is not yet established.

## November 23 Replacement: Confirmed Conflicts Addressed

1. The packaged HTML forced `user-select: text !important` with a selector more
   specific than the injected hold suppression. Both source and packaged HTML
   now exclude reserved/active reorder roots from that default. Scoped injected
   rules suppress selection on the held surface and its descendants. At the
   reservation boundary the console reports effective computed user-select for
   both the hit element and the source surface. No permanent suppression is
   applied to the editor.
2. `selectCalloutInsteadOfText` independently promoted native text ranges to
   block selection. That handler/listener is removed. Text ranges remain text
   ranges outside reserved reorder gestures. Reserved holds reject native
   selection through `selectstart` and `selectionchange`, without promoting them.
3. Selection claimed the contact before its full swipe threshold. Authorization
   now occurs on commitment. Rightward swipes cannot start selection. Every
   off-to-on selection transaction also requires an authorization marker; direct
   unclassified transaction entry is rejected and logged.
4. Explicit commands such as Select All and link reselection remain supported,
   but cannot steal a pending hold or an active reorder. Selection-mode taps
   require a completed tap, not the compatibility click after a canceled hold.
5. The previous custom recognizer stayed `.possible` through both its sleep and
   JS lift response. UIKit now recognizes the hold independently of preview IPC.
   The native scroll gate waits for that recognizer, while actual selection
   commitment explicitly releases it. The later pointer-input correction narrows
   native prevention to scroll/long-press actions and permits simultaneous WebKit
   input delivery, rather than treating delivery recognizers as block actions.
6. Page/Card actions could create a NodeSelection after 550 ms. Page, legacy
   gutter, attachment, calendar-header, shared control and Tab settings hold
   handlers now consult the same ownership policy. Dedicated Tab buttons remain
   excluded from reorder, so tap-to-switch and hold-for-settings remain separate
   working code paths. Mouse context menus retain their existing path.
7. Native reset, DOM cancellation and delayed IPC previously had separate
   lifetimes. Token-scoped release, released-token tombstones and ordered
   lift/finish/cancel operations keep one contact from acting on a later one.
   An invalidated source is canceled rather than silently reinterpreted as
   selection. Document replacement, locking and editor teardown release contact
   state and temporary CSS.

The user's supplied old diagnostic showed `armed=false`, `owner=ineligible-contact`,
three selected blocks and a reset at 1,196 ms while the editor was ready/editable.
That proves the old attempt did not reach a valid two-second lift. It does not
identify which JS eligibility guard rejected it. The replacement reports the
specific source/control/text/ownership rejection at the native arm response.

## Automatic Xcode Diagnostics

Filter the Xcode console for **`[Penned Drag]`**. No scheme changes, environment
variables, launch arguments, Web Inspector commands or diagnostic settings are
needed. Native messages use the existing bridge logger at notice level. JS
gesture diagnostics are automatically forwarded through `blockDragDiagnostic`.

Records include native epoch timestamps, document ID, native contact token,
DOM contact ID, browser timestamp/elapsed milliseconds, owner, outcome/reason,
and relevant source identity/selection state. The native arm response joins the
IDs even if the first DOM event happened before the native token arrived.

| Events | What they establish |
| --- | --- |
| `controller-installed` | The JS ownership controller installed; includes the hold duration |
| `native-contact-start`, `dom-contact-start` | Initial delivery on each side; source ID/type, selected status and eligibility |
| `native-hit-test-contact`, `contact-input-joined`, `arm-accepted`, `arm-rejected`, `native-arm-response` | Immediate native hit testing, joined pointer/native IDs and exact eligibility outcome; the old arm wait is removed |
| `contact-input-rejected`, `selection-contact-start` | Input outside/unavailable editor roots, or actual admission into selection tracking with source and block position |
| `native-hold-completed`, `native-state`, `native-lift-request` | UIKit recognition and native state before lift IPC |
| `owner-transition`, `selection-motion-tracking`, `selection-entry-attempt`, `selection-entry-rejected` | Intent, ownership and the originating selection handler/command |
| `native-competition`, `native-competitor-outcome` | Other recognizer class/readable state, public prevention/failure/simultaneous decision, and observed terminal outcome; deduplicated per contact |
| `text-suppression`, `native-text-selection-rejected` | Effective computed style and any native selection attempted during the reservation |
| `competing-hold-rejected`, `control-hold-permitted` | Which block-specific handler yielded or retained a dedicated control |
| `javascript-lift-request`, `lift`, `lift-rejected`, `native-lift-response` | Actual JS preparation result, not merely completion of the native hold |
| `scroll-gate-*`, `selection-contact-ended`, `native-yield-to-selection` | Scroll/range admission, cancellation and handoff |
| `native-contact-release`, `native-hold-released`, `native-cancel`, `native-reset`, `ownership-released` | Release, reset, canceled hold, actual drag termination and ownership cleanup |
| `stale-*`, `gesture-script-failed`, `*-bridge-failed` | Late callbacks, JS exception type/source frames or IPC failure |
| Existing `destination`, `drop-*`, `transfer-*` events | Insertion validation, committed/no-op/rejected drops and durable nested transfers |

There is no per-keystroke, SwiftUI-body or per-frame trace. Selection range
movement does not repeatedly log entry authorization. Native state/competition
records are deduplicated; JS only samples computed style at hold reservation.
Payload forwarding uses a fixed scalar allowlist. Document text, titles, HTML,
JSON bodies and clipboard content are not logged. Exception frames are retained
without forwarding arbitrary exception messages that could contain node text.

For a device comparison, inspect the entire sequence, not only `native-state`:
`native-arm-response accepted=true` -> `native-hold-completed accepted=true` ->
`owner-transition owner=reorder` -> `lift` -> `native-lift-response accepted=true`.
If it stops, the immediately preceding rejection/cancellation/competition record
identifies that boundary. A normal swipe should instead show selection
authorization, `owner=selection`, and native yield/release, without a lift.

## Current Files and Preserved Functionality

- `Vellix/Editor/MobileBlockDragGesture.swift`: standard UIKit hold, token-scoped
  contact lifecycle, ordered lift completion and automatic native diagnostics.
- `Vellix/Editor/MobileBlockDragAndDrop.swift`: coordinated DOM ownership,
  selection admission, CSS/text-selection protection and forwarded JS diagnostics.
- `Vellix/Editor/MobileBlockSelection.swift`: authorized entry/commit boundary,
  left-swipe entry and removal of callout text-range promotion. `rangeSelection`,
  `targetAt` and `continueDragScroll` are retained.
- `Vellix/Editor/MobileBlockSelectionScrollGate.swift`: motion-based admission,
  not touch-based recognition; existing DOM hit lookup and pan role retained.
- `Vellix/Editor/TipTapEditorSession.swift`: automatic notice-level logging and
  an explicit diagnostic-field allowlist. Existing injection and session routing
  continue through `TipTapWebView` and `DocumentEditorView` without new UI.
- `penned-editor/src/page-reference-node.js`, `block-actions.js`,
  `attachment-actions.js`, `week-strip.js`, `tabs.js`,
  `editor-control-activation.js`: consult the shared hold policy.
- Source and packaged `tiptap.html`: remove the selection-specificity conflict.
- Packaged `tiptap.bundle.js`: mechanically synchronize those exact hold-policy
  handler edits without rebuilding or replacing unrelated bundled work.
- This report and `Docs/EditorInteractionFixes.md`: current behavior, historical
  failure, diagnostics and validation boundaries.

The existing `MobileBlockSelectionScrollDriver` is untouched. Range math,
upward/downward hit testing and directional tracking remain in the original
selection engine. Drag previews, layered count badges, insertion indicators,
destination haptics, compatible/empty/collapsed container validation, Page/Card
transfers, structural transactions, undo/redo and persistence machinery remain
in place. No schema, database, CloudKit, document-opening/readiness, preview
cache or PNG persistence changes are part of this replacement.

Research supporting the replacement: Apple's [long-press recognizer](https://developer.apple.com/documentation/uikit/uilongpressgesturerecognizer),
[gesture ordering](https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another)
and [prevention distinction](https://developer.apple.com/documentation/uikit/uigesturerecognizer/canbeprevented(by:));
[WebKit's interaction implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/WKContentViewInteraction.mm);
the [Pointer Events touch-action contract](https://www.w3.org/TR/pointerevents3/#the-touch-action-css-property);
[ProseMirror's event contract](https://github.com/ProseMirror/prosemirror-view/blob/master/src/index.ts),
[Tiptap's drag-handle implementation](https://github.com/ueberdosis/tiptap/blob/main/packages/extension-drag-handle/src/drag-handle-plugin.ts)
and [touch activation constraints in dnd-kit](https://dndkit.com/legacy/api-documentation/sensors/touch/).
No new drag library was installed and ProseMirror-owned document DOM is not
reordered directly by a sortable library.

**Validation:** source/diff review only. No builds, compilation checks, tests,
simulators or application launches were run. Recognition order on the physical
iPhone, lift responsiveness, uninterrupted scrolling/range selection, visual
feedback and end-to-end undo/persistence after real touches remain unconfirmed.
This report does not claim the user's drag-and-drop problem is resolved.

## November 23 Follow-Up: Idle Cleanup Blocked Document Loading

The coordinated replacement introduced a JavaScript error unrelated to an
actual finger gesture. `MobileBlockSelection.command` calls
`cancelForLifecycle` before document content replacement. With no active
contact and no token, two optional-chain token comparisons in `releaseHold`
could compare `undefined` with `undefined`, pass, and dereference a null
`contact` or `interaction`. The error aborted `setContent` before the document
body was installed. Native load failure handling then cleared the loaded ID
and published the bridge error; subsequent WebView updates could attempt the
same unsuccessful load again.

The correction is limited to `MobileBlockDragAndDrop.swift`: both release
conditions require their object to exist, and tokenless cancellation without
a live gesture is an idle no-op, including no idle gesture-release log or
plugin-state dispatch. Real contact/token cleanup, late-callback rejection,
automatic `[Penned Drag]` diagnostics, and the ownership architecture remain.
No document-loading, navigation, cache, readiness, selection-range, scrolling,
bundle or persistence behavior was changed to work around the exception.

See `Docs/EditorInteractionFixes.md`, "Document Loading Regression in Gesture
Cleanup", for the exact expressions and complete source-level failure path.
The screenshot establishes the generic JavaScript alert, not the identity of
every repeated log. No builds, compilation checks, tests or app launches were
run; physical-device opening and console behavior remain unverified.

## November 23 Follow-Up: Selection and Lift Both Failed Without Touchstart

### Device Evidence

The supplied trace contains 16 `native-contact-start` and 16
`arm-awaiting-dom-contact` events, no `dom-contact-start`, no `arm-accepted`, no
`native-hold-completed`, and no `lift`. All 16 arm responses are unsuccessful;
four explicitly report `dom-contact-not-delivered`. The other attempts release
or move before completion. Pointer-based block-actions handlers do run during
these contacts. Zero blocks are selected in every native contact record.

This confirms that the newly required DOM contact never reaches the controller
in this trace. It does not prove that all WebKit TouchEvents are globally absent,
nor which internal recognizer or delivery condition caused the absence. Native
competition logs alone cannot establish that specific internal cause.

**Later diagnosis:** the lifecycle investigation below explains how the
controller rejected real input before recording a contact: its editor reference
had been cleared during normal PluginView recreation. Missing contact logs were
not evidence that WebKit itself failed to emit the events. The input-stream
change did not address that reference-lifetime error.

Both features had been coupled to that missing event: native arming waited for
it, and selection `start` rejected a contact that was not already registered by
it. Increasing hold time cannot correct that dependency. The previous idle
cleanup correction addressed the document-loading exception, not this problem.

### Implemented Input-Layer Correction

1. `MobileBlockSelection.swift` chooses one sensor: touch-origin Pointer Events
   where available, otherwise TouchEvents. An event-local cached adapter retains
   real pointer identity, coordinates, cancellation and default-prevention state
   while reusing the existing selection engine's contact shape. Mouse input is
   not reinterpreted as a finger. Active pointer continuation uses document
   listeners so inline DOM replacement does not strand the contact.
2. `MobileBlockDragAndDrop.swift` observes that same sensor at window capture,
   before block handlers. Selection may initialize/join its contact from its own
   event; it no longer depends on a separate TouchEvent or an IPC response.
3. Native `arm` immediately resolves `elementFromPoint` and the actual block
   node from UIKit coordinates. The 1,750 ms DOM-contact waiter is removed.
   Pointer/native arrival in either order joins one record. Token tombstones,
   cancellation, source identity checks and the two-second native hold remain.
4. `MobileBlockDragGesture.swift` no longer attempts to prevent every WebKit
   recognizer. Non-long-press WebKit input delivery is allowed simultaneously;
   prevention is limited to pan/long-press actions. Movement beyond the existing
   ten-point tolerance explicitly fails the pending hold immediately. Its log
   includes native movement deltas. No private recognizer names drive behavior.
5. `MobileBlockSelectionScrollGate.swift` admits eligible initial left swipes
   even before selection mode, using the selection controller's binding and
   blocked-control classification. Selected vertical motion still reserves the
   pan; unselected vertical motion still yields. Existing motion thresholds,
   lookup deadline and active-range calculations remain unchanged.
6. Whole-block lifting retains actual ProseMirror nodes and descendants. A
   container-chrome fallback accepts real schema block nodes rather than only
   text-oriented selection records. It does not lift structural wrapper nodes
   or convert blocks to text. Selected groups still use the full ordered units.

The pointer adapter changes input delivery, not `rangeSelection`, `targetAt`,
`continueDragScroll`, or `MobileBlockSelectionScrollDriver`. Existing preview
clones, dimming, stack badges, insertion lines, haptics, destination validation,
schema transactions, Page/Card transfers, undo/redo and autosaving are retained.
Tab settings controls remain dedicated controls. Document opening/readiness,
caching, PNG previews, schemas, persistence and editor content are not changed.
All code changes are in the four named native Swift files containing the injected
scripts and recognizers. No editor bundle build or bundle replacement is needed.

### Research Applied

- [WebKit: Pointer Events support](https://webkit.org/blog/9674/new-webkit-features-in-safari-13/)
  documents the hardware-independent input stream already observed in the log.
- [W3C: Pointer Events](https://www.w3.org/TR/pointerevents3/) distinguishes
  pointer input from optional device-specific event streams and explains that
  pointer-event cancellation does not itself suppress viewport manipulation.
  This is why the native pan gate remains necessary and blanket `touch-action:
  none` is not applied to all unselected document content.
- [Apple: Coordinating recognizers](https://developer.apple.com/documentation/uikit/coordinating-multiple-gesture-recognizers)
  and [gesture priority](https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another)
  explain simultaneous processing versus action precedence. The native adapter
  must not compete with the event delivery on which the JS controller depends.
- [WebKit touch recognizer source](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/WKTouchEventsGestureRecognizer.mm)
  shows that native-to-web touch transport is itself implemented by a recognizer.
  This supports keeping transport distinct from application action ownership;
  it is not proof of the exact private recognizer behavior on this device.

### Diagnostic Comparison and Limits

Filter `[Penned Drag]` without enabling any flags. New installation records show
`source=pointerdown` on Pointer Events hosts. A delivered contact should show
`dom-contact-start source=pointer`; a native-first contact instead shows
`native-hit-test-contact`, followed by `contact-input-joined` if web input arrives.
Selection admission shows `selection-contact-start`; full authorization remains
`selection-entry-attempt`. Native arming must now report a concrete hit-test,
eligibility or ownership outcome instead of waiting for a missing TouchEvent.

A lift sequence still requires `arm-accepted` -> `native-hold-completed` ->
`javascript-lift-request` -> `lift` -> `native-lift-response accepted=true`.
`sourceID`, `blockType`, `count` and contact/token IDs distinguish one full block
from an ordered selected group. Source/transfer/drop diagnostics remain present.
There is no per-frame or per-keystroke diagnostic added.

Validation is source/diff inspection only. No builds, compilation checks, tests,
simulators or app launches were run. Restored swipe selection, continuous range
selection, normal scrolling and whole-block lifting require iPhone confirmation;
this document does not claim successful device behavior from source inspection.

## November 23 Follow-Up: Startup Plugin Registration Cleared the Drag Runtime

### New Device Evidence

For contact `8DF91996-0CD9-4CA1-91F9-75DE35AB5440`, the supplied log reports
`arm-rejected reason=native-contact-outside-editor`, no contact ID, and
`owner=none`. The native selection scroll gate nevertheless classifies a left
swipe in the document. The native hold's later reset/release messages are
consequences of that arm rejection, not its originating cause.

### Confirmed Source-Level Failure

The complete startup path was checked in native source, installed dependency
source and Penned's shipped `tiptap.bundle.js`:

1. `TipTapWebView.makeWebView` injects `TextBlockConversion.script` at document
   end, after the ordinary synchronous editor bundle script in `tiptap.html`.
2. `TextBlockConversion.script` calls `editor.registerPlugin(plugin)`.
3. Tiptap's `registerPlugin` reconfigures the current state's plugins and calls
   `view.updateState`.
4. ProseMirror's `updatePluginViews` destroys existing PluginViews when the plugin
   array changes, then creates their replacements. This is normal operation,
   not destruction of the TipTap editor or its document.
5. The new drag PluginView's `destroy` callback assigned `view = editor = null`.
   Its replacement assigned only `view = editorView`. The `onBeforeCreate`
   callback that originally assigned `editor` does not run for PluginView
   recreation, so `editor` stayed null.
6. The old `root()` used `editor?.view.dom`, which therefore returned undefined.
   Real pointer/touch contacts failed the root-membership guard before becoming
   an interaction. Native hit testing reported the same condition as
   `native-contact-outside-editor`. The selection ownership admission also
   required a contact and consequently rejected selection.

This is a concrete lifetime error in the added drag controller. Previous input
and gesture-priority changes could not repair an editor reference that stayed
null. The earlier missing-touch-delivery diagnosis was incomplete: missing
controller contact was observed, but raw WebKit event absence was not proven.

### Targeted Correction

- The plugin captures its owning TipTap editor in `addProseMirrorPlugins`.
- Every PluginView factory invocation rebinds both `editor = owningEditor` and
  `view = editorView`. Initial creation and later registration/reconfiguration
  use the same initialization contract.
- `root()` uses the currently bound ProseMirror view's `dom` directly.
- Arming separately reports `editor-runtime-unavailable`,
  `drag-or-transfer-busy`, `native-hit-test-empty`, and a genuine
  `native-contact-outside-editor`. A missing runtime is no longer mislabeled as
  a touch outside the editor.
- `controller-installed` reports `accepted=true reason=editor-reference-bound`
  when its runtime reference and DOM root are bound. `controller-view-destroyed`
  records a PluginView release, and cancellation identifies
  `plugin-view-destroyed` rather than claiming the whole editor was destroyed.

Only implementation file changed in this follow-up:
`Vellix/Editor/MobileBlockDragAndDrop.swift`. The two existing fixes reports were
updated. `TextBlockConversion` itself is unchanged; registering its plugin is
valid behavior and conversion functionality must remain intact. No packaged
editor bundle, dependency or project configuration was modified.

Selection range calculations, hit testing, scrolling thresholds, the two-second
hold, pointer adapter, full-node block/group moves, previews, haptics, transfers,
undo/redo and persistence are unchanged by this lifecycle correction. No
document opening, readiness, navigation or preview-cache changes were made.

### Research and Validation

[Tiptap's Editor implementation](https://github.com/ueberdosis/tiptap/blob/main/packages/core/src/Editor.ts)
shows `registerPlugin` reconfiguration.
[ProseMirror's EditorView implementation](https://github.com/ProseMirror/prosemirror-view/blob/master/src/index.ts)
shows `destroyPluginViews` followed by replacement creation when plugins change.
[Tiptap's lifecycle documentation](https://tiptap.dev/docs/editor/api/events)
distinguishes initial editor creation from editor destruction. The same
reconfiguration behavior was verified in the installed code and shipped bundle,
not inferred solely from current online documentation.

Filter `[Penned Drag]`. Startup can legitimately show a controller installation,
a `controller-view-destroyed`, and another installation after conversion plugin
registration. The replacement installation should retain
`accepted=true reason=editor-reference-bound`; subsequent contacts should then
reach actual selection/arm admission. This is an expected sequence, not a claim
that the sequence has already been captured on the iPhone.

No builds, compilation checks, tests, simulators or app launches were run.
Validation is source/diff inspection only. The faulty lifecycle path is corrected
in code, but restored selection and successful block lifts remain unconfirmed on
the physical device.

## November 23 Follow-Up: Stale Pointer Sequences Blocked Left Swipes

### Evidence and User Clarification

The next supplied trace shows four `controller-installed` events with
`accepted=1 reason=editor-reference-bound`, including replacement installation
after PluginView destruction. It contains 16 native contacts, 14 successful
arms, ten DOM contact starts and eight selection contact starts. It contains
no selection commitment or lift. The two arm rejections are dedicated-control
and no-selectable-block outcomes, not the previous missing-runtime failure.

After contact `DC6AD95D` moves and ends, its JavaScript contact does not record
a terminal DOM event. The following contact triggers `additional-dom-touch` in
JavaScript even though the native contact-start path accepts only a single
physical touch. Four later native contacts classify left-swipe motion, but none
produces a fresh DOM/selection contact start. Native arming falls back to
native-only contact identifiers instead.

The adapter's `inputPoints` Map retained pointers until `pointerup` or
`pointercancel`. If one terminal event did not reach this path, the next finger
was counted alongside a stale entry. Both `beginContact` and selection `start`
reject contact lists whose length is not one. This is a concrete stale-state
failure in the added pointer adapter, not evidence of deliberate two-finger
input or another editor-reference failure. The trace does not identify which
specific mechanism prevented the terminal event reaching the adapter.

The user confirmed these attempts were swipes or shorter holds, not stationary
holds of at least two seconds. Successful arming is not a successful drag, but
the absence of `native-hold-completed`/`lift` in this capture does not establish
that the two-second lift path fails. The longest recorded native contact ends
at approximately 1.35 seconds, with movement beyond tolerance before that.

### Correction

- `MobileBlockSelection.contactEvent` treats a new touch `pointerdown` marked
  `isPrimary` by the browser as a new physical sequence. Stale Map entries are
  removed before constructing the contact list. The event cache ensures this
  happens once per real event, not once for every listener.
- A real secondary touch is not marked primary, so it still adds a second
  contact and follows the existing multi-touch cancellation rules. This is not
  a blanket replacement of the contact list with one finger on every move.
- `MobileBlockDragAndDrop.arm` does not attach a new native token to an old
  bound interaction. It cancels the previous contact's transient gesture,
  releases stale adapter state and then establishes the new contact normally.
  Existing selected blocks are retained; the selection range engine is not
  rewritten. This covers native-first as well as pointer-first delivery.
- A delivered pointer can join a native-first record only while that native
  token has not been released. A later pointer cannot accidentally adopt an
  old native-only contact simply because it starts at the same coordinates.
- Automatic `[Penned Drag]` diagnostics add `input-sequence-rebased` with the
  retired-entry count and `native-contact-rebased` for native token replacement.
  Existing ownership, selection admission, lift and drop diagnostics remain.

This follows the [W3C primary-pointer contract](https://www.w3.org/TR/pointerevents3/#the-primary-pointer):
the first active pointer of a type is primary. It does not assume that pointer
IDs increase monotonically or can never be reused.

Changed implementation files in this follow-up:
`Vellix/Editor/MobileBlockSelection.swift` and
`Vellix/Editor/MobileBlockDragAndDrop.swift`. Both existing fixes reports were
updated. No recognizer timing, movement tolerance, scrolling thresholds, range
calculations, hit testing, native autoscroll, block schemas, full-node/group
transactions, transfers, undo, autosaving, opening/readiness or preview caching
changes were made. The two-second hold remains two seconds for both an
individual block and the selected group.

No builds, compilation checks, tests, simulators or app launches were run.
The lifecycle repair and successful arming are supported by this device trace.
Restored selection after these contact-sequence changes, and an actual
two-second whole-block/group lift, remain unconfirmed on the physical iPhone.
