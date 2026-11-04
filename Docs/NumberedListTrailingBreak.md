# Numbered List: Blank Line Inside the Final Paragraph

## Runtime Evidence

The supplied `PENNED-LIST` record, sequence 22, shows:

- Selection path: `doc > plainCallout > orderedList > listItem > paragraph`.
- The paragraph has one child, node size 3, and caret offset 1.
- Its height is 45.53125px with a 21.28px line height and 1.5px vertical padding:
  two rendered lines, not an empty single-line paragraph.
- Native selection is `P` at child offset 1. Numbered-list ancestry is active.
- Placeholder/projection flags and placeholder authoring are all false.

This confirms that the caret is inside the final item's paragraph, not a
separate paragraph and not the secondary-paragraph case handled previously.
The one-unit inline content and two-line geometry are consistent with a single
hard break, or a literal newline. The original diagnostics did not report the
inline child type, so this record alone does not distinguish those two.

Penned's iconless-callout Return handler inserts `hardBreak` content. Numbering
that paragraph keeps its inline content, including any trailing hard break.
That trailing blank visual line therefore remains in the numbered paragraph.
The previous fixes required an empty paragraph or a gap outside its rectangle;
they did not cover this nonempty, two-line paragraph. Dismissing the keyboard
does not establish that a different bundle was used; the user confirmed the
bundle had been shipped.

## Scoped Correction

When a user explicitly taps the final blank visual line after a trailing line
break in the last paragraph of the final numbered item, the editor now moves
only that final break into a real sibling paragraph after the list. It leaves
the existing numbered item and all preceding content in place, and positions
the caret at offset zero in the new ordinary paragraph.

The tap is checked against the actual final line's geometry. A tap on the
numbered line above does not trigger it. Tables, composition, read-only mode,
block-selection mode, and protected placeholders retain their existing gates.

If the caret is already on that trailing blank line, Numbered List performs
the same local separation and numbers the new paragraph in one command chain.
The preceding item remains numbered; the new item becomes the next number.
Toolbar state distinguishes the final blank line from its numbered parent.

Both `hardBreak` nodes and trailing literal newlines are supported. Earlier
line breaks, nonfinal list items, rich text before the break, paragraph
alignment/indent, typing marks, and containing callout configuration are
preserved. Normal callout Return behavior is unchanged. This is not a blanket
replacement of soft breaks and does not rewrite documents when they open.

## Files Changed

- `../penned-editor/src/caret-slots.js`: identifies the trailing blank line and
  performs a localized break-to-sibling-paragraph transaction; handles its tap.
- `../penned-editor/src/editor.js`: integrates the tap path, toolbar state, and
  compound numbering command for this specific inline-break case.
- `../penned-editor/tests/numbered-list-trailing-line.test.js`: source-model
  cases matching the reported one-unit paragraph, hard breaks/newlines,
  ordinary documents/callouts, content/marks, undo/redo, and exclusions.
- `../penned-editor/tests/paragraph-gap-runtime.test.js`: full-editor tap and
  direct-numbering cases with a hard break in item 4, checking that item 5 is
  independent and the earlier items remain unchanged.
- `Vellix/Editor/MobileEditorInteractions.swift`: reports inline child types,
  sizes, and newline-only flags without text; serializes caret rectangle fields
  explicitly rather than sending a possibly nonenumerable DOMRect object.
- `Docs/NumberedListTrailingBreak.md`: this evidence and implementation record.
- `Docs/NumberedListTapInsertion.md` and `Docs/NumberedListDiagnostics.md`: link
  this runtime finding and describe the added diagnostic fields.

## Validation Boundary

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. Regression cases were added, not executed. This change is based on
the supplied runtime structure; successful physical-device behavior is not yet
verified. Do not treat this report as a claim of device validation.

The editor source must be regenerated with the existing `npm run build` in
`/Users/asteriasmoons/Desktop/penned-editor` before installing the app to test
the correction. The diagnostic-field update additionally needs a native Debug
build. Generated editor resources were not hand-edited or rebuilt here.
