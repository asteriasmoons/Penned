# Divider Conversion in Selection Mode

## Selection-Exit Correction

The next screenshot showed an inactive native selection covering the preceding
callout after divider conversion and leaving block-selection mode. The new
attribute-only conversion had left the underlying ProseMirror selection
implicit. The mobile block selector restored editability on exit without
clearing an editor-owned browser selection for this new conversion path.

Divider conversion now explicitly collapses the underlying selection. An
existing unprotected collapsed text caret is retained. Otherwise, it chooses
an unprotected text position after the divider, then before it if needed,
skipping locked placeholder regions rather than allowing a caret there to
become a whole-placeholder node selection. In a document with no safe text
position, the fallback is the divider itself, never an unrelated callout.

The safe selection is established without adding a history edit before changing
divider attributes, so Undo/Redo do not restore the previous callout selection.
The editor is blurred before reading conversion positions, since blur can clean
up an unused caret slot. Its owned DOM range is cleared after conversion.

A transaction marker tells the existing mobile selection plugin to clear any
retained editor DOM range once more when this selection session closes. This
is limited to sessions that performed a divider conversion; fresh selection
sessions reset the marker. It does not suppress future taps, introduce delayed
cleanup, change callout content, or change placeholder protection/authoring.

Updated files for this correction: `../penned-editor/src/editor.js`,
`Vellix/Editor/MobileBlockSelection.swift`,
`../penned-editor/tests/divider-conversion.test.js`, and this document. Added
regression cases cover regular and template documents with an old callout node
selection, stale native DOM ranges, exit from selection mode, content integrity,
and Undo/Redo selection bookmarks. These cases were not run.

This correction needs both shared JavaScript bundle regeneration and a native
app rebuild. Neither was run here, and physical-device behavior is unverified.

## Disabled-Menu Correction

The screenshot showed a selected divider with every divider choice disabled.
The missing native integration was in
`TipTapEditorSession.handle(_:)` for `.textConversionStateChanged`: its existing
filter accepted availability only when `selectionMode == "off"`. That discarded
every new divider target during the exact block-selection context that needed
it. The earlier JavaScript-only regression coverage did not cover this Swift
state handoff.

The native session now retains divider targets during single/multi block
selection while withholding text-range tokens and text conversion targets.
Ordinary text-range availability still follows its previous path. Readiness,
loading, and read-only guards remain. Actual mode changes clear stale state;
repeated reports of the same mode do not disable an unchanged selection.

This correction changes native Swift only and requires a native app rebuild,
not another JavaScript bundle generation. It does not change any divider design
or the previously implemented editor conversion command.

The existing add-shaped Convert Selection button now includes a **Divider**
submenu in block-selection mode, using `VellixDividerStyle`'s existing choices:
Dotted Circles, Four Circles, Thin Line, and Thick Line.

The submenu is enabled when at least one selected block is a divider. With a
mixed selection, divider choices change only selected dividers; selected text
and other blocks are untouched. Selecting a containing callout does not
implicitly convert its unselected nested dividers.

## Implementation

The existing `setSelectedBlockType` bridge carries `divider:<style>` targets.
The editor handles these targets separately from text conversion, using local
`setNodeMarkup` updates instead of rebuilding the document or inserting a new
divider. Divider IDs, positions, attributes, document text-color inheritance,
and selection are preserved. Batch conversions share a single history event,
with boundaries before and after so Undo/Redo restore the previous style(s).
Choosing an already-applied style does not rewrite document content.

The existing conversion-availability payload also carries divider targets in
block-selection mode. Its cache now includes the selected-divider signature,
so changing selection without editing the document updates menu availability.
The mobile selection implementation exposes its existing indexed selected
records rather than rescanning all document blocks. Desktop availability uses
the existing selected-block DOM markers.

Ordinary text-range conversion options, text-block conversions, divider
insertion, all four divider designs (including the current 4px four-dot size),
caret behavior, and template permissions are unchanged. No schemas, migrations,
new native controls, or persistence systems were introduced.

## Files Changed

- `Vellix/Editor/TipTapEditorSession.swift`: accepts divider availability in
  block-selection mode without exposing text-range conversion state there.
- `Vellix/VellixTests/SpaceEnvironmentTests.swift`: native bridge regression
  coverage for single/multi selection, all four targets, clearing stale/empty
  state, repeated mode events, normal text conversion, and read-only rejection.
- `Vellix/Editor/TextBlockConversion.swift`: Divider submenu in the existing
  block-conversion menu, per-target enablement, and selected-divider availability.
- `Vellix/Editor/MobileBlockSelection.swift`: read-only access to indexed selected
  records for availability and conversion; existing selection ownership remains.
- `../penned-editor/src/editor.js`: divider-only bridge routing and localized,
  undoable style conversions for top-level and nested selected dividers.
- `../penned-editor/tests/divider-conversion.test.js`: mobile/desktop regression
  cases for all four styles, mixed selections, IDs/attributes, same-style no-ops,
  nested dividers, read-only behavior, save/reload, and undo/redo.
- `Docs/DividerConversion.md`: this implementation and handoff record.

## Build and Validation

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. Added tests are unexecuted, and device/menu behavior is unverified.

This feature includes shared editor JavaScript changes. Before using the new
menu in the app, run the existing `npm run build` from
`/Users/asteriasmoons/Desktop/penned-editor` to regenerate/sync the editor bundle,
then build the native app. The generated bundle was not hand-edited or rebuilt
here. Unlike the preceding HTML-only dot-size adjustment, this conversion
feature does require JavaScript bundle regeneration.
