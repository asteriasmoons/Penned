# Block Swipe Selection

## Architecture

`MobileBlockSelection.swift` supplies a self-contained TipTap extension at document start on iPhone and iPad. Its ProseMirror plugin owns the selected block references, mode, gesture phase, originating block, persistent range anchor/head, click suppression and haptic revision. Selection transactions have `addToHistory: false` and never change document content. Positions map through transactions; stable document block IDs reconcile whole-document transformations performed by existing editor commands. Position matching takes precedence over ID matching so duplicate IDs cannot redirect a touch to another block.

The registry walks the actual ProseMirror hierarchy and retains each block's full model path. Editable paragraphs/headings inside toggles, quotes, callouts and lists are independently selectable; structural wrappers are not included alongside their children. Toggle headings and body paragraphs therefore select separately, as do paragraphs inside a nested callout. Other textblocks and atomic blocks (including code blocks, dividers, page breaks, attachments, properties and nested-page references) participate through the same registry. Tables remain atomic: rows/cells are never detached from their table by a block command. Collapsed/hidden descendants are excluded from gesture ranges. No selection operation flattens or reparents the document.

Selection painting uses node decorations on the actual selectable element, not text-range estimates or gutter coordinates. A translucent lavender surface and subtle inset edge replace the hard outline/left stripe without changing layout. Text surfaces have a small visual inset around the text; cards follow the actual card button rather than its full-width wrapper. A single-paragraph callout/quote follows its existing rounded container, while a selected paragraph inside a multi-block container remains independently painted. Tables tint their opaque cells instead of the full-width scroll wrapper. Only the actively swiped block receives a temporary transform; ordinary idle blocks have no transform or new containing block.

The existing copy, cut, duplicate, formatting and grouping commands read the plugin through a stateless compatibility interface using those full paths. That interface does not contain its own selected-ID set. Nested deletion (including Cut) uses a schema-fitted ProseMirror transaction rather than deleting JSON children that may be required by their parent; for example, a list item's required leading paragraph is retained empty when its nested list must remain. Nested transforms reuse the existing transformation callback, validate every replacement against its actual parent schema before changing anything, and commit a ProseMirror transaction. A forbidden type change (for example replacing a list item's mandatory leading paragraph with a heading) reports the existing native editor error and leaves the document unchanged rather than storing invalid content or silently changing hierarchy. The established immediate snapshot bridge and Undo/Redo are preserved. The old iOS handle/gutter recognizer is bypassed. Native mode/count values are acknowledgements from ProseMirror rather than optimistically assigned SwiftUI state. The existing native bridge handles meaningful selection updates and haptics. Once the plugin has recognized a committed vertical selection drag, it also supplies that drag's platform-scrolling samples; native code does not recognize the gesture or maintain the selected-block range.

## Editing Lifecycle Corrections

The previous capture-phase `touchstart` handler immediately dispatched a selection-metadata transaction. ProseMirror flushes outstanding native DOM input later in that event's propagation. Dispatching first could render stale text over the pending keyboard input, and the subsequent document transaction unconditionally cleared the pending swipe. The old listener cache also assumed an unchanged model document meant unchanged NodeView DOM.

Contact now observes passively and queues its initial metadata transaction until after native touchstart propagation. This provisional event snapshot is not a second selected-block store. Its origin maps through intervening input transactions before the ProseMirror gesture state is established. Pending gestures also map through subsequent edits; an actual document edit during an active drag cancels only the transient drag. There is no app-resume dependency, timeout-based reinitialization, WebView recreation or composition-state manipulation.

The plugin reconciles actual block DOM identities on every view update, plus a plugin-owned child-list MutationObserver for NodeView DOM churn without a model change. The original block/contact-target binding is retained until its stream ends, including an inline mark element detached during input reconciliation. Events reaching both bindings are handled once. Removed bindings and the observer are cleaned up when the contact ends or the editor is destroyed. No global gesture listener is introduced.

## Gesture Rules

- Listeners belong to individual model block elements and are installed/removed by the ProseMirror plugin view. No document/window/editor-root pointer recognizer, gutter or handle is added.
- `touchstart` observes passively and does not dispatch before native input flushes. Taps, existing text selections, composition, multitouch and long presses are not claimed.
- With no blocks selected, horizontal movement must reach 18 CSS pixels and dominate vertical movement by 1.8:1 before activation. With an existing selection, horizontal activation needs only 8 pixels. Vertical movement reaching 10 pixels before activation is released to scrolling unless resuming from selected content. A pending contact older than 320 ms cannot activate unless it began on selected content, where native text selection is already disabled.
- Only cancellable movement is eligible. `preventDefault()` is used after horizontal recognition, never unconditionally on contact or movement. A non-cancellable/cancelled stream is abandoned rather than trying to recover it mid-scroll.
- Ordinary text blocks declare `touch-action: pan-y pinch-zoom` before contact. Potential horizontal-scroll containers do not receive this restriction. Actual horizontal-scroll areas and interactive controls remain excluded from gesture origins.
- At 48 CSS pixels of horizontal displacement (24 with an existing selection), the first commit selects only the touched block. It does not search for a nearest neighbor at that threshold, even if keyboard/layout movement has changed its rectangle.
- Continuous range extension starts after an additional 6 CSS pixels of deliberate vertical movement. New blocks require entry 4 CSS pixels inside their rendered edge (less for very short blocks); existing selected blocks can be re-entered immediately to shrink. Gaps are sticky. Fast drags include crossed blocks even when no event lands inside them, and can reach the first/last block. Each changed selection produces one haptic; extra movement within the same selection produces none.
- Selection and its range anchor/head persist after release. Starting another vertical drag on selected content resumes that range after 4 pixels of vertically dominant movement (1.1:1), without another horizontal swipe or reopening editing/the keyboard. A tapped/command-selected block without a saved range establishes one at that block while preserving other independently selected blocks. A slightly sideways start can still transition into vertical continuation before committing. Only selected block surfaces reserve that next contact with `touch-action: none`, declared before contact. Unselected content retains ordinary vertical scrolling. Direction reversal shrinks the range back to its anchor.
- A following synthetic click is suppressed once. In selection mode, deliberate block taps toggle selection anywhere in its non-control content. Navigation/file-card buttons permit swipe observation while retaining ordinary tap activation; sliders, form inputs, media controls, resizing handles and horizontal scrolling remain excluded.
- Deselecting the final selected block exits selection mode in the same ProseMirror transaction and clears the transient range/gesture. The native mode acknowledgement closes the selection toolbar; entering selection mode before choosing a block is still permitted.
- The plugin also exits whenever a previously nonempty selection becomes empty through a command or document transaction. This covers both top-level deletion (which clears the compatibility selection before committing) and schema-fitted nested deletion/Cut, rather than relying on a particular toolbar handler.
- Document loading, locking, cancellation, edits that invalidate a gesture and editor destruction clear the appropriate transient state. Explicit history boundaries keep native selection actions independently undoable.

## Selection Drag Scrolling (2026-10-29)

The document uses a non-scrolling, content-height WKWebView inside SwiftUI's
native UIScrollView. The plugin previously claimed a selection drag and updated
the ProseMirror range, but never drove that surrounding scroll view. Dragging
therefore selected only the blocks already reachable on screen.

The existing selection drag now drives native document scrolling from anywhere
the drag is already supported. No screen-boundary trigger is required. After
the existing deliberate vertical-extension threshold, dragging down scrolls
down; dragging up reverses scrolling and shrinks/extends the same persistent
range. Holding the drag continues scrolling; release stops it and retains the
selection. Ordinary vertical scrolling and unrecognized contacts are unchanged.

The plugin alone recognizes the gesture and remains the authoritative selection
store. It sends only committed selection-drag samples, using screen-coordinate
movement so native scrolling is not mistaken for additional finger movement.
A small iOS-only display-link driver moves the existing backing UIScrollView,
converts the finger's fixed window position back to editor coordinates, and asks
the same plugin to extend its range. Native scrolling runs each display frame,
without waiting for a WebView reply; only one range update is in flight at a
time, coalescing further scrolling into the next update. Speed starts at 360
points/second and rises with directional drag distance to 1,440 points/second
(previously 120-720). Contact tokens and movement revisions reject callbacks from an older
gesture or direction change. At the actual scroll limit, the range can reach
the first/last visible model block, including content beyond the floating bar.

Scrolling stops on release, cancellation, invalidated selection, editing changes,
backgrounding, disappearance, or document-owner change. The driver keeps weak
view references and does not reparent, recreate, or resize the WebView. No new
gesture recognizers, document/window pointer listeners, selection handles,
highlight changes, page-padding changes, or persisted document edits are added.
Mac selection/scrolling and the working iPad WebView ownership are unchanged.

Files for this correction:

- `Vellix/Editor/MobileBlockSelection.swift`: active-drag scrolling messages and token-checked range continuation through the existing plugin.
- `Vellix/Editor/MobileBlockSelectionScrollDriver.swift`: iPhone/iPad native scroll motion, coordinate conversion, bounds clamping, callback backpressure and cleanup.
- `Vellix/Editor/TipTapEditorSession.swift`: route the iOS-only drag bridge message without publishing pointer positions into document state.
- `Vellix/Editor/DocumentEditorView.swift`: connect the existing scroll proxy to the driver and stop it when the view/app/selection deactivates.
- `Docs/BlockSwipeSelection.md`: cause, behavior, integration boundaries, and verification status.

No builds, automated tests, app launches or simulator checks were run for this
correction. Physical iPhone/iPad verification is still required: extend down
from the middle of the visible document to the final block, reverse to shrink,
release and resume, repeat inside nested content, and cancel by switching
documents/backgrounding. Confirm ordinary scrolling, typing, native text
selection and toolbar actions retain their existing behavior.

### Continued-Selection Responsiveness

Physical-device feedback found continuation too difficult and slow. The resume
and extension thresholds above now become lighter only after selection exists;
the initial no-selection swipe retains its deliberate thresholds. Selected
contacts no longer expire while being held, and tapped selections can resume
without a missing-range failure. Native scroll motion no longer loses frames
to the WebView acknowledgement delay, while range updates remain serialized.
Selection geometry, ordinary scrolling, document loading, and Mac are unchanged.

This refinement changes only `MobileBlockSelection.swift`,
`MobileBlockSelectionScrollDriver.swift`, and this document. No builds, tests,
or app launches were run; touch sensitivity, speed, and range tracking still
require physical iPhone/iPad verification.

The standards describe why gesture axis policy must exist before contact and why cancellation cannot be assumed after scrolling starts: [Pointer Events touch-action](https://www.w3.org/TR/pointerevents3/#the-touch-action-css-property), [Touch Events touchmove](https://www.w3.org/TR/touch-events/#the-touchmove-event).

## Native Embedded Surfaces

Native Kanban overlays do not deliver their touch streams to TipTap. Their controls and drag/drop remain native. Their corresponding document blocks participate atomically when a range crosses them or Select All is used, but directly initiating a swipe on the opaque native overlay is not implemented. Doing that would require a separately approved hosting/input change; forwarding every touch through SwiftUI would violate this implementation's gesture boundary. Oversized tables/code/media retain horizontal scrolling rather than sacrificing that interaction to selection.

Selected collection block IDs are sent as a changed-only `blockSelectionSurfaces` acknowledgement. An iOS-only, non-interactive native tint paints the Kanban overlay so its opaque content cannot hide the selection. This is derived rendering state, not a second selection authority; it does not forward touches or change WebView ownership.

## Mobile Spacing and Selection Appearance

The mobile plugin applies a 10-point sibling gap to the live document, toggle/quote contents and list items. Existing callout-internal spacing, compact property rows and page-break sheet-edge spacing remain intact. The iOS opening preview uses the same 10-point root-block gap; compact library previews and Mac spacing are unchanged.

Text selection surfaces extend six points into the document's side margins for breathing room. The live iOS WebView and its native collection overlay receive matching negative horizontal padding, while the HTML page reserves the same six-point gutter internally. Its maximum width includes both gutters, preserving the existing text column, line wrapping and header alignment on iPhone and iPad. Unlike the former unreserved negative inset, the highlight now stays within the WebView's drawable bounds instead of being clipped at its left edge. Rounded single-paragraph callouts/quotes and cards keep their own fitted surfaces. The opening preview, selection-mode behavior and Mac layout are unchanged.

This appearance-only update changes `MobileBlockSelection.swift`, `ImmediateDocumentPreview.swift`, the iOS selection-paint acknowledgement in `TipTapEditorSession.swift`, and the native Kanban paint overlay in `DocumentEditorView.swift`. It does not change gesture thresholds, block commands, saved document content, HTML assembly, editor initialization or the iPad WebView lifecycle.

No builds, tests, compiler/bundler commands, app launches or simulator checks were run for this appearance update, as requested. The historical checks below were not rerun. Visual review on iPhone/iPad remains necessary for wrapped/indented text, nested callouts/quotes, narrow cards, colored tables and native Kanban, including opening-preview-to-editor transitions.

## Mobile Divider Corrections

`MobileEditorInteractions.swift` renders thin/thick dividers as straight one-/two-point lines in the document's text color, with matching six-point end insets and a 20-point block height. The thin line uses half opacity; the thick line no longer uses an eight-point gray pill. Dotted/four-circle styles are unchanged. The iOS immediate preview mirrors the two line styles; Mac rendering and the shared bundled schema are unchanged.

For both Backspace key events and cancellable `deleteContentBackward` input, Backspace in an empty text block immediately after a divider deletes only that empty block, dismisses the keyboard and clears the browser's visible caret/selection. This includes empty paragraphs, headings, captions and code blocks. The divider remains intact, no replacement block is inserted, and no scroll-to-caret is requested. ProseMirror keeps a valid unfocused text bookmark where available; an atom-only document uses its non-node AllSelection fallback without a visible DOM selection. Parent content validity is checked before deletion. The existing quote-specific Backspace path is preserved. No builds or tests were run for these divider/deletion corrections; physical keyboard and touch-keyboard verification remains pending.

## Files Changed in This Correction

- `Vellix/Editor/MobileBlockSelection.swift`: deferred/mapped contact lifecycle, live DOM reconciliation, hierarchical registry, origin-only first commit, resumable vertical ranges, aligned/table-visible decorations and schema-safe nested deletion/transforms.
- `../Vellix-backend/src/editor.js`: optional nested-deletion and transformation hooks invoking the established snapshot bridge. The absent-provider Mac/non-mobile path is unchanged.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: equivalent optional hooks in the existing shipping artifact.
- `Scripts/install-block-selection-hooks.mjs`: guarded AST-located installation of those hooks, reusing the existing transformation/deletion/snapshot functions. No compiler or bundler.
- `Scripts/test-block-swipe-selection.mjs`: shipping editor/plugin regressions with native-style pending DOM input, NodeView recreation, actual hierarchy, persistent ranges, schema validation, snapshot/Undo/Redo, and shipping CSS for alignment/table states.
- `Scripts/fixtures/mac-ios-source-lock.json`: only the reviewed artifact hash is advanced for this correction.
- `Docs/BlockSwipeSelection.md`: corrected architecture, causes, interaction rules, limitations and verification checklist.

The working iPad WebView ownership/lifecycle, native editor host/session, other mobile editing adapters, Mac implementations, schemas, persistence and synchronization are intentionally unchanged.

## Verification Boundary

No Xcode build, Swift compilation, editor bundler, application launch, simulator or physical-device test was performed for this change. Node/JSDOM checks execute the shipping editor with the exact injected extension; they prove model transactions and event-routing decisions, not WebKit/UIKit arbitration, rendering, native keyboard transitions or felt haptics.

The correction passes 101 checks: 50 swipe/selection regressions, 33 existing mobile-editing regressions, 15 Mac-isolation checks and 3 gallery/loading checks. Maintained editor-source syntax, artifact syntax/idempotent hook installation, and whitespace checks also pass. Shipping-CSS assertions verify the intended selected element and table/cell paint rules, not physical-device pixel alignment.

```sh
node --test Scripts/test-block-swipe-selection.mjs Scripts/test-mobile-editor-interactions.mjs Scripts/test-mac-isolation.mjs Scripts/test-phone-gallery-loading.mjs
git diff --check
```

## Physical Device Acceptance

Required on both an iPhone and an iPad before calling touch behavior fully verified:

1. Type paragraphs, move/place the caret and delete characters normally; use text range selection and long-press selection handles.
2. Type (including composition/autocorrect), immediately swipe, then repeat after splitting/deleting/inserting blocks and opening/closing the keyboard. Confirm no text loss, missed swipes or app-restart requirement.
3. Scroll vertically with slow starts, fast flicks and diagonal movement. Horizontal swipes must not hijack an already-scrolling contact. Swipe near a block's lower edge and verify the initial selection never includes its neighbor.
4. Extend a selection vertically in both directions, shrink back to the origin, lift, then drag vertically from selected content to resume/expand/shrink. Verify unselected content still scrolls. Confirm one haptic per changed selection.
5. Independently select a toggle heading, body paragraph and text inside a nested callout/quote/list without painting the entire container. Repeat through variable-height blocks, collapsed toggles, dividers, fitting/nested tables and nested pages. Check oversized horizontal-scroll surfaces and native Kanban controls remain usable.
6. Copy, duplicate, format, group and delete selected blocks using existing native controls; verify Undo/Redo and attachment/nested-page relationships.
7. Check highlight alignment with short/wrapped paragraphs, indented/nested content, tables narrower than their scroll wrapper, colored table cells, page zoom/rotation and keyboard resizing. After release, no selection transform should remain. Repeat with Reduce Motion enabled. Exit selection and confirm caret placement, typing, the formatting toolbar, slash dismissal and divider insertion still work.
8. Switch documents, accounts and Spaces while selection is active; ensure no previous document's selection is restored into another owner or page.
