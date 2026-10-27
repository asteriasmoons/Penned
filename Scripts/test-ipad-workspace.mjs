import { readFile, access } from "node:fs/promises";
import { test } from "node:test";
import assert from "node:assert/strict";

const root = new URL("../Vellix/", import.meta.url);
const read = name => readFile(new URL(name, root), "utf8");

test("the dedicated workspace is gated by iPad idiom, not iPhone size class", async () => {
  const source = await read("App/VellixShellView.swift");
  assert.match(source, /UIDevice\.current\.userInterfaceIdiom == \.pad[\s\S]*?PadWorkspaceView\(environment: environment\)[\s\S]*?else if horizontalSizeClass == \.compact \{\s*compactWorkspace/);
  assert.match(source, /private var compactWorkspace:[\s\S]*?NavigationStack[\s\S]*?compactEditorDeck[\s\S]*?LibraryBottomBar\(\)/);
  assert.match(source, /\.sheet\(item: \$environment\.librarySheet\)/);
  assert.match(source, /\.sheet\(item: \$environment\.spaceSheet\)/);
});

test("one retained sidebar and content hierarchy adapt by placement instead of reconstruction", async () => {
  const source = await read("App/PadWorkspaceView.swift");
  assert.equal((source.match(/PadWorkspaceSidebar\(workspace:/g) ?? []).length, 1);
  assert.equal((source.match(/ForEach\(workspace\.tabs\)/g) ?? []).length, 1);
  assert.match(source, /\.padding\(\.leading, sidebarVisible && !overlaysSidebar/);
  assert.match(source, /sidebarVisible && overlaysSidebar[\s\S]*?Color\.black\.opacity\(0\.48\)/);
  assert.match(source, /\.offset\(x: sidebarVisible \? 0/);
  assert.doesNotMatch(source, /NavigationSplitView|\.id\((?:metrics|geometry|sidebarVisible)/);
});

test("keyboard-safe sidebar decisions use actual window bounds, not screen constants", async () => {
  const source = await read("App/PadWorkspaceView.swift");
  assert.match(source, /window\?\.bounds\.size/);
  assert.match(source, /size != lastSize/);
  assert.match(source, /height: windowSize\.height > 0 \? windowSize\.height : geometry\.size\.height/);
  assert.doesNotMatch(source, /UIScreen\.main|UIDevice\.current\.orientation/);
});

test("editors remain one cached deck independent of tab and sidebar navigation", async () => {
  const source = await read("App/PadWorkspaceView.swift");
  assert.match(source, /@ObservedObject var cache: DocumentEditorCache/);
  assert.match(source, /ForEach\(cache\.preparedModels, id: \\.documentID\)/);
  assert.match(source, /DocumentEditorView\(model: model, sidebarAction: sidebarAction\)/);
  assert.match(source, /\.opacity\(selectedID == model\.documentID \? 1 : 0\)/);
  assert.doesNotMatch(source, /WKWebView|ImageRenderer|TipTapEditorSession\(\)/);
  const model = await read("App/PadWorkspaceModel.swift");
  assert.match(model, /try await environment\.prepareForWorkspaceNavigation\(\)/);
  assert.doesNotMatch(model, /editorCache\.remove|discardPendingSave/);
});

test("gallery layout uses the exact existing previews and preserves phone columns", async () => {
  const source = await read("Documents/DocumentBrowserView.swift");
  assert.match(source, /LibraryDocumentPreview\(document: document, visibleHeightFraction: previewHeightFraction\)/);
  assert.match(source, /if let phoneFraction = LibraryDocumentPreview\.phoneGalleryHeightFraction/);
  assert.match(source, /return mode == \.all && displayTitle == nil \? 0\.7 : phoneFraction/);
  assert.match(source, /return workspace == nil \? 1 : PadWorkspaceMetrics\.galleryPreviewHeightFraction/);
  assert.match(source, /workspace == nil \? 2 : \(availableWidth > 0/);
  assert.match(source, /PadWorkspaceMetrics\.galleryColumns/);
  assert.match(source, /ForEach\(0\.\.<columnCount/);
  assert.match(source, /gallerySpacing: CGFloat = 10/);
  assert.match(source, /LazyVStack\(spacing: gallerySpacing\)/);
  assert.match(source, /\.frame\(width: cardWidth\)/);
  assert.match(source, /PadWorkspaceMetrics\.galleryCardWidth/);
  assert.match(source, /\.padding\(\.horizontal, 16\)/);
  assert.match(source, /\.frame\(maxWidth: \.infinity, alignment: workspace == nil \? \.center : \.leading\)/);
  assert.match(source, /\.frame\(maxWidth: workspace == nil \? \.infinity : nil\)/);
  assert.match(source, /\.scrollPosition\(\$scrollPosition\)/);
  assert.match(source, /workspace == nil \|\| !query\.isEmpty/);
  assert.doesNotMatch(source, /padToolbar|showingSearch|compactGallery/);
  assert.doesNotMatch(source, /ImageRenderer|WKWebView/);
});

test("highlighted iPad controls are removed without removing phone controls or document actions", async () => {
  const source = await read("Documents/DocumentBrowserView.swift");
  assert.match(source, /if workspace == nil \{\s*Picker\("Sort", selection: \$sort\)/);
  for (const operation of [/environment\.requestMove\(/, /environment\.starDocuments\(/, /trashSelection\(\)/]) assert.match(source, operation);
  assert.match(source, /try await workspace\.openDocument\(document\)/);
  const workspace = await read("App/PadWorkspaceView.swift");
  const header = workspace.slice(workspace.indexOf("private var header:"), workspace.indexOf("private func toggleSidebar"));
  assert.doesNotMatch(header, /PadIconButton\("(?:Back|Forward|New Document)"/);
  assert.match(header, /PadIconButton\("Toggle Sidebar", icon: "sidebar"/);
  assert.match(header, /LibraryIcon\(name: "dotswavy"/);
  assert.match(workspace, /\.toolbar\(\.hidden, for: \.navigationBar\)/);
});

test("sidebar exposes tabs, Space actions, existing destinations and scoped folder/tag data", async () => {
  const source = await read("App/PadWorkspaceSidebar.swift");
  for (const text of ["Tabs", "New Tab", "Starred", "Folders", "Tags", "New Document"]) assert.ok(source.includes(`"${text}"`));
  for (const operation of ["workspace.selectTab", "workspace.closeTab", "workspace.newTab", "environment.overview.favorites", "environment.overview.folders", "environment.tags.catalogue()", "SpacePickerSheet()", "FolderContextMenu(folder: folder)"]) assert.ok(source.includes(operation));
  assert.match(source, /visited\.insert\(folder\.id\)\.inserted/);
  assert.doesNotMatch(source, /Connections|Shared with Me|Image\(systemName:/);
});

test("new workspace controls use assets that actually exist", async () => {
  for (const file of ["App/PadWorkspaceView.swift", "App/PadWorkspaceSidebar.swift", "App/PadSettingsView.swift"]) {
    const source = await read(file);
    assert.doesNotMatch(source, /Image\(systemName:/);
    for (const match of source.matchAll(/(?:LibraryIcon\(name:|icon:) "([A-Za-z0-9_-]+)"/g)) {
      await access(new URL(`Assets.xcassets/${match[1]}.imageset/Contents.json`, root));
    }
  }
});

test("both sidebar controls use the requested sidebar asset", async () => {
  assert.match(await read("App/PadWorkspaceView.swift"), /if !sidebarVisible \{\s*PadIconButton\("Toggle Sidebar", icon: "sidebar"/);
  assert.match(await read("App/PadWorkspaceSidebar.swift"), /PadIconButton\("Hide Sidebar", icon: "sidebar"/);
  await access(new URL("Assets.xcassets/sidebar.imageset/Contents.json", root));
});

test("open documents hide the workspace bar and put the sidebar action beside the editor back button", async () => {
  const workspace = await read("App/PadWorkspaceView.swift");
  assert.match(workspace, /if environment\.selectedDocumentID == nil \{ header \}/);
  assert.match(workspace, /editorSidebarAction: \(\(\) -> Void\)\? \{\s*guard !sidebarVisible else \{ return nil \}\s*return \{ toggleSidebar\(\) \}/);
  assert.match(workspace, /sidebarAction: editorSidebarAction/);
  const editor = await read("Editor/DocumentEditorView.swift");
  assert.match(editor, /init\(model: DocumentEditorModel, sidebarAction: \(\(\) -> Void\)\? = nil\)/);
  assert.match(editor, /if let sidebarAction \{[\s\S]*?editorAssetIcon\("sidebar"[\s\S]*?Button\(action: backAction\)/);
  assert.match(editor, /accessibilityIdentifier\("ipad-editor-sidebar-toggle"\)/);
  assert.match(editor, /showsDocumentHeading: workspace == nil/);
  assert.match(editor, /if showsDocumentHeading && isThemed && !isCompact/);
});

test("the bottom crop preserves the existing renderer and isolates phone gallery overrides from iPad sizing", async () => {
  const preview = await read("Documents/LibraryDocumentPreview.swift");
  assert.match(preview, /visibleHeightFraction: CGFloat = 1/);
  assert.match(preview, /Image\(decorative: snapshot, scale: 1\)\.resizable\(\)\.scaledToFill\(\)/);
  assert.match(preview, /height: geometry\.size\.height, alignment: \.top/);
  assert.match(preview, /\/ min\(1, max\(0\.01, visibleHeightFraction\)\)/);
  assert.match(preview, /\.clipped\(\)/);
  assert.match(preview, /frame\(width: current\.isThemed \? 376 : 360, height: 740/);
  assert.match(preview, /UIDevice\.current\.userInterfaceIdiom == \.phone \? 0\.6 : nil/);
  assert.match(await read("Tags/TagBrowserView.swift"), /visibleHeightFraction: LibraryDocumentPreview\.phoneGalleryHeightFraction\s+\?\? \(workspace == nil \? 1 : PadWorkspaceMetrics\.galleryPreviewHeightFraction\)/);
  const metrics = await read("App/PadWorkspaceModel.swift");
  assert.match(metrics, /galleryWidthIncrease: CGFloat = 1\.1/);
  assert.match(metrics, /galleryCornerEnlargement: CGFloat = 1\.05/);
  assert.match(metrics, /galleryPreviewHeightFraction: CGFloat = 0\.8 \/ galleryWidthIncrease/);
});

test("ordinary document opening stays in the active tab and explicit new-tab actions remain", async () => {
  assert.match(await read("App/PadWorkspaceModel.swift"), /func openDocument\(_ document: DocumentRecord, newTab: Bool = false\)/);
  assert.match(await read("Documents/DocumentBrowserView.swift"), /workspace\.openDocument\(document, newTab: true\)[\s\S]*?Open in New Tab/);
  assert.match(await read("App/PadWorkspaceSidebar.swift"), /workspace\.newTab\(\)/);
});

test("iPad editor controls remain fixed and have a small top gap without changing phone spacing", async () => {
  const editor = await read("Editor/DocumentEditorView.swift");
  assert.match(editor, /let isCompact = workspace != nil \|\| proxy\.size\.width < 620/);
  assert.match(editor, /maxWidth: workspace == nil \? 900 : 720/);
  assert.match(editor, /maxWidth: workspace != nil \? 720 : \(isCompact \? \.infinity : 900\)/);
  assert.match(editor, /let scrollWidth: CGFloat\? = workspace == nil \? nil : size\.width/);
  assert.match(editor, /let scrollHeight: CGFloat\? = workspace == nil \? nil : size\.height/);
  assert.match(editor, /\.frame\(width: scrollWidth, height: scrollHeight\)/);
  assert.match(editor, /\.padding\(\.top, workspace != nil \? 8 : \(isCompact \? 0 : 56\)\)/);
  assert.match(editor, /ScrollView\(showsIndicators: false\)[\s\S]*?\.onChange\(of: model\.tableEditorRequest\?\.id\)[\s\S]*?EditorTopControls\(/);
  const workspace = await read("App/PadWorkspaceView.swift");
  assert.match(workspace, /\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\s*\.overlay \{\s*ZStack \{\s*PadEditorDeck/);
});

test("WebKit recovery reuses the existing view and startup snapshots cannot save empty content", async () => {
  const view = await read("Editor/TipTapWebView.swift");
  assert.match(view, /func webViewWebContentProcessDidTerminate[\s\S]*?session\.markNavigationStarted\(\)\s*loadEditor\(webView, self\)/);
  for (const dependency of ["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js", "vellix-tables.css"]) {
    assert.ok(view.includes(`"${dependency}"`));
  }
  const session = await read("Editor/TipTapEditorSession.swift");
  assert.match(session, /pendingDocument = documentForRecovery\?\(\) \?\? pendingDocument \?\? recoveryDocument/);
  assert.match(session, /case \.documentChanged\(let json\), \.documentSnapshot\(let json\):[\s\S]*?guard isReady, !isLoadingDocument, let loadedDocumentID/);
  assert.match(session, /return \(document\.id, self\.latestJSON \?\? document\.tipTapJSON\)/);
  assert.match(session, /self\.loadGeneration == generation, self\.isReady/);
  assert.match(session, /callAsyncJavaScript\("await window\.tiptapCommand\(name, args\);"/);
  assert.doesNotMatch(session, /let js = "void window\.tiptapCommand/);
});

test("settings have adaptive category navigation and reuse live account/library/Space controls", async () => {
  const source = await read("App/PadSettingsView.swift");
  assert.match(source, /@State private var selected: PadSetting = \.space/);
  assert.match(source, /geometry\.size\.width >= 760/);
  assert.match(source, /selected = item; showingCategories = false/);
  assert.match(source, /AccountSettingsView\(embeddedInWorkspace: true\)/);
  assert.match(source, /AccountLibrarySheet\(identity: identity, embeddedInWorkspace: true\)/);
  assert.match(source, /environment\.spaceSheet = \.edit\(space\)/);
  assert.match(source, /try await environment\.deleteSpace\(\$0\)/);
  assert.match(source, /\.confirmationDialog\("Permanently delete this Space/);
  assert.doesNotMatch(source, /Not available yet|PlaceholderView|Coming Soon/);
});

test("embedded settings do not change the standalone iPhone account and sheet defaults", async () => {
  const account = await read("Accounts/AccountSettingsView.swift");
  assert.match(account, /var embeddedInWorkspace = false/);
  assert.match(account, /if !embeddedInWorkspace \{ HStack \{\s*SettingsBackButton\(\)/);
  const library = await read("Accounts/AccountLibrarySheet.swift");
  assert.match(library, /var embeddedInWorkspace = false/);
  assert.match(library, /if embedded \{ content \}\s*else \{ content\.pennedSheet/);
});

test("the navigation layer never creates databases, assigns ownership or alters CloudKit mapping", async () => {
  for (const file of ["App/PadWorkspaceModel.swift", "App/PadWorkspaceView.swift", "App/PadWorkspaceSidebar.swift", "App/PadSettingsView.swift"]) {
    assert.doesNotMatch(await read(file), /import GRDB|import CloudKit|AppDatabase\.make|\.scoped\(to:|\.execute\(sql:|claimLocalLibrary|\.adopt\(|CKRecord\(/);
  }
});

test("inactive calendar tabs stop background work without changing the phone default", async () => {
  const view = await read("App/PadWorkspaceView.swift");
  assert.match(view, /\.environment\(\\.pennedWorkspaceTabActive, tab\.id == workspace\.activeID\)/);
  const model = await read("App/PadWorkspaceModel.swift");
  assert.match(model, /PadWorkspaceActiveKey: EnvironmentKey \{ static let defaultValue = true/);
  assert.match(await read("Calendar/CalendarView.swift"), /\.onChange\(of: workspaceTabActive\)/);
});

test("each iPad Home tab owns its search model while iPhone still uses the existing shared search", async () => {
  assert.match(await read("App/PadWorkspaceView.swift"), /StateObject\(wrappedValue: SearchModel\(service: environment\.search\)\)/);
  const home = await read("Documents/HomeView.swift");
  assert.match(home, /search: SearchModel\? = nil/);
  assert.match(home, /search \?\? environment\.librarySearch/);
  assert.match(home, /guard workspaceTabActive, environment\.isLibrarySearchRequested/);
});

test("Tasks reads all scoped tasks and Collections includes nested owner pages", async () => {
  const source = await read("App/PadWorkspaceView.swift");
  assert.match(source, /tasks = try environment\.tasks\.all\(\)/);
  assert.match(source, /CalendarTaskRow\(model: model, entry: CalendarTaskEntry/);
  assert.match(source, /owners = try environment\.documents\.editorDocuments\(\)\.filter/);
  assert.match(source, /collectionIDs\(forDocument: document\.id\)/);
});

test("Space ordering and Daily Notes search remain usable without native navigation toolbars", async () => {
  const settings = await read("App/PadSettingsView.swift");
  assert.match(settings, /struct PadSpaceManagementView:[\s\S]*?EditButton\(\)[\s\S]*?\.environment\(\\.editMode, \$editMode\)/);
  assert.match(settings, /DailyNotesSettingsView\(isWorkspaceEmbedded: true\)/);
  const notes = await read("DailyNotes/DailyNotesSettingsView.swift");
  assert.match(notes, /var isWorkspaceEmbedded = false/);
  assert.match(notes, /if onSelected != nil \|\| isWorkspaceEmbedded \{ PennedSheetSearchField/);
});
