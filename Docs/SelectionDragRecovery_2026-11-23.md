# Selection and Drag-and-Drop Recovery — November 23, 2026

## Historical reference
Read-only GitHub source: `asteriasmoons/Penned`, commit `07433ffc1400b1d399048958fa9dbc4a7690d292`, file `Vellix/Editor/MobileBlockSelection.swift`.
The local repository's HEAD is the same commit. GitHub was not modified.

## Local recovery
- `Vellix/Editor/MobileBlockSelection.swift`: restored the original GitHub selection engine (touch-based left-swipe initiation, existing upward/downward range selection, hit testing, range calculations, autoscroll, selection state and deletion/toolbar semantics). Only added a read-only integration surface for drag (selected records, record lookup, active gesture check, cancel-on-actual-lift) and appended the drag extension. Removed the old independent native-text-selection-to-Callout-selection promotion so long holds cannot silently activate Callout block selection.
- `Vellix/Editor/DocumentEditorView.swift`: removed the new `MobileBlockSelectionScrollGate` recognizer from installation. The old selection engine and native scrolling are no longer dependent on that gate. The unused `MobileBlockSelectionScrollGate.swift` source file remains in the project but is not instantiated.
- `Vellix/Editor/MobileBlockDragGesture.swift`: the two-second native long-press recognizer no longer forces the outer UIScrollView pan to wait for its failure. Ordinary motion can end a pending hold, and the scroll view can respond normally.
- `Vellix/Editor/MobileBlockDragAndDrop.swift`: removed unused APIs that could authorize/veto selection; the module now observes existing selection rather than controlling it. Removed the ProseMirror plugin's document-wide `editable` override and its blanket rejection of document-changing transactions while a transfer awaits a response. Fixed the rejected-transfer path that retained `busy=true`. Aborted short holds no longer suppress ordinary subsequent clicks. Added a bounded recovery timeout for missing transfer responses. Registered the custom ProseMirror TransferStep type idempotently within the same document/JS realm to avoid duplicate-ID exceptions on editor recreation. Kept previews, haptics, insertions, block moves, nesting, undo/redo, and nested-document transfer mechanics.

## Behavioral responsibilities
- Left swipe: original block selection engine, without a drag-controller permission check.
- Drag vertically from selected block: original range selection (and original scroll driver).
- Drag vertically from unselected text/block: native scrolling.
- Stationary two-second hold: UIKit long-press candidate for reorder; JS resolves source and selected group. Recognition and final lift are not confirmed until physically checked.
- Normal typing, caret placement, and deletion: unaffected by drag's global editability state or pending-transfer veto (both removed).
- Cancel/failure: the drag cannot globally switch editing off; transfer response timeout clears pending ownership.

## Safeguards and verification
Before editing, backed up the prior local source files under `/Users/asteriasmoons/Desktop/Vellix/.selection_drag_recovery_20261123_125330`.
JavaScript syntax extraction + Node syntax validation and Swift parser validation passed before the final small hardening adjustments; repeat syntax verification afterward.
No iPhone physical gesture validation or full iOS build is claimed here. Verify restored selection first and then the two-second hold, using automatically exposed `[Penned Drag]` logs if needed.
Do not reintroduce the prior global edit lock, transaction veto, native selection scroll gate, or drag-controlled selection authorization.
