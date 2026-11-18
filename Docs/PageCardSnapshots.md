# Real Page Snapshots on Cards

## Cause

The little pages inside `PageCardView` used `NestedPageThumbnail` and `DocumentThumbnailLayout`, a Canvas-based schematic renderer. Page-reference blocks became generic container marks, not pictures of their referenced cards. This path never used Penned's real document snapshots. Separately, a page with no ordinary text received the fallback excerpt "Empty page" even when it contained page/card blocks.

## Behavior

- Actual page cards now use `DocumentPreviewCache` images, the same rendered document snapshots used by document previews. Saved miniature content is no longer drawn as placeholder bars.
- When a current WebKit snapshot is not available, the existing `ImmediateDocumentPreview` renderer supplies a cached real-content capture using the page's saved blocks, referenced documents, images, styles, and collections.
- Both immediate and template-gallery preview rendering lay out consecutive small page cards in responsive side-by-side slots, matching the editor. A page containing two cards therefore shows those two cards in its miniature.
- Card titles, backgrounds, paper shadows, dimensions, opening, editing, selection, and persisted document content are unchanged. The back decorative paper layer uses the same actual page capture; it is not a separate pagination preview.
- Synthetic sheet artwork remains only in the card-style chooser's explicit sample previews. If a capture is unavailable or recursion is cut off, actual cards use an undecorated paper surface rather than invented content.
- Pages containing nested page/card references show their referenced page titles, or an honest nested-page count if titles are unavailable, rather than "Empty page". Collections and attachments also have non-empty fallback labels. Search/plain-text persistence is unchanged.

## Refresh and Resource Handling

- Snapshot cache keys include bounded nested-card dependencies and a rendering-version bump, so old schematic snapshots are not reused as current captures.
- Saves invalidate affected page/ancestor metadata. Editor sessions compare snapshot presentation keys and regenerate only changed page-reference images, including when a real WebKit snapshot becomes available.
- Card fallback captures are cached separately with a bounded memory cost. Recursive references are guarded, and nested capture/dependency traversal is limited to three levels.
- Card presentation keys are memoized until their own content/dependencies or appearance changes; unrelated document autosaves do not repeatedly analyze and hash every linked page.
- WebKit snapshot rendering retains the existing serialized renderer and active-editing deferral. Dependencies are prepared before the parent enters that queue to avoid waiting recursively on the same renderer.
- Collection-only editor payload preparation skips nested-card snapshot dependency work.
- No attachment files, documents, or user databases are deleted or reset.

## Files Changed

- `Vellix/Editor/PageCardView.swift`: renders real snapshot images in miniature paper faces, retains sample artwork only for style samples, and shares native small-card grouping.
- `Vellix/Editor/PageReferencePresentation.swift`: supplies the cache to card image rendering and derives honest excerpts for non-text pages.
- `Vellix/Documents/DocumentPreviewCache.swift`: cached miniature captures, guarded native fallback rendering, save invalidation, dependency-first WebKit generation, and snapshot-availability refresh notifications.
- `Vellix/Documents/DocumentPreviewContent.swift`: nested-card dependency keys, appearance-sensitive keys, and snapshot rendering-version invalidation.
- `Vellix/App/AppEnvironment.swift`: wires the existing immediate renderer into the cache and routes save notifications to preview invalidation.
- `Vellix/Editor/DocumentEditorCache.swift` and
  `PennedMac/Editor/MacDocumentEditorCache.swift`: supply the shared preview cache to live editor sessions.
  The Mac adapter now declares the property assigned by `AppEnvironment` and forwards it before preparing each editor model.
- `Vellix/Editor/TipTapEditorSession.swift` and `PennedMac/Editor/MacTipTapEditorSession.swift`: cache-key-aware page-image updates and snapshot refresh observation.
- `Vellix/Documents/ImmediateDocumentPreview.swift` and `Vellix/Templates/GalleryDocumentPreview.swift`: render actual small-card groups side by side and supply their snapshot cache.
- `Vellix/Editor/DocumentEditorView.swift` and `PennedMac/Editor/MacDocumentEditorContainer.swift`: supply the same cache to native fallback cards.
- `Docs/PageCardSnapshots.md`: documents this change.

## Build and Verification

No builds, tests, simulators, launches, or automated verification commands were run, as requested. This change is native Swift and does not require a new `npm run build`; use your normal Xcode build. Previously pending web-editor source changes still need your existing editor build/sync workflow if they have not already been bundled.

On-device checks remain: open a card whose referenced page contains two cards; confirm the miniature shows their actual artwork and side-by-side layout, edit one of those pages and return, check light/dark appearances and a template preview, and confirm ordinary editor responsiveness remains unchanged.

## Sticky Note Transparency

Sticky Note uses a separate, transparent content-only variant of these captures. The outer document background and inner-page surface are omitted in both the native fallback and the WebKit compositor; actual content, including covers and content-block backgrounds, remains. Pages and normal library previews continue to use the full-page capture. See [StickyNoteCards.md](StickyNoteCards.md#content-only-sticky-note-captures) for changed files and cache behavior. No builds or tests were run for this native-only refinement.

## Title-Free Card Miniatures

Pages and Sticky Note now use dedicated captures without the document's title heading/divider. Covers, properties, body headings, and all other content remain; the card's own label and normal library/document titles are not removed. Sticky Note alone omits page surfaces. These variants have separate versioned in-memory cache keys and share existing rendering/dependency invalidation. Normal document captures still retain their titles and on-disk cache. See [StickyNoteCards.md](StickyNoteCards.md#title-free-miniatures-and-caching) for the exact changed files, cache limits, and validation boundary.

## Open Page Spreads

The third illustrated treatment, **Open Page**, uses two distinct real snapshots instead of the Pages treatment's overlapping decorative sheets. Content flows left-to-right through a fixed-height preview-only column layout; explicit page breaks advance to the next sheet. Its title-free pair has a separate bounded memory cache and uses the existing idle render queue. Uncached spreads now receive a real-content native fallback pair during active editing, using consecutive content slices or the next explicit saved sheet rather than repeating the first page. Native entries remain eligible for the idle WebKit upgrade. Both platforms' Open Page carousels use the real preview cache, and the sheet rims/fold remain visible against black backgrounds. The offscreen WebView also matches the full two-column PDF width during capture and is restored afterward. Pages and Sticky Note behavior are unchanged. See [OpenPageCards.md](OpenPageCards.md#invisible-spread-and-missing-snapshot-correction) for all changed files, publishing/privacy scope, fallback limitations, and the source-only validation boundary. No builds or tests were run for this native-only correction.

## Paper Depth Around Actual Snapshots

Real Pages snapshots now use `NestedPageThumbnail`'s original layered card-paper face rather than a plain rounded image. Snapshot content bypasses schematic layout, and paper lighting is reapplied above the image so real pixels do not flatten the sheet artwork. Open Page and Sticky Note also have stronger leaf/curl depth treatment. See [CardPreviewDepth.md](CardPreviewDepth.md) for exact changed files and cache invalidation. Snapshot content, pagination, title suppression, card sizes, and editing behavior are unchanged. No builds or tests were run; device appearance remains unverified.
