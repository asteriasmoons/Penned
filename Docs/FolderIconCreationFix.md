# Folder Creation With SF Symbols

Date: November 4, 2026

## Cause

The folder icon picker supports two libraries: Penned assets and SF Symbols. It returns an SF Symbol as a name prefixed with `sf:`, such as `sf:square.grid.2x2`.

`AppEnvironment.saveFolder()` validated the selection against `VellixAssetIconLibrary.names`, which contains only Penned asset names. Every SF Symbol failed that guard, producing the screenshot's "Choose a folder name and an icon from your library" error before reaching the database. The "Move is not allowed" prefix comes from the existing `VellixError.impossibleMove` error wrapper; this failure is not actually a folder move or storage error.

Folder icon rendering and the edit sheet's initial state also checked only asset names. Fixing saving alone would therefore leave a saved SF Symbol displaying as the default folder icon or being replaced when editing the folder later.

## Fix

Added `VellixAssetIconLibrary.isSupported(_:)`, which accepts existing Penned assets or an `sf:` name present in the existing SF Symbol catalogue and available on the current OS. It uses the same catalogue and availability rule as the picker; unknown names remain invalid. The existing asset-only `names` set was not broadened, avoiding changes to unrelated asset-rendering code.

Folder saving, folder icon rendering, editor initialization and Home folder rows now use that shared check. Reopening the icon picker starts in the saved icon's library instead of always returning to Penned assets.

## Files Changed

| File | Change |
| --- | --- |
| `Vellix/Resources/VellixAssetIconLibrary.swift` | Shared validation for both icon libraries. |
| `Vellix/App/AppEnvironment.swift` | Accept valid SF Symbols during both folder creation and editing. |
| `Vellix/Documents/FolderLibraryViews.swift` | Preserve/display saved SF Symbols on iPhone/iPad and reopen the appropriate picker library. |
| `PennedMac/Browser/MacFolderControls.swift` | Apply the same correction to the existing Mac adapter. |
| `Vellix/Documents/HomeView.swift` | Display the selected folder icon on Home instead of substituting the default. |
| `Vellix/VellixTests/FolderLibraryTests.swift` | Three regression cases: both libraries, nested creation/editing persistence, and rejection without writes. |
| `Docs/FolderIconCreationFix.md` | This cause, implementation and validation record. |

## Validation

- Unsigned arm64 iOS simulator app build: passed. No app or simulator was launched.
- Compiled and ran the actual icon-library/catalogue source in a temporary Foundation-only validation executable. All 635 Penned assets and 9,524 available SF Symbols were accepted. Nine explicit cases verified default/custom assets, valid prefixed symbols, and rejection of empty, unknown and incorrectly unprefixed names.
- `git diff --check`: passed.
- The three GRDB/AppEnvironment regression tests were added but not run. The native test target has the previously identified, unrelated `LibrarySyncTests.swift:170` call to `TaskCompletedOccurrence` missing `scheduledAt`; that file was left unchanged.
- Device confirmation of tapping Save and reopening the folder remains outstanding. The Mac adapter was updated but not separately built or launched.

Folder colors, hierarchy, Space ownership, repository writes, refresh behavior, persistence and synchronization are unchanged. No migration or database reset is needed. Existing uncommitted editor-bundle changes were left untouched. This is a native-only fix: rebuild the app; no npm/editor-bundle build is required.
