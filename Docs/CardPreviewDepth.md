# Dimensional Card Preview Artwork

## Cause and Scope

The real Pages snapshot path displayed a `CGImage` in a plain rounded rectangle. That bypassed the existing `NestedPageThumbnail.drawCardSheet` paper artwork, which already draws curved edges, stacked leaves, lighting, and thickness for style samples. Open Page was also two flat rounded rectangles with a straight seam; its snapshot surfaces had no curved leaf silhouette. A drop shadow alone did not supply the missing paper depth.

This change addresses the native card-preview artwork for Pages, Sticky Note, and Open Page. It does not change document rendering, content, pagination, persistence, or card dimensions. The existing real snapshots remain the content source.

## Appearance

- **Pages:** real snapshots now use the original Canvas paper face rather than a bare image rectangle. Thin lower leaves remain visible, the face retains its slight edge curvature, and directional edge lighting is painted above the actual snapshot so the image cannot cover the depth treatment. Snapshot content remains top-aligned and title-free.
- **Open Page:** the left/right sheets use mirrored curved silhouettes, dipping toward the binding at the top and lifting toward it along the bottom. Two thin underlying leaves give the lower edge thickness. A broad, soft page-roll highlight transitions into a dark recessed gutter instead of the previous straight highlighted rule. Separate contact and lifted shadows reinforce the paper volume. Both distinct snapshots are retained; the book is not replaced by a decorative empty object.
- **Sticky Note:** the existing yellow paper, tape, tilt, and rounded lifted corner remain. A thin underside is visible below the note, the curl has a stronger light/shadow transition, the tape has a subtle contact shadow, and restrained surface lighting sits above the transparent content capture.

The treatments are resolution-independent SwiftUI/Canvas artwork around the existing bitmap snapshots. There is no animated 3D scene, external asset, new WebView, timer, or additional snapshot pass. Existing fixed card sizes, placements, side-by-side sizing, clipping, selection, opening, and editing controls are unchanged.

## Rendering and Caching

`NestedPageThumbnail` accepts an optional `snapshot` for its existing card-sheet face. When supplied, it skips schematic content layout/cover loading, draws the real image, and reapplies paper lighting. This does not turn real document content back into placeholder bars. Other callers retain their previous behavior because the new input defaults to `nil`.

`card-paper-depth-v1` is included in the existing conditional card-preview cache revision. Rendered card/library snapshots containing these treatments therefore regenerate instead of reusing flat cached artwork. Existing bounded caches, recursion guards, native fallback, idle WebKit upgrade, and parent dependency invalidation remain in place. No database, attachment, or document is deleted or reset.

## Files Changed

| File | Change |
| --- | --- |
| `Vellix/Editor/NestedPageThumbnail.swift` | Optional actual snapshot input; reuse existing layered card paper; shared lighting painted after snapshot content. |
| `Vellix/Editor/PageCardView.swift` | Route real Pages miniatures through that original paper renderer. |
| `Vellix/Editor/OpenPagePreview.swift` | Mirrored curved leaves, underlying paper thickness, page-roll lighting, recessed binding, and layered shadows. |
| `Vellix/Editor/StickyNotePagePreview.swift` | Lifted underside/corner lighting, paper-edge bevel, and tape/contact shadows. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Conditional artwork cache revision for cards and their containing document previews. |
| `Docs/CardPreviewDepth.md` | Explain cause, visual treatment, changed files, and validation boundary. |
| `Docs/OpenPageCards.md` | Link the curved/depth treatment and supersede the earlier flat sheet description. |
| `Docs/PageCardSnapshots.md` | Record that real snapshots retain the original dimensional paper face. |
| `Docs/StickyNoteCards.md` | Record the stronger native paper/curl depth treatment. |

## Validation Boundary

No builds, tests, simulators, launches, linters, screenshot automation, or automated verification commands were run. The result has not been visually verified on a device.

This is native-only: no `npm run build`, generated editor-bundle edit, or deployment is required for this correction. The existing public-reader artwork was intentionally left unchanged; this addresses the native cards shown in the supplied screenshots. On-device checks remain for light/dark and photo-backed cards, each card size, real snapshot readability, the Open Page gutter/curved silhouette, and the sticky-note curl.
