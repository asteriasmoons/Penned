# Penned: Document Opening and Callout Fixes

## Document opening rollback

The document-opening follow-up was reverted after documents stopped opening on
the affected device. The rollback restores the previous request and readiness
handling, snapshot error handling, iPad routing, and gallery tap handling in
`AppEnvironment.swift`, `TipTapEditorSession.swift`, `PadWorkspaceModel.swift`,
`PadWorkspaceView.swift`, `DocumentBrowserView.swift`, and
`LibraryDocumentPreview.swift`. The earlier editor-readiness implementation
was left in place. The callout and selection fixes below were not reverted.

## Bold and Enter in callouts

**Before:** Plain Callout Return inserts a hard break. Two lines separated by
that break may look like two paragraphs while still belonging to one
ProseMirror text block. The formatting toolbar's caret-based mark command
treated the whole block as its target.

**Changed:** The maintained editor source, `penned-editor/src/editor.js`, limits
the caret-based mark range in a plain callout to the surrounding hard breaks.
When text is selected explicitly, the mark command acts on that selection before
restoring editor focus. The corresponding commands in the app's
[shipped JavaScript](../Vellix/VellixEditor.bundle/tiptap.bundle.js) were updated
directly.

**Expected:** Applying Bold at the caret affects the current logical line, not
the preceding line. A selection that intentionally spans multiple lines can
still format all selected text. **No Enter or Return shortcut changed.**
Existing line breaks, callout structure, and saved documents are not rewritten.

## Visible text selection

**Before:** Callout text relied on the normal WebKit selection paint, which
could be hard to see against a solid background.

**Changed:** The maintained `penned-editor/src/tiptap.html` and the
[shipped editor HTML](../Vellix/VellixEditor.bundle/tiptap.html) give selected
callout text a high-contrast background and foreground. The iPhone/iPad plugin
in [MobileBlockSelection.swift](../Vellix/Editor/MobileBlockSelection.swift)
also paints the active text range with a ProseMirror inline decoration outside
block selection mode. The highlight is visual only and is not saved as a mark.

**Expected:** Selected text is visible inside a callout without painting the
whole callout or changing its saved text color.

## Indented and nested callout sizing

**Before:** A percentage-width callout could claim the full parent width and then
add its indentation margin on top, overflowing the available space. A callout
inside a toggle already starts from a narrower content column, making the
overflow more obvious.

**Changed:** The same two editor HTML files subtract the current block's indent
from its available width and include it in the flex sizing of resizable callout
rows. The follow-up aligns an indented callout directly after a toggle to the
toggle's body inset, which is wider than the ordinary first indent. Actual
toggle children use the width of their own content column. Additional indents
and manually saved widths are retained. No content is moved into or out of a
toggle. The existing colors, icon pipeline, and corner radius remain intact.

**Expected:** A default full-width callout with one indent immediately after
a toggle lines up with both edges of full-width blocks inside that toggle.
Text wraps to the available width; manually narrowed callouts stay narrow.

## Empty block selection

**Before:** On iPhone and iPad, selection could enter a non-off mode with no
selected blocks. Some empty transitions left editing disabled or kept the
selection controls visible.

**Changed:** `MobileBlockSelection.swift` ends selection mode whenever an
active selection becomes empty, while preserving the pending swipe gesture
before a real selection is committed. Selecting an actual block can still
enter selection mode.
[DocumentEditorView.swift](../Vellix/Editor/DocumentEditorView.swift) also
requires a nonzero count before showing the selection toolbar.

**Expected:** Deselecting or removing the last selected block exits selection
mode and returns control to the editor. An empty selection cannot leave the
selection toolbar on screen.

## Scope and verification

These are the follow-up fixes to the earlier
[editor-readiness handoff](EditorReadinessHandoff.md), not a new startup
architecture. No changes were made to the PNG cache keys, persistence,
validation, pruning, or the separate preview renderer. No builds or tests were
run. The rollback, on-device highlight, and nested callout layout remain to be
confirmed on the affected device.
