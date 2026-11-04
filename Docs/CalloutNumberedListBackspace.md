# Numbered-List Backspace and Ordinary Paragraph Exit

The later, exact Enter/re-enable-numbering/tap-below sequence is addressed in
[NumberedListTapInsertion.md](NumberedListTapInsertion.md). It identifies the
tap-gap routing error that could create a second paragraph inside the final
list item. The Backspace work below is not, by itself, a fix for that sequence.

## Screenshot Clarification

The follow-up screenshot and clarification establish that the caret should
remain on a separate line, in an ordinary paragraph after the numbered list,
not in a list-indented continuation. The problem can occur outside callouts too.
The earlier change was too narrow: it handled only callouts and joined a later
item before checking whether its blank trailing line should exit the list.

The handler now checks for an empty paragraph at the end of the final numbered
item before the callout-specific joins. It uses ProseMirror's `lift` command to
move only that paragraph out of the list structure. Existing numbered text stays
in the list above it. This also handles a blank continuation paragraph after an
item's text without moving that text or deleting its number. Keyboard Backspace
and cancelable native deletion use this same shared path, inside or outside a
callout.

The caret is mapped into the lifted paragraph at offset zero, so it no longer
inherits the list item's text-column indentation. There is no CSS translation,
fabricated caret, forced inline placement, or change to numeral rendering.
Nested lists exit to their existing containing block; callout boundaries and
side-by-side siblings remain intact. Nonempty deletion and items with following
content retain their existing paths.

The source tests now include ordinary documents, both callout types, keyboard
and native deletion, blank items and blank continuation paragraphs, nested
numbered lists, preservation of prior items, and undo/redo. Full-editor cases
also assert that the caret paragraph has no `ol` or `li` DOM ancestor.
No tests or builds were run for this follow-up either. Exact physical-device
caret geometry remains unverified; the screenshot alone does not expose its
stored document structure. Bundle regeneration described below is still pending.

## Scope

The reported caret jump happens when pressing Backspace while editing a
numbered list, not while typing digits. The shared empty-tail exit applies to
ordinary documents and callouts. The remaining boundary-join correction below
is limited to collapsed selections at the logical start of a non-code textblock
inside a callout. Both icon and iconless callouts use the same correction.

## Identified Code Path

The installed TipTap list keymap handles a list-item boundary in
`@tiptap/extension-list/src/keymap/listHelpers/handleBackspace.ts` by lifting the
list item. A subsequent Backspace in a paragraph following a list takes its
`hasListBefore()` branch, which cuts that paragraph into the previous list and
then joins forward.

`@tiptap/core/src/commands/cut.ts` explicitly resets the selection near the
inserted fragment with `new TextSelection(...Math.max(newPos - 1, 0))`. This
lift/cut/reselect cycle changes the document structure and caret location instead
of joining adjacent numbered textblocks in place. The list handler also treats
an inner paragraph at offset zero as a list boundary when its callout is nested
inside an outer list item, allowing the outer item to be targeted.

These are confirmed source-level paths that can produce unwanted movement.
Their relationship to the exact physical-device symptom has not been profiled
or runtime-verified in this change.

## Implementation

`createCalloutListBackspace` installs a narrowly scoped ProseMirror plugin at
priority 110, ahead of the default TipTap list keymap's priority 100. It handles
keyboard Backspace and cancelable native `beforeinput` events with input type
`deleteContentBackward` through the same operation.

- A blank trailing paragraph exits the numbered list using ProseMirror's `lift`
  command before considering any join. Only its wrapping list structure is
  removed; preceding numbered content and paragraph attributes are retained.
- A subsequent nonempty numbered item joins the preceding textblock using ProseMirror's
  `joinTextblockBackward`. The caret is placed at the join, not at an inferred
  DOM position or an offset from a moved fragment.
- The first numbered item uses `joinBackward` for the normal structural
  unlisting behavior, contained by the callout's existing isolating boundary.
- A paragraph immediately following a numbered list uses the same direct join
  instead of the list keymap's cut-and-reselect path.
- The standard `selectNodeBackward` fallback remains available when joining is
  not possible. An isolating boundary that cannot be changed consumes this
  Backspace rather than letting the generic list handler lift an outer item.
- Existing input-rule undo takes precedence, preserving Backspace undo of
  automatic `1. ` list creation.

The commands operate on the existing transaction model and history. No document
reconstruction, new persistence attributes, migrations, or hardcoded scroll
positions are introduced. Boundary detection walks only selection ancestors.

Normal character deletion, selected-range deletion, other list types inside a
callout, and nonempty numbered lists outside callouts retain their existing handlers.
Read-only mode, composition, active block-selection mode, modified shortcuts,
and noncancelable native input are not intercepted by this plugin.

## Files Changed

- `../penned-editor/src/callout-list-backspace.js`: keyboard/native deletion
  handler using the installed ProseMirror commands, with a shared blank-tail
  list exit before the callout-specific boundary joins.
- `../penned-editor/src/editor.js`: imports and registers the handler, passing
  the editor's existing block-selection state.
- `../penned-editor/tests/callout-list-backspace.test.js`: model-level regression
  cases for joins, first-item unlisting, native deletion, side-by-side siblings,
  outer numbered lists, paragraph-after-list joins, undo/redo, and exclusions.
- `../penned-editor/tests/callout-runtime.test.js`: adds full-editor keydown and
  native-input cases for both callout types, preserving content, marks, caret
  position, attributes, outside blocks, and undo/redo.
- `Docs/CalloutNumberedListBackspace.md`: this implementation and handoff record.

Editor source paths are relative to the Vellix repository root. Dependency
sources were read but not modified.

## Intentionally Unchanged

No template or publishing files were changed. Iconless-callout Return remains
a line break inside the callout; tapping below still provides the existing way
to write outside it. Resizing, side-by-side layout, insertion routing, colors,
fonts, nested cards, and native editing/gesture code were not modified.

## Validation and Handoff

No builds, tests, linters, launches, simulators, or runtime verification commands
were run, as requested. Added regression cases have not been executed. Source
inspection is not evidence of physical iPhone keyboard behavior.

The generated editor resources have deliberately not been rebuilt or hand-edited.
Before this source correction reaches the native editor, run the existing
`npm run build` from `/Users/asteriasmoons/Desktop/penned-editor`. Its existing
sync step updates `Vellix/VellixEditor.bundle`; an Xcode-only build does not
regenerate this JavaScript. The runtime regression file also reads `dist`, so
it needs the regenerated bundle. This generation step remains pending.

Manual checks should cover Backspace at the first, second, and empty numbered
items; an ordinary paragraph after the list; nested lists and headings within
items; icon and iconless callouts; side-by-side siblings; a callout inside an
outer numbered item; undo/redo; ordinary typing and selection deletion; and
Return/tap-below behavior. Physical iPhone/iPad WebKit behavior remains unverified.
