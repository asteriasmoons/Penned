# Template Editor Selection Correction

Date: 2026-11-01

Follow-up clarification: selected placeholder blocks may be deleted or cut with
Placeholder Mode off. The earlier blanket deletion restriction has been removed;
see [PlaceholderDeletion.md](PlaceholderDeletion.md).

## Required Behavior

Templates use the same selection system as ordinary documents. Text highlighting,
selection handles, block selection, and Select All must remain available.
Selecting a placeholder permits deliberately deleting or cutting its block, not
typing or pasting over its guidance. With Placeholder Mode off, an insertion
caret inside guidance and edits to a surviving placeholder's contents or
configuration remain restricted.

## Confirmed Source-Level Cause

In `../penned-editor/src/structured-placeholders.js`, `appendTransaction` calls
`guardSelection` after a selection change in a template with Placeholder Mode off.
The guard previously checked whether the selection was a `TextSelection`, but
did not distinguish an empty insertion caret from a nonempty highlighted range.
If either range endpoint was inside a protected placeholder, it replaced the
range with the previous selection or a node selection. This canceled normal
highlighting and selection-handle movement involving that region.

The same extension also installed `handleClickOn`, which called
`preventDefault()` and consumed every click on a protected placeholder. That
intercepted selection-related clicks instead of restricting only editing.

These are confirmed behavior paths in source. No device profiling or runtime
verification was performed, so this report does not establish that they were
the only causes of every selection failure on the user's device.

## Correction

- `guardSelection` now applies only to an empty `TextSelection`: an insertion
  caret. Nonempty text ranges are left intact, even when an endpoint is inside
  protected guidance.
- Removed the placeholder extension's click interception. The existing editor
  and selection handlers receive clicks normally.
- The selection correction initially left `filterTransaction` and
  `preservesLockedRegions` unchanged. The subsequent deletion clarification now
  permits selected block removal while still preventing typing, paste, and
  internal formatting changes from overwriting guidance.
- Kept the existing non-editable placeholder decorations and collapsed-caret
  restriction. Selecting a protected block does not enable editing it.
- Did not change ordinary-document filling, active placeholder authoring,
  document loading, storage, synchronization, or the shared selection architecture.

`Vellix/Editor/MobileBlockSelection.swift` was inspected but not modified. Its
gesture and block-selection updates use metadata-only transactions. The existing
placeholder transaction filter already permits transactions with no document
changes; the correction does not introduce a separate block-selection system.

## Files Changed

- `../penned-editor/src/structured-placeholders.js`: distinguish highlighted
  ranges from insertion carets and remove blanket click consumption.
- `../penned-editor/tests/structured-placeholders.test.js`: regression cases for
  range endpoints in guidance, both selection directions, selected-content edit
  protection, node selection, Select All, and absence of click interception.
- `Docs/TemplateAuthoring.md`: update the main authoring specification and link
  this correction.
- `Docs/TemplateSelectionFix.md`: record the cause, scope, and verification limits.

## Verification Status

Source changes are implemented. Regression tests were added or updated but were
not run. No builds, tests, simulators, launches, linters, or runtime verification
commands were run. Generated JavaScript bundles were not edited or regenerated.

The app uses the generated editor bundle, not these source modules directly.
Regenerate it with `npm run build` in
`/Users/asteriasmoons/Desktop/penned-editor` before building Penned in Xcode.
That pending integration step and device verification are not claimed complete.

## Manual Checks

1. In a template with Placeholder Mode off, highlight ordinary text and drag
   selection handles toward and across guidance. Confirm the range is not reset.
2. Use Select All and select individual blocks, including protected placeholders.
   Confirm the selection remains visible without granting edit permission.
3. Swipe-select one or more blocks and extend the selection through the page.
   Check nested cards and tables using their existing selection interactions.
4. Delete or cut selected placeholder blocks and confirm removal works. Undo and
   redo the operation. Separately try typing, pasting, or formatting over guidance
   and confirm surviving placeholders retain their content and configuration.
5. Edit surrounding ordinary content and verify its normal caret, typing, and
   selection behavior. Selection must not create extra blocks automatically.
6. Enable Placeholder Mode and confirm existing guidance-authoring behavior.
   Disable it and confirm a collapsed insertion caret cannot remain in guidance.
7. Use a template to create an ordinary document. Confirm its normal placeholder
   filling and selection behavior are unchanged.
