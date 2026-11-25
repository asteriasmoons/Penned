# Mood Bar Widget

## Current Shared Layout

See [Shared Document Widget Layout](WidgetLayoutSystem.md) for the current
192-point frame, proportional artwork/slider, matched serialized rendering,
and shared native/miniature preview sizing. It supersedes the original fixed
artwork dimensions below without changing mood state, settings, or interactions.

### Document Behavior

- Add through **Add Block > Widgets > Mood Bar**, or the slash menu's
  **Mood Bar** entry. This is a real `moodBar` document node, not a template-only
  component, an attachment or a separate screen.
- A thick, seven-position range control changes the displayed artwork directly
  as it moves: miserable, upset, low, neutral, content, happy, ecstatic. New bars
  start at neutral. The widget has no visible title, labels, numbers or text.
  Mood names are available to assistive technology only.
- The seven original PNGs come from their existing named asset-catalog image
  sets. No artwork was replaced, recolored, cropped or generated. All seven
  image elements load at widget creation, retain a fixed display area, and warm
  their decode on load so changing mood switches already-requested artwork.
- Long-press the artwork area for approximately 550 ms to customize the widget.
  The native settings sheet has live background, bar and border color controls,
  slider-button color, slider-button border color, half/full size, border
  thickness, a preview, Done/Close, and the existing iOS keyboard-dismiss
  button. The range control is reserved for dragging; holding it does not open
  settings. A vertical pan from the artwork cancels its hold and remains available
  to ordinary document scrolling. The block's outer border/padding remains
  separate from its controls.
- Dragging changes only the widget's local display until change/release/blur,
  when it commits a ProseMirror attribute transaction through the existing undo,
  update and autosave pipeline. Backgrounding also commits a pending choice.
  No document serialization or SwiftUI publication happens for every movement.
- Mood and appearance are stored in document JSON with a persistent block ID.
  Each widget has independent state. The block can live in compatible nested
  containers, and existing block copy/move/delete operations retain its attrs.
- Swipe the artwork or the widget's background to select the whole Mood Bar.
  Use the existing selection toolbar's Delete action to remove it. In selection
  mode, the image and slider yield their contacts to whole-block selection;
  normal mode retains slider dragging and the artwork's settings hold.
- A selected Mood Bar also exposes the existing `settingswavy` button beside
  Style on the selection toolbar. Mixed block-type selections do not expose a
  settings button. Half-size Mood Bars and Countdowns can sit side by side.

### Integration and Files

- `penned-editor/src/mood-bar.js` and matching
  `Vellix/VellixEditor.bundle/mood-bar.js`: shared node schema, validation,
  noneditable node view, seven original-color images, native range control,
  settings hold, accessible values, HTML serialization, scoped styles and
  attribute-update command. Listeners/timers are removed with the node view.
- `penned-editor/src/editor.js`: schema registration, ID/indent integration,
  slash-menu entry, insertion without opening the keyboard, settings command.
- Both `src/tiptap.html` and the shipping bundle's `tiptap.html` load the Mood
  Bar resource before editor construction. `esbuild.mjs` includes it in future
  output; the existing shipping bundle was mechanically synchronized with the
  narrow editor integration changes without running a build.
- `penned-editor/src/block-actions.js`: the new artwork control alone is excluded
  from the older generic block-actions hold, preventing it from opening a delete
  menu over the Mood Bar's own settings hold. No existing block's eligibility,
  selection calculation or drag behavior was changed.
- `Vellix/Editor/MoodBarSettings.swift`: native settings data, sheet and text-free
  static preview using the seven named catalog assets.
- `TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`, `DocumentEditorView.swift`:
  decode and guard settings requests, present only in the owning active editor,
  apply appearance changes, clear stale requests on document changes, add the
  insertion menu entry, and exclude the sheet from web-caret reveal handling.
- `TipTapWebView.swift`: inline the required Mood Bar resource along with other
  editor dependencies. The existing icon scheme has an explicit `tint=original`
  path which preserves image composition/colors at bounded display resolution.
  Its PNG results use a small memory cache; other icon rendering is unchanged.
- `ImmediateDocumentPreview.swift`, `DocumentThumbnailLayout.swift` and
  `NestedPageThumbnail.swift`: render saved mood/appearance in immediate body
  previews and miniature document thumbnails. Existing PNG persistence, keys,
  generation, validation and pruning are unchanged. Isolated WebKit renderers use
  the same bundled schema and original-color asset path.

### Interaction Boundaries and Verification

The artwork is a dedicated settings button and also a whole-widget swipe-selection
surface. Only the native range input reserves normal-mode contacts for changing
mood. In selection mode both controls yield to block selection. Reordering keeps
its existing dedicated-control exclusions. Text editing does not activate from
these controls. Existing blank-area paragraph insertion, the 1.5-second reorder
hold, range-selection math, navigation, database and CloudKit machinery are untouched.

Only source/diff/resource synchronization checks were performed. No builds,
compilation checks, tests, app launches or simulator/device runs were performed.
Touch dragging, long-press presentation, VoiceOver, undo/reopen persistence and
the final visual result still require device confirmation. Documents containing
the new node should be edited with an app version that includes this schema.

References: [Tiptap interactive node views](https://tiptap.dev/docs/editor/extensions/custom-extensions/node-views),
[Tiptap Node API](https://tiptap.dev/docs/editor/extensions/custom-extensions/create-new/node),
[W3C Pointer Events](https://www.w3.org/TR/pointerevents/).

## Widgets Submenu and Mood Bar Placement

### Before

Mood Bar was initially added under **Add Block > Other Blocks**. This was the
wrong category for the requested widget organization.

### Requested and Implemented Placement

The Add Block menu now has a separate, top-level **Widgets** submenu. Mood Bar
is inside it and is no longer listed under Other Blocks:

```text
Add Block
  Widgets
    Mood Bar
```

### Files Changed

- `Vellix/Editor/DocumentEditorView.swift`, `EditorInsertMenu.body`: add
  `Menu("Widgets")` containing the existing Mood Bar insertion button. Remove
  that button from `Menu("Other Blocks")`. The action remains
  `insertBlockAction("moodBar")`; only menu organization changed.
- `Docs/MoodBarWidget.md`: document the Mood Bar insertion path in the
  feature documentation and add this explicit menu-placement change record.

### Unchanged Behavior

Mood Bar's seven PNGs, slider interaction, long-press customization, colors,
border settings, saved state, undo/autosave, previews and slash-menu entry are
unchanged. Other Blocks retains its other entries. No other block interaction,
selection, drag-and-drop, cursor or paragraph-insertion behavior was modified
for this menu change.

### Expected Result and Verification

Users open **Add Block > Widgets > Mood Bar** to insert the existing widget.
Source inspection confirms the Widgets submenu and the removal of the old
Other Blocks entry. The scoped diff check passed. No builds, tests, compilation
checks, simulator runs or app launches were performed; device confirmation
remains outstanding.

## Whole-Block Selection and Deletion

### Cause

The Mood Bar node already declared `atom: true` and `selectable: true`, so the
existing mobile selection registry included it. However, the generic control
guard rejected gestures beginning on the artwork because it is a button. The
slider also correctly reserved normal-mode drags, leaving most of the widget's
surface unavailable for initiating whole-block selection.

### Changes

- `Vellix/Editor/MobileBlockSelection.swift`, `blockedTarget`: recognize the
  Mood Bar as a whole-block selection surface. Allow the existing swipe-selection
  handler on its artwork/background; retain the slider's contact reservation
  while selection mode is off. This exception applies only to Mood Bar.
- `penned-editor/src/mood-bar.js` and matching shipping resource: while block
  selection is active, route pointer hits through the image and slider to the
  widget container, and stop the node view from swallowing selection events.
  Keep the existing adaptive block highlight inside the widget's clipped border
  so the entire selected widget has a visible outline and veil.
- The current top-level and nested `deleteSelectedBlocks` paths already remove
  this atomic node. No new deletion command or document replacement logic was
  introduced. The existing Delete toolbar action, undo and autosave are reused.

### Expected Behavior and Validation

Swipe the image/background to select the whole widget, or tap it while already
in selection mode. The widget can also participate in the existing continuous
range selection. Delete removes the complete Mood Bar rather than changing its
mood or removing image content. Leaving selection mode restores the slider and
long-press settings interactions. No existing selection thresholds, range math,
scrolling or drag-and-drop lifecycle logic changed.

Source/diff and resource synchronization checks only. No builds, tests,
compilation checks, simulator runs or app launches were performed. Swipe
selection, the selected highlight, deletion/undo and control restoration still
need physical-device confirmation.

## Additional Settings and Nonediting Customization

Added on November 25, 2026:

- `width` persists `half` or `full`; old Mood Bars default to full size. The
  existing two-column block layout now recognizes half-size document widgets,
  including a Mood Bar and Countdown beside one another. Size is also respected
  by immediate, template-gallery and miniature document previews.
- `buttonColor` and `buttonBorderColor` customize the slider thumb independently
  from its track and widget border. Defaults preserve the prior dark thumb and
  white thumb outline. Live settings and all preview representations use them.
- The previous settings hold did not prevent initial focus/compatibility mouse
  defaults. The shared `document-widgets.js` helper now cancels those defaults
  on widget settings surfaces, consumes their ordinary/held clicks before generic
  gap insertion, prevents native selection within the noneditable widget, and
  clears only an editor-owned native range when opening settings. It does not
  cancel ordinary pan-y scrolling or change the global selection/drag engines.
  A canceled/released pending hold does not request settings or typing mode.
  Widget node views also stop normal-mode focus/edit events from reaching
  ProseMirror through the outer padding; drag/drop events still pass through.
- `settingsKind` and `requestBlockSettings` now route `moodBar` through the
  existing contextual selection-toolbar settings system, using the same target
  identity validation and existing selection-mode exit as other block settings.
  The native title mapping enables the existing asset icon without a new toolbar.

Files for this follow-up: `penned-editor/src/document-widgets.js`, `mood-bar.js`,
`editor.js`, `block-actions.js`, `tiptap.html`, and `esbuild.mjs`; their shipping
resources and narrow bundle integration; native `MoodBarSettings.swift`,
`MobileBlockSelection.swift`, `TipTapBridgeTypes.swift`, `TipTapWebView.swift`,
`PageCardView.swift`, `ImmediateDocumentPreview.swift`, `GalleryDocumentPreview.swift`,
`DocumentThumbnailLayout.swift` and `NestedPageThumbnail.swift`. Countdown's
native integration is described separately in [CountdownWidget.md](CountdownWidget.md).

Source/diff/resource checks only. No builds, tests, compilation checks, simulators
or app launches were run. The long-press focus correction and half-size layout
must still be confirmed on the physical device; they are not reported as runtime
verified. The older settings-hold implementation described earlier is superseded
by this section.
