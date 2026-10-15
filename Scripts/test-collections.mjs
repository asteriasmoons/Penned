import { mkdtemp, mkdir, readdir, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

// Compile the real persistence/domain files into a headless macOS test module.
// This never builds or launches the Penned application or a simulator.
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
const workspace = await mkdtemp(join(tmpdir(), "penned-collection-checks-"));
await mkdir(join(workspace, "Sources/Vellix"), { recursive: true });
await mkdir(join(workspace, "Tests/CollectionTests"), { recursive: true });
const files = [
  "Persistence/AppDatabase.swift", "Documents/DocumentRecords.swift", "Documents/DocumentRepositories.swift",
  "Documents/DocumentAppearance.swift", "Documents/StructuredTemplateContent.swift", "Documents/FolderHierarchy.swift",
  "Editor/InlineProperty.swift", "Editor/TipTapContentAnalyzer.swift", "Editor/PageCardStyle.swift", "Editor/DocumentPresentationState.swift",
  "Documents/DocumentPreviewContent.swift", "Documents/DocumentPreviewPresentation.swift", "Documents/InlinePropertyPreview.swift", "Editor/DocumentEditorWarmupPolicy.swift",
  "Tasks/DocumentTask.swift", "Tasks/DocumentTaskRepository.swift", "Calendar/CalendarAgenda.swift",
  "Calendar/CalendarEventNoteRepository.swift", "Attachments/AttachmentStore.swift",
  "Collections/CollectionModels.swift", "Collections/CollectionRepository.swift", "Collections/CollectionMigration.swift", "Collections/CollectionStore.swift",
  "Collections/CollectionSnapshotPreview.swift"
];
for (const path of files) await symlink(join(root, "Vellix", path), join(workspace, "Sources/Vellix", path.replaceAll("/", "_")));
const cardSource = await readFile(join(root, "Vellix/Editor/PageCardView.swift"), "utf8");
const marker = cardSource.indexOf("\nenum CardImageLoader {");
if (marker < 0) throw new Error("The production image-loader declaration changed; update this harness.");
await writeFile(join(workspace, "Sources/Vellix/CardImageLoader.swift"), "import Foundation\nimport ImageIO\n" + cardSource.slice(marker));
function declaration(source, start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  if (first < 0 || last < 0) throw new Error(`The production preview helper changed: ${start}`);
  return source.slice(first, last);
}
const chrome = await readFile(join(root, "Vellix/Documents/LibraryChrome.swift"), "utf8");
const icons = await readFile(join(root, "Vellix/Resources/VellixAssetIconLibrary.swift"), "utf8");
const properties = await readFile(join(root, "Vellix/Collections/CollectionPropertySheets.swift"), "utf8");
const editor = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
await writeFile(join(workspace, "Sources/Vellix/NativePreviewHelpers.swift"), "import SwiftUI\n" +
  declaration(chrome, "struct LibraryIcon:", "enum LibrarySearchScope:") +
  declaration(icons, "struct VellixAssetIcon:", "struct VellixAssetIconCategory:") +
  declaration(properties, "struct CollectionOptionChip:", "\nextension View {") +
  declaration(editor, "struct ThemeCoverArt:", "\nprivate struct StoredAttachmentImage:"));
await symlink(join(root, "Vellix/VellixTests/CollectionTests.swift"), join(workspace, "Tests/CollectionTests/CollectionTests.swift"));
await symlink(join(root, "Vellix/VellixTests/DocumentLaunchTests.swift"), join(workspace, "Tests/CollectionTests/DocumentLaunchTests.swift"));
await writeFile(join(workspace, "Package.swift"), `// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "PennedCollectionChecks", platforms: [.macOS(.v15)],
  dependencies: [.package(name: "GRDB", path: ${JSON.stringify(grdb)})],
  targets: [
    .target(name: "Vellix", dependencies: [.product(name: "GRDB", package: "GRDB")],
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "CollectionTests", dependencies: ["Vellix", .product(name: "GRDB", package: "GRDB")],
      swiftSettings: [.swiftLanguageMode(.v5)])
  ])
`);
console.log(`Headless collection tests: ${workspace}`);
const processHandle = spawn("swift", ["test", "--package-path", workspace, "--scratch-path", join(tmpdir(), "penned-collection-checks-cache"), "-j", "4"], { stdio: "inherit" });
processHandle.on("exit", code => { process.exitCode = code ?? 1; });
