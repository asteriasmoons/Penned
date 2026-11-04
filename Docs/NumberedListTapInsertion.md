# Numbered List: Tap Below an Item and Add the Next Number

The subsequent device log exposed a different, missed case: a single numbered
paragraph containing an inline break, not an empty continuation paragraph.
See [NumberedListTrailingBreak.md](NumberedListTrailingBreak.md). The fixes
below were insufficient for that reported state and are not device-validated.

## Reported Sequence

1. Return on an empty item 4 exits the list into a paragraph. This is expected.
2. Numbered List turns that paragraph back into item 4.
3. Tapping the line below item 4 should create/select an ordinary paragraph.
4. Numbered List should turn that paragraph into item 5.

Instead, the tapped line had no number but inherited the item's indent and
numbered toolbar state. Backspacing and dismissing the keyboard worked around
it. The earlier Backspace-only changes did not address this tap-created state.

## Cause in Penned

`src/editor.js` routes whitespace taps through `insertParagraphFromEmptySurface`
to `blockGapAtPoint` and `placeCaretInSlot` in `src/caret-slots.js`.

`blockGapAtPoint` enumerated insertion boundaries from the deepest hit outward.
A `listItem` accepts multiple paragraphs, so the boundary after its last paragraph
passed the schema check. Tapping below the final item's text could therefore
create this structure:

```html
<ol>
  <!-- items 1 through 3 -->
  <li><p>item 4</p><p>unnumbered caret line</p></li>
</ol>
```

The second paragraph has no separate list marker, but it is structurally inside
item 4. The old formatting-state calculation checked only for an `orderedList`
ancestor. The button then used the ordinary list toggle on that containing item
rather than creating the next item. List/item box padding also allowed the
deepest item boundary to win over the actual boundary after the list.

This is a concrete source-level insertion-routing error matching the reported
state. Exact physical-device reproduction has not been run.

## Correction

- Item-edge whitespace is no longer an implicit insertion point inside a
  `listItem`. Genuine gaps between existing blocks inside an item remain valid.
- Ordered/bullet list and item bounds use the bottom of their last rendered
  child for gap detection. Trailing wrapper padding no longer hides the real
  insertion area after the list.
- A tap below the last item resolves to a sibling paragraph in the document or
  its existing callout/container. The existing list remains unchanged.
- A blank secondary paragraph already inside an ordered item is not presented
  as a numbered paragraph in toolbar state. Pressing Numbered List splits the
  containing item at that paragraph using a schema-checked ProseMirror
  transaction. The paragraph becomes the next numbered item, preserving its
  identity and caret, with a new item ID. This repairs the existing malformed
  location on demand without rewriting documents when they open.
- Normal first-paragraph list toggles and nonempty continuation paragraphs keep
  their existing behavior. There are no CSS caret offsets, fake markers,
  delayed selection resets, or full-document reconstruction.

## Web Research

The search did not establish an exact upstream iOS bug matching Penned's full
sequence. It did distinguish coordinate hit-testing and list structure:

- [ProseMirror's coordinate API](https://prosemirror.net/docs/ref/#view.EditorView.posAtCoords)
  returns the nearest document position, not a guarantee that a whitespace tap
  belongs inside that position's deepest ancestor. The indexed official
  reference and installed source were used; direct retrieval of the reference
  page returned HTTP 403 during this session.
- [The maintainer's gap-cursor explanation](https://discuss.prosemirror.net/t/gapcursor-within-list-item-not-working-as-expected/4110)
  clarifies that positions within and between list items have distinct semantics,
  and nearby textblocks do not necessarily get a gap cursor automatically.
- [TipTap's list toggle](https://tiptap.dev/docs/editor/api/commands/lists/toggle-list)
  operates on list structure. Its installed `toggleList.ts` calls
  `liftListItem` for the same active list type. This is not the operation needed
  to number an unnumbered secondary paragraph independently.
- The installed `prosemirror-transform` implementation provides `canSplit` and
  `Transform.split`, used here for a local item split rather than vendor edits
  or a package upgrade. Research supports the approach; Penned's own hit-test
  code supplies the specific cause.

## Files Changed

- `../penned-editor/src/caret-slots.js`: correct list/item gap geometry and
  exclude item-edge insertion while retaining genuine internal block gaps.
- `../penned-editor/src/editor.js`: distinguish blank unnumbered continuations
  in toolbar state and turn them into independent numbered items on request.
- `../penned-editor/tests/paragraph-gap-runtime.test.js`: regression cases for
  the reported Enter/re-enable/tap/number sequence in ordinary documents and
  iconless callouts; existing-continuation repair; caret/ID preservation;
  undo/redo; and genuine internal item gaps.
- `Docs/NumberedListTapInsertion.md`: this change record and research.
- `Docs/CalloutNumberedListBackspace.md`: links this correction and distinguishes
  the tap bug from the preceding Backspace work.

Editor paths are relative to the Vellix repository root. Native Swift, template
permissions, Return bindings, callout resizing/rows, stored schemas, vendor
dependencies, and existing documents were not changed.

## Validation Boundary

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. Added regression cases are unexecuted and use the real bundled editor
with controlled geometry; they are not proof of physical WebKit behavior.

The maintained JavaScript source is changed. Generated `dist` and
`Vellix/VellixEditor.bundle` were not rebuilt or hand-edited. Before testing the
app, run the project's existing `npm run build` in
`/Users/asteriasmoons/Desktop/penned-editor` to regenerate and sync those editor
assets, then build/install Penned as usual. An Xcode-only build does not regenerate
the JavaScript. Without this step the installed app will still use the old code.
