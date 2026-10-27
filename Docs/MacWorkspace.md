# Penned Native macOS Workspace

Implementation and verification record, October 19, 2026.

## Target and Isolation

The existing `PennedMac` target is a native SwiftUI/AppKit application, not Catalyst. Its bundle identifier remains `im.lystaria.PennedMac`, with a macOS 26.5 deployment target. Its own entry point, window state, tabs, sidebar, browser, editor container, inspectors and Settings are in `PennedMac/`.

The target shares compatible Penned models, repositories, GRDB schemas, account services, CloudKit sync engine, attachments, styles, preview rendering, and the existing TipTap JavaScript bundle. It excludes the original iPhone/iPad interface and platform editor hosts. No document, Space, account identifier, ownership rule or serialization format was replaced.

The Mac editor session, WebView host and cache have dedicated target-only source copies. Their implementation bodies retain the established ownership and lifecycle contracts. The iOS editor copies remain untouched. The isolation check compares 154 production source files against the reviewed baseline and checks the editor adapter bodies against the originals, allowing only the exact Mac-only wheel-bridge installation and visible-viewport hit-test guard described below. The one-line successful-opening completion fix in `AppEnvironment` is checked as an exact difference. The later, explicitly requested cross-platform collection deletion updates five reviewed baseline files, listed below; editor hosting/session baselines remain unchanged.

Pre-existing iOS appearance/menu changes in the dirty worktree are not part of this Mac implementation and have not been reverted. The Mac icon artwork added during development is preserved. The Mac asset names are now `PennedMacAppIcon` and `PennedMacAccentColor`, avoiding collisions with the shared iOS catalog while including the actual Mac artwork in the build.

## Sign-In and Collection Actions Follow-Up

- Mac Sign In now uses the native AppKit Apple authorization button at the full available content width, matching the email button. The decorative violet border and native focus ring are removed. Existing Apple request scopes and credential handling are retained; dismissing the view cancels an active authorization request.
- The dotswavy Collection management sheet has a destructive Delete Collection action on iPhone, iPad and Mac, using the existing platform confirmation presentation. The separate Views selector remains unchanged.
- Confirmation explains that collection configuration, views, fields, field values and membership are deleted permanently, while entry documents remain ordinary nested pages. The owner document and other content are not deleted.
- Deletion drains pending writes, removes the block in existing live TipTap editors without replacing their WebViews, and saves through the existing document pipeline. This deletion is excluded from undo history so Undo cannot resurrect a block whose collection metadata no longer exists. Repository cleanup and metadata deletion are transactional. Scope checks reject collections in another Space or account library. Errors keep the sheet open.

Files changed for this follow-up:

| Files | Purpose |
| --- | --- |
| `PennedMac/Accounts/MacSignInView.swift`, `MacAppleSignInButton.swift` | Full-width native Apple authorization button without the outline. |
| `Vellix/Collections/CollectionViewSheets.swift`, `PennedMac/Collections/MacCollectionViewSheets.swift` | Delete action, confirmation, progress protection and error handling. |
| `Vellix/Collections/CollectionDeletion.swift` | Shared save-safe live-editor deletion coordination. |
| `Vellix/Collections/CollectionRepository.swift`, `Vellix/Documents/DocumentRepositories.swift`, `Vellix/Editor/TipTapContentAnalyzer.swift` | Scoped atomic deletion and existing document-save pipeline reuse. |
| `Vellix/VellixTests/CollectionTests.swift`, `Tests/PennedMacTests/MacWorkspaceTests.swift` | Preservation, rollback, account/Space isolation and live WebView/undo regressions. |
| `Scripts/test-collection-actions.mjs`, `test-sheet-style.mjs`, `test-collections.mjs`, `test-mac-native.mjs` | UI wiring checks, new row expectation and shared source inclusion in test harnesses. |
| `Scripts/fixtures/mac-ios-source-lock.json`, `Scripts/test-mac-isolation.mjs` | Documented review of the five intentionally changed shared/iOS collection sources, retaining all editor lifecycle protections. |
| `Docs/MacWorkspace.md` | Actual implementation and verification record. |

Verification: 130 native tests in nine suites passed, including the real production TipTap WebView deletion test; 173 source checks passed. Native Mac and iOS simulator compatibility builds passed. CLI builds used a byte-identical temporary Xcode project with symlinks to the real source to avoid the existing project file-coordination stall. The final signed development Mac app was launched, and its Sign In sheet was visually checked: both buttons occupy the same full width, and Apple has no purple outline. No live authentication was submitted. Physical iPhone/iPad sheet interaction and cross-device CloudKit deletion propagation were not tested. No user collection was deleted during verification. The running development build does not replace the installed `/Applications/PennedMac.app` copy.

## Mac Scrolling and Preview Height Follow-Up

The editor body is a full-content-height WKWebView inside the native document ScrollView. Wheel input over WebKit was not explicitly routed to that outer scroll view, while the shared HTML disables overscroll chaining. The Mac-only `MacDocumentScrollBridge` installs a non-passive wheel listener at document end. Vertical document wheel deltas move the enclosing native clip view, constrained to its real content bounds. Nested scrolling regions retain wheel input while they can scroll in the requested direction; horizontal gestures, Shift-wheel, Control-wheel, and already handled events are not intercepted. This changes neither document JSON nor editor ownership, loading, focus, selection or caching. The bridge weakly references its WebView and is retained only by that view's content controller. iOS and shared editor resources are unchanged.

Mac gallery cards now use the existing `visibleHeightFraction` presentation option at `0.65`, cropping the bottom 35 percent while preserving width and rendering scale. Masonry height estimates use the same fraction. Column calculations, list/sidebar thumbnails and iPhone/iPad sizing are unchanged.

Files changed:
- `PennedMac/Editor/MacDocumentScrollBridge.swift`: Mac-only wheel routing to the native document scroll view.
- `PennedMac/Editor/MacTipTapWebView.swift`: one installation call in the existing Mac configuration branch; no hosting/lifecycle changes.
- `PennedMac/Browser/MacDocumentBrowser.swift`: gallery bottom crop and matching masonry estimates.
- `Scripts/test-mac-document-scrolling.mjs`: executes the actual injected wheel script for direction, delta units, nested-scroll edges and preserved gestures; checks native wiring and preview sizing.
- `Scripts/test-mac-isolation.mjs`: verifies the exact scroll installation and viewport hit-test adapter differences while continuing to compare the entire remaining host/session bodies.
- `Scripts/test-mac-native.mjs`: includes the adapter in the existing native test harness for future authorized runs.
- `Docs/MacWorkspace.md`: implementation and verification boundaries.

Verification: 37 non-build Node checks passed across `test-mac-document-scrolling`, `test-mac-isolation` and `test-ipad-workspace`; `git diff --check` passed. Per the user's instruction, no build, compilation-based tests, or app launch was performed for this follow-up. The edited Swift adapter and actual Mac scrolling/preview presentation remain unverified in a newly compiled running app. Earlier build results above do not cover this follow-up. No further builds should be run unless the user explicitly reverses that instruction.

## Top Navigation and Header Correction

The previously added bottom formatting bar was an incorrect interpretation of the request. It and its source file are removed, together with the extra top Insert shortcut. The subsequent explicit header-cleanup request also removes the top Format, Style and Info shortcuts. The eye/lock button is unchanged. Per the clarified sharing request, the send/share button remains visible with its original icon, but its action is deliberately empty: it opens no menu and shares nothing. Formatting, insertion, styling and document information remain in the existing right inspector. Back/Forward navigation, template-specific controls and save status are unchanged by this header cleanup. The sharing correction changes only `MacDocumentEditorContainer.swift`, its source regression assertion in `Scripts/test-mac-editor-navigation.mjs`, and this record.

Back previously used only the tab's existing history index. A directly opened nested page could have no Back destination, or could point straight at the browser instead of its parent. `parentBackLocation` resolves an accessible, same-Space, non-trashed/non-archived parent only when there is no preceding document in history. Back inserts that parent before the child inside the existing save-safe navigation transition. Forward then returns to the same child and cached editor. Existing document-to-document history is left intact. This applies equally to nested pages, cards and collection entries through their existing parent relationships. Navigation is still account checked and failed saves prevent history changes.

The fixed top header has explicit stacking priority. The scroll surface has a rectangular clipped hit boundary, and the Mac native WebView container rejects hit tests outside its `visibleRect`. This prevents a full-height editor scrolled underneath the header from accepting clicks outside its visible scroll viewport. It does not alter WebView ownership, attachment, loading or teardown.

Files changed:
- `PennedMac/Editor/MacDocumentEditorContainer.swift`: remove the unrequested bar/Insert shortcut; elevate the existing header and bound the scroll surface.
- `PennedMac/Editor/MacDocumentEditingToolbar.swift`: removed.
- `PennedMac/Workspace/MacWorkspaceModel.swift`: scoped parent Back fallback, Forward preservation and captured-tab validation after saving.
- `PennedMac/Editor/MacTipTapWebView.swift`: Mac-only visible-viewport hit-test guard.
- `Tests/PennedMacTests/MacWorkspaceTests.swift`: native regressions for nested pages/cards/collection entries, parent/browser/Forward traversal, pending-edit preservation and save failures. Added, not run.
- `Scripts/test-mac-editor-navigation.mjs`: static removal, header wiring, hit-boundary and history safeguards; replaces tests for the rejected bottom bar.
- `Scripts/test-mac-isolation.mjs`: verifies the exact viewport guard while preserving comparison of all other host/session code.
- `Docs/MacWorkspace.md`: corrected implementation record. No iPhone/iPad or shared persistence files changed.

Verification: 38 static Node source checks passed across editor navigation, Mac isolation and iPad workspace suites; `git diff --check` passed. No build, simulator, app launch or compilation-based test was run. The two already-running apps were distinguished by their executable paths. In the Xcode-built instance, activating the top Style button through accessibility opened its inspector, demonstrating that the action was wired. The revised hit-testing and parent-navigation changes have not been compiled or runtime verified; the source checks are not proof of pointer interaction correctness. Existing WebKit scrolling changes and the 35-percent preview crop were left unchanged.

## Workspace and Windows

- The tab/view title previously displayed as Home now reads All Docs through a label-only change in `MacDestination.title`. Its route, icon, saved tabs/history and document listing are unchanged. Only `MacWorkspaceModel.swift`, its source check in `Scripts/test-mac-isolation.mjs`, and this documentation change for this correction.
- The Mac sidebar Space header has one `chevdown` control opening the existing Space switcher; the redundant dotswavy Space actions menu is removed. Home is removed from the sidebar destination list, which starts with All Docs. Settings and existing workspace/history destinations remain available. This cleanup changes `MacNavigationSidebar.swift`, its two source checks in `Scripts/test-mac-isolation.mjs`, and this record; no iOS code is changed.
- A native `WindowGroup` creates independent workspaces. `HSplitView` supports independently collapsible, draggable left and right columns, with a flexible editor/browser center.
- The right inspector and its toolbar toggle exist only for document destinations. All Docs and every other browser destination use the full remaining center width, with no empty inspector. Returning to a document restores the user's inspector visibility choice. Its menu shortcut is disabled outside documents.
- Each window owns a revocable scoped environment over the shared database writer. Closing windows and changing account/library contexts drain queued operations and save pending edits first. Save failures cancel closure instead of discarding edits.
- The registry prevents simultaneous independent editing sessions for the same document in different windows, focusing the existing document window instead.
- Horizontal tabs maintain their own destination, history, browser query, sort, selection, task filter and calendar model. Browsing does not automatically create tabs. Existing document tabs are selected instead of duplicated.
- Workspace restoration keys include library, account, window and Space identities. Saved tab destinations are validated before restoration. Another account's tabs are never reused.
- Document scroll state is retained while moving through tabs/history. Live editor instances remain in the window's retained editor deck during tab switches and sidebar/inspector changes.
- The tab strip is leading-aligned using the actual sidebar width. Its New Tab button is inside the horizontal strip immediately after the tabs, not pinned to the far edge of a stock toolbar capsule. Shared native toolbar backgrounds are hidden.

Native commands include New Document, New Tab, New Window, Save, Find, Undo/Redo, Back/Forward, adjacent-tab selection, sidebar/inspector visibility, Style Gallery and backups. Command-W explicitly closes the active tab; with one tab it uses the safe window-close path. Shift-Command-W closes the workspace window. Command-Comma opens Settings.

## Browsing and Editing

The Mac gallery disables only its native focus effect with `.focusEffectDisabled()` after `.focusable()`, preventing the purple outline around the full gallery when it gains focus during document or Space navigation. Focusability, Return/arrow/Delete handlers and individual selected-card outlines are retained. This correction changes `MacDocumentBrowser.swift`, its regression in `Scripts/test-mac-isolation.mjs`, and this record. Verification is source-only; no build, simulator or app launch was run.

The Mac browser arranges the existing `LibraryDocumentPreview` components. It does not implement a new renderer, snapshot generator, document appearance model or preview cache. It supports responsive columns, existing theme-aware/custom previews, list view, search, sorting, folders, tags, selection, double-click opening, contextual actions, keyboard traversal and document-to-folder drops.

The sidebar's Starred document rows also use `LibraryDocumentPreview`, with the same live document/cache subscriptions as iPad, instead of generic document icons.

The editor container composes the existing document cover/background/appearance, title, inline properties, embedded collections and rich-text session. Formatting, commands, JSON capture, repository saves and backups use the existing contracts. Native file panels feed the existing attachment/style import pipeline. Delayed imports verify the owning account and active document before applying results.

The native paper now caps its inner content at the same 720-point limit used by the existing HTML `.vellix-editor-page`. The previous 900-point native paper allowed a wider title/cover than the centered HTML body and visibly indented the body at wide window sizes. The shared width plus 28-point native content insets aligns these elements with either sidebar configuration, without changing saved paragraph alignment or any WebView hosting code.

Theme changes use the existing live presentation bridge. They do not recreate or detach the cached WebView, reload the document, write theme colors into content, or replace unsaved edits. Default documents and previews follow Penned's existing Light/Dark/System preference; explicitly saved document appearances and formatting stay independent.

### Successful Opening Timeout Correction

The reported "This page could not be prepared" alert came from the shared opening timeout. `finishDocumentOpening` selected a successfully prepared document but left `pendingDocumentID`, its readiness subscription, and its 12-second timeout alive. Consequently a successful cold or cached open could still report failure 12 seconds later. The success branch now calls the existing `cancelDocumentOpening()` before publishing the selected document. Actual failures retain their existing timeout and error handling.

This is a completion-state correction, not a new editor-loading mechanism. No WebView hosting, ownership, teardown, TipTap resources, document JSON, or saved appearance values changed. Temporary Mac geometry diagnostics were removed. On-screen checks of the existing local document showed its saved paragraphs after opening and after browser/inspector transitions. The previously blank Xcode-launched instance had exposed those paragraphs through accessibility; this did not indicate missing saved content.

Regression coverage includes a real production TipTap WebView starting without a preset frame, successful cold and cached opens clearing the pending request, waiting beyond the original timeout without a false error, unchanged stored document JSON, and inspector availability across every browser destination.

## Inspectors

- Insert exposes supported Penned commands, grouped by type and searchable. Attachments, tables, properties, nested pages, cards, lists, separators, template components and collections use their existing implementations.
- Format reflects the existing selection and formatting state, including inline marks, lists, alignment, block types, callout colors and page grouping. Selection formatting calls the existing session commands. **Selected Text Color**, below Inline Formatting, now edits just the selected text using Solid or Gradient colors, custom Palette/Spectrum/RGB/hex pickers for each color, preview, angle/swap, Apply, Cancel and Default Text Color. Its held ProseMirror selection survives sidebar/picker focus; selecting different text or leaving the document cancels that draft. The document-wide Style text color remains separate. No bottom formatting bar was added. See `Docs/InlineTextColor.md` for changed files and tests; Mac native compilation/runtime verification was not performed for this addition, respecting the no-build instruction.
- Style edits the existing document style definition. Custom background-mode buttons, color swatches, Palette/Spectrum/RGB controls, validated hex input, font buttons and gradient samples replace system pickers. Opening a color control does not commit a value. Explicit changes save through the existing appearance pipeline.
- The floating Style Gallery is an `NSPanel` using the existing saved-style repository and `DocumentStyleThumbnail`, with search, application, rename and confirmed deletion. It remains associated with the active editor.
- Info displays stored dates, document statistics and relationships, plus supported document/selection actions and version history. Unsupported reference-only AI review, whiteboard and presentation features are not exposed as working actions.

## Custom Application Controls

Mac-only reusable controls use the existing Penned semantic palette, rounded typography and icon assets. Application-owned dropdowns, segments, switches, sliders, numeric steppers, calendars/time controls, fields, menu triggers, buttons and confirmation prompts have custom presentation. Their bindings and existing save/action handlers are preserved.

Native menus in the macOS menu bar and secondary-click menus remain native desktop interaction surfaces. Traffic lights, permission dialogs, Apple sign-in and system file/photo panels remain operating-system integrations, not replacement custom implementations. The final emergency termination/save-failure alert also remains a native safeguard.

## Settings

The dedicated two-column Settings window now includes every category shown in the supplied phone settings photos, with the same grouping:

- Space Settings: Templates, Published Content, Stats, On-device Folders, Tags, Space Settings.
- Daily Notes: Daily Notes.
- General Settings: Appearance & Sound, Language & Spelling, Security, Advanced.
- Your Account: Account Settings, My Subscription, My Spaces, My Team, Integrations, Assistant, Notifications. Library & Sync is retained as an additional existing destination.
- Penned: Diagnostics, About.

Working panes use the actual repositories/services: template creation/opening, folders and tags, Space metadata/archive/delete/restore, default daily-note templates, account profile and saved-account flows, sync configuration/recovery, library counts, diagnostics, Calendar integration and reminder authorization/scheduling. Spelling options use `NSSpellChecker`. Sound and operating-system permission configuration open macOS Settings; no nonfunctional parallel preference is stored.

The appearance preference uses Penned's existing `PennedAppearancePreference.storageKey` in local `UserDefaults`, defaulting to Dark. The Mac observable preference store writes that same key; the shared SwiftUI appearance modifier and native window bridge apply it immediately. System clears an explicit `NSAppearance` override so device changes propagate normally.

Published Content, My Subscription, My Team and Assistant do not have implemented services in the existing iPhone application. Their categories are included and explicitly identified as unavailable. No fake subscription, publishing, team or AI backend was invented. This remains a product functionality limitation, not a verified complete implementation of those services.

## Build and Run

Use the existing `PennedMac` scheme, or the Codex Run action:

```sh
./script/build_and_run.sh
```

The script saves/quits a running Penned instance gracefully, builds and launches the native app. It never force-kills pending edits. Supported alternatives are `--debug`, `--logs`, `--telemetry` and `--verify`. `PENNED_MAC_DERIVED_DATA` overrides the build location.

The signed development build used for verification is `/tmp/PennedMacSigned/Build/Products/Debug/PennedMac.app`.

```sh
node Scripts/test-mac-native.mjs
node Scripts/test-mac-isolation.mjs
node Scripts/test-accounts.mjs
xcodebuild -project Vellix.xcodeproj -scheme PennedMac -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Vellix.xcodeproj -scheme Vellix -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The native test harness is bounded and uses temporary in-memory libraries. `--penned-mac-ui-test` is an explicit app verification argument that supplies a disposable in-memory library, temporary attachments and isolated account data instead of opening or modifying the real library. Normal launches do not use those fixtures.

## Verification Record

- Latest focused native regression run: 125 tests in eight suites passed. It includes cold/cached opening completion beyond the original timeout, document-only inspector behavior, zero-initial-frame Mac layout, Space navigation, save failure protection, account boundaries, restoration, browser state, custom control non-mutation, all settings categories, the native/HTML width contract, existing preview/appearance contracts and actual WebKit lifecycle regressions.
- Existing account suite: 62 tests passed. These are local/mocked service tests, not proof of a live Apple/Supabase sign-in.
- Original iOS editor/appearance/iPad workspace regression harness: 51 tests passed against the untouched original implementations.
- Existing source checks for icon menus, appearance, iPad workspace and sheet style: 159 checks passed again after the opening/inspector correction. All eleven Mac isolation/wiring checks passed, including the exact shared-source completion fix, preserved iOS/editor implementations, document-only inspector wiring and live sidebar preview reuse.
- Native Mac development signing and entitlements were inspected. CloudKit container `iCloud.im.lystaria.Penned`, Apple sign-in, push, sandbox, outgoing network, user-selected file access, calendar and photo capabilities are configured.
- The iOS simulator compatibility build passed again after the opening completion correction. iPhone/iPad interface and editor host/session files remain unchanged; the shared opening completion handler has the documented one-line correction above. This is compilation verification, not a new physical iPhone/iPad interaction test.
- On-screen Mac checks used the running native app and disposable data: real body rendering/editing, Callout insertion, Bold formatting, tab switching, independent sidebar/inspector visibility, sidebar resizing, multiple windows, Command-W, custom color swatches/hex validation/fonts, Light mode and custom-style application. These checks preserved the edited body across the exercised transitions.
- The final development-signed Mac build passed. The expanded Settings categories and working Stats/folder/Space actions were exercised on screen; opening and cancelling the custom archive confirmation preserved the Space. Title/body alignment was verified with both panels closed and with the sidebar open. Actual Starred document thumbnails, aligned tabs and the inline add button were visually confirmed. The add button created one tab and Command-W closed it, returning to the same retained, visible document body.
- Verification mode was closed afterward. The final signed app was launched normally, and the existing local document restored its saved body and tab state. Its existing content was not replaced with the disposable verification data.
- After the reported opening error, the final signed Mac build was relaunched in the normal library. The existing document body rendered visibly. All Docs had neither a right inspector nor its toggle, even with the inspector preference enabled; its shortcut did not open a panel there. Switching back restored the inspector alongside the same visible saved body. No body text was edited during these checks.

One Xcode command was blocked in `NSFileCoordinator` while opening the live project, before compilation. The final build check uses a byte-identical temporary copy of the project file with symlinked original source folders to avoid that file-coordination lock. It does not use a different target, source implementation or build configuration.

## Files Added or Changed

All source paths below are relative to the repository root. Mac-only files are members of PennedMac, not the iOS target.

| File | Responsibility |
| --- | --- |
| `Vellix.xcodeproj/project.pbxproj` | Existing Mac target membership, packages, resources, native settings and capabilities. |
| `Vellix/App/AppEnvironment.swift` | Complete successful document-opening requests so their failure timeout cannot fire afterward. |
| `PennedMac/PennedMacApp.swift` | Dedicated application entry, workspace/Settings scenes and native commands. |
| `PennedMac/PennedMac.entitlements` | Sandbox, network and file access alongside existing Apple/CloudKit capabilities. |
| `PennedMac/Resources/MacInfo.plist` | Native bundle configuration and shared public auth configuration. |
| `PennedMac/ContentView.swift` | Removed the unused starter view. |
| `PennedMac/Assets.xcassets/PennedMacAppIcon.appiconset/` | Renamed and included the supplied Mac icon set; all ten PNGs remain unchanged. |
| `PennedMac/Assets.xcassets/PennedMacAccentColor.colorset/Contents.json` | Namespaced Mac accent using Penned's existing light/dark purple values. |
| `PennedMac/App/MacApplicationModel.swift` | Accounts, library activation, foreground sync and save-safe application termination. |
| `PennedMac/Accounts/MacLibraryWorkspace.swift` | Existing library/sync behavior with save-safe multiwindow transition hooks. |
| `PennedMac/Accounts/MacSignInView.swift` | Mac-only existing Apple/email sign-in presentation. |
| `PennedMac/Accounts/MacAccountLibraryView.swift` | Mac-only existing library/sync/recovery controls. |
| `PennedMac/Workspace/MacWorkspaceModel.swift` | Account-scoped navigation, per-tab history, serial actions and save boundaries. |
| `PennedMac/Workspace/MacWorkspaceState.swift` | Per-tab browser/sidebar/document view state. |
| `PennedMac/Workspace/MacWorkspaceView.swift` | Native split layout, retained editors, toolbar alignment and presentations. |
| `PennedMac/Workspace/MacWorkspaceTabBar.swift` | Custom leading-aligned tabs, inline add action, reordering and closing. |
| `PennedMac/Workspace/MacNavigationSidebar.swift` | Spaces, existing destinations, starred pages, folders, tags and settings. |
| `PennedMac/Workspace/MacWorkspaceCommands.swift` | Real native menu actions and keyboard shortcuts. |
| `PennedMac/Workspace/MacWindowRegistry.swift` | Multiwindow account/save coordination and existing-document focus. |
| `PennedMac/Workspace/MacWindowBridge.swift` | AppKit close delegation without discarding edits. |
| `PennedMac/Workspace/MacSplitSizing.swift` | Narrow AppKit split sizing/persistence adapter. |
| `PennedMac/Browser/MacDocumentBrowser.swift` | Desktop arrangement/interactions using existing previews. |
| `PennedMac/Browser/MacFolderControls.swift` | Mac-only existing folder editing/moving controls. |
| `PennedMac/Browser/MacCalendarBrowser.swift` | Dedicated calendar and task browsing. |
| `PennedMac/Browser/MacCalendarDocumentPreview.swift` | Existing calendar preview adapter. |
| `PennedMac/Browser/MacCalendarEventDetailSheet.swift` | Existing event-linked note controls on Mac. |
| `PennedMac/Editor/MacDocumentEditorContainer.swift` | Native document surroundings, title, scrolling, Find and retained editor composition. |
| `PennedMac/Editor/MacDocumentLayout.swift` | Native content-width/inset contract matching the existing HTML body. |
| `PennedMac/Editor/MacEditorPresentations.swift` | Existing editor request handlers through Mac presentations. |
| `PennedMac/Editor/MacTipTapWebView.swift` | Target-isolated existing host/ownership contract. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Target-isolated existing editor bridge/session contract. |
| `PennedMac/Editor/MacDocumentEditorCache.swift` | Target-isolated existing model/session cache. |
| `PennedMac/Editor/Controls/MacAttachmentEditorSheet.swift` | Existing attachment commands with custom Mac display controls. |
| `PennedMac/Editor/Controls/MacTableEditorSheet.swift` | Existing table operations with custom Mac controls. |
| `PennedMac/Editor/Controls/MacTaskEditorSheet.swift` | Existing reminders/recurrence operations with custom Mac controls. |
| `PennedMac/Editor/Controls/MacInlinePropertyEditorSheet.swift` | Existing property operations with custom Mac controls. |
| `PennedMac/Editor/Controls/MacPageCardEditorSheet.swift` | Existing page-card styling isolated for Mac. |
| `PennedMac/Editor/Controls/MacTemplateComponentEditorSheet.swift` | Existing template component editing on Mac. |
| `PennedMac/Editor/Controls/MacTagEditorIntegration.swift` | Existing inline tag integration isolated for Mac. |
| `PennedMac/Collections/MacCollectionDocumentIntegration.swift` | Existing collection request/actions adapter. |
| `PennedMac/Collections/MacCollectionKanbanView.swift` | Existing board interactions adapted for Mac. |
| `PennedMac/Collections/MacCollectionPropertySheets.swift` | Existing collection field/value controls. |
| `PennedMac/Collections/MacCollectionViewSheets.swift` | Existing collection views, filters and sort controls. |
| `PennedMac/Inspector/MacDocumentInspector.swift` | Independently scrolling, contextual inspector sections. |
| `PennedMac/Inspector/MacInsertInspector.swift` | Searchable categories of actual insertion commands. |
| `PennedMac/Inspector/MacFormatInspector.swift` | Context-aware existing formatting commands. |
| `PennedMac/Inspector/MacStyleInspector.swift` | Existing document styling through custom Mac controls. |
| `PennedMac/Inspector/MacStyleGallery.swift` | Floating native gallery using existing style thumbnails/repository. |
| `PennedMac/Inspector/MacInfoInspector.swift` | Real document metadata, management and backups. |
| `PennedMac/Appearance/MacDocumentStyleControls.swift` | Existing appearance UI adapter with custom controls. |
| `PennedMac/Appearance/MacCardBackdropSheet.swift` | Existing card background styling adapter. |
| `PennedMac/Appearance/MacCardPhotoSearchSheet.swift` | Existing photo search/import presentation adapter. |
| `PennedMac/Appearance/MacCardThreeModeColorPicker.swift` | Custom Palette/Spectrum/RGB and validated hex. |
| `PennedMac/Appearance/MacStyleWidgets.swift` | Reusable swatches, font buttons and gradient choices. |
| `PennedMac/Appearance/MacStyleNameAlert.swift` | Mac-target compatibility for existing style naming contract. |
| `PennedMac/Appearance/MacAppearanceComponents.swift` | Isolated existing icon, style-art and formatting controls. |
| `PennedMac/Appearance/MacWindowAppearance.swift` | Shared-key Mac preference observation and native appearance bridge. |
| `PennedMac/Settings/MacSettingsView.swift` | Full grouped settings navigation, existing appearance and Space controls. |
| `PennedMac/Settings/MacSettingsCategory.swift` | Testable settings category and availability definitions. |
| `PennedMac/Settings/MacSettingsPanes.swift` | Repository/service-backed library, stats, language, security, integration, notification and diagnostic panes. |
| `PennedMac/Settings/MacAccountSettings.swift` | Existing profile, saved account and destructive account flows. |
| `PennedMac/Settings/MacDailyNotesSettings.swift` | Existing default daily-note template selection on Mac. |
| `PennedMac/Settings/MacSpaceControls.swift` | Existing Space edit, transfer, archive and deletion flows. |
| `PennedMac/Support/MacControls.swift` | Existing asset-backed icons at proper AppKit intrinsic sizes. |
| `PennedMac/Support/MacCustomControls.swift` | Custom field, button, switch, options, segments, menus and form styling. |
| `PennedMac/Support/MacValueControls.swift` | Custom numeric, slider, calendar and time controls. |
| `PennedMac/Support/MacPrompt.swift` | Custom app-owned confirmation/error/naming presentation. |
| `PennedMac/Support/MacVerificationFixtures.swift` | Explicit disposable UI verification library. |
| `Tests/PennedMacTests/MacWorkspaceTests.swift` | Focused state, ownership, save, appearance/control and settings tests. |
| `Scripts/test-mac-native.mjs` | Bounded headless native Mac regression harness. |
| `Scripts/test-mac-isolation.mjs` | Target/source isolation and UI wiring checks. |
| `Scripts/fixtures/mac-ios-source-lock.json` | Pre-Mac production-source integrity baseline. |
| `script/build_and_run.sh` | Single native build/run/debug/log entry point. |
| `.codex/environments/environment.toml` | Codex Run action. |
| `Docs/MacWorkspace.md` | Architecture, file manifest, verification and remaining limits. |

The renamed Mac icon directory contains `Contents.json`, `16x16.png`, `32x32.png`, `32x32 1.png`, `64x64.png`, `128x128.png`, `256x256.png`, `256x256 1.png`, `512x512.png`, `512x512 1.png` and `1024x1024.png`. All ten image hashes were compared with the supplied staged originals and are unchanged.

## Remaining Physical Verification

- Sign in on Mac and iPhone with the same existing Apple/email account. Verify identical account-owned Spaces/documents, without creating replacement records.
- Ensure the Mac Apple Sign-In App ID is grouped appropriately with the existing primary iOS App ID in the developer portal. No client-side subject rewriting is used.
- Verify CloudKit uploads/downloads, attachments, offline edits, conflict recovery and push delivery on physical devices under the same Apple cloud account. Configured entitlements and compilation alone do not prove this.
- Exercise account switching with pending edits across several windows and relaunch restoration using the real signed build.
- Check long documents, native file/photo permission flows, large libraries, keyboard layouts and accessibility on the deployment macOS version.
- Distribution/archive/notarization has not been performed. The inspected signature is a development signature.
