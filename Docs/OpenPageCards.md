# Open Page Card Previews

## Experience

Card Style offers **Pages**, **Sticky Note**, **Open Page**, and **None** on iPhone, iPad, and Mac. Open Page is the third illustrated treatment; it does not add or change card sizes.

Open Page shows two adjoining, curved portrait sheets with a recessed center binding. Thin underlying leaves, a narrow paper rim, and page-roll highlights give the spread depth even when the document and card both use black backgrounds. The spread enters from the bottom/right of the card and is clipped by the card edges, matching the supplied reference. The existing outside title/excerpt, backgrounds, photo credits, and proportional side-by-side card sizing remain unchanged.

| Size | Spread Size | Position |
| --- | --- | --- |
| Compact | 40 x 28 | 14, 12, above the compact card's label |
| Small Landscape | 188 x 131 | 31, 47, clipped at the right and bottom |
| Small Portrait | 188 x 131 | 31, 47, with more sheet height visible |
| Wide | 120 x 84 | 238, 24, at the lower-right edge |
| Large | 164 x 114 | 202, 27, beside the existing title/excerpt |

These dimensions are in the card's existing intrinsic coordinate system and scale with its normal card slot. The document title and its divider are not repeated inside either miniature. Actual body headings are still included.

## Real Content and Pagination

- The existing serialized `DocumentPreviewCache` WebView loads the saved document, resolves referenced cards/collections, and waits for fonts and images using the existing snapshot workflow.
- After the normal document snapshot, Open Page makes a separate DOM copy of that resolved content. The copy is outside ProseMirror's observed editor DOM and is never saved back to the document.
- The copy uses sequential, fixed-height CSS columns, not balanced columns. Each content column is 320 x 460 points. The miniature gets the same normal document surfaces and 20-point content inset as other full-page previews.
- The first page fills before content continues on the second. Text can fragment naturally at line boundaries; image/table-row/card-row break hints preserve those units where they fit. Content after the second page is outside this two-page preview, not removed from the document.
- A document `pageBreak` becomes a forced column break. If it occurs on the first preview page, following content starts on the right. Breaks after content has already filled the first page continue in document order; the renderer does not skip intervening content to show a later page.
- A title-free cover/properties header is included once at the start of the flow. The normal document preview still includes its title. Both miniature pages retain the document's backgrounds; Sticky Note alone remains content-only/transparent.
- One transparent PDF capture contains both content columns. The offscreen WebView is temporarily widened to 680 points, matching the two-column capture, and layout is read before capturing. Its original frame is restored on success or failure. The left and right regions are cropped separately and composited onto their own page surfaces. The right image is not a duplicate of the first image or a fake set of bars.
- The temporary copy and stylesheet are removed after capture, including error paths. The interactive editor's content, selection, caret, scrolling, undo, and saved page breaks are not changed.

Pagination uses standard [CSS multi-column fragmentation](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Multicol_layout/Handling_content_breaks). Oversized indivisible content remains subject to WebKit's fragmentation rules; complex tables, tall attachments, and callout nesting need the on-device check below.

## Caching and Editing Responsiveness

- Open Page has a separately versioned pair cache, limited to 24 entries / 16 MB. Final miniature sheets use a 1x native composition of the higher-resolution WebKit capture rather than caching two full-resolution library thumbnails for every card.
- Keys include the existing document content, appearance, card style, collection metadata, color scheme, and bounded referenced-card dependencies. An Open Page-specific rendering revision also invalidates parent snapshots when necessary.
- Existing dependency-first rendering, serialized WebView ownership, recursion limits, save invalidation, and snapshot-availability refresh notifications are reused.
- WebKit rendering still defers while an editor is active. An uncached spread now uses a cached pair rendered from real saved content by `ImmediatePreviewBlocks`, the existing native document-preview renderer. It does not wait until the parent editor closes and never duplicates the first page onto the right.
- The native fallback measures the first saved sheet and caps its content bitmap at two preview pages. Natural overflow uses the next 460-point slice. If a page break occurs before the first sheet fills, the right side starts with the following saved sheet instead. Covers/properties appear only at the beginning. Short documents leave the right side genuinely empty. This fallback is a native raster continuation, not WebKit's line-aware column fragmentation; the idle capture upgrades it using the real editor's rendering.
- Native and final captures share the bounded pair cache, but native entries are marked non-final so they cannot prevent the later WebKit upgrade. Both variants retain the existing three-level cycle/dependency guard. The native renderer retains its existing bounded-block preview behavior.
- A failed WebKit pair capture does not invalidate a successful normal document preview, suppress the real native fallback, or start a repeated retry loop. Failure is remembered for that content revision and cleared when the document/affected ancestor is saved or the cache is reset.
- Specialized pairs are memory-cached, not persisted on disk. They can be regenerated after eviction or app restart. Normal library document previews retain their existing PNG disk cache.

## Persistence and Publishing

`PageCardStyle.previewStyle` stores `openPage` in the existing `cardStyleJSON` field. Existing document persistence, template duplication/import, export rendering, and CloudKit carry that field unchanged. No database or editor-document schema migration is required. Older styles with no preview style still decode as Pages; unknown values retain the existing fallback to Pages.

The publishing sanitizer now accepts `openPage`. The public reader displays the matching two-sheet artwork and flows only the existing approved cover/excerpt across it, without repeating the title inside the spread. It does **not** receive private native snapshots, complete nested-document content, or private page-break metadata. The full real-content/page-break preview described above is the native in-app implementation. This preserves the existing selected-document publishing/privacy boundary.

## Files Changed

| File | Reason |
| --- | --- |
| `Vellix/Editor/PageCardStyle.swift` | Persist/name the third illustrated choice while retaining old-style decoding. |
| `Vellix/Editor/OpenPagePreview.swift` | Shared two-sheet/gutter artwork and distinct left/right image inputs. |
| `Vellix/Editor/PageCardPreviewOptions.swift` | Add Open Page beside Pages, Sticky Note, and None in the shared iOS/Mac selector. |
| `Vellix/Editor/PageCardView.swift` | Render Open Page in all five existing sizes using real cached pairs. |
| `Vellix/Documents/OpenPageSnapshotRenderer.swift` | Preview-only DOM flow, explicit-break handling, canvas copying, PDF capture/crops, and cleanup. |
| `Vellix/Documents/DocumentPreviewCache.swift` | Pair caching, deferred generation, failure guards, native page compositing, and snapshot presentation keys. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Open Page-specific content/dependency cache version. |
| `Vellix/Documents/ImmediateDocumentPreview.swift` | Native paired fallback using existing rich block previews, bounded layout measurement, overflow slices, and explicit saved-sheet boundaries. |
| `Vellix/App/AppEnvironment.swift` | Wire the native Open Page fallback into the existing preview service. |
| `Vellix/Editor/PageCardEditorSheet.swift` | Supply/observe the real preview cache and show the document's actual Open Page spread in the size carousel. |
| `PennedMac/Editor/Controls/MacPageCardEditorSheet.swift` | Same live Open Page carousel behavior on Mac. |
| `Vellix/Editor/DocumentEditorView.swift` | Pass the existing document-preview service into the card sheet. |
| `PennedMac/Editor/MacEditorPresentations.swift` | Pass that same service into the Mac card sheet. |
| `supabase/functions/penned-publishing/visible-content.ts` | Allowlist the new style without broadening published content. |
| `penned-editor/src/public-document.js` | Emit a title-free public spread using only the approved cover/excerpt. |
| `Penned-Site/src/styles/reader.css` | Public spread surfaces, sequential excerpt flow, and five size placements. |
| `Docs/OpenPageCards.md` | Record behavior, implementation, caching, privacy, and validation limits. |
| `Docs/PageCardSnapshots.md` | Link the new genuinely paginated treatment and explain its separate cache/fallback. |
| `Docs/StickyNoteCards.md` | Update the available styles and publishing allowlist documentation. |

The public stylesheet uses the existing global reader CSS integration described in [Astro's styling guide](https://docs.astro.build/en/guides/styling/). New shared Swift files use the Xcode project's existing synchronized source groups; no new project/target or manual generated-bundle edit is needed.

## Build and On-Device Boundary

No builds, tests, simulators, launches, linters, or automated verification commands were run. This implementation has not been visually or interactively verified on a device.

- Native Open Page selection/rendering needs your normal Xcode build. Its capture script is native Swift-owned WebKit integration; an npm build is not needed for the in-app feature.
- Public-reader JavaScript also changed. To ship the public treatment, use the existing editor build/sync and Penned-Site deployment workflow, plus deployment of the updated publishing function. No generated bundles were changed or services deployed here.
- On device: check every card size and small-card pairs; compare a short page (empty right side), long text overflowing onto the right, an early explicit page break, cover/properties, images, nested cards, formulas/tables, and callouts. Confirm no repeated miniature title, normal save/reopen/template-copy/CloudKit behavior, and that Pages/Sticky Note/None remain unchanged.

## Optional Capture Rectangle Correction

`WKPDFConfiguration.rect` is optional, while `CGPDFPage.getDrawingTransform` requires a non-optional `CGRect`. `OpenPageSnapshotRenderer.swift` now creates one non-optional `captureRect` and passes it to both APIs instead of reading the optional configuration property back. The capture dimensions, scaling, crops, and pagination are unchanged. No force unwrap was introduced.

Only `Vellix/Documents/OpenPageSnapshotRenderer.swift` and this document changed for this correction. No builds, tests, or automated verification commands were run.

## Invisible Spread and Missing Snapshot Correction

The supplied screenshots exposed two confirmed code-level omissions: `openPageSnapshots` returned no image while a parent editor was active, and both card-style carousels deliberately used `isStylePreview: true` with no preview cache. On a black document, the unfilled sheets also matched the black card exactly. Separately, the PDF capture requested 680 points while its offscreen WebView was still only 320 points wide; that viewport mismatch has been removed rather than relying on painting outside the viewport.

The native fallback, live carousel wiring, visible sheet treatment, and capture-viewport correction above address those paths. Open Page uses the actual document title/excerpt in its carousel and actual saved content inside the miniature. The Pages/Sticky Note sample-carousel behavior, static option icons, existing card sizes, editor data, active-editing WebKit deferral, and publishing rules are intentionally unchanged. Cache suffix/version 2 invalidates earlier Open Page renders, including parent document previews.

Files changed for this correction: `OpenPagePreview.swift` (sheet visibility), `PageCardView.swift` (contrasting paper rim), `DocumentPreviewCache.swift` (cached fallback/final distinction), `DocumentPreviewContent.swift` (cache revision), `ImmediateDocumentPreview.swift` (paired native rendering), `AppEnvironment.swift` (renderer injection), `OpenPageSnapshotRenderer.swift` (capture viewport), both platform `PageCardEditorSheet` files (real snapshots/observation), `DocumentEditorView.swift` and `MacEditorPresentations.swift` (service passing), plus this document and `Docs/PageCardSnapshots.md`.

No builds, tests, launches, or automated verification commands were run. This correction is native-only and does not require `npm run build`. On-device visual checks remain: reopen the Card sheet on a black/themed document, compare the carousel with the saved card, check a short document, natural overflow and an early page break, and confirm the later WebKit capture refreshes without needing to reopen the app.

## Dimensional Paper Refinement

The flat rounded sheet shapes and straight seam have been replaced with mirrored curved leaves, thin layered paper edges, page-roll lighting over the actual snapshots, and a shadowed recessed binding. The spread's original size/placement, real left/right snapshots, overflow, explicit page-break behavior, cache limits, and editor behavior are unchanged. A conditional artwork cache revision also refreshes containing document/card images. See [CardPreviewDepth.md](CardPreviewDepth.md) for the full changed-file list, all three native paper treatments, and the unverified on-device appearance boundary. No builds or tests were run.
