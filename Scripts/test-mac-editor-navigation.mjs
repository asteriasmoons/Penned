import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

const read = path => readFile(new URL("../" + path, import.meta.url), "utf8");
const container = await read("PennedMac/Editor/MacDocumentEditorContainer.swift");
const model = await read("PennedMac/Workspace/MacWorkspaceModel.swift");

test("the unrequested bottom formatting bar and extra Insert shortcut are removed", async () => {
    assert.doesNotMatch(container, /MacDocumentEditingToolbar|safeAreaInset\(edge: \.bottom|MacIconButton\("Insert"/);
    await assert.rejects(access(new URL("../PennedMac/Editor/MacDocumentEditingToolbar.swift", import.meta.url)), { code: "ENOENT" });
    const inspector = await read("PennedMac/Inspector/MacDocumentInspector.swift");
    assert.match(inspector, /case \.format: MacFormatInspector\(workspace: workspace, session: model\.session\)/);
    assert.match(inspector, /case \.insert: MacInsertInspector\(workspace: workspace, model: model\)/);
});

test("the actual top Back and Forward buttons still invoke the shared history actions", async () => {
    const header = container.slice(container.indexOf("private var toolbar:"), container.indexOf("private func persistTitle"));
    assert.match(header, /MacIconButton\("Back", icon: "chevleft"\).*workspace\.travel\(-1\).*disabled\(!workspace\.canGoBack\)/);
    assert.match(header, /MacIconButton\("Forward", icon: "chevright"\).*workspace\.travel\(1\).*disabled\(!workspace\.canGoForward\)/);
    const commands = await read("PennedMac/Workspace/MacWorkspaceCommands.swift");
    assert.match(commands, /Button\("Back"\).*travel\(-1\)/);
    assert.match(commands, /Button\("Forward"\).*travel\(1\)/);
    assert.doesNotMatch(header, /MacIconButton\("(?:Insert|Format|Style|Document Info)"/);
    assert.ok(header.includes('MacIconButton(locked ? "Unlock Editor" : "Lock Editor", icon: locked ? "eyeslash" : "eye") { locked.toggle() }'));
    assert.ok(header.includes('Button {} label: { LibraryIcon(name: "sendbutton", size: 17) }'));
    assert.doesNotMatch(header, /ShareLink|Share Text|NSSharingServicePicker/);
    const inspector = await read("PennedMac/Inspector/MacDocumentInspector.swift");
    for (const section of ["insert", "format", "style", "info"]) assert.ok(inspector.includes(`case .${section}:`));
});

test("Back has a scoped parent fallback for direct nested pages rather than requiring an existing history entry", () => {
    assert.match(model, /var canGoBack: Bool \{ activeTab\.historyIndex > 0 \|\| parentBackLocation != nil \}/);
    const fallback = model.slice(model.indexOf("private var parentBackLocation:"), model.indexOf("private var archiveKey:"));
    assert.match(fallback, /tab\.historyIndex == 0 \|\| tab\.history\[tab\.historyIndex - 1\]\.documentID == nil/);
    assert.match(fallback, /document\.parentDocumentID/);
    assert.match(fallback, /parent\.spaceID == spaceID, !parent\.isTrashed, !parent\.isArchived/);
    assert.doesNotMatch(fallback, /cardStyle|collectionID/);
});

test("parent return is inserted only inside the save-safe transition so Forward returns to the child", () => {
    const travel = model.slice(model.indexOf("func travel("), model.indexOf("func switchSpace("));
    assert.match(travel, /let parent = direction == -1 \? parentBackLocation : nil/);
    assert.match(travel, /try await transition \{[\s\S]*guard self\.activeID == tab\.id[\s\S]*try self\.validate\(location\)[\s\S]*tab\.history\.insert\(parent, at: tab\.historyIndex\)/);
    assert.match(travel, /else \{ tab\.historyIndex = index \}/);
    assert.match(travel, /tab\.location = location/);
    assert.doesNotMatch(travel, /self\.open\(|self\.record\(|WKWebView\(|loadHTMLString|CREATE TABLE/);
    const transition = model.slice(model.indexOf("private func transition("), model.indexOf("private func record("));
    assert.ok(transition.indexOf("try await flush()") < transition.indexOf("try change()"));
});

test("the full-height WebView cannot hit-test over the fixed header outside its visible scroll viewport", async () => {
    assert.match(container, /toolbar\.zIndex\(1\)/);
    assert.match(container, /\.clipped\(\)\s+\.contentShape\(Rectangle\(\)\)\s+\.onReceive\(session\.caretUpdates\)/);
    const host = await read("PennedMac/Editor/MacTipTapWebView.swift");
    const macHost = host.slice(host.indexOf("final class TipTapWebViewContainer: NSView"));
    assert.match(macHost, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{[\s\S]*?guard visibleRect\.contains\(convert\(point, from: superview\)\) else \{ return nil \}[\s\S]*?return super\.hitTest\(point\)/);
});

test("native regression coverage includes nested pages cards collection entries Forward and failed saves", async () => {
    const tests = await read("Tests/PennedMacTests/MacWorkspaceTests.swift");
    assert.match(tests, /@Test\(arguments: \["page", "card", "collection"\]\)/);
    assert.match(tests, /workspace\.activeEditor === editor/);
    assert.match(tests, /nestedBackReachesTheParentBeforeTheBrowserAndKeepsExistingTabs/);
    assert.match(tests, /failedSaveDoesNotInsertAParentOrMoveTheNavigationCursor/);
});
