# Fixed Landscape Document Covers

Document cover photos now use a stable 16:9 landscape frame, matching the
intended Daily Check In and Daily Reflection Journal screenshots. The frame
fills the document's existing content width; its height is always that width
multiplied by 9/16. For example, a 336-point-wide cover is 189 points high,
regardless of the source photo's orientation or resolution.

## Cause and Correction

`DocumentEditorView.coverView` previously applied an aspect-ratio modifier to
a `ZStack` containing the cover artwork. `StoredAttachmentImage` uses aspect
fill, so a portrait image could report a taller size through that stack instead
of remaining within the intended landscape header.

An independent transparent 16:9 surface now owns the layout. The existing
image/theme artwork is rendered as its centered overlay and clipped to the
same rounded frame. The image can no longer determine the header's height.
Portrait and square photos fill/crop within that frame rather than making the
cover vertically long; they are not stretched. The frame also stays stable
while a cover image is loading.

The original photo file, selected cover, photo credits, page width/padding,
corner radii, border, cover-to-title spacing, title styling, page background,
and editing controls are unchanged. The shared stored-image component was
deliberately not changed because it also renders other image surfaces.

## Files Changed

- `Vellix/Editor/DocumentEditorView.swift`: makes the cover's independent 16:9
  surface determine layout and places the existing artwork in its overlay.
- `Docs/DocumentCoverSizing.md`: this change record.

`LibrarySnapshotHeader` already constrains cover previews to 320x180. Collection
snapshot covers already use a ratio-owned overlay. Those preview systems,
their caches, and cover pickers were inspected and left unchanged. No changes
were made to the list fixes completed by the user, editor JavaScript, document
data, attachments, template behavior, or persistence/synchronization.

## Validation Boundary

No builds, tests, linters, launches, simulators, or runtime verification commands
were run. Actual device layout remains unverified. This is native SwiftUI only:
it requires a native app rebuild, not `npm run build` or editor bundle regeneration.
