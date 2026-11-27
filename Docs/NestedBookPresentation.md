# Nested Document Book Presentation

## Requested Appearance

The nested-document Book is a raised, punched-spine book rather than a flat
card. The reference's white page edges must follow the actual nested document's
paper colors. The book is also 10% shorter vertically; its width is unchanged.

## Previous Behavior

- Books used a 170-by-234-point presentation with a flat, full-size front face.
- Binding holes were translucent black circles with one thin uniform outline.
  They had no recessed rim or directional shading.
- The preview occupied 34% of the book height. A tall page image used an
  unconstrained aspect-fill layout inside that short window. It had no explicit
  width-based top-of-page drawing rectangle.
- When the cached image was unavailable, the window displayed generic bars,
  not the nested document's saved blocks.
- The book had no separate page-edge stack, cover lip, or ruled impressions
  beneath its preview and title.

Source inspection establishes those layout limitations. It does not prove why
the specific document in the screenshot had an empty-looking cached image.

## Changes

### Proportions and Preview

`PageCardStyle.bookRenderSize` is now 170 by 210.6 points: exactly 10% less height
than 234. This book-only dimension is already consumed by the native settings
preview and the editor bridge's card width/height payload. Ordinary Page, Card,
Sticky Note, and Open Page dimensions are unchanged.

The front cover reserves space within that frame for exposed page edges and
shadow. Its preview window is 28% of the front-cover height, approximately 55.6
points, instead of the old 79.6-point window. It is deliberately a short,
landscape crop rather than a stretched portrait page.

The existing `cardSnapshot` supplies the real nested-document body image,
without the cover or document-title header for Books. A
GeometryReader scales it to the window's exact width, preserves its aspect
ratio, aligns it to the top, and clips only the part below the window. It does
not center on an empty middle section or squeeze an entire page into the strip.
Content below this crop remains in the document; the Book is not a full-page
viewer.

If the image is not available, the existing `NestedPageThumbnail` renders the
actual saved JSON, colors, and supported block marks, with its cover disabled
and no document title. Generic fake text
bars were removed from the Book window. Existing preview-cache updates and
page-reference refreshes still supply the final bitmap through the same path.

### Physical Depth

- Six individually shaded paper leaves show along the right and bottom edges,
  with the bottom layers extending under the spine to the left edge. The upper
  layers remain tucked beneath the top cover overhang. There is no
  oversized backing plate behind the cover.
- By default, page leaves use the resolved nested document's real paper background colors:
  the inner page for themed documents and editor paper for plain documents.
  There is no hardcoded white paper fill.
- The front cover has a directional bevel and contact shadow. A small shadow
  follows the composited Book silhouette rather than an extra rounded plate.
- The spine keeps its saved solid, gradient, or image settings and gains a
  curved-lighting treatment and a narrow crease against the face.
- Each punched hole has a dark interior, directional rim, and lower highlight,
  producing a recessed opening instead of a flat dot.
- Thick, round-ended, softly highlighted rules sit below the preview, title and
  excerpt. Their default is off-white at 42% opacity. These are decorative cover
  impressions, not fabricated document text.
- Face/spine images have explicit surface bounds. The face also uses the
  existing supplied photo when available, including the settings preview.

Book lighting and page edges are composed inside the exported PNG's own bounds
because the editor clips its card images. Non-Book cards retain their previous
clipping and border path.

### Cached Previews

A targeted `book-presentation-v10-adaptive-description` key contribution is included only
when the document or one of its resolved children uses Book presentation. This
allows affected parent previews to regenerate with the revised book artwork.
The same key function serves record- and summary-based preview lookups.

There is no global preview-version bump, cache deletion, storage migration,
queue change, or change to retaining existing PNGs while replacements generate.
Previously rendered parent images can remain visible until the existing queue
finishes their replacement.

## Files Changed for This Request

| File | Purpose |
| --- | --- |
| `Vellix/Editor/PageCardView.swift` | Book-only cover, holes, page edges, rules, bounded content preview and saved-content fallback. Non-Book rendering is preserved. |
| `Vellix/Editor/PageCardStyle.swift` | Book-only dimensions and additive, optional `bookColors` settings. Existing records default to the current appearance. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Add the targeted Book rendering revision to affected preview keys. Preserve the existing global version. |
| `Docs/NestedBookPresentation.md` | Record the design, implementation, cache behavior and verification limits. |

## Preserved Behavior and Verification Limits

The user's completed preview-coverage work and other existing worktree changes
were left in place. The shared editor bundle, document-opening behavior,
autosave, attachment ownership and synchronization implementation are unchanged.
The subsequent Book-only settings hold is described below. Book title/excerpt
and face/spine customization continue using the existing models and helpers.

Validation is source and diff review only. No builds, compilation checks, tests,
simulators, app launches, or browser sessions were run. Physical-device visual
acceptance, the contents of the particular cached image in the screenshot, and
cache regeneration timing remain unconfirmed.

## Customization and Settings Follow-Up

### Appearance Controls

The Book settings sheet contains Face, Spine, Title, Description, Preview Border,
Cover Border, Cover Lines, Page Edges, and Edges Border. The seven color controls
support Solid or Gradient plus opacity. Face and Spine retain their existing
solid/gradient colors and image options.

Page edges default to the nested document's resolved paper colors and can now
be overridden. The title defaults to the existing automatic black/white choice,
and the description defaults to secondary grayish-white; both allow explicit
color overrides. Edges Border controls the outlines of the layered page edges
and their lower outer edge, independently of the front Cover Border and Preview
Border. There is no separate backing plate or back-cover configuration.
Binding holes, their rims, and the spine
crease keep their fixed dimensional treatment and have no user-facing settings.

The preview border is now a thin 0.85-point configurable outer rim with a
recessed inner edge. There are exactly four filled, round-ended bubbly bars,
left-aligned at 40%, 60%, 80%, and 100% of the available width. They use up to
8.5 points of thickness with 7-point gaps, scaling down vertically if necessary
to fit the remaining space. A rounded upper highlight adds volume. Their
default remains off-white at 42% opacity.
The Book remains 170 by 210.6 points; other presentations keep their dimensions.

Editable paints are stored in the child document's existing card-style JSON.
Missing paint entries resolve to the defaults, including the actual paper
colors for uncustomized page edges. The optional
dictionary requires no database migration. Existing versions ignore unknown
JSON properties; editing those settings on older versions cannot be assumed to
retain fields that those versions do not know.

There are no alignment controls in the Book settings path. iPhone/iPad Book,
surface, part-color and native color-picker sheets include the existing
`keyboardclose` header button. It uses `PennedSheetKeyboardDismissButton`,
which resigns the native first responder.

### Photos and Persistence

Face > Image > Photo Library uses the existing PhotosPicker. The uploaded image
fills and clips to the front-face surface behind its preview, title and rules,
without recoloring the spine. Pending face and spine images appear in the live
settings preview. Both are passed to `savePageCard` and use the existing owned
attachment import, database transaction and synchronization paths. No photo is
stored as a Photos-library identifier or external URL.

### Hold Ownership and Selection

Books remain the same selectable, atomic `pageReference` nodes. No new block
schema or alternate selection engine was introduced. `MobileBlockSelection`
already includes these atoms and allows swipes on their page-reference buttons.
Its range calculations, hit testing, upward/downward tracking and auto-scroll
code were not edited.

`BookPageInteractions` is a native-host WKUserScript installed on iPhone/iPad and
Mac. The bridge includes an `isBook` presentation flag, and the script marks
matching page-reference DOM surfaces. Both `preparePresentation` (initial open)
and `setPageReferences` (later updates) update those markers. A bounded DOM
observer marks newly inserted references; it does not change saved content.

In normal mode, a stationary 550 ms Book hold opens the existing native card
settings route directly. Pointer-down capture prevents the old Page actions
timer from starting. It does not cancel or stop the TouchEvents used by the
selection engine, and does not claim pointer capture or disable scrolling.
Movement beyond 10 pixels, scrolling, pointer cancellation, extra touches,
hidden/detached views and document/editability changes cancel a pending hold.

The native reorder controller's eligibility check rejects only an unselected,
editable Book settings surface as `dedicated-book-settings`. Its reorder
threshold and movement/transfer machinery are unchanged. In selection mode,
the Book hold does not replace existing selected-group reorder behavior.

A successful settings hold blurs the editor and posts `pageCardSettingsRequest`
without setting a ProseMirror NodeSelection or calling focus/paragraph insertion.
Its synthetic click is consumed, so release does not also open the child page.
Ordinary short taps continue through the original open action. The existing
iPhone/iPad native presentation checks still require an active editor; the
existing handler resigns WKWebView's editing responder before the sheet appears.
Mac forwards the same settings event with ready/editable/document checks.

This relies on the documented distinction between PointerEvents and native
panning, and cancellation when scrolling takes over; it does not suppress all
touch input to obtain hold ownership. See the [W3C Pointer Events specification](https://www.w3.org/TR/pointerevents/)
and Apple's [WKUserScript injection-time documentation](https://developer.apple.com/documentation/webkit/wkuserscriptinjectiontime).

### Diagnostics

Normal development console output uses the existing `[Penned Drag]` channel:

- `book-settings-hold-started`
- `book-settings-hold-cancelled`, including movement/scroll/cancellation reasons
- `book-settings-requested`
- `book-settings-click-suppressed`
- The existing native arm log reports `dedicated-book-settings` when reorder
  yields that unselected Book contact to its settings control.

These logs occur on gesture activity, not every SwiftUI render or keystroke.

### Additional Files Changed

| File | Purpose |
| --- | --- |
| `Vellix/Editor/BookAppearance.swift` | Persisted paint model, defaults and Book part inventory; shared surface target. |
| `Vellix/Editor/BookAppearanceControls.swift` | Shared Book color/surface rows and the solid/gradient part editor. |
| `Vellix/Editor/PageCardView.swift` | Use each saved paint, dimensional preview rim, bubbly rules and pending spine image. |
| `Vellix/Editor/PageCardEditorSheet.swift` | Scrollable Book appearance controls, live face/spine photos, no alignment controls, keyboard dismissal. |
| `Vellix/Editor/CardBackdropSheet.swift` | Optional restricted modes, opacity and keyboard dismissal; defaults preserve other callers. |
| `Vellix/Editor/CardThreeModeColorPicker.swift` | Optional Book color-picker keyboard dismissal; other callers default to their previous header. |
| `Vellix/Editor/BookPageInteractions.swift` | Scoped hold, cancellation, click consumption and Book DOM markers. |
| `Vellix/Editor/TipTapWebView.swift` | Install the Book interaction script in the native host. |
| `Vellix/Editor/PageReferencePresentation.swift` | Send the Book presentation flag with existing page payloads. |
| `Vellix/Editor/MobileBlockDragAndDrop.swift` | Book-only settings-surface eligibility exception; selection/reorder engine unchanged. |
| `Vellix/Documents/DocumentPreviewContent.swift` | Book-specific custom-paint artwork revision, without a global version bump. |
| `PennedMac/Appearance/MacCardBackdropSheet.swift` | Match the surface-binding API and solid/gradient/opacity options used by shared Book controls; preserve Mac photo/color presentation. |
| `PennedMac/Editor/Controls/MacPageCardEditorSheet.swift` | Equivalent Book controls and face/spine preview/save data in the Mac adapter. |
| `PennedMac/Editor/MacEditorPresentations.swift` | Pass spine-image data through to the existing save path. |
| `PennedMac/Editor/MacTipTapWebView.swift` | Install the same Book host behavior on Mac. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Forward Book settings requests and carry spine-image data through saving. |
| `Docs/NestedBookPresentation.md` | Update the appearance, controls, behavior, sources and verification record. |

### Verification Boundary

The user confirmed the previous raised-book presentation looked good. The new
border/rules, custom paints, Photos upload and hold interactions are implemented
but not yet confirmed on the physical device. No builds, compilation checks,
tests, simulators, app launches or browser sessions were run for this follow-up.
The JavaScript editor source and generated bundle were not changed; the Book
behavior is installed through the app's existing native-host script mechanism.

### Earlier Scope Correction: Fixed Details and Four Bubbly Bars

This correction changes only these files:

- `Vellix/Editor/BookAppearance.swift`: restrict `BookColorPart` to Preview Border,
  Cover Border, and Cover Lines. The shared settings rows on both platforms
  automatically omit the removed controls.
- `Vellix/Editor/PageCardView.swift`: restore fixed/automatic physical and text
  treatments, ignore their obsolete overrides, and draw four progressively
  longer filled capsules instead of repeated thin rules.
- `Vellix/Documents/DocumentPreviewContent.swift`: refresh only the conditional
  Book artwork revision so affected cached images can regenerate normally.
- `Docs/NestedBookPresentation.md`: correct the current configuration inventory
  and record this narrower scope.

Book dimensions, preview framing, allowed color/image controls, Photo Library
uploads, keyboard dismissal, long-press behavior and the selection engine are
unchanged by this correction. No builds or tests were run; the revised bars
remain unverified on the device.

### Restored Controls and New Edges Border

The subsequent user request explicitly restores Page Edges, Title, and
Description color settings and adds Edges Border. Those four are now included in
the shared `BookColorPart` inventory, so the existing iPhone/iPad and Mac sheet
rows expose them without another sheet implementation. They use the existing
Solid/Gradient and opacity controls and the existing per-document `bookColors`
JSON storage. Previously saved `pages`, `title`, and `description` values are
honored again. Binding holes/rims, spine crease, and a separate back-cover
configuration remain excluded.

`BookPageEdges` now receives a separate border paint for all six leaf outlines;
the same paint colors the lower outer edge. The front Cover Border and inset
Preview Border remain separate choices. Existing default title contrast,
secondary description color, and paper colors apply when there is no override.

The user confirmed the four bubbly bars are correct. This update does not touch
`BookCoverRules`; its source hash before and after the edit is identical. Bar
widths, thickness, spacing, highlights, count and layout are unchanged. Photos,
book dimensions, gestures, selection, keyboard dismissal and the API hostname
are also unchanged.

Only these files changed for this follow-up:

- `Vellix/Editor/BookAppearance.swift`: restore three paint parts and add the
  independent `edgesBorder` paint and defaults.
- `Vellix/Editor/PageCardView.swift`: apply the restored text/page paints and the
  new exposed-edge border paint in the shared renderer.
- `Vellix/Documents/DocumentPreviewContent.swift`: Book-only artwork revision
  `book-presentation-v5-page-edge-border` for normal cache regeneration.
- `Docs/NestedBookPresentation.md`: update the current controls and scope.

Source/reference and whitespace review only; no builds, compilation checks,
tests, simulators or app launches were run. The newly restored color controls
and border still require device confirmation. Existing PNGs remain eligible
for retention while normal background replacements generate.

### Corner Silhouette Cleanup

The supplied screenshot shows unwanted extra shapes at the lower-left and
upper-right corners. Source inspection found an oversized rounded backing
rectangle with its own shadow, six translated full-size leaves exposed past
the binding/top cover, and the editor's generic rectangular card-button shadow
around a Book PNG that already contains its own shading. These are matching
sources for the extra silhouettes; final visual confirmation is still pending.

The backing rectangle is removed. `BookPageEdges` clips the upper paper stack
inside the spine boundary and below the top overhang. The later bottom-width
correction described below lets bottom leaves extend under the spine. The
exposed layers retain their existing color/border controls. A small shadow is
applied after compositing the actual Book silhouette. The native host's
Book-only CSS suppresses the generic card-button box shadow; other card styles
retain their existing shadow. The gesture handlers in that script are unchanged.

Only these files changed for this correction:

- `Vellix/Editor/PageCardView.swift`: remove the backing plate, contain the page
  layers, and keep a restrained silhouette/contact shadow.
- `Vellix/Editor/BookPageInteractions.swift`: one Book-only visual CSS rule to
  suppress the duplicate rectangular host shadow; no interaction changes.
- `Vellix/Documents/DocumentPreviewContent.swift`: conditional Book revision
  `book-presentation-v6-clean-depth` for ordinary preview replacement.
- `Docs/NestedBookPresentation.md`: document the cleanup and scope.

The four bubbly lines have an identical source hash before and after this
correction. Book dimensions, preview content, user colors and settings, Photos
uploads, binding holes, selection and hold behavior remain unchanged. No global
cache clearing or separate preview-renderer changes were made. No builds,
tests, simulators or app launches were run; device confirmation remains pending.

### Full-Width Bottom Page Layers

The corner-cleanup mask also cut the bottom paper stack off at the spine
boundary. The user's next screenshot confirms that this leaves the gray bottom
layers stopping short of the Book's left side.

The mask now includes a full-width rounded bottom band. Each leaf retains its
small right/down depth offset beneath the cover's rounded silhouette. This lets
the gray pages continue beneath the pink spine instead of ending at its inner
edge, without restoring the removed backing plate or the generic card shadow.
The upper inset/top-right cleanup is preserved.

Only `Vellix/Editor/PageCardView.swift` (paper mask/alignment),
`Vellix/Documents/DocumentPreviewContent.swift` (conditional Book artwork
revision), and this document changed. Bubbly bars, Book dimensions, colors,
settings and interaction code are unchanged. The bar renderer's source hash
still matches the approved version. No builds or tests were run; final visual
confirmation remains on the device.

### Bottom Leading-Edge Correction

The first full-width-bottom change also anchored every paper leaf at zero and
grew its width with the depth offset. That unnecessarily exposed gray paper
outside the front cover's rounded lower-left corner, as the next screenshot
shows. The full-width bottom mask was needed; that extra left-alignment change
was not.

Each leaf now uses the same small right/down offset again, at the cover's width
and corner radius. Its rightmost edge and vertical depth are unchanged. The
bottom mask still reaches underneath the spine, but no longer forces every leaf
flush against the outer left boundary. The top-right cleanup is unchanged.

This correction is one rectangle-alignment line in
`Vellix/Editor/PageCardView.swift`, the conditional Book artwork revision in
`Vellix/Documents/DocumentPreviewContent.swift`, and this documentation update.
Dimensions, colors, bubbly bars, settings and interactions are unchanged. Source
and whitespace review only; no builds or tests were run. Final corner alignment
still requires device confirmation.

### Body-Only Book Preview Window

The Book previously reused the ordinary card snapshot. That image suppressed
the document title but retained its cover, so a short preview window could show
only the cover instead of the document's first content blocks.

Book captures now omit the entire document header. The canonical WebKit body
image is composed onto the existing paper surface with `headerHeight` zero.
The ordinary full library PNG still includes its cover and document title; no
cover asset, title, or document block is removed from storage. Actual headings
and images inside the document body remain visible and are not filtered out.

The native immediate fallback has a `showsDocumentHeader` option that defaults
to true; only Book card fallback requests pass false. Its collection entry
header is also omitted so it starts at the saved body. The small JSON fallback
inside the Book already passes an empty title and now disables its cover too.
The title and description printed beneath the Book's preview window remain
unchanged.

Books consistently use the pages-style snapshot branch even if converted from
a Sticky Note/Open Page or a card with its optional preview turned off. Book
presentation always draws a preview window, so its existing capture/dependency
checks now include Books independently of the old `showsPages` value. Both
record-based and summary-based dependency keys use that same predicate. This
does not change non-Book preview choices or introduce another renderer/queue.

The body-only change introduced the conditional Book artwork revision
`book-presentation-v9-body-only-preview` (subsequently advanced below). Old cover-bearing Book miniatures do
not qualify as exact-key images. Larger retained library PNGs still follow the
normal replacement behavior; there is no bulk cache deletion or pruning change.

Files changed for this request:

- `Vellix/Documents/DocumentPreviewCache.swift`: Book-only header omission and
  consistent capture style/eligibility, using the existing body render.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: optional header suppression,
  defaulting to the existing behavior for other callers.
- `Vellix/App/AppEnvironment.swift`: disable the header for the Book's native
  card fallback only.
- `Vellix/Editor/PageCardView.swift`: disable the cover in the last-resort small
  JSON fallback; exterior text and geometry are unchanged.
- `Vellix/Documents/DocumentPreviewContent.swift`: conditional Book revision and
  matching record/summary dependency handling for Book previews.
- `Docs/NestedBookPresentation.md`: document the body-only behavior and scope.

The bubbly-line source hash is unchanged. No editor bundle, selection, focus,
gesture, autosave, image-persistence or synchronization implementation changed.
Source/reference and whitespace checks only; no builds or tests were run. The
new body-only window still requires confirmation on the physical device.

### Compact Description on Wider Books - November 26, 2026

The Book's canonical image is 170 points wide and contains an 11-point description.
The editor's existing inline-card layout stretches that entire image to half the
available document width. On an iPad, this also enlarged the baked-in description:
at a displayed Book width of 340 points, the old description appeared 22 points
high. The title and other artwork scaled too; there was no independent iPad text
style responsible for the large description.

Only the description now compensates for that enlargement. Books displayed up to
196 points wide retain their existing 11-point source typography. Beyond that
width, the source description font is divided by `displayWidth / 196`, keeping
its displayed size at approximately 12.7 points instead of continuing to grow.
The 196-point threshold leaves normal portrait-phone card slots unchanged.
The description remains two lines maximum and retains its selected font and
solid/gradient color. The Book's outer width/height, title typography, preview
window, page-edge geometry, and bubbly bar construction are not changed.

The shared SwiftUI renderer uses its actual layout width when filling a card slot.
The editor cannot accomplish this with a CSS text-size override because its Book
is one native-generated PNG. The existing Book host script therefore observes
the Book's actual button width with `ResizeObserver` and requests an adjusted
image through the existing native message channel. It does not infer the size
from device model, screen width, or whether the device is an iPad.

Requests use four-point width buckets and are deduplicated by Book, source image
and width. Phone-size Books require no extra image render. For wider Books the
existing native renderer produces the same Book with compensated description
typography, at up to twice its normal raster resolution to preserve clarity.
The current image stays visible while that rendering is prepared. Image responses
must match the current Book node's request token; stale responses are ignored.
Repeated page-reference publications reapply the already prepared image rather
than generating another one. Narrowing a Book restores the normal source image.
Removed Books are unobserved, and editor destruction disconnects the observer.

The correction also handles editor width changes such as rotation or a resized
iPad workspace. It does not start or await document loading, change presentation
readiness, navigate, update document JSON, change selection, or modify any gesture
handler. The native message handlers consume only the Book image-sizing request;
the existing editor state and event paths remain unchanged.

Files changed for this adjustment:

- `Vellix/Editor/PageCardView.swift`: width-aware Book description font sizing in
  native previews and the renderer; all non-Book text remains unchanged.
- `Vellix/Editor/PageReferencePresentation.swift`: reuse the existing renderer for
  a requested Book width, validate requests against existing Book records, and
  return a tokened image-only update. Existing bridge callers retain defaults.
- `Vellix/Editor/BookPageInteractions.swift`: measure Book widths, deduplicate
  requests, apply only matching image responses, and clean up size observation.
  Its existing settings/selection/gesture behavior is unchanged.
- `Vellix/Editor/TipTapEditorSession.swift` and
  `PennedMac/Editor/MacTipTapEditorSession.swift`: forward the narrow image-sizing
  message to the shared renderer on each native editor host. No readiness,
  timeout, navigation, loading or caching condition is changed.
- `Vellix/Documents/DocumentPreviewContent.swift`: advance only the conditional
  Book artwork revision to `book-presentation-v10-adaptive-description` so native
  preview surfaces refresh without a global cache reset or PNG deletion.
- `Docs/NestedBookPresentation.md`: document the cause, compensation rule,
  image-only width handoff, and verification boundary.

Verification was limited to source/reference inspection and `git diff --check`.
No builds, tests, app launches or device checks were run. The resulting apparent
text size, resize behavior and rendering cost still need confirmation on the
physical iPad. No generated editor bundle or JavaScript editor source was changed.
