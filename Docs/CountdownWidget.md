# Countdown Document Widget

## Current Shared Layout

See [Shared Document Widget Layout](WidgetLayoutSystem.md) for the current
192-point frame, top-aligned header, expanding tile rows, shared preview sizing, and delegation to
the icon-callout renderer. That report supersedes the original content-driven
sizing described below. Targets, unit arithmetic, settings, and persistence are
unchanged; long titles/messages are bounded visually, not discarded.

## Entry Points

**Add Block > Widgets > Countdown**, or the slash menu's **Countdown** entry.
This is a persistent, selectable `countdown` document block, not a separate app
calendar, a template-only component or an image of a timer. A newly inserted
widget stores a target instant one day ahead; it does not recalculate that target
when reopening the document.

## Settings and Display

- Optional icon from Penned's existing icon library, Photos, or Files; the default
  is the existing `clockwavy` asset. Icon visibility, icon color, and original-color
  mode are independent settings. See **Icon Sources and Custom Images** below.
- Custom title and target date/time, with independent visibility controls for
  icon, title and target-date display. The stored target is an ISO-8601 absolute
  instant, displayed in the current device's locale/time zone.
- Independent Months, Weeks, Days, Hours and Minutes toggles. There are no
  seconds tiles, seconds settings or per-second display refreshes. Disabled
  larger units roll into enabled smaller units rather than hiding elapsed time.
- A custom completion message replaces the countdown tiles after completion
  when count-up is disabled. With count-up enabled, the message can remain while
  the enabled time units show elapsed time since the target. An empty completion
  message is allowed. Hiding target-date display does not disable the clock.
- Half/full size. Adjacent half-size widgets share the existing two-column block
  layout, including mixed Mood Bar/Countdown pairs. Full-size widgets span the row.
- Balanced time-unit rows: half size allows at most three tiles per row; four
  units form two plus two, five form three plus two. Full size supports up to
  five units per row. Every row divides its available width equally.
- Large black-weight rounded numbers, smaller unit labels, and number sizing
  based on the tile's available space and digit count, not viewport font scaling.
- The icon/title/target-date header starts at the existing top inset. Tile rows
  divide all height left after the actual visible header, completion message,
  and gaps. Rows have equal heights; hiding header fields or enabling fewer unit
  rows redistributes the space rather than leaving a centered compact group.
- Tile padding, number size, unit-label size, and number/label spacing respond
  to each tile's actual width and height. Full and half widths retain their
  existing balanced unit grouping, settings, and 192-point outer frame.
- Appearance controls: background, border color/thickness, icon color, title
  color, number color, unit-label color and time-tile background color.

## Customization and Selection

Long-press the widget's content/settings surface for approximately 550 ms, or
select the whole block and use the existing `settingswavy` button beside Style
on the selection toolbar. The contextual button follows existing rules: no button
for mixed block types, and no arbitrary choice between multiple widget instances.

Both Countdown and Mood Bar use `document-widgets.js` for settings holds. It
prevents focus/compatibility-mouse defaults on the reserved settings surface,
consumes its clicks before generic gap insertion, cancels moved/released holds,
and blurs/clears editor-owned native caret ranges before requesting settings.
Widget node views also stop normal-mode focus/edit events on their outer padding
from reaching ProseMirror, while preserving drag/drop event passthrough.
Vertical panning remains a normal scroll path. Existing swipe selection, upward
and downward range selection, block deletion and drag/reorder logic are reused;
no new global gesture recognizer or selection engine was introduced.

The native settings sheet uses the existing icon picker and sheet chrome,
including keyboard dismiss, Done and Close. Changes remain a local draft while
typing/editing controls. Done applies one attribute transaction; Close cancels
the draft. The save validates block identity and original settings so a stale
sheet cannot silently overwrite changed settings. Requests are restricted to the
owning active editor and cleared on document changes/deactivation.

## Icon Sources and Custom Images

The icon controls follow the existing Icon Callout import/storage/rendering
architecture rather than creating a new photo store:

- **Icon Library** opens `VellixIconLibraryPicker`. Choosing a library icon
  replaces any custom image on this widget without changing the other settings.
- **Photo Library** uses `PhotosPicker`, restricted to images.
- **Choose File** uses the existing image-only file importer and
  `CustomCalloutIconImage.readFile`, including security-scoped file access.
- Either import control can replace an existing image. **Remove Custom Image**
  clears this widget's image reference and returns to its retained library icon.
  **Show Icon** can hide either source without discarding it.
- **Keep Original Colors** works for both library artwork and custom images.
  Imported images initially use original colors. Choosing an **Icon Color**
  turns original-color mode off and applies that color to the active source.
  The chosen tint remains saved when switching original colors on and off.
- Existing Countdown blocks retain their previous tinted appearance: missing
  `originalIconColors` defaults to `false`, and missing `imagePath` defaults to
  `null`. Existing title, target, unit, size, completion and appearance settings
  keep their existing defaults and behavior.

Image reading/preparation and attachment import run off the main actor. Like
Icon Callouts, input is limited to 20 MB, orientation-corrected, bounded to a
288-pixel longest edge, and encoded as a browser-compatible PNG. Countdown opts
out of the shared helper's optional outer-hairline cleanup so imported artwork's
alpha/silhouette is not intentionally stripped. Existing Callout imports keep
their previous default cleanup behavior.

Recoloring is a display operation, not a destructive edit of the imported file.
The live editor and WebKit preview HTML reuse `iconCalloutGlyph` and
`iconCalloutImage` with standalone rasterized output. Library images use the
existing `vellix-icon` tint/original-color route. Tinted uploaded images use the
existing authorized file handler's `preview=icon&tint=...` variant, generated by
the callout image tinting helper without modifying the attachment. Countdown
does not depend on callout-only CSS masks or callout DOM hydration. Native previews use
SwiftUI original/template image rendering. All paths fit the image proportionally
inside its icon area, retaining transparent areas and aspect ratio; no forced
square stretching, opaque background, or contrasting outline is added. An opaque
photo naturally has an opaque rectangular silhouette when tinted; original-color
mode restores the photo's colors.

### Saving, Sync, and Image Availability

Image bytes remain only in the sheet's draft until **Done**. Close discards the
draft. Done uses `DocumentEditorModel.saveCountdown` and the same scoped
`AttachmentRepository.importData` path as Icon Callouts, writing an immutable,
UUID-named PNG attachment owned by the active document. The widget stores only
its `imagePath`, tint, and `originalIconColors` attributes, not base64 image data,
Photos identifiers, external file URLs, or security-scoped bookmarks.

The model pins the persistent operation, rechecks the owning request after an
asynchronous import, refreshes the editor's authorized attachment records, and
commits the block settings with the existing identity/original-settings check.
The command returns a canonical document snapshot; the model saves that snapshot
through `saveCurrentContent` before dismissing the sheet. The session also checks
its load generation after the bridge call so an old response cannot be applied
to a new document load.

`EditorAttachment.paths` and JavaScript's `containsAttachments` now include
Countdown image paths. These connect to the existing attachment resolution,
native clipboard handling, nested transfers, duplication/template path remapping,
and active-content protection mechanisms. Attachment database rows continue
through the existing CloudKit attachment/asset synchronization; no sync schema,
record format, ownership rule, or new storage system was introduced.

The existing `setAttachments` failed-image retry also recognizes Countdown roots.
If pasted content first requests an image before its native attachment capability
is available, resolution refreshes the image source while preserving the icon
preview and tint parameters. Existing callouts also refresh their alpha mask.
This extends the existing Callout recovery path, not a new timer or retry loop.

Replacing/removing an image changes its reference, not the old attachment file.
Previous files are not eagerly deleted, preserving the existing undo/history and
shared-attachment behavior. Runtime synchronization, undo, and clipboard results
still require device verification.

### Preview Coverage

- The settings preview renders pending imports immediately from the prepared
  image, and existing imports through the Space-checked attachment lookup.
- Immediate document-body and template-gallery previews resolve the same stored
  attachment and honor original/tinted colors in both widget sizes.
- Miniature/nested-page thumbnails load through the existing `CardImageLoader`
  cache and aspect-fit the original/template image.
- WebKit preview/snapshot rendering uses the same Countdown extension, serialized
  settings, attachment URL scheme, and Callout image/mask helper as the editor.
  Export attachment collection already recognizes `imagePath` generically.
- Existing preview PNG storage, keys, validation, pruning, generation scheduling,
  and old-preview-until-replacement behavior are unchanged. Remote attachment bytes
  still depend on the existing sync/download pipeline being available.

## Time Calculation and Performance

The editor uses built-in Date/Intl facilities with explicit calendar-month
clamping and calendar-day advancement. Months are not approximated as 30 days;
weeks contain seven calendar days. Remaining hours/minutes use elapsed time,
including time-zone/daylight-saving effects. Native previews use Foundation's
Gregorian Calendar date-component calculation in the current time zone.

The live node view derives its displayed values from the stored target and the
current clock. Its next refresh is scheduled for a minute-value boundary or the
target transition; it does not run a seconds display loop. Ordinary ticks update
number text in place and retain the header/icon. Appearance/visibility/completion
transitions rebuild only the widget's own contents. Hidden-document timers pause,
visibility restoration recalculates from real time, and node destruction clears
timers and listeners. Tile-relative CSS handles resize typography automatically,
including serialized previews, so the old Countdown text-fitting ResizeObserver
and its layout reads are no longer needed. Digit-count metadata updates alongside
the displayed number to keep long values fitted without rebuilding the icon.

Clock refreshes do not dispatch document transactions, request snapshots, write
the database, or trigger autosave/CloudKit changes. Only actual settings changes
use the existing update/save pipeline. Settings text fields do not send full
document updates on each keystroke. Existing preview PNGs remain captured images,
not per-minute regenerated files; no preview keys, pruning, persistence or
generation connections were changed.

### Countdown-Only Fill Layout Follow-Up

The previous compact layout vertically centered the content group and limited
tile rows to 38-44 points. That left unused space despite the correct outer size.
The editor now pins the header/message to the top and uses equal flexible rows
with no fixed tile-height cap. Each tile is a size-query container; both saved
HTML and the live node view use the same proportional padding/typography rules.

Native `CountdownWidgetPreview` lets SwiftUI measure the visible header and
message, then divides the remaining GeometryReader height evenly between rows,
subtracting only the existing inter-row gaps. `CountdownUnitTile` applies the
same width/height/digit-count fitting factors as WebKit. Settings, body previews,
template previews, and miniature Canvas symbols already use this native view.
One row fills the remaining area; two rows split it equally; a hidden header
reserves no header space. With no active unit tiles (disabled units or completion
without count-up), only the configured header/message appears at the top; the
layout does not invent hidden units or extra content to fill that state.

Number sizing is bounded at 52 points and unit labels at 15 points, with further
fitting for narrow/short tiles and long values. This changes presentation only:
the clock, settings attributes, icon rendering, settings gestures, selection,
undo, and saving paths are unchanged. Calculator, Mood Bar, shared dimensions,
widths, and shared spacing were not edited for this follow-up.

Files for this follow-up: `penned-editor/src/countdown-widget.js`, its shipping
`VellixEditor.bundle/countdown-widget.js` copy, `CountdownSettings.swift`, this
document, and the Countdown sections in `WidgetLayoutSystem.md`. Validation is
static source/resource comparison and diff review only; no builds, compilation
checks, tests, app launches, or browser sessions were run. Actual device layout
still needs confirmation. Existing cached PNGs remain until normal regeneration.

## Persistence and Integration

Each widget stores its own settings and persistent block ID in document JSON.
The schema is atomic and selectable, so existing block copy/paste, identity
deduplication, nested block movement, explicit deletion, undo and autosave apply.
HTML serialization includes canonical settings for restoration. Older app
versions without the new schema should not edit documents containing this node.

Immediate document-body previews, template-gallery previews and miniature
thumbnails include both full/half sizing and Countdown's selected visibility,
colors and time units. WebKit document rendering uses the same bundled schema.

## Files

- `penned-editor/src/countdown-widget.js`: schema, settings validation, calendar
  decomposition, balanced rows, serialized HTML, live node view and guarded save.
- `penned-editor/src/document-widgets.js`: shared nonediting customization hold
  and widget-scoped interaction styles; used by Mood Bar and Countdown only.
- `penned-editor/src/mood-bar.js`: shared widget sizing/hold integration and
  independent slider-thumb colors.
- `penned-editor/src/editor.js`: schema registration, IDs/indent, slash entry,
  non-focusing insertion, settings command and contextual selection settings.
- `penned-editor/src/block-actions.js`: exclude widget settings surfaces from
  the older generic block-action hold, without changing other block eligibility.
- `penned-editor/src/tiptap.html`, `esbuild.mjs`, shipping `tiptap.html`, widget
  resources and `tiptap.bundle.js`: dependency order, future resource copying,
  existing half-width grid support and synchronized narrow native-bundle changes.
- `Vellix/Editor/CountdownSettings.swift`: native settings/request models,
  local-draft sheet, three icon sources, original/tint mode, import preparation,
  native icon/preview rendering and time decomposition.
- `IconCalloutSettings.swift`: optional hairline-cleanup argument on the reused
  image-preparation helper; existing Callout behavior remains the default.
- `MoodBarSettings.swift`: additional Mood Bar settings and shared half-size check.
- `TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`, `DocumentEditorView.swift`:
  active-editor request guards, safe save, sheet lifecycle, Widgets menu and
  contextual settings titles. Countdown's model save imports the attachment and
  persists the returned settings snapshot. Existing selection-toolbar UI/asset
  is reused.
- `Vellix/Attachments/AttachmentMedia.swift`, `penned-editor/src/attachments.js`:
  Countdown attachment-reference detection, clipboard routing, and the existing
  late-resolution image/mask retry. Corresponding narrow changes are synchronized
  in the shipping `tiptap.bundle.js` without running a bundle build.
- `TipTapWebView.swift`: inline required widget resources before editor startup.
- `MobileBlockSelection.swift`: recognize widget content as a selectable block;
  only the normal-mode Mood Bar slider keeps its dedicated drag reservation.
- `PageCardView.swift`, `ImmediateDocumentPreview.swift`, `GalleryDocumentPreview.swift`:
  optional widget grouping and native half/full body/template previews.
- `DocumentThumbnailLayout.swift`, `NestedPageThumbnail.swift`: saved-state
  widget miniatures, paired half-width placement and bounded drawing.

## Verification Limits

Only source/diff, resource references and source/shipping synchronization were
inspected. No builds, tests, compilation checks, app launches, simulators or
device runs were performed. Physical confirmation is still required for focus
suppression, contextual settings, selection/delete/undo, copy/paste, paired layout,
all visibility combinations, long-number sizing, target completion/count-up,
month-end/DST behavior, settings conflict handling and reopen persistence.
Custom-image verification remains required for Photos/Files import/cancellation,
replacement/removal, transparent/nonsquare artwork, original/tint switching,
full/half rendering, each preview path, undo/copy/paste, and cross-device sync.
Implementation is not claimed to be runtime-verified.

## References

- [Tiptap node views](https://tiptap.dev/docs/editor/extensions/custom-extensions/node-views).
- [W3C Pointer Events](https://www.w3.org/TR/pointerevents/): pointer-default
  cancellation and touch-action are separate concerns; widget focus prevention
  is scoped to controls rather than canceling document scrolling globally.
