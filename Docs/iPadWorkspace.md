# Penned iPad Workspace

## Scope

The iPad idiom now uses a dedicated two-area workspace instead of the old
three-column NavigationSplitView. iPhone continues to use the existing compact
workspace, bottom bar, editor deck, settings navigation and sheet defaults.
macOS retains its existing shell. No document schema, identifiers, ownership,
attachment paths, authentication, CloudKit mappings or sync behavior changed.

The supplied seven Craft screenshots guide organization and layout only. Penned
keeps its asset icons, rounded typography, purple accents, black surfaces,
frosted fields, existing editor controls and document appearances.

## Adaptive Sidebar

`PadWorkspaceMetrics` chooses overlay when the available window is portrait or
too narrow for a usable docked sidebar and main workspace. A sufficiently wide
landscape window docks the same sidebar on the left. The sidebar can be hidden
in either configuration. Overlay presentation dims the workspace without changing
the gallery width; docked presentation changes the content's leading inset.

There is one sidebar and one main content tree, not separate portrait/landscape
trees. Showing, hiding, rotating or resizing does not replace their identities.
The UIKit size probe reads the current window, not UIScreen or physical-device
orientation, so keyboard avoidance cannot turn a portrait window into a landscape
classification. The editor still receives its existing keyboard/safe-area handling.

Sidebar contents: tabs and close/new/duplicate actions; active Space and its
switcher/management/creation controls; All Docs, Tasks, Calendar, Collections,
Home, Recents and Templates; collapsible Starred, Folders and Tags; Spaces,
Trash and Settings. Folder nesting uses FolderHierarchy with cycle protection,
custom icons and existing contextual move/edit actions. Starred previews and
tags come from the scoped existing library, not a second catalogue. Long starred
lists have Show More/Show Fewer controls and the entire sidebar scrolls separately.
Both the workspace toggle and sidebar hide control use the existing `sidebar` asset.
Only the sidebar-header toggle is visible while the sidebar is open; the main
toolbar toggle is shown only while it is closed.
Inside a document, the entire workspace header (title, history and creation/actions)
is hidden. The existing editor toolbar instead receives an optional sidebar action
and places the custom `sidebar` asset in a matching frosted circular button directly
before Back. These controls sit over the document background, without an extra black
bar or duplicated title/Library heading. When the sidebar is open, only its own
header toggle remains visible. Browsers/settings keep the workspace header; iPhone
callers keep the nil sidebar-action default and their existing toolbar.

## Tabs and Navigation

`PadWorkspaceModel` owns only UI state over the existing AppEnvironment. Each tab
has a stable identifier, destination, folder, tag filters, active document and
back/forward history. New tabs start at All Docs. Ordinary gallery and Starred
document selection navigates within the active tab. Only explicit New Tab,
Duplicate Tab and Open in New Tab actions add tabs. Explicit document new-tab
opening selects an existing tab for that document when possible.
Previously `openDocument` defaulted to creating a tab for every ordinary tap;
returning from those documents changed their destinations back to All Docs and
made them look like spontaneously created browser tabs. The default is now false.
Existing document/folder context menus retain explicit Open in New Tab behavior.

Tab panes stay mounted while inactive, retaining SwiftUI browsing/search/sort,
scroll and settings-category state. Settings stays mounted while another
destination is in front. Browser scroll positions use native
[ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition).
Calendar model state belongs to the tab, and inactive calendar/task tabs stop
their background refreshes. Tasks includes all current scoped task records,
not just the displayed calendar week, with search, status filtering, completion
and source-document navigation. Collections browses existing owner documents,
including nested pages, and opens the actual editor with its existing collection
views and editing controls.

Before selecting, closing or replacing a tab, the coordinator calls
`AppEnvironment.prepareForWorkspaceNavigation`. This uses the existing persistent
operation drain, title callback, native content capture and save boundary. A save
failure leaves the current tab/editor in place and reports the failure. It does
not evict models or discard pending saves. The shared editor deck contains one
DocumentEditorView per cached model, even when the same document has two tabs.
Sidebar changes do not call the save/close path or recreate editors.

## Editor Viewport and Loading Correction

The retained editor deck is an overlay on the main pane's bounded viewport,
matching the iPhone shell's hosting structure, instead of a sibling contributing
its full content height to the workspace ZStack. The iPad document ScrollView is
explicitly bounded to that viewport; its content can still grow and scroll.
The fixed top editor controls remain outside the ScrollView.

The previous wide-screen branch used a 900-point document, 30-point title,
68-point controls, 150-point top margin and larger page padding. Dedicated iPad
workspaces now use the existing compact editor proportions for the entire editor,
including its title, page padding, native controls and toolbars. Plain and themed
document surfaces are capped at 720 points, adapting down to the available width;
covers follow that narrower page. Body rich-text rendering, saved appearance,
backgrounds and the existing editor are preserved without a scale transform.
Phone and macOS keep their existing size-selection branches.

### Physical iPad WebView Host Handoff

The 2026-10-18 physical-iPad lifecycle trace confirmed a native ownership bug,
not missing saved content. The existing WebView contained all five saved blocks
and was presentation-ready. SwiftUI created its replacement container, then
delivered a late update to the outgoing container. That update reclaimed the
same cached WebView; dismantling the outgoing container subsequently removed it.
The replacement remained empty while the native cover and title stayed visible.
The captured removal stack was `dismantleUIView -> unhost -> removeFromSuperview`.

`TipTapEditorWebViewStore` now tracks its current container weakly. A container
claims ownership only when created, before attaching the cached WebView. Updates
and teardown from superseded containers cannot reclaim or detach it. Ownership
is released before the current container removes its view, and queued session
loads also verify that their originating container is still current. UIKit and
AppKit use the same ownership rule. The WebView, coordinator, loaded document,
pending content, editor geometry, appearance and persistence pipeline are retained.

Regression cases replay replacement/late-update/teardown and verify that live
rich text and the original WebView survive without an HTML reload. All 26 native
workspace tests passed in the existing macOS WebKit harness, including both new
handoff cases, pending-save handling and account/Space/tab isolation. All 21
workspace source-contract checks passed as well. The Debug iOS build completed,
its code signature was verified, and it was installed over the existing physical
iPad app without resetting data. The post-fix device trace exercised the same late
update and teardown: both were rejected as stale, and the replacement kept the
loaded WebView attached to its window with the saved body visible in the DOM.
The user visually confirmed that the document body now appears and stays visible
after opening another document, returning, and toggling the sidebar. This confirms
that physical-iPad interaction sequence, not every orientation, editing gesture,
or physical-iPhone regression case. No iPhone UI or gallery layout was changed
for this host-ownership correction. Diagnostic capture remains Debug-only.

The native WebKit tests reproduced a first-load body failure: the inline editor
HTML still depended on external local table/formula scripts. The formula parser
was unavailable when `setContent` triggered the table plugin, throwing before
the body was applied, even for a plain-text document. The existing asset cache
now inlines all five bundled scripts in their original order and the existing
table stylesheet. It does not change or regenerate their contents.

The bridge also used `evaluateJavaScript` with `void tiptapCommand(...)`, which
acknowledged scheduling while that async command was still running. It could mark
the body loaded before `setContent` completed and miss a rejected promise. Commands
now use `callAsyncJavaScript` and await completion with structured arguments.
A gated real-WebKit test holds the command pending and checks that native loading
stays true and content capture stays unavailable until it resolves.

The loading trace also found two concrete recovery holes: WebKit process termination
only logged an error, leaving the cached session marked ready while its web body
was gone; a later navigation cleared the loaded document ID without requeuing
its JSON. The coordinator now reloads the same WKWebView after process exit, and
the session requeues the model's latest unsaved canonical JSON before resetting
its bridge/presentation state. This does not recreate a document or its ID.
Ordinary sidebar and tab switches still do not reload the web view.

Load-generation checks reject stale asynchronous loading completions. Startup
update/snapshot messages and content captures cannot persist the empty template
before saved JSON has loaded. A repeated SwiftUI update carrying an older saved
row cannot replace a queued recovery payload. Navigation failures surface an
editor error instead of only logging it.

These are reproduced first-load and simulated process-recovery failure paths, not
proof that every instance reported on a physical iPad had the same cause. Actual
device reproduction and final paint/scroll/touch verification remain required.

### Hidden Editor Readiness Deadlock

A subsequent hosted, real-WebKit test reproduced a separate rendering deadlock
with production presentation readiness enabled. The saved paragraphs were present
in the DOM, fonts were loaded, there were no pending images, and WebKit had
received eight animation-frame requests but delivered zero while hidden.
`prepareDocumentPresentation` awaited one of those frames, while the native editor
remained transparent until that preparation completed. Cached workspace editors
also remain hidden until document selection, so this wait could prevent opening.

The maintained `Vellix-backend/src/presentation-ready.js` now waits for fonts and
visible image decoding but does not await `requestAnimationFrame`. Its generated
`tiptap.bundle.js` has been rebuilt and copied into the existing editor bundle.
The native `WKWebView.takeSnapshot(afterScreenUpdates: true)` paint confirmation,
native collection layout checks, saved JSON, editor instances and save pipeline
are unchanged. No timer, empty-document fallback or document reset was added.

Before this correction, both hosted cases timed out. Afterwards, both passed,
including the initially transparent case, and their actual WebKit snapshots
contained painted text. Three JavaScript readiness tests also passed, including
a hidden-page test whose animation-frame callbacks never run. This is native
macOS WebKit rendering evidence, not physical-iPad verification. The simulator
previously stalled opening its library in a separate notification-service call;
no successful iPad document rendering is claimed from that launch.

`TipTapEditorWebViewStore` accepts an optional test loader, with its production
default unchanged. The hosted tests now exercise the production WebView factory,
representable and presentation gate rather than bypassing readiness. The session
exposes read-only presentation diagnostics for useful timeout failures.
The focused native regression run passed all 24 workspace tests, including saved
rich text, async loading, retained-editor recovery, pending saves and account/tab
isolation. No further full iOS build or simulator capture was run for this fix.

Tabs are session-local, not a new persistent document store. Space changes use
the existing safe Space switch, then reset old Space tabs; an open Settings tab
stays in Settings with the new Space. Account/library switches recreate the
workspace at the existing authenticated library boundary. Revoked database handles
cannot navigate. New routes validate document/folder/tag access against the active
scoped repositories. Deleted/trashed destinations are removed from tab history
without deleting their stored content.

## Existing Preview Rendering

### Current Requested UI Adjustments

The editor's fixed toolbar now has an additional 8-point top inset on iPad only.
The highlighted gallery Back/Forward arrows and header New Document plus are
removed. The entire highlighted secondary gallery toolbar (sort, presentation,
Select, extra actions and search) is removed. The unmarked sidebar toggle,
destination title and main actions menu remain. iPhone keeps its existing controls.

Using the earlier 194-point card width as the baseline, current iPad previews are
10% wider followed by a small 5% proportional enlargement: 224.07 points wide.
The previous bottom crop is adjusted to keep the displayed height increase at 5%,
rather than also stretching it by the width-only increase. The same existing
renderer and leading-aligned gallery are used, with unchanged gaps and insets.
At the supplied 889-point portrait width this produces three columns; narrower
windows and wider landscapes continue to adapt. These changes are applied once,
not compounded each time the request is revisited. Tag results share the sizing.

The earlier sizing history below records the previous 194-point/.8-crop stage;
the values in this subsection describe the current implementation.

All preview-generation, snapshot, appearance and TipTap rendering internals are
unchanged. DocumentBrowserView still uses
LibraryDocumentPreview directly. Only its gallery container and iPad controls
change: a responsive lazy multi-column layout, native scroll position, sorting,
gallery density, search, selection and the existing bulk operations.
The iPad document-options menu retains confirmed Empty Trash, which previously
lived in the native navigation toolbar.

The preferred column budget comes from the entire available workspace window.
An independent minimum card width reduces that budget for smaller content areas.
Cards match the user's iPhone 16 Plus All Docs gallery width, adding columns
as available space increases rather than enlarging cards. Cards stagger
vertically within lazy columns.
Tag results use the same adaptive container policy and unchanged preview cards.
iPhone keeps its existing two-column gallery, search and toolbar behavior.

The follow-up sizing correction gives each iPad lazy column an explicit measured
width, rather than relying on flexible HStack proposals around GeometryReader-based
previews. Standard cards use the existing iPhone two-column calculation at the
iPhone 16 Plus's standard 430-point portrait width: `(430 - 2 * 16 - 10) / 2`, or
194 points wide. The gallery is leading-aligned with the same 16-point inset and
10-point gaps as iPhone; it is not centered. At 1280 points it fits six columns;
at 889 points, or 944 points beside the sidebar, it fits four. Narrow windows reduce
columns or card width only when necessary to fit. Compact Gallery remains an
optional smaller presentation. Preview contents and snapshot generation are
unchanged. Tag results use the same measured policy. These are container sizing
checks, not physical-device screenshot verification.

The latest height-only correction adds a `visibleHeightFraction` parameter to the
existing LibraryDocumentPreview display container, defaulting to 1. iPad document
and tag galleries pass 0.8. At exactly the same card width, the container becomes
80% as tall; its existing top-aligned, scaled-to-fill snapshot retains its original
width scale and is clipped at the bottom. Typography and content are not compressed.
No card-width, column-count, spacing, alignment or preview-generation changes
accompany this crop. All phone/default callers retain the full height.

## Settings

Settings uses a scrollable category column and an independent detail area.
At narrow widths, category navigation is available in a shared frosted sheet.
The regular workspace sidebar is hidden on entry to avoid a third permanent
column; its previous visibility is restored on leaving Settings. The sidebar
toggle can still temporarily overlay Settings.

Only functional existing categories are exposed: Space Settings, Templates,
Folders, Tags, Daily Notes, My Spaces, Account Settings, Library & Sync and About.
The Space page uses the existing Space image editor and name/description editor,
archive operation and separately confirmed permanent deletion operation. Account
and Library & Sync embed their existing views, with standalone headers disabled
only when explicitly embedded. Their default iPhone presentations remain intact.
Unsupported settings categories were not filled with new placeholder views.

## Files

| File | Purpose |
| --- | --- |
| `Vellix/App/PadWorkspaceModel.swift` | Scoped tabs, history, validated routes, adaptive metrics, measured gallery/card widths and UI environment keys |
| `Vellix/App/PadWorkspaceView.swift` | Retained adaptive main area/editor deck, per-tab panes, tasks and collection browsing |
| `Vellix/App/PadWorkspaceSidebar.swift` | Tabs, Space controls, destinations, Starred, hierarchy and tag navigation |
| `Vellix/App/PadSettingsView.swift` | Adaptive categories and real Space/account/library settings |
| `Vellix/App/VellixShellView.swift` | iPad-only integration; existing global sheet/alert handlers retained |
| `Vellix/App/AppEnvironment.swift` | Expose the existing save boundary without closing the library or editor cache |
| `Vellix/Documents/DocumentBrowserView.swift` | iPhone-sized iPad cards, leading alignment, matching gaps/insets and controls; existing cards/context/bulk operations |
| `Vellix/Documents/HomeView.swift` | Optional per-tab Home search; phone keeps its existing shared model and focus behavior |
| `Vellix/DailyNotes/DailyNotesSettingsView.swift` | Optional embedded search field because iPad hides native browser bars; phone default is unchanged |
| `Vellix/Tags/TagBrowserView.swift` | Same measured iPad card-width policy and native browsing position |
| `Vellix/Calendar/CalendarView.swift` | Stop inactive iPad-tab work; phone activity default stays unchanged |
| `Vellix/Accounts/AccountSettingsView.swift` | Optional embedded header mode; default remains standalone |
| `Vellix/Accounts/AccountLibrarySheet.swift` | Optional embedded presentation; standalone shared sheet retained |
| `Vellix/VellixTests/PadWorkspaceTests.swift` | Native layout policy, navigation, saves, history and isolation tests |
| `Scripts/test-collections.mjs` | Include the real coordinator and native workspace tests |
| `Scripts/test-ipad-workspace.mjs` | Source contracts for iPad/iPhone branching, retained views, controls and assets |
| `Scripts/test-sheet-style.mjs` | Follow the shared presentation wrapper for embedded Library & Sync |
| `Vellix.xcodeproj/project.pbxproj` | New test target membership, without changing signing or capabilities |
| `Docs/iPadWorkspace.md` | Implementation, boundaries and physical-device checklist |

### Latest Correction Files

| File | Change |
| --- | --- |
| `Vellix/Documents/LibraryDocumentPreview.swift` | Optional display-height crop on the existing preview, full-height default |
| `Vellix/Documents/DocumentBrowserView.swift` | iPad-only 0.8 crop; explicit context-menu new-tab request |
| `Vellix/Tags/TagBrowserView.swift` | Same iPad-only gallery crop |
| `Vellix/App/PadWorkspaceView.swift` | Single visible sidebar toggle; bounded overlay editor deck |
| `Vellix/App/PadWorkspaceModel.swift` | Ordinary document opens no longer create tabs |
| `Vellix/Editor/DocumentEditorView.swift` | Whole-editor iPad proportions, narrower pages and bounded scrolling; top controls stay fixed |
| `Vellix/Editor/TipTapEditorSession.swift` | Requeue latest JSON after navigation; loading-generation and initialization-save guards |
| `Vellix/Editor/TipTapWebView.swift` | Inline existing dependencies for reliable first load; reload the retained WKWebView after process termination; surface navigation errors |
| `Vellix/VellixTests/PadWorkspaceTests.swift` | Tab accumulation, pixel crop, saved-content guards and real WebKit/TipTap recovery fixtures |
| `Scripts/test-collections.mjs` | Include existing preview and supply production editor asset directory to native tests |
| `Scripts/test-ipad-workspace.mjs` | Crop, single-toggle, fixed-control, lifecycle and explicit-tab source contracts |
| `Docs/iPadWorkspace.md` | Findings, implementation and verification boundaries |

## Automated Verification

- 227 native headless macOS tests passed, including 23 workspace tests. They
  exercise the real AppEnvironment, GRDB records, editor cache and save pipeline,
  without running the iOS app or connecting a live CloudKit/Supabase session.
- 21 iPad source-contract tests and 119 existing sheet/account-style contracts
  passed. These are structural checks, not rendered UI evidence.
- 62 existing account and Supabase SDK-boundary tests passed using their injected
  account/profile/network fixtures, not live authentication or CloudKit accounts.
- An unsigned generic iOS Debug build passed. No iOS simulator was launched.

The latest tests render the actual LibraryDocumentPreview container using
ImageRenderer at the same 194-point width, compare full/cropped image dimensions,
and compare interior pixels at matching positions to detect scaling/compression.
They check repeated document-open/back cycles keep one tab, explicit new-tab
actions still work, initial empty snapshots cannot overwrite saved JSON, and
recovery uses pending model text rather than an older database row.

Three windowless macOS WKWebView cases load the actual bundled TipTap scripts
through the production asset loader. They check saved body/formatting in the live
DOM and JSON, a deterministically gated async load, and reloading one retained web
view without blanking another. The process-exit delegate is invoked deliberately;
the OS did not actually kill a content process in these tests. Native paint readiness
is disabled only in these headless fixtures, not in production. The harness now
explicitly uses `--no-parallel` so unrelated renderer/editor fixtures do not flood
the WebKit main run loop and cause integration-test timeouts.

These checks do not exercise touch scrolling, the physical iPad viewport,
sidebar animations, keyboard placement or iPhone interactions. iPhone's gallery
height default and existing layout branches remain unchanged in source; its
shared WebKit loader receives the same loading correctness fixes.

The tests cover portrait/landscape/narrow-window policy and reference column
counts, tab creation/closing/selection/history, pending editor writes, failed-save
retention, duplicate document selection, account/Space isolation, invalidated
handles, settings navigation and pruning trashed destinations.

For the phone-size/sidebar follow-up, the 16 native workspace tests and 16 iPad
source contracts passed again, and the unsigned generic iOS Debug build passed.
They check equality with the iPhone 16 Plus two-column
card calculation, leading alignment, smaller-window fitting, compact presentation,
unchanged phone columns and the requested `sidebar` asset on both controls.

Follow-up files: `App/PadWorkspaceModel.swift` owns the phone-sized metrics;
`Documents/DocumentBrowserView.swift` and `Tags/TagBrowserView.swift` use fixed,
leading-aligned columns and phone spacing; `App/PadWorkspaceView.swift` and
`App/PadWorkspaceSidebar.swift` use the sidebar asset;
`VellixTests/PadWorkspaceTests.swift` and `Scripts/test-ipad-workspace.mjs` cover
those changes; this document records the implementation and validation boundary.

## Physical iPad Checklist

The following are not yet verified on a physical iPad:

1. Portrait: open/close the sidebar over All Docs and an edited document; confirm
   dimming, unchanged gallery width, retained scroll positions and caret/selection.
2. Landscape: dock/hide/show the sidebar; inspect card framing, column counts,
   editor resizing and independent scrolling in both areas.
3. Rotate repeatedly and use Split View/Stage Manager, including a tall resizable
   window with the keyboard visible. Confirm no accidental layout mode change,
   clipped controls, overlapping text or unexpected keyboard scrolling.
4. Keep two documents plus folder/tag/calendar/settings tabs open. Change sort,
   search, scroll, calendar date and settings category. Switch/close tabs with
   pending text and title edits, and verify their state and persisted content.
5. Complete tasks outside the current calendar week and open their source pages.
   Open collections in nested pages and exercise their real gallery/table/kanban
   controls. Verify old features and native system authorizations remain available.
6. Switch Spaces and accounts while editing. Confirm old tabs are inaccessible,
   failed saves block navigation, and account/sync functionality is unchanged.
7. On an iPhone, check the original bottom navigation, two-column browsers,
   editor, settings, standalone account/library sheets and keyboard interaction.

Builds and source tests cannot prove orientation animations, actual pixels,
touch interactions, WebKit caret behavior or physical-device performance. No
claim of that visual/runtime verification is made here.
