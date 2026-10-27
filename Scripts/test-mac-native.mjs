import { mkdtemp, mkdir, readdir, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

// Compile the real Mac editor adapters and shared domain files into a headless test module.
// This does not open the application or access the production document library.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let grdb = process.env.PENNED_GRDB_PATH;
if (!grdb) {
  const derived = join(homedir(), "Library/Developer/Xcode/DerivedData");
  for (const directory of await readdir(derived)) {
    if (!directory.startsWith("Vellix-")) continue;
    const path = join(derived, directory, "SourcePackages/checkouts/GRDB.swift");
    try { await readFile(join(path, "Package.swift")); grdb = path; break; } catch {}
  }
}
if (!grdb) throw new Error("Set PENNED_GRDB_PATH to the existing GRDB.swift checkout.");
const workspace = await mkdtemp(join(tmpdir(), "penned-mac-checks-"));
await mkdir(join(workspace, "Sources/Vellix"), { recursive: true });
await mkdir(join(workspace, "Tests/CollectionTests"), { recursive: true });
const fullApp = true;
const files = [
  "Resources/PennedAppearance.swift",
  "Persistence/AppDatabase.swift", "Persistence/LibraryOwnership.swift", "Persistence/LibraryAccess.swift", "Documents/DocumentRecords.swift", "Documents/DocumentRepositories.swift",
  "Sync/LibrarySyncSchema.swift",
  "Sync/LibrarySyncStore.swift",
  "Sync/LibrarySyncRecords.swift", "Sync/LibrarySyncImport.swift",
  "Sync/LibrarySyncEngine.swift",
  "Spaces/SpaceOwnership.swift", "Spaces/SpaceOperations.swift", "Search/DocumentSearchService.swift", "Documents/DocumentStyleRepository.swift",
  "Documents/DocumentAppearance.swift", "Documents/StructuredTemplateContent.swift", "Documents/FolderHierarchy.swift",
  "DailyNotes/DailyNoteRepository.swift", "DailyNotes/TemplateComponent.swift",
  "Tags/DocumentTagRepository.swift",
  "Editor/InlineProperty.swift", "Editor/TipTapContentAnalyzer.swift", "Editor/PageCardStyle.swift", "Editor/DocumentPresentationState.swift",
  "Documents/DocumentPreviewContent.swift", "Documents/DocumentPreviewPresentation.swift", "Documents/InlinePropertyPreview.swift", "Editor/DocumentEditorWarmupPolicy.swift",
  "Tasks/DocumentTask.swift", "Tasks/DocumentTaskRepository.swift", "Calendar/CalendarAgenda.swift",
  "Calendar/CalendarEventNoteRepository.swift", "Attachments/AttachmentStore.swift", "Attachments/AttachmentMedia.swift",
  "Calendar/CalendarModel.swift", "Calendar/AppleCalendarService.swift",
  "Collections/CollectionModels.swift", "Collections/CollectionRepository.swift", "Collections/CollectionMigration.swift", "Collections/CollectionStore.swift",
  "Collections/CollectionSnapshotPreview.swift"
];
if (fullApp) files.push(
  "Collections/CollectionDeletion.swift",
  "Accounts/LibraryWorkspace.swift", "Accounts/AccountIdentity.swift", "Accounts/AccountPersistence.swift",
  "Services/AccountCloudStore.swift", "Models/AuthUser.swift",
  "Attachments/AttachmentSchemeHandler.swift", "Attachments/AttachmentBlockPreview.swift", "Attachments/AttachmentEditorSheet.swift",
  "App/AppEnvironment.swift", "App/PadWorkspaceModel.swift", "Editor/DocumentEditorCache.swift", "Editor/TipTapEditorSession.swift",
  "Editor/TipTapBridgeTypes.swift", "Editor/TipTapWebView.swift", "Editor/TableEditorTypes.swift",
  "Editor/PageReferencePresentation.swift", "Editor/NestedPageThumbnail.swift", "Editor/NestedPageRow.swift", "Editor/DocumentThumbnailLayout.swift",
  "Editor/PrecomputedTipTapIconData.swift", "Editor/PageCardView.swift", "Editor/CardPhotoService.swift", "Documents/DocumentPreviewCache.swift",
  "Documents/InlineTextColor.swift", "Documents/ImmediateDocumentPreview.swift", "Documents/ImmediateTablePreview.swift", "Documents/DocumentBackgroundFill.swift", "Documents/LibraryDocumentPreview.swift",
  "Search/SearchView.swift", "Tasks/TaskNotificationsManager.swift", "Collections/CollectionCoverSchemeHandler.swift",
  "Resources/VellixDesignSystem.swift", "Resources/VellixAssetIconLibrary.swift", "Resources/VellixSymbolCatalog.swift",
  "Resources/PennedSheetStyle.swift", "Resources/PennedFrostedCard.swift", "Spaces/PennedAppearanceSettingsView.swift"
);
const adapters = {
  "Accounts/LibraryWorkspace.swift": "Accounts/MacLibraryWorkspace.swift",
  "Editor/DocumentEditorCache.swift": "Editor/MacDocumentEditorCache.swift",
  "Editor/TipTapEditorSession.swift": "Editor/MacTipTapEditorSession.swift",
  "Editor/TipTapWebView.swift": "Editor/MacTipTapWebView.swift",
  "Attachments/AttachmentEditorSheet.swift": "Editor/Controls/MacAttachmentEditorSheet.swift"
};
for (const path of files) await symlink(
  adapters[path] ? join(root, "PennedMac", adapters[path]) : join(root, "Vellix", path),
  join(workspace, "Sources/Vellix", path.replaceAll("/", "_")));
for (const file of ["MacWorkspaceModel", "MacWorkspaceState", "MacWindowRegistry"]) {
  await symlink(join(root, "PennedMac/Workspace", file + ".swift"), join(workspace, "Sources/Vellix", file + ".swift"));
}
for (const file of ["MacStyleWidgets", "MacCardThreeModeColorPicker"]) {
  await symlink(join(root, "PennedMac/Appearance", file + ".swift"), join(workspace, "Sources/Vellix", file + ".swift"));
}
for (const file of ["MacControls", "MacCustomControls", "MacValueControls", "MacPrompt"]) {
  await symlink(join(root, "PennedMac/Support", file + ".swift"), join(workspace, "Sources/Vellix", file + ".swift"));
}
await symlink(join(root, "PennedMac/Settings/MacSettingsCategory.swift"), join(workspace, "Sources/Vellix/MacSettingsCategory.swift"));
await symlink(join(root, "PennedMac/Editor/MacDocumentLayout.swift"), join(workspace, "Sources/Vellix/MacDocumentLayout.swift"));
await symlink(join(root, "PennedMac/Editor/MacDocumentScrollBridge.swift"), join(workspace, "Sources/Vellix/MacDocumentScrollBridge.swift"));
await symlink(join(root, "Tests/PennedMacTests/MacWorkspaceTests.swift"), join(workspace, "Tests/CollectionTests/MacWorkspaceTests.swift"));
const cardSource = await readFile(join(root, "Vellix/Editor/PageCardView.swift"), "utf8");
const marker = cardSource.indexOf("\nenum CardImageLoader {");
if (marker < 0) throw new Error("The production image-loader declaration changed; update this harness.");
if (!fullApp) await writeFile(join(workspace, "Sources/Vellix/CardImageLoader.swift"), "import Foundation\nimport ImageIO\n" + cardSource.slice(marker));
function declaration(source, start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  if (first < 0 || last < 0) throw new Error(`The production preview helper changed: ${start}`);
  return source.slice(first, last);
}
const chrome = await readFile(join(root, "Vellix/Documents/LibraryChrome.swift"), "utf8");
const icons = await readFile(join(root, "Vellix/Resources/VellixAssetIconLibrary.swift"), "utf8");
const properties = await readFile(join(root, "Vellix/Collections/CollectionPropertySheets.swift"), "utf8");
const editor = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
const taskSheet = await readFile(join(root, "Vellix/Editor/TaskEditorSheet.swift"), "utf8");
await writeFile(join(workspace, "Sources/Vellix/NativePreviewHelpers.swift"), "import SwiftUI\n" +
  (fullApp ? "" : declaration(icons, "struct VellixAssetIcon:", "struct VellixAssetIconCategory:")) +
  (fullApp ? declaration(taskSheet, "struct TaskEditorRequest:", "\nprivate enum TaskSheetPanel:") : "") +
  (fullApp ? declaration(editor, "struct ThemePatternOverlay:", "struct ThemeCoverArt:") : "") +
  declaration(properties, "struct CollectionOptionChip:", "\nextension View {") +
  declaration(editor, "struct ThemeCoverArt:", "\nprivate struct StoredAttachmentImage:"));
await symlink(join(root, "Vellix/VellixTests/CollectionTests.swift"), join(workspace, "Tests/CollectionTests/CollectionTests.swift"));
await symlink(join(root, "Vellix/VellixTests/DocumentLaunchTests.swift"), join(workspace, "Tests/CollectionTests/DocumentLaunchTests.swift"));
for (const file of ["SpaceTests", "CalendarTests", "DocumentTaskTests", "AttachmentTests", "DocumentTagTests"]) {
  await symlink(join(root, `Vellix/VellixTests/${file}.swift`), join(workspace, `Tests/CollectionTests/${file}.swift`));
}
await symlink(join(root, "Vellix/VellixTests/LibraryOwnershipTests.swift"), join(workspace, "Tests/CollectionTests/LibraryOwnershipTests.swift"));
await symlink(join(root, "Vellix/VellixTests/LibrarySyncTests.swift"), join(workspace, "Tests/CollectionTests/LibrarySyncTests.swift"));
if (fullApp) for (const file of ["SpaceEnvironmentTests", "FolderLibraryTests", "AttachmentBridgeTests", "TagBridgeTests", "LibraryWorkspaceTests", "PadWorkspaceTests", "AppAppearanceTests", "DocumentPreviewTests"]) {
  await symlink(join(root, `Vellix/VellixTests/${file}.swift`), join(workspace, `Tests/CollectionTests/${file}.swift`));
}
await writeFile(join(workspace, "Package.swift"), `// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "PennedCollectionChecks", platforms: [.macOS(${fullApp ? '"26.5"' : '.v15'})],
  dependencies: [.package(name: "GRDB", path: ${JSON.stringify(grdb)})],
  targets: [
    .target(name: "Vellix", dependencies: [.product(name: "GRDB", package: "GRDB")],
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "CollectionTests", dependencies: ["Vellix", .product(name: "GRDB", package: "GRDB")],
      swiftSettings: [.swiftLanguageMode(.v5)])
  ])
`);
console.log(`Headless native Mac tests: ${workspace}`);
// WebKit integration cases need the main run loop without concurrent renderer fixtures.
const processHandle = spawn("swift", ["test", "--package-path", workspace, "--scratch-path", join(tmpdir(), "penned-mac-checks-cache"), "-j", "4", "--no-parallel", "--filter", "MacWorkspaceTests|PadWorkspaceTests|AppAppearanceTests|DocumentPreviewTests|LibraryOwnershipTests|LibraryWorkspaceTests|FolderLibraryTests|SpaceEnvironmentTests"], {
  stdio: "inherit", detached: true,
  env: { ...process.env, PENNED_EDITOR_ASSET_DIRECTORY: join(root, "Vellix/VellixEditor.bundle") }
});
const timeout = setTimeout(() => {
  console.error("Library checks exceeded 600 seconds");
  try { process.kill(-processHandle.pid, "SIGKILL"); } catch {}
}, 600_000);
processHandle.on("error", error => { clearTimeout(timeout); console.error(error); process.exitCode = 1; });
processHandle.on("exit", code => { clearTimeout(timeout); process.exitCode = code ?? 1; });

