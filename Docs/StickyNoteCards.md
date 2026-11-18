# Sticky Note Card Previews

## Experience

Card Style now offers **Pages**, **Sticky Note**, **Open Page**, and the existing **None** choice on iPhone, iPad, and Mac. Sticky Note is the second illustrated treatment, not a new card size or a replacement for Pages. The third treatment is documented in [OpenPageCards.md](OpenPageCards.md).

The note matches the supplied reference: pale yellow paper, a softly curved lower-right edge, translucent olive-colored tape across the top, a slight counterclockwise tilt, and a restrained paper shadow. Actual cards display their real document snapshot inside the note. Style-chooser samples deliberately show blank paper like the reference, not invented document content.

All existing card sizes are supported without changing their dimensions:

| Card Size | Sticky Note Placement |
| --- | --- |
| Compact | Small taped note above the compact card's title/excerpt |
| Small Landscape | Larger note rising from the bottom, clipped by the short card |
| Small Portrait | Same note placement with the taller paper face visible |
| Wide | Note entering from the lower-right edge and intentionally clipped at the card edges |
| Large | Nearly complete note on the right, leaving the existing title/excerpt on the left |

The note and its content scale with the existing proportional card/half-row layout. The existing backgrounds, photo selection/credits, title typography, size carousel, selection, opening, editing, and deletion paths are unchanged. None hides either preview treatment; turning previews on again retains the selected treatment.

## Persistence and Snapshots

- `PageCardStyle.previewStyle` stores `pages`, `stickyNote`, or `openPage` in the existing `cardStyleJSON` field.
- Decoding old styles with no new field defaults to Pages. An unrecognized preview-style value also falls back to Pages rather than discarding the card. Existing size, visibility, backdrop, colors, and photo fields are retained.
- The existing document, template-copy/import, attachment remapping, export/snapshot, and CloudKit paths already carry `cardStyleJSON`; no database migration, document schema rewrite, entitlement, or new asset catalogue is needed.
- Sticky notes use the same `DocumentPreviewCache.cardSnapshot` real-content captures, invalidation, bounded recursion, and native/WebKit fallback behavior as Pages. They do not add a renderer, observer, or per-keystroke capture pipeline.
- Existing card-style and preview cache keys already include `cardStyleJSON`, so choosing Sticky Note invalidates the relevant rendered image through the normal path.

## Published Documents

The publishing sanitizer accepts only the three known preview-style values and defaults old records to Pages. The public renderer and Penned-Site reader stylesheet support the same tape, note silhouette, and five size placements.

Public notes display only the already-approved published preview content (title, excerpt, and cover). No private native document snapshot, nested page body, or additional attachment is uploaded or exposed by this change. Native in-app notes use the full real document captures.

## Files Changed

- `Vellix/Editor/PageCardStyle.swift`: preview-style enum, persisted field, and backward-compatible decoding while retaining existing initializers/encoding.
- `Vellix/Editor/StickyNotePagePreview.swift`: shared native paper/tape/curl artwork and snapshot placement.
- `Vellix/Editor/PageCardPreviewOptions.swift`: shared Pages/Sticky Note/None selector with responsive sizing, selected state, and accessibility labels.
- `Vellix/Editor/PageCardView.swift`: chooses Pages or Sticky Note and provides reference-matched placement for every size using the existing snapshot cache.
- `Vellix/Editor/PageCardEditorSheet.swift`: adds the shared selector to iPhone/iPad card editing.
- `PennedMac/Editor/Controls/MacPageCardEditorSheet.swift`: adds the same selector to Mac card editing.
- `supabase/functions/penned-publishing/visible-content.ts`: preserves the allowlisted preview-style choice in published cards.
- `penned-editor/src/public-document.js`: emits the public sticky-note markup and size metadata without changing the native editor's card-node behavior.
- `Penned-Site/src/styles/reader.css`: published note/tape artwork and matching size-specific placement.
- `Docs/StickyNoteCards.md`: documents the feature, compatibility, and build/deployment boundary.

## Build and Deployment

No builds, tests, simulators, app launches, linters, or automated verification commands were run, as requested. No services were deployed.

- The in-app feature is native SwiftUI and is picked up by your normal Xcode build. It does not need a new npm build merely to display native sticky-note cards.
- Public-reader support also changes JavaScript. For published documents, use the existing `penned-editor` build/sync and Penned-Site build/deployment workflow, and deploy the updated `penned-publishing` function. Generated bundles were not manually edited.
- On-device visual and persistence checks remain: select Sticky Note in each size, switch back to Pages/None, save/reopen, reopen an older card, confirm real snapshots refresh after content edits, and check template copying/CloudKit on your devices.

Reader stylesheet integration follows the existing global reader CSS path described by [Astro's styling documentation](https://docs.astro.build/en/guides/styling/). Native paper/tape artwork is a SwiftUI shape, not a generated image asset.

## Content-Only Sticky Note Captures

Sticky Note previews now render the document content without the document's outer background or inner-page surface. This removes background colors/photos/patterns, the inner paper fill, and the page-surface outline from the miniature; the yellow sticky paper remains visible behind the content.

The title, divider, cover, collection properties, text and formatting, images, nested cards, tables, callouts, tags, and other body content still render. Content-block backgrounds are preserved. Fonts, text colors, content spacing, saved appearance settings, and the actual editor are not changed. Pages previews and ordinary document previews retain their existing backgrounds.

- Sticky Note requests a separate alpha-preserving content-only image instead of reusing an opaque full-page snapshot.
- Both the immediate native fallback and the cached WebKit capture omit the same two page surfaces. A full cached image is never substituted for the transparent note image.
- WebKit body/header rendering is shared with the normal preview. The transparent version is composited from that capture without loading another editor or changing document content.
- Transparent captures use a separate bounded memory-cache key. A Sticky Note-specific rendering revision invalidates earlier background-filled captures, including parent document previews containing them.
- Existing active-editor deferral, dependency ordering, recursion limits, and snapshot refresh notifications are retained.

Files changed for this refinement:

- `Vellix/Editor/PageCardView.swift`: requests the content-only snapshot only for Sticky Note.
- `Vellix/Documents/DocumentPreviewCache.swift`: distinct capture/cache variant, transparent compositing, and conditional page-surface rendering.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: optional omission of the outer and inner surfaces while retaining the content layout.
- `Vellix/App/AppEnvironment.swift`: passes the capture mode to the existing native fallback renderer.
- `Vellix/Documents/DocumentPreviewContent.swift`: invalidates old Sticky Note captures without invalidating unrelated Pages previews.
- `Docs/StickyNoteCards.md` and `Docs/PageCardSnapshots.md`: document the scope and rendering boundary.

No builds, tests, app launches, or automated verification commands were run for this refinement. It is native Swift and requires only your normal Xcode build, not a new npm build. On-device checks remain: compare Pages and Sticky Note on a themed page with a cover, nested cards, and properties; the note should retain those contents without the document background or inner paper rectangle.

## Title-Free Miniatures and Caching

Both Pages and Sticky Note miniatures now omit the document title heading and its associated divider. The main title printed on the card itself remains. Actual headings inside document content, covers, properties, body content, and the title in the open document and ordinary library previews are unchanged.

- The real WebKit-backed capture and immediate native fallback both suppress the miniature's document-title header.
- Empty headers are omitted entirely so no blank title row or orphan divider remains above the body. A cover or property section is still rendered when present.
- Pages retains its normal page surfaces. Sticky Note retains its content-only transparency.
- Both miniature variants have separate versioned cache keys, so older images containing titles cannot be reused. Parent document preview keys are also invalidated when they contain affected cards.
- Miniatures use bounded in-memory caches shared with the existing preview system: 24 MB for immediate native captures and the existing 32 MB rendered-image cache. Normal document PNG snapshots are additionally persisted on disk; the specialized title-free miniatures are memory-cached and may be regenerated after eviction or app restart.
- Cached miniatures are reused on redraw. Content, appearance/style, referenced-page updates, or cache eviction can cause regeneration. WebKit rendering still defers during active editing.

Files changed for title suppression: `Vellix/Documents/DocumentPreviewCache.swift` (header/compositor and miniature cache variants), `Vellix/Documents/ImmediateDocumentPreview.swift` (title visibility), `Vellix/App/AppEnvironment.swift` (title-free native fallback), and `Vellix/Documents/DocumentPreviewContent.swift` (preview versioning). This section and `Docs/PageCardSnapshots.md` record the change.

No builds, tests, launches, or automated verification commands were run. No new npm build is needed for this native-only refinement. Your on-device check remains: the card's outer title should remain, but neither miniature should repeat it.

## Dimensional Paper Refinement

The native note now has a visible thin underside, stronger lifted-corner lighting/shadow, directional paper-edge lighting, and a subtle tape/contact shadow. The yellow paper, tape, tilt, snapshot transparency, title suppression, dimensions, and content are unchanged. Depth lighting is applied above the snapshot so its content does not flatten the paper. See [CardPreviewDepth.md](CardPreviewDepth.md) for the changed-file list and artwork cache revision. This native-only refinement needs no npm build. No builds, tests, or device visual checks were run.
