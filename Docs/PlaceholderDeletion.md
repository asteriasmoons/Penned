# Selected Placeholder Deletion

Date: 2026-11-01

## Corrected Requirement

Placeholder Mode controls editing guidance, not whether a placeholder block may
be removed. With Placeholder Mode off, users can deliberately delete or cut
selected placeholder blocks, including as part of a larger selection or Select
All. The prior blanket deletion restriction was too strict.

Ordinary typing and paste must still not overwrite a placeholder, and an
insertion caret must not remain inside its guidance while Placeholder Mode is
off. Guidance authoring remains available with that mode enabled.

## Cause

`preservesLockedRegions` in `../penned-editor/src/structured-placeholders.js`
required every protected node to survive each content-changing transaction
unchanged. It did not distinguish deliberate block removal from editing a
placeholder's contents. Consequently, otherwise valid selection deletions were
rejected by the same guard intended to prevent accidental overwrites.

## Implementation

- Standard nonempty-selection deletion is recognized from ProseMirror deletion
  steps. A required empty paragraph left after deleting the final child is
  treated as schema repair, not typed replacement content.
- Existing selected-block and block Delete commands identify their original
  removal ranges using transaction-only metadata. This supports iOS swipe
  selection, nested blocks, context-menu Delete, and the existing desktop
  whole-document commit path without replacing their selection systems.
- A removed placeholder must fall within a selected removal range. An unselected
  placeholder must still survive unchanged. A placeholder that remains in the
  document cannot have its contents or configuration changed by this exception.
- Typing or pasting over a selected placeholder is not classified as deletion.
  Partially deleting a placeholder's internal guidance is still an edit rather
  than removal of its selected block and requires Placeholder Mode.
- Existing ProseMirror history may restore and replay whole-placeholder
  removals. No parallel history stack or persistent deletion metadata is created.
- No schema, database, saving, CloudKit, template-duplication, caret-placement,
  or document-rendering architecture is changed by this correction.

## Files Changed

- `../penned-editor/src/structured-placeholders.js`: permits intentional selected
  removals while retaining content/configuration protection for surviving nodes.
- `../penned-editor/src/editor.js`: passes existing ProseMirror step/history APIs
  and carries selected removal ranges through the existing block commit path.
- `../penned-editor/src/block-actions.js`: identifies the range removed by the
  existing block Delete action, including an emptied list wrapper.
- `Vellix/Editor/MobileBlockSelection.swift`: identifies the existing nested
  swipe-selected removal ranges; gesture handling and selection thresholds stay
  unchanged.
- `../penned-editor/tests/structured-placeholders.test.js`: selected Delete/Cut,
  Select All, complete text-range deletion, nested deletion, remaining-guidance
  integrity, overwrite prevention, and existing-history undo/redo regressions.
- `Docs/TemplateAuthoring.md` and `Docs/TemplateSelectionFix.md`: correct the
  previously documented blanket deletion restriction.
- `Docs/PlaceholderDeletion.md`: records this requirement clarification and fix.

The separate native Safari Web Inspector setting is documented in
[EditorWebInspector.md](EditorWebInspector.md).

## Verification Boundary

Source changes are implemented. Regression tests were added or updated but not
run. No builds, tests, simulators, launches, linters, or runtime verification
commands were run. Device behavior is not claimed verified.

The JavaScript editor bundle has not been regenerated. Before building Penned,
run `npm run build` in `/Users/asteriasmoons/Desktop/penned-editor` to regenerate
and copy the existing shared bundle. The native mobile selection script is
compiled from Swift by the normal Xcode build. No data migration is required.

## Manual Checks

1. With Placeholder Mode off, select a placeholder block and delete or cut it.
   Confirm it is removed without requiring Placeholder Mode.
2. Delete a mixed selection of ordinary and placeholder blocks, including nested
   placeholders, list items, and callout contents. Unselected guidance must remain.
3. Use Select All and delete. Confirm the editor retains its normal empty typing
   paragraph, not an undeletable empty placeholder.
4. Undo and redo both individual and multi-block deletions. Confirm the original
   guidance and surrounding structure are restored and removed correctly.
5. Try typing and pasting over a selected placeholder. Confirm that these do not
   overwrite guidance while Placeholder Mode is off.
6. Enable Placeholder Mode and check the existing guidance-editing workflow.
   Confirm ordinary documents created from templates still fill normally.
