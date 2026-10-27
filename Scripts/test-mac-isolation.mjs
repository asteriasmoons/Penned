import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = path => readFile(join(root, path), "utf8");
const lock = JSON.parse(await read("Scripts/fixtures/mac-ios-source-lock.json"));
const project = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(root, "Vellix.xcodeproj/project.pbxproj")], { encoding: "utf8" })).objects;
const mac = project.CF8C0EA6308548190058BF74;
const ios = project.CFA16D66301AC182007825F0;
const exclusions = project.D00100000000000000000003.membershipExceptions;

test("protected production sources retain the reviewed baseline and documented collection/mobile changes", async () => {
    assert.ok(lock.files.length >= 150);
    for (const file of lock.files) {
        let data = await readFile(join(root, file.path));
        if (file.path === "Vellix/App/AppEnvironment.swift") {
            const completed = 'print("VELLIX-OPEN finishDocumentOpening READY -> show id=\\(document.id)")\n            cancelDocumentOpening()\n            selectedDocumentID = document.id';
            const original = completed.replace("\n            cancelDocumentOpening()", "");
            assert.equal(data.toString().split(completed).length, 2, "successful opens must cancel the pending timeout exactly once");
            data = Buffer.from(data.toString().replace(completed, original));
        }
        assert.equal(createHash("sha256").update(data).digest("hex"), file.sha256, file.path);
    }
});

test("the inspector and its layout column are restricted to document destinations", async () => {
    const workspace = await read("PennedMac/Workspace/MacWorkspaceView.swift");
    assert.match(workspace, /if workspace\.showsInspector \{/);
    assert.match(workspace, /inspectorVisible: workspace\.showsInspector/);
    assert.match(workspace, /if workspace\.canShowInspector \{/);
    const commands = await read("PennedMac/Workspace/MacWorkspaceCommands.swift");
    assert.match(commands, /disabled\(workspace\?\.canShowInspector != true\)/);
});

test("the Mac sidebar has one chevron Space switcher instead of a redundant Space actions menu", async () => {
    const sidebar = await read("PennedMac/Workspace/MacNavigationSidebar.swift");
    const header = sidebar.slice(sidebar.indexOf("var body: some View"), sidebar.indexOf("            ScrollView {"));
    assert.match(header, /Button \{ switchingSpace = true \}/);
    assert.equal((header.match(/LibraryIcon\(name: "chevdown"/g) ?? []).length, 1);
    assert.match(header, /MacSpaceSwitcher\(workspace: workspace\)/);
    assert.doesNotMatch(header, /dotswavy|Space Actions|MacPopoverMenu|Edit Space|Manage Spaces/);
});

test("the Mac sidebar starts with All Docs and does not expose the redundant Home row", async () => {
    const sidebar = await read("PennedMac/Workspace/MacNavigationSidebar.swift");
    assert.match(sidebar, /ForEach\(\[MacDestination\.allDocuments, \.recents, \.tasks, \.calendar, \.collections, \.templates\]\)/);
    assert.doesNotMatch(sidebar, /MacDestination\.home|navigate\(\.home\)|rowLabel\("Home"/);
    assert.match(sidebar, /SettingsLink/);
});

test("the displayed Home tab and view heading say All Docs without redirecting their route", async () => {
    const model = await read("PennedMac/Workspace/MacWorkspaceModel.swift");
    assert.match(model, /case \.home: return "All Docs"/);
    assert.match(model, /case \.allDocuments: return "All Docs"/);
    assert.match(model, /self\.id = id; self\.location = location; self\.history = history \?\? \[location\]/);
    assert.doesNotMatch(model, /replacingLegacyHome/);
    assert.match(await read("PennedMac/Browser/MacDocumentBrowser.swift"), /case \.recents, \.home: return overview\.recent/);
});

test("only the existing native Mac app target owns Mac UI and platform adapters", () => {
    assert.equal(mac.name, "PennedMac");
    assert.ok(mac.fileSystemSynchronizedGroups.includes("CF8C0EA8308548190058BF74"));
    assert.ok(!ios.fileSystemSynchronizedGroups.includes("CF8C0EA8308548190058BF74"));
    for (const id of project[mac.buildConfigurationList].buildConfigurations) {
        const settings = project[id].buildSettings;
        assert.equal(settings.SDKROOT, "macosx");
        assert.equal(settings.SUPPORTED_PLATFORMS, "macosx");
        assert.equal(settings.SUPPORTS_MACCATALYST, "NO");
        assert.equal(settings.PRODUCT_BUNDLE_IDENTIFIER, "im.lystaria.PennedMac");
        assert.equal(settings.ASSETCATALOG_COMPILER_APPICON_NAME, "PennedMacAppIcon");
    }
    assert.equal(Object.values(project).filter(value => value.isa === "PBXNativeTarget" && value.name === "PennedMac").length, 1);
    assert.ok(!project.D00100000000000000000004.membershipExceptions.includes("Assets.xcassets"));
});

test("Mac target excludes the original iPad interface and editor hosts while sharing previews and persistence", () => {
    for (const path of ["VellixApp.swift", "App/PadWorkspaceView.swift", "App/PadWorkspaceModel.swift", "App/PadWorkspaceSidebar.swift", "App/VellixShellView.swift", "Editor/TipTapWebView.swift", "Editor/TipTapEditorSession.swift", "Editor/DocumentEditorView.swift", "Editor/DocumentEditorCache.swift"]) {
        assert.ok(exclusions.includes(path), path);
    }
    for (const path of ["Persistence/AppDatabase.swift", "Documents/DocumentRecords.swift", "Documents/LibraryDocumentPreview.swift", "Documents/DocumentPreviewCache.swift", "Documents/DocumentStyleRepository.swift", "Sync/LibrarySyncEngine.swift", "Data/AppState.swift", "Services/SupabaseEmailAuth.swift"]) {
        assert.ok(!exclusions.includes(path), path);
    }
});

test("Mac WebView ownership and session safety retain the established working contracts", async () => {
    for (const [source, copy] of [["Editor/TipTapWebView.swift", "Editor/MacTipTapWebView.swift"], ["Editor/TipTapEditorSession.swift", "Editor/MacTipTapEditorSession.swift"], ["Editor/DocumentEditorCache.swift", "Editor/MacDocumentEditorCache.swift"]]) {
        let original = await read("Vellix/" + source);
        const mobileAdditions = source === "Editor/TipTapWebView.swift" ? [
            '\n        #if os(iOS)\n        contentController.addUserScript(WKUserScript(source: MobileBlockSelection.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))\n        contentController.addUserScript(WKUserScript(source: MobileEditorInteractions.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))\n        #endif\n',
            '\n        #if os(iOS)\n        if let dictionary = message.body as? [String: Any],\n           dictionary["kind"] as? String == "mobileSlashSuppression",\n           let payload = dictionary["payload"] as? [String: Any],\n           let suppressed = payload["suppressed"] as? Bool {\n            session.setMobileSlashMenuSuppressed(suppressed)\n            return\n        }\n        #endif\n',
        ] : source === "Editor/TipTapEditorSession.swift" ? [
            '    private var mobileSlashMenuSuppressed = false\n',
            '        setMobileSlashMenuSuppressed(false)\n',
            '\n    func dismissSlashMenu() {\n        setMobileSlashMenuSuppressed(true)\n        send(TipTapEditorCommand("mobileDismissSlashMenu"))\n    }\n\n    func setMobileSlashMenuSuppressed(_ suppressed: Bool) {\n        mobileSlashMenuSuppressed = suppressed\n        if suppressed { slashMenuState = nil }\n    }\n',
            '            if mobileSlashMenuSuppressed, state != nil { return }\n',
        ] : [];
        for (const addition of mobileAdditions) {
            assert.equal(original.split(addition).length, 2, "allow only the explicit mobile interaction adapter once: " + source);
            original = original.replace(addition, "");
        }
        let adapter = await read("PennedMac/" + copy);
        if (copy === "Editor/MacTipTapWebView.swift") {
            const installation = "        MacDocumentScrollBridge.install(on: webView)\n";
            assert.equal(adapter.split(installation).length, 2, "install the Mac-only wheel routing exactly once");
            adapter = adapter.replace(installation, "");
            const hitBoundary = '\n    override func hitTest(_ point: NSPoint) -> NSView? {\n        // The full-height editor must not intercept the fixed header outside its scroll viewport.\n        guard visibleRect.contains(convert(point, from: superview)) else { return nil }\n        return super.hitTest(point)\n    }\n';
            assert.equal(adapter.split(hitBoundary).length, 2, "bound native editor hit testing exactly once");
            adapter = adapter.replace(hitBoundary, "");
        }
        assert.ok(adapter.endsWith(original), copy + " must retain the working host/session implementation apart from the explicit Mac scroll/hit-test and iOS interaction adapters");
    }
});

test("Mac gallery directly arranges the existing previews and inspector exposes only connected commands", async () => {
    const browser = await read("PennedMac/Browser/MacDocumentBrowser.swift");
    assert.match(browser, /LibraryDocumentPreview\(/);
    assert.doesNotMatch(browser, /WKWebView|takeSnapshot|drawHierarchy|UIGraphics/);
    const sidebar = await read("PennedMac/Workspace/MacNavigationSidebar.swift");
    assert.match(sidebar, /LibraryDocumentPreview\(document: document, fixedAspectRatio: 0\.72, showsStar: false/);
    const insert = await read("PennedMac/Inspector/MacInsertInspector.swift");
    assert.match(insert, /model\.session\.insertBlock/);
    assert.match(insert, /model\.session\.insertDivider/);
    const format = await read("PennedMac/Inspector/MacFormatInspector.swift");
    assert.match(format, /formatCurrentSelection/);
    assert.match(format, /formatSelectedBlocks/);
    const styles = await read("PennedMac/Inspector/MacStyleGallery.swift");
    assert.match(styles, /environment\.documentStyles\.apply/);
    assert.match(styles, /DocumentStyleThumbnail/);
    assert.match(styles, /NSPanel/);
});

test("Mac gallery suppresses the whole-area focus ring without removing keyboard navigation or card selection", async () => {
    const browser = await read("PennedMac/Browser/MacDocumentBrowser.swift");
    assert.match(browser, /\.scrollPosition\(\$browser\.scroll\)\.focusable\(\)\s+\.focusEffectDisabled\(\)/);
    for (const key of ["return", "rightArrow", "leftArrow", "downArrow", "upArrow"]) {
        assert.ok(browser.includes(`.onKeyPress(.${key})`));
    }
    assert.match(browser, /\.onDeleteCommand/);
    assert.match(browser, /strokeBorder\(browser\.selectedIDs\.contains\(document\.id\) \? VellixSurface\.violet : \.clear/);
    assert.doesNotMatch(browser, /\.focusable\(false\)|NSView\.appearance\(|NSScrollView\.appearance\(/);
});

test("Mac window/account transitions drain pending edits and do not implement new storage or sync mappings", async () => {
    const registry = await read("PennedMac/Workspace/MacWindowRegistry.swift");
    assert.match(registry, /try await flushAll\(\)/);
    assert.match(registry, /try await workspace\.flush\(\)/);
    const model = await read("PennedMac/Workspace/MacWorkspaceModel.swift");
    assert.match(model, /currentOwner\(\) == ownerKey/);
    assert.match(model, /try await flush\(\)/);
    assert.doesNotMatch(model, /CREATE TABLE|CKRecord\(|claimLocalLibrary|accountLibrary\(/);
});

test("native Mac controls reference real Penned custom icon assets", async () => {
    const assets = new Set((await readdir(join(root, "Vellix/Assets.xcassets"))).map(value => value.split(".")[0]));
    for (const folder of ["Inspector", "Workspace", "Browser", "Settings", "Support"]) {
        for (const file of await readdir(join(root, "PennedMac", folder))) {
            if (!file.endsWith(".swift")) continue;
            const source = await read("PennedMac/" + folder + "/" + file);
            for (const match of source.matchAll(/(?:icon:|LibraryIcon\(name:)\s*"([a-z0-9]+)"/g)) assert.ok(assets.has(match[1]), file + ": " + match[1]);
        }
    }
});

test("document styling uses custom Penned swatches, font choices and color panels instead of system pickers", async () => {
    const inspector = await read("PennedMac/Inspector/MacStyleInspector.swift");
    assert.doesNotMatch(inspector, /\b(?:ColorPicker|Picker)\(/);
    assert.match(inspector, /MacColorRow/);
    assert.match(inspector, /MacFontOptions/);
    assert.match(inspector, /MacGradientDirectionControl/);
    const picker = await read("PennedMac/Appearance/MacCardThreeModeColorPicker.swift");
    assert.doesNotMatch(picker, /\bColorPicker\(|NSColorPanel|UIColorPickerViewController/);
    assert.match(picker, /"Palette", "Spectrum", "RGB"/);
    assert.doesNotMatch(picker, /onChange\(of: (?:hue|value\.wrappedValue)\)/);
});

test("native close shortcuts explicitly route through safe tab and window closure", async () => {
    const commands = await read("PennedMac/Workspace/MacWorkspaceCommands.swift");
    assert.match(commands, /closeTab\(workspace\.activeID\)/);
    assert.match(commands, /keyboardShortcut\("w"\)/);
    assert.match(commands, /keyboardShortcut\("w", modifiers: \[\.command, \.shift\]\)/);
    const bridge = await read("PennedMac/Workspace/MacWindowBridge.swift");
    assert.match(bridge, /await workspace\.waitForOperations\(\)/);
    assert.match(bridge, /try await workspace\.flush\(\)/);
    assert.doesNotMatch(bridge, /charactersIgnoringModifiers/);
});

test("Mac application-owned choices and prompts use custom controls", async () => {
    async function audit(folder) {
        for (const entry of await readdir(join(root, folder), { withFileTypes: true })) {
            const path = folder + "/" + entry.name;
            if (entry.isDirectory()) { await audit(path); continue; }
            if (!path.endsWith(".swift") || /MacTipTap|MacDocumentEditorCache|MacCustomControls|MacValueControls|MacPrompt/.test(path)) continue;
            const source = await read(path);
            assert.doesNotMatch(source, /\b(?:Picker|ColorPicker|DatePicker|Slider|Stepper)\(/, path);
            assert.doesNotMatch(source, /\.(?:alert|confirmationDialog)\(/, path);
            assert.doesNotMatch(source, /textFieldStyle\(\.roundedBorder\)/, path);
        }
    }
    await audit("PennedMac");
    const tabs = await read("PennedMac/Workspace/MacWorkspaceTabBar.swift");
    assert.ok(tabs.indexOf('MacIconButton("New Tab"') < tabs.indexOf('.onChange(of: workspace.tabs.count)'));
    const workspace = await read("PennedMac/Workspace/MacWorkspaceView.swift");
    assert.match(workspace, /sharedBackgroundVisibility\(\.hidden\)/);
    assert.doesNotMatch(workspace, /placement: \.principal/);
});
