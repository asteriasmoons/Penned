# Safari Web Clipper

## Entry Point and Interface

Penned Web Clipper is a **separately installable iPhone/iPad companion app** in
the existing `Vellix.xcodeproj`. Its app target is `PennedWebClipper`; its bundled
Safari Web Extension remains the existing `PennedClipper` target. There is no
second Xcode project or duplicate extension implementation.

| Product | Target | Bundle identifier |
| --- | --- | --- |
| Main Penned application | `Vellix` | `im.lystaria.Vellix` |
| Penned Web Clipper companion | `PennedWebClipper` | `im.lystaria.PennedWebClipper` |
| Companion's Safari extension | `PennedClipper` | `im.lystaria.PennedWebClipper.Extension` |

Only `PennedWebClipper` embeds `PennedClipper.appex` and depends on its target.
The main `Vellix` target has neither the extension copy phase nor that dependency.
The companion also has no build dependency on Penned, GRDB, Supabase or the editor.
Both apps can be built, archived, distributed, installed and removed independently;
the main app does not need the companion installed for normal use. To import
clips into Penned, both apps must be installed on the same device.

The companion has its own `AppIcon` catalogue, Home Screen app entry, launchable
SwiftUI setup screen and shared `PennedWebClipper` scheme. Its icon/controls reuse
Penned artwork and assets. It displays the main app's connection/account and
available Space count, detects whether the `penned` URL handler is installed,
and reports missing-account/App Group errors without adding another login.

Safari enablement is read through Apple's iOS/iPadOS
`SFSafariExtensionManager.getStateOfExtension(withIdentifier:completionHandler:)`.
The Safari Extension Settings button uses
`SFSafariSettings.openExtensionsSettings(forIdentifiers:)` for this specific
extension. Failure reports a real error alongside manual Settings instructions,
never a simulated enabled status. Status refreshes on launch, foreground return,
pull to refresh and the refresh button. These Safari APIs require iOS/iPadOS
26.2; the companion and extension retain the project's iOS 26.5 deployment target.
Mac extension support is not added.

The Safari action opens an extension-owned popup over the current webpage,
using Penned's app icon, purple accent and existing wavy icon assets. It has an
editable article title, optional notes, selectable/searchable existing tags,
editable author/website metadata and the original URL. The destination picker
contains Unsorted and the selected Space's actual folders, including searchable
folder paths. **Unsorted is the default destination for every new clip**; only
the selected Space is remembered between popup sessions, not a previously chosen
folder. An explicitly chosen folder remains selected for the current clip, with
Unsorted restored if that folder is no longer available or the Space changes.
Unsorted is Penned's existing built-in folder in every Space: documents without
an assigned folder (`folderID = nil`) appear there automatically. It is present
on fresh installations even when empty, needs no user-created folder or seeded
database record, and stays available across account/library changes. The clip
importer uses the same document-creation path and nil folder ID, so articles sent
to Unsorted appear alongside other unfiled documents in that Space. No duplicate
Unsorted record or storage/sync migration is introduced.
There are no Today, Tomorrow or Tasks destinations. Space selection
is available from the popup header and from its settings screen. Switching
Spaces clears folder/tag selections rather than carrying invalid IDs across.
Settings include working System/Light/Dark appearance controls and a native
Manage Account link, not another sign-in form or browser sign-out system.

## Article Extraction

`Readability.js` is the unmodified, bundled Mozilla Readability **0.6.0** source,
with its upstream license. It runs against a clone of the active tab document
only after the user opens the clipper. No always-on content script, remote
extraction service, remotely loaded script, editor bundle or bundler is used.

The content adapter converts the extracted article DOM into structured editable
blocks: paragraphs, headings, bold/italic/underline/strikethrough/code, links,
ordered/unordered lists, task lists, quotations, images, captions, code blocks,
dividers and tables with spans. It preserves source order, including images
between segments of text, and resolves relative/lazy-loaded image URLs against
the original page. Tracking-sized images are excluded. Readability removes
article clutter; extracted HTML is parsed in a detached document and is never
injected into the webpage, popup or Penned editor. Unsupported script/form
content does not become executable document content.

The clipper reports a real extraction error when Readability cannot identify
an article. It does not silently substitute a bookmark, PDF, screenshot or the
whole website. Paywalls are not bypassed; extraction uses content available in
the current Safari DOM, not subsequent pages or unrendered application data.

## Authentication and Account Boundaries

All three targets declare `group.com.asteriasmoons.Penned`: the main Penned app,
the companion app and the companion's extension. Shared files remain in that
same App Group's `WebClipper` directory, preserving existing catalogue, queued
clips, image files and receipt data. The GRDB database and attachment store are
not moved or made writable by browser JavaScript or the companion app.

The main Penned app publishes a connection catalogue only for its active, authenticated
account and opened library. Apple sign-in and verified-email sign-in continue
through the existing Account Settings/AuthService path. The catalogue contains
destination names/IDs, small display images, icon images and an opaque local
connection generation. It contains no Apple identity token, Supabase token,
refresh token, password or Keychain item. Native owner/library identifiers are
also removed from the response returned to the popup.

Entering an account operation, signing out, changing accounts, losing an active
session or beginning a library transition invalidates the connection. The native
handler checks its connection generation, Space, folder and tag scope before
downloading and again immediately before accepting a clip. A clip started under
one account cannot finish into the next account. Previously accepted clips stay
associated with their original account/library and import only when that owner
returns. Browser preferences store only theme and a generation-scoped destination.
Pending article content is not copied into browser local storage.

When not connected, Connect to Penned opens `penned://clipper/connect`, which
presents the existing main Penned Account Settings view. The companion merely
queries this scheme in `LSApplicationQueriesSchemes`; it does not register or
take over Penned's URL scheme. The user returns to Safari
and refreshes the connection. The URL grants no access or credential itself.
Remote credential revocation is detected through Penned's existing native
authentication lifecycle, not a second extension login or background auth client.

## Durable Save and Native Import

1. The background extension accepts native requests only from extension pages,
   not tab/content scripts. The manifest requests `activeTab`, `scripting`,
   `nativeMessaging` and `storage`, without all-sites host permissions.
2. The native handler decodes a bounded, typed article tree and validates its
   block hierarchy, allowed marks, URLs, account generation and destinations.
3. Images download into private staging files using ephemeral, disk-backed
   URLSession downloads. No app credentials, shared HTTP cookies or URL cache
   accompany these requests. URLs and redirects reject local/private address
   destinations; ImageIO checks actual image type and pixel dimensions.
4. Only after all images are present does the native handler atomically move
   the complete payload/image directory into the App Group inbox. File locking
   serializes this acceptance with account invalidation and import. Failed
   downloads return an error and never report a saved clip with missing images.
5. An already-running main Penned app receives the inbox notification. Otherwise, pending
   clips import automatically when Penned next opens/returns to the foreground.
   Library changes also drain newly pending imports. Failed imports remain in
   the inbox and retry on app connection/foreground or a corrected Safari save;
   ordinary edits do not repeatedly redisplay the same failed-import alert.
   No claim is made that an iOS extension
   can arbitrarily launch or run its suspended containing app.
6. Import uses `DocumentRepository.create` and `saveEditorJSON`, the existing
   attachment store/records, and the existing inline-tag index in one GRDB
   transaction. Failure rolls back the document and removes newly copied files.
   The selected Space/folder are revalidated against the actual current library.
7. A local `webClipImports` receipt commits in that same transaction. Retrying
   after a crash between database commit and inbox acknowledgement returns the
   same document instead of creating another. Receipts survive document deletion
   with a null document ID so a stale queued delivery cannot recreate a deleted
   page. Imported inbox image copies are removed after acknowledgement.

The created page has its edited title and ordinary editable article blocks.
Immediately below the document title/divider, new clips begin with one charcoal,
rounded source card. It reuses the existing `plainCallout` block with a narrowly
scoped `clipSource` attribute (original URL, title and optional local thumbnail),
not a new document type, editor overlay or separate native storage system.

The card renders a dark, single-line thumbnail/title link, followed by editable
`Site: ` text with a bold website name, the selected real `inlineTag` nodes, and
an existing editable date property named `Saved`. The date property has a compact
purple calendar chip and a separate `at <time>` caption. Its original clipping
date/time comes from the accepted envelope, not the later import time. The chip
shows Today, Yesterday, or a localized medium date; time uses the same localized
short clock formatting as the editor's date properties. No tag paragraph is
created when no tags are chosen. Date configuration and tag editing/navigation
use the existing native property and tag flows. The source preview opens the
original URL through the existing native URL-opening bridge, without focusing a
new editing host or navigating the editor WebView away from the document.

The featured image comes from Open Graph/Twitter metadata, falling back to the
first extracted article image. It uses the same bounded, authenticated-account-
scoped native downloader and local attachment records as article images. A
separate optional featured image that cannot be downloaded does not discard the
article; an available article image is used instead. Missing images that actually
belong to the article retain the existing explicit save-error behavior.

There is no duplicate blue URL paragraph, metadata caption or tag row outside the
card. The existing `fourCircles` divider follows the source card, separating it
from the article text with Penned's four solid dots. It is an ordinary editable
divider block, not decoration baked into the source card. Optional personal notes remain editable quotations after the
article; author/source metadata also remains in the durable clip receipt without
adding an unrequested row to the card. Previously imported documents are not
rewritten or migrated.

The thumbnail is included in attachment reference tracking, so it survives
reopening, normal copy/export asset collection and CloudKit attachment delivery.
PDF/image/print use the same source-card renderer and styles in their isolated
editor. Markdown/TextBundle retain a linked title and quoted metadata fallback;
Word retains the linked preview, thumbnail and metadata in a shaded table, with
normal Word format limitations rather than claiming pixel-identical rounded CSS.
Publishing projects the source thumbnail to a manifest-backed media ID only;
the backend validates its image reference and does not expose a local file path.
The shared public renderer supports the same card and compact saved-date layout.

### Document Previews

Home and All Docs share an immediate SwiftUI preview before the isolated WebKit
snapshot is available. That fallback originally treated the new source card as a
generic callout: it omitted the thumbnail/title strip and displayed Saved as a
full-width property row. It now renders the same charcoal card, local thumbnail,
single-line title, site text, wrapping tag chips and compact saved-date line.
Small nested-page thumbnails also recognize the source-card layout and thumbnail.

A source-card-specific cache revision replaces previously generated previews for
affected documents without clearing unrelated previews. The revision includes
the current day so Today/Yesterday labels do not persist across days. The isolated
WebKit snapshot rasterizes the saved-date calendar mask to preserve its icon in
PDF-based snapshots. Until the bundled editor supports source cards, it retains
the native fallback instead of caching an inaccurate generic callout snapshot.
Preview dimensions, cropping, library navigation and live editor ownership are
unchanged. Existing documents are not rewritten to insert the new divider.

These details travel with the normal document JSON through saving, editing,
exporting and CloudKit. Article images remain Penned `attachment` nodes
referencing imported local assets, not hotlinks. Normal document/attachment sync journals handle uploads
when the account's existing Library & Sync feature is enabled. This feature
does not enable CloudKit sync or publish documents without user consent.

The popup distinguishes saving, durable queued success, completed import and
genuine errors. When the main Penned app is suspended, it explicitly says the
saved clip/images will appear when Penned next opens. Opening the companion is
not a document import: the companion only provides setup and connection status.
The native inbox remains the handoff, not a second document database. Existing
article extraction, popup, Space/folder/tag pickers, metadata, image downloads,
account scoping, GRDB import, CloudKit sync and the main app's document-loading
pipeline are unchanged by moving the extension to the companion.

## Bounds and Genuine Limitations

- Article payload: 8 MiB, 50,000 structured nodes, maximum 48 nested levels.
  Oversized input is rejected explicitly, not truncated.
- Up to 150 distinct article images, 12 MiB each, 80 MiB total and 80 million
  pixels per image. Original supported raster bytes are retained, not screenshots.
- HTTP images remain subject to Apple's App Transport Security. HTTPS is
  preferred; this implementation does not weaken the app's network policy.
- Cookie-protected, expired, unsupported/SVG or unreachable image URLs report a
  save error. The native image downloader deliberately cannot access Safari's
  website cookies. Embedded raster data URLs are supported. Signed image URLs
  work when still valid. No fabricated image placeholders are inserted.
- Extraction fidelity on highly dynamic sites depends on content being loaded
  in the tab. Videos, interactive embeds and remote application widgets are not
  converted into editable widgets. No promise of universal website extraction
  is made; the saved article is editable Penned content, not an HTML archive.
- Source metadata is retained as ordinary editable document blocks as well as
  local delivery metadata. It does not add a new editor schema or metadata UI.
- The extension reads the destination catalogue last published by the app.
  Device-local account and destination changes invalidate/recheck it; remote
  changes are incorporated when Penned performs its existing synchronization.

## Files

- `PennedClipper/ClipperShared.swift`: shared, credential-free DTOs, bounded
  structural validation, App Group protected storage and cross-process locking.
  Compiled by the extension's synchronized group and explicitly by both iOS apps;
  the companion reads its catalogue but never authenticates or imports documents.
- `PennedClipper/SafariWebExtensionHandler.swift`: real native messaging,
  account/destination validation, bounded image downloads and durable saves.
- `PennedClipper/Resources/manifest.json`: action, native messaging, active-tab
  extraction permissions, packaged Penned icon and extension CSP.
- `PennedClipper/Resources/background.js`: extension-page-only native routing
  and user-triggered active-tab extraction. Its native message identifier follows
  the extension's new companion-prefixed bundle identifier.
- `PennedClipper/Resources/content.js`: Readability adapter and semantic block
  conversion without modifying the live webpage.
- `PennedClipper/Resources/Readability.js`, `READABILITY-LICENSE.txt`,
  `READABILITY-APACHE-LICENSE.txt`: pinned upstream extraction dependency,
  attribution and full license text.
- `PennedClipper/Resources/popup.html`, `popup.css`, `popup.js`: complete clipping,
  picker, metadata, notes, tags, theme and save-state interface.
- `PennedClipper/Resources/_locales/en/messages.json`: actual extension name and
  description in place of Apple's starter strings.
- `PennedClipper/Resources/images/`: Penned app artwork and mechanically copied
  existing icon PNG data for the extension interface; no redesigned icon set.
- `Vellix/Clipper/WebClipperCoordinator.swift`: catalogue publication, inbox
  notifications, account-scoped import, real attachments/tags and receipts.
- `Vellix/Data/AppState.swift`: invalidate extension access during native account
  operations and session changes; existing authentication logic is reused.
- `Vellix/VellixApp.swift`: coordinator lifecycle/foreground handoff and Connect
  routing to existing Account Settings; existing document links remain intact.
- `Vellix/Persistence/AppDatabase.swift`: additive v30 local delivery-receipt
  migration only. Existing tables, storage location and migrations are retained.
- `PennedWebClipper/PennedWebClipperApp.swift`: the independent companion's app
  entry point, setup-screen ownership and foreground refresh.
- `PennedWebClipper/ClipperSetupModel.swift`: actual Safari enablement/settings
  APIs, installed-Penned detection, read-only App Group connection status and the
  existing native Account Settings deep link; no duplicated auth or storage.
- `PennedWebClipper/ClipperSetupView.swift`: responsive, dark Penned setup,
  connection and Safari enablement interface with real errors/instructions.
- `PennedWebClipper/Info.plist`: Penned scheme query permission and the bundled
  Safari extension's identifier, without registering Penned's scheme itself.
- `PennedWebClipper/PennedWebClipper.entitlements`: companion App Group membership.
- `PennedWebClipper/Assets.xcassets/`: dedicated Home Screen AppIcon catalogue,
  Penned logo and copied existing control assets, with no main-app resource bundle
  dependency at runtime.
- `Vellix.xcodeproj/project.pbxproj`: new companion app target/product, iPhone/iPad
  Debug/Release signing and App Group settings, source/resource membership and
  extension embedding/dependency moved from Penned to the companion. The extension
  ID now has the companion's bundle prefix, with extension-safe API enforcement.
- `Vellix.xcodeproj/xcshareddata/xcschemes/PennedWebClipper.xcscheme`: independent
  build/run/profile/archive scheme for the companion. The Penned scheme is unchanged.

The restructuring edits only the project file, new companion files/assets and
scheme, the shared contract's explanatory/error text, the native message target
in `background.js`, and this document. The main app's Swift sources, database
migration, authentication, importer, editor and synchronization are intentionally
left unchanged for this architectural correction.

## Apple Developer / Xcode Attention

1. Register the **new explicit app IDs** `im.lystaria.PennedWebClipper` and
   `im.lystaria.PennedWebClipper.Extension` under the existing developer team
   `PLRRW8XCVU`. The extension's identifier changes from the old Penned-prefixed
   `im.lystaria.Vellix.PennedClipper` because its containing app is now different.
   This is not a rename of the main Penned app ID.
2. Assign the existing `group.com.asteriasmoons.Penned` App Group to **all three**
   explicit app IDs: main Penned, companion, and new extension. Keep all three
   signed by the same developer team and refresh provisioning profiles with
   those entitlements. Source entitlement files cannot perform portal assignments.
3. Use the `PennedWebClipper` scheme to build/archive/install the separate
   companion. Create a separate App Store Connect app record for its app bundle
   ID when distributing it; its Safari extension ships inside that companion,
   not as another standalone app. Keep companion and extension marketing/build
   versions aligned for releases. Penned's own versions can change independently.
4. Use the existing `Vellix` scheme for Penned; do not re-add the extension to
   Penned's target dependencies or copy phases. Install the updated main app to
   remove its old embedded-extension registration; an already-installed older
   binary still has its old layout until you update it. Do not delete libraries
   or reset the App Group to perform this transition. Pending inbox data uses
   the same paths and is retained.
5. After installing the companion, enable its new extension identity in Settings >
   Apps > Safari > Extensions, or use the companion's Safari Extension Settings
   button. The previous extension's permissions/theme settings may not migrate
   to the new bundle identifier, so Safari may request website access again.
   Open/sign into Penned once to publish its current account catalogue.
6. The companion intentionally requests no Apple sign-in, CloudKit, Supabase or
   Keychain capabilities. Those remain in the main app. The companion requires
   only App Groups; the extension retains its existing App Group entitlement
   and Safari extension point/native handler configuration.
7. A CloudKit library syncs clips only when its existing user-controlled sync
   is enabled. No new CloudKit container, server, Supabase function, publishing
   session, Keychain access group or website deployment is required.

## Execution Boundary

### Source Card Resource Updates

The source-card changes include the extension's `content.js`/`popup.js`,
`ClipperShared.swift`, native handler/importer, `AttachmentMedia.swift`,
`TipTapContentAnalyzer.swift`, Markdown/Word/visual export integration, and the
native/server publication projections. In the sibling `penned-editor` project,
`src/clip-source.js`, `editor.js`, `inline-property-node.js`, `attachments.js`,
`tiptap.html` and `public-document.js` define the persisted rendering and styles.
No editor-loading/HTML-assembly code or iPad WebView ownership was changed.

Source-card file changes:

- `PennedClipper/Resources/content.js`: extract a featured-image/thumbnail URL without changing article block conversion.
- `PennedClipper/Resources/popup.js`: forward that optional thumbnail with the existing save request.
- `PennedClipper/ClipperShared.swift`: optional backwards-compatible thumbnail field and URL validation.
- `PennedClipper/SafariWebExtensionHandler.swift`: reuse bounded native image downloads for the optional preview, preserving article-image failures.
- `Vellix/Clipper/WebClipperCoordinator.swift`: create one source card with editable site text, actual tag IDs and the saved-date property before the article.
- `Vellix/Attachments/AttachmentMedia.swift`: include source thumbnails in normal attachment reference tracking.
- `Vellix/Editor/TipTapContentAnalyzer.swift`: include the source preview title in searchable document text.
- `Vellix/Documents/ImmediateDocumentPreview.swift`: source-card-specific native rendering for Home/All Docs and body previews.
- `Vellix/Documents/DocumentPreviewContent.swift`: invalidate affected cached source-card previews and relative date labels.
- `Vellix/Documents/DocumentPreviewCache.swift`: source-aware snapshot readiness and calendar-icon rasterization without touching the live editor.
- `Vellix/Editor/DocumentThumbnailLayout.swift`: preserve source-card structure in miniature drawing instructions.
- `Vellix/Editor/NestedPageThumbnail.swift`: draw the source-card surfaces and actual local thumbnail in small page previews.
- `Vellix/Export/DocumentMarkdownExport.swift`: meaningful linked source-card fallback for Markdown/TextBundle.
- `Vellix/Export/DocumentWordExport.swift`: shaded, linked source preview with a small embedded thumbnail and metadata.
- `Vellix/Export/DocumentExportScript.swift`: omit an emptied source tag row when export settings hide tags.
- `Vellix/Publishing/PublishingProjection.swift`: project only approved source metadata and manifest-backed thumbnail references.
- `supabase/functions/penned-publishing/contract.ts`: validate source URLs and image media access without accepting private file paths.
- `Docs/SafariWebClipper.md`: document the source card, format limitations, resource generation and execution boundary.
- `penned-editor/src/clip-source.js`: shared source-preview and relative saved-date formatting helpers.
- `penned-editor/src/editor.js`: persisted callout source attributes, compact preview, native URL opening and copy/paste parsing.
- `penned-editor/src/inline-property-node.js`: compact saved-date presentation using the existing date editor.
- `penned-editor/src/attachments.js`: recognize thumbnail-only clipped documents as attachment-bearing content.
- `penned-editor/src/tiptap.html`: scoped charcoal card, link preview, spacing and date-chip styling.
- `penned-editor/src/public-document.js`: read-only source-card rendering using protected publication media.

Build/resource generation was deliberately not run. Before installing/testing
the updated native app, run `npm run build` in
`/Users/asteriasmoons/Desktop/penned-editor`; its existing sync script copies the
compiled renderer into `Vellix/VellixEditor.bundle`. An Xcode build alone does not
regenerate that JavaScript bundle. The generated bundle is not hand-edited.
For published clips, the updated `penned-publishing` Edge Function and regenerated
shared public reader/CSS must be deployed together using the existing publishing
workflow. Neither backend nor website deployment was performed for this task.

### Not Executed

No builds, tests, simulators, launches, linters, type/syntax checks, project
validators or verification commands were run. The restructuring used source
inspection, Apple API documentation, scoped edits and copies of existing assets.
Compilation, signing, Safari enablement, app-group access, real article/image
extraction, account switching and live CloudKit delivery remain unverified and
must be exercised by the developer. This document describes implementation, not
a claim of device-tested or production-verified behavior.

## Primary References

- [Apple: Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [Apple: Distributing a Safari web extension](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)
- [Apple: iOS extension state](https://developer.apple.com/documentation/safariservices/sfsafariextensionmanager/getstateofextension(withidentifier:completionhandler:))
- [Apple: Open extension settings](https://developer.apple.com/documentation/safariservices/sfsafarisettings/openextensionssettings(foridentifiers:completionhandler:))
- [Mozilla Readability](https://github.com/mozilla/readability/tree/0.6.0)
- [MDN: scripting.executeScript permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/scripting/executeScript)
