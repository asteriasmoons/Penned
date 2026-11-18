# List Grid in document previews

Saved List Grids render as two-column blocks in Home, All Docs, other library
previews, template previews, and Pages, Sticky Note, and Open Page card
snapshots. Nested-page and other small thumbnails draw the same grid with
miniature cell text. The existing preview crop still determines which blocks
are visible; a grid farther down the document does not change the crop.

The renderers use the saved colors and column split. Default, Both Filled, and
Both Outlined keep their respective cell treatments. Older header rows still
render as Both Filled when no explicit style is saved. Full-size preview
rendering uses the existing rich inline text renderer; tiny thumbnails show a
simplified version of the actual cell text.

## Files changed

- `Vellix/Documents/ListGridPreview.swift`: Shared style resolution and native
  two-column rendering with aligned cells and wrapped rich text.
- `Vellix/Documents/ImmediateDocumentPreview.swift` and
  `Vellix/Templates/GalleryDocumentPreview.swift`: Route saved grids to that
  renderer instead of falling through to stacked paragraphs.
- `Vellix/Editor/DocumentThumbnailLayout.swift` and
  `Vellix/Editor/NestedPageThumbnail.swift`: Draw grid panels, cell treatments,
  and saved text in small previews without starting another web view.
- `Vellix/Editor/TipTapContentAnalyzer.swift` and
  `Vellix/Documents/DocumentPreviewContent.swift`: Detect grids in saved content
  and version only the affected document and card preview caches.
- `Vellix/Documents/DocumentPreviewCache.swift`: Keep the native fallback
  when the bundled snapshot renderer does not expose the current List Grid
  markup.
- `Vellix/Documents/OpenPageSnapshotRenderer.swift`: Allow the snapshot-only
  grid to flow between pages and request breaks between rows, not within them.

Editor interaction, stored documents, card artwork, preview sizes, cover-only
tiles, and public publishing are unchanged. No web editor source or generated
bundle files changed. If the existing bundle already includes the current
List Grid row styles, no npm rebuild is needed for this change.

No build, tests, or app launch were run. Device rendering, including the
two-page snapshot break, remains to be checked.
