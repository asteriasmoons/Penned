# Shared Document Widget Layout

## Scope

This refactor standardizes Mood Bar, Countdown, and Calculator dimensions and
uses the icon-callout rendering system for Countdown icons. It does not change
document opening, caret placement, selection, dragging, settings gestures,
database coordination, synchronization, or document preview caching.

## Before and Cause

- Mood Bar used fixed 80/100-point artwork areas, separate image dimensions, and
  different half/full padding. Serialized HTML differed from the live node view.
- Countdown had 78-point minimum editor tiles and a separate native
  minimum-height-plus-padding calculation. Large numbers and wrapping headers
  could make the frame grow depending on its settings.
- Calculator used 52/36-point full/half keypad rows, an at-least-44-point answer
  row, additional display padding, and independent outer spacing.
- Miniatures calculated another set of type-dependent heights. Mood/Countdown
  were drawn separately; Calculator used a hardcoded native reference width.
  These independent rules prevented mixed pairs from aligning consistently.
- Countdown constructed its own library-icon URL and native glyph rather than
  delegating the complete rendering decision to the icon-callout system.

There was also a source-level attachment readiness gap: `setAttachments` retried
an icon only when its image request was already `complete` with zero natural
width. If authorization arrived while that request was still pending, the retry
was skipped. This is a confirmed weakness in the source, not proof that it was
the sole cause of every missing icon on a physical device.

## Shared Contract

`penned-editor/src/document-widget-layout.json` is the canonical specification.
The same JSON is embedded before widget execution in shipping HTML and copied
into `VellixEditor.bundle` for native previews to read once. Native code has
matching fallback values if that small resource is unavailable.

| Property | Value |
| --- | --- |
| Full width | Available content width |
| Half width | Equal columns: `(available width - 12) / 2` |
| Outer height, either width | 192 points / CSS pixels at the editor's normal scale |
| Inner padding | 6 points inside the configured border |
| Internal spacing | 4 points; keypad/tile gaps capped at 3 points |
| Paired-widget gap | 12 points |
| Unconstrained native reference width | Full 320; half 154 |

The frame includes its border. Thicker custom borders reduce inner space rather
than increasing outer dimensions. Calculator corner-radius settings are retained;
Mood and Countdown retain their 8-point corners. No height is persisted in a
document, and no data migration is required.

`DocumentWidgetFrame` establishes native geometry and supplies actual container
metrics to its content. `document-widgets.js` applies the same border-box frame
in WebKit. Widget-scoped size containers allow internal CSS to respond to the
widget rather than the screen. The existing two-column block layout handles
pairing; the native half-widget classifier reads the shared type registry.

Future widgets should register their type in this spec and use this frame/class.
They still require their own rendering and data integration; registering a type
does not implement it automatically.

## Internal Layouts

### Countdown

- Approximately 18-22-point icons, 14-16-point titles, 9-10-point target labels,
  and reduced header gaps. Titles fit/truncate on one line instead of growing
  the frame; target labels are limited to two lines.
- The header is top-aligned. Equal flexible tile rows fill the remaining height
  after the actual visible header/message and existing gaps, without a fixed
  tile-height cap. Hiding header fields immediately returns their space to tiles.
- Tile padding and number/label spacing scale with the tile dimensions. Numbers
  are capped at 52 points and unit labels at 15, with width/height/digit fitting
  using matching rules in WebKit and native previews.
- Existing balanced unit rows remain: at most three units per half-width row
  and five per full-width row. Unit arithmetic and date calculations are unchanged.
- Completion text is limited to three visible lines, or two when count-up units
  also need space. Full titles/messages remain
  stored, available to accessibility, and editable in settings.
- One unit row fills the remaining area; two rows share it evenly. With no unit
  rows, the configured header/message remains at the top without fabricated content.
- Minute-boundary scheduling, hidden-document timers, and image retention during
  ordinary clock updates remain unchanged.

### Calculator

- A 40-point display contains compact expression and answer rows. Five keypad
  rows evenly divide the actual remaining height, with four columns retained.
- Gaps adapt to available width. Result/expression/button typography and the
  copy glyph are bounded by the display/key area. Requested font sizes remain
  saved, but rendered sizes are capped/fitted to the available space.
- Independent colors, font family/weight, borders, radius, arithmetic, repeat
  equals, errors, copy, per-widget state, sound previews, volume, and optional
  sound/haptic behavior are unchanged.

Four half-width calculator keys cannot each be 44 points wide on a narrow phone.
The common frame does not claim otherwise; physical-device touch comfort and
readability still need assessment.

### Mood Bar

- Artwork uses the available image area with contain/scaled-to-fit rendering,
  preserving transparency and aspect ratio without cropping or distortion.
- The slider retains a 44-point interaction area, with a proportional
  22-26-point track, 30-point thumb, and its independent colors.
- Live and serialized HTML now use matching artwork/track structure and spacing.
  The seven preloaded images, immediate local changes, and commit behavior remain.

## Icon-Callout Renderer Reuse

Countdown no longer constructs a separate icon URL or image mask:

1. `icon-callout.js` exposes `iconCalloutGlyph`, selecting the existing custom
   attachment renderer or library renderer. Actual callouts now delegate to it
   with the same inputs and output as before.
2. `editor.js` supplies the same `renderCalloutLibraryIcon` callback to both
   Countdown and callouts, retaining registered asset lookup, the `vellix-icon`
   scheme, and tint handling. Countdown requests its standalone image output;
   actual callouts retain their original default output.
3. Custom images use the shared `attachmentURL` and `iconCalloutImage` renderer.
   Countdown requests a real image rather than a remote CSS mask. Its tinted
   representation uses `preview=icon&tint=...` through the existing authorized
   attachment handler and `CustomCalloutIconImage.tinted` alpha-compositing helper.
   The temporary PNG is downsampled to at most 192 pixels per axis off the live
   main actor; originals are never rewritten. Original-color images are served
   unchanged. The export asset resolver supports the same variant.
4. Countdown uses callout attachment metadata, `data-callout-image`. The existing
   authorization refresh now retries newly authorized images with zero natural
   width whether the earlier request is completed or unresolved. Image and mask
   URLs refresh together, preserving existing preview/tint parameters. No polling
   or retry loop was added.
5. Native `CountdownIcon` delegates to `IconCalloutGlyph`. Size and original
   library-color options have defaults that preserve actual callout rendering.
   Settings/native previews/miniatures all use that glyph implementation.

Countdown does not receive callout container classes or callout settings buttons.
Its widget interactions remain its own. Photos/Files importing, owned attachment
storage, authorization, synchronization, replacement, and removal remain in use.

## Previews and Integrity

- Settings, `ImmediateDocumentPreview`, and `GalleryDocumentPreview` already
  use native widget views and now inherit the shared frame.
- `DocumentThumbnailLayout` uses a common quarter-scale height of 48 points.
  Existing paired placement remains in place.
- `NestedPageThumbnail` renders all widgets as native Canvas symbols at the
  actual target width, then scales uniformly into their thumbnail rectangles.
  Separate hand-drawn Mood/Countdown miniatures were removed.
- Serialized HTML and the separate WebKit preview renderer receive the same
  widget CSS/spec and icon renderer as live editor resources.
- No document JSON fields, target dates, mood values, calculator state, ownership
  checks, autosave, undo/copy/paste transactions, or attachment contracts changed.
- PNG cache keys, persistence, validation, pruning, and generation scheduling
  were not changed. Existing PNGs remain visible and can show the old layout
  until normal regeneration. This refactor does not delete them to force refresh
  or introduce gray placeholders.

## Files Changed for This Refactor

| Files | Purpose |
| --- | --- |
| `penned-editor/src/document-widget-layout.json` | Canonical dimensions, spacing, reference widths, and type registry. |
| `penned-editor/src/document-widgets.js` | Shared frame and size containment; settings binder unchanged. |
| `penned-editor/src/mood-bar.js` | Proportional artwork/track and matched serialized structure. |
| `penned-editor/src/countdown-widget.js` | Compact layout and shared callout icons. |
| `penned-editor/src/calculator-widget.js` | Compact display/keypad and fitted typography. |
| `penned-editor/src/icon-callout.js` | Shared glyph decision with optional standalone rasterized output. |
| `penned-editor/src/editor.js` | Shared library-icon callback and Countdown wiring. |
| `penned-editor/src/attachments.js` | Shared callout metadata and unresolved-image readiness coverage. |
| `penned-editor/src/tiptap.html`, `penned-editor/esbuild.mjs` | Inline config before widget execution and resource inclusion for future normal packaging. |
| `Vellix/Editor/DocumentWidgetLayout.swift` | Native frame, container metrics, specification loader. |
| `Vellix/Editor/MoodBarSettings.swift` | Shared frame and registry-based half-size classification. |
| `Vellix/Editor/CountdownSettings.swift` | Compact native content and callout glyph delegation. |
| `Vellix/Editor/CalculatorSettings.swift` | Native display/keypad fitted to common frame. |
| `Vellix/Editor/IconCalloutSettings.swift` | Backward-compatible glyph options and bounded, alpha-preserving tinted PNG helper. |
| `Vellix/Attachments/AttachmentSchemeHandler.swift` | Serve temporary tinted icon PNGs only after existing attachment authorization. |
| `Vellix/Export/DocumentExportRenderer.swift` | Resolve the same tinted icon variant in exports. |
| `Vellix/Editor/DocumentThumbnailLayout.swift` | Common miniature height. |
| `Vellix/Editor/NestedPageThumbnail.swift` | Native widget symbols instead of separate drawings. |
| `Vellix/VellixEditor.bundle/document-widget-layout.json`, `document-widgets.js`, `mood-bar.js`, `countdown-widget.js`, `calculator-widget.js` | Shipping config and widget resources. |
| `Vellix/VellixEditor.bundle/tiptap.html`, `tiptap.bundle.js` | Inline spec and narrow shared icon/attachment wiring. |
| `Docs/WidgetLayoutSystem.md`, `Docs/MoodBarWidget.md`, `Docs/CountdownWidget.md`, `Docs/CalculatorWidget.md` | Current contract and feature-document references. |

## Validation and Remaining Limits

### 192-Point Follow-Up and Missing Countdown Icon

The original 240-point shared frame was reduced by exactly 20% to 192 for both
sizes. Reference widths (154/320), two-column grouping, the 12-point paired gap,
saved customization attributes, and all interaction handlers remain unchanged.
Padding was reduced from 8 to 6 and general spacing from 6 to 4. Calculator's
display was reduced from 48 to 40, with 1-point key padding and narrower gaps to
preserve the largest practical key area within the requested height. Default
key rows are approximately 25 points tall; this is not a claim of 44-point keys
inside a 192-point, five-row calculator. Requested typefaces/weights/sizes remain
saved and are fitted at rendering time.

Countdown initially used a smaller header and 38-44-point tiles. The subsequent
Countdown-only refinement replaced that centered compact group with top-aligned
content and expanding equal rows, as described above and in
[CountdownWidget.md](CountdownWidget.md#countdown-only-fill-layout-follow-up).
The 192-point shared frame was not changed again. Mood Bar needs no new
fixed image height: its existing flexible image area responds to the reduced
frame while preserving the 44-point slider interaction area. Miniatures inherit
48-point outer heights from the same shared specification divided by four.

The previous icon refactor was incomplete. Source inspection identified these
specific dependencies:

- `tiptap.html` gives `.vellix-callout-icon-image` absolute positioning and
  `background-image: none !important`. It displays the glyph through
  `--vellix-callout-icon-mask`, whose fallback is completely transparent.
- The HTML callout layout helper sets that mask only for `.vellix-callout`
  containers with editable text. Countdown is intentionally not a callout
  container, so it never receives that mask or its containing-block setup.
- Reusing the icon DOM factory alone did not supply these missing dependencies.
  Native settings previews use SwiftUI and are not affected by those CSS rules.

Countdown now requests the shared glyph renderer's rasterized mode: a real
`img.penned-icon-callout-image`, with no inherited legacy glyph mask. For library
icons, the shared renderer uses the existing native asset/tint URL directly.
For uploaded images, original mode serves the original image; tinted mode uses
an in-memory, alpha-preserving PNG generated by the callout's existing tint
helper. Both the live attachment handler and export resolver implement this
variant after their existing ownership/snapshot checks. The live conversion runs
on a worker and is capped at 192 pixels, with no new stored files or database
fields. Late authorization retries preserve the variant/color instead of
downgrading the request to an untinted original.

The CSS dependency is a confirmed source defect. A custom-scheme mask fetch
problem on the reported iPhone has not been independently confirmed. However,
remote masks have resource/CORS requirements and a missing or rejected mask can
hide the entire glyph, as documented in [MDN's mask-image reference](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/mask-image).
The rasterized path avoids that additional dependency instead of treating an
ordinary image load as proof that a separate mask loaded successfully. Custom
URLs still pass through [WebKit's existing scheme handler mechanism](https://developer.apple.com/documentation/webkit/wkurlschemehandler);
no permission checks or WebKit security settings were weakened.

Only static source inspection, resource comparisons, and diff/whitespace review
were performed. No builds, compilation checks, automated tests, app launches,
simulators, or browser sessions were run. Shipping resources were synchronized
mechanically with guarded single-match replacements, not rebuilt.

Actual iPhone rendering, narrow-width touch comfort, large accessibility text,
custom font/border extremes, custom-image cold loads, nested mixed pairs, export
rendering, and each preview surface remain unconfirmed at runtime. Source changes
remove separate sizing rules and reuse the requested icon system; they do not
establish that every reported physical-device issue is resolved.
