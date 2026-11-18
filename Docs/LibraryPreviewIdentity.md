# Library preview identity and sync refresh

## What was observed

The Mac and connected iPhone had the same 26 active ordinary document IDs,
titles, bodies, and locations in a read-only database comparison. Both
inboxes were empty. The iPad library was not inspected. The Home strip on
iPhone and the Mac and iPad library browsers route opens by the tile's
document ID, not by its displayed image.

The shared preview cache could drop its WebView queue barrier on a cache
reset while a capture was still running. A later document could replace
the WebView contents during capture, leaving a tile with the wrong image.
The tile could also appear black when the capture was blank or unavailable.
Separately, the Mac gallery used changing preview heights to assign columns,
so a tile could move as its image arrived.

The Mac sync coordinator also tried to save each window's editor again
after a remote transaction committed. That second save could write old
content back or fail on a remotely deleted page before the window refreshed.

## Changes

- `Vellix/Documents/DocumentPreviewCache.swift`: Keeps the capture queue
  serialized through resets and discards canceled or superseded results.
  Uses the resolved saved record and exact revision for capture and reuse.
- `Vellix/Documents/DocumentPreviewContent.swift`: Invalidates the old
  snapshot keys and resolves page references from the same saved revision.
- `Vellix/Documents/DocumentPreviewPresentation.swift`: Rejects blank
  library bitmaps, including transparent captures, without applying that
  rule to intentionally transparent nested card surfaces.
- `Vellix/Documents/LibraryDocumentPreview.swift`: Uses the saved record
  for the shared native fallback when the library tile has no usable image.
  This covers Home, All Docs, and other consumers on iPhone, iPad, and Mac.
- `Vellix/Editor/TipTapEditorSession.swift` and
  `PennedMac/Editor/MacTipTapEditorSession.swift`: Let the capture pipeline
  verify which document finished loading on each platform.
- `PennedMac/Browser/MacDocumentBrowser.swift`: Assigns columns from the
  sorted document order, independent of late-arriving preview images.
- `Vellix/App/AppEnvironment.swift` and
  `PennedMac/Workspace/MacWindowRegistry.swift`: Flush editors before the
  import and reload after it, without another save of pre-import content.
  iPhone and iPad retain their existing single-environment import flow.

No document records, CloudKit zones, navigation targets, or editor bundle
files were modified. No build, tests, or app launch were run. The remaining
runtime check is to open the same cards from Home and All Docs on each
platform and confirm that a remote edit or deletion refreshes an open Mac
window without reverting the change. No npm build is needed.

## Home and All Docs capture verification

Serializing the renderer prevented overlapping capture jobs, but the old
check still trusted the Swift session's document ID. That ID is set before
TipTap applies the content and does not prove what is painted in the DOM.
The editor command can acknowledge the load without independently confirming
that its document transaction applied.

- `DocumentPreviewPresentation.swift`: Gives each offscreen load a unique
  block ID, using an existing text block where possible or a hidden probe
  otherwise. The saved document is never modified.
- `DocumentPreviewCache.swift`: Checks that ID in the actual editor DOM
  before measuring and on both sides of PDF capture. Discards a failed or
  interrupted renderer before the next job, so an old callback cannot affect
  a new capture. The bitmap lookup uses only the full revision key, and
  embedded card fallbacks render the same saved revision used for their key.
- `DocumentPreviewContent.swift`: Versions out previously cached bitmaps.
- `LibraryDocumentPreview.swift`: Rejects observed records from another
  document or Space and binds the displayed image to its full preview key.

Home and All Docs use the same pipeline on iPhone, iPad, and Mac. Tile
dimensions, navigation, interactive editing, and the Templates screen are
unchanged. No editor bundle rebuild is required. No builds, tests, or app
launches were run for this follow-up.
