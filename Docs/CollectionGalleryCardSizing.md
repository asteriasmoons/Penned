# Collection Gallery Card Sizing

## Cause

Gallery cards allowed their property container to grow to fit every populated field and every selected option. Multi-select values wrapped vertically without a height limit, so adding properties stretched the entire grid row into a tall card. The native saved-preview renderer also used an unbounded property layout.

## Change

- Gallery property previews now reserve a fixed single-row area, even when no values are set. Adding fields or options cannot enlarge that area or the card.
- Normal cards use a 36-pixel property region including padding; compact cards use 32 pixels. Individual values and option chips remain within that region rather than building a vertical list.
- The native saved preview clips its property area to the matching 28-point content height.
- Existing gallery columns, cover aspect ratio, title styling, card styling, action button, gallery scrolling, and property editing are unchanged.
- No field definitions or values are removed. Open the entry document to see and edit all its properties. Table and Kanban layouts are unchanged.

## Files Changed

- `penned-editor/src/tiptap.html`: bounds gallery-only property previews and multi-select chip overflow.
- `Vellix/VellixEditor.bundle/tiptap.html`: applies the identical static CSS change to the shipped editor immediately. The compiled JavaScript is unchanged.
- `Vellix/Collections/CollectionSnapshotPreview.swift`: bounds the property area in native collection gallery previews.
- `Docs/CollectionGalleryCardSizing.md`: records the cause and fix.

## Validation

No builds, tests, simulators, launches, or automated verification commands were run, as requested. The static HTML stylesheet was updated in both source and the shipped bundle; `npm run build` is not required for this change. A future editor build will retain the source CSS changes.

On-device visual checks remain: compare empty and fully populated entries, add several multi-select values, check compact/normal gallery modes, and confirm entry opening and actions still work.
