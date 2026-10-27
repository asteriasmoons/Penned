import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

// Runs the shipping editor in JSDOM; never compiles or launches the app.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { JSDOM } = await import(pathToFileURL(join(backend, "node_modules/jsdom/lib/api.js")));
const files = ["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js"];
const scripts = await Promise.all(files.map(file => readFile(join(root, "Vellix/VellixEditor.bundle", file), "utf8")));
const p = (id, text) => ({ type: "paragraph", attrs: { id }, ...(text ? { content: [{ type: "text", text }] } : {}) });
const item = (id, text, task = null) => ({ type: "taskItem", attrs: { id, checked: false, trackedTask: task }, content: [p(id + "-text", text)] });
const list = (...items) => ({ type: "taskList", attrs: { id: randomUUID() }, content: items });
const doc = content => ({ type: "doc", content });
const task = () => ({ id: randomUUID(), occurrenceID: randomUUID(), reminderEnabled: false, history: [] });
const copy = value => JSON.parse(JSON.stringify(value));
const wait = () => new Promise(resolve => setTimeout(resolve, 340));

async function fixture(t, content, mobile = true) {
    const dom = new JSDOM("<!doctype html><html><body><main class='vellix-editor-page'><div id='editor'></div></main></body></html>",
        { runScripts: "outside-only", pretendToBeVisual: true, url: "https://vellix.test" });
    t.after(() => dom.window.close());
    const w = dom.window, events = [];
    w.console.log = w.console.info = () => {};
    w.ResizeObserver = class { observe() {} disconnect() {} };
    w.Range.prototype.getClientRects = () => [];
    w.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 100, bottom: 24 });
    w.crypto.randomUUID = randomUUID;
    w.webkit = { messageHandlers: { tiptap: { postMessage: event => events.push(event) } } };
    if (mobile) {
        const source = await readFile(join(root, "Vellix/Editor/MobileBlockSelection.swift"), "utf8");
        w.eval(source.match(/static let script = #"""\n([^]*?)\n"""#/)[1]);
    }
    scripts.forEach(source => w.eval(source));
    await w.tiptapCommand("setContent", { document: content });
    const editor = w.document.querySelector(".tiptap-editor").editor;
    const command = (name, args) => w.tiptapCommand(name, args);
    const completions = () => events.filter(e => e.kind === "taskCompletionRequest");
    return { w, editor, events, command, completions };
}

for (const mobile of [true, false]) {
    const platform = mobile ? "mobile provider" : "Mac editor";
    test(`${platform}: a single tap completes once after the double-tap window, even after typing`, async t => {
        const metadata = task(), h = await fixture(t, doc([list(item("source", "Task", metadata))]), mobile);
        h.editor.commands.setTextSelection(3);
        h.editor.commands.insertContent("Typed ");
        h.w.document.querySelector("label").click();
        assert.equal(h.completions().length, 0);
        await wait();
        assert.equal(h.completions().length, 1);
        assert.equal(h.completions()[0].payload.skipped, false);
        assert.equal(h.completions()[0].payload.completed, true);
        assert.match(h.completions()[0].payload.text, /Typed/);
    });
    test(`${platform}: a double tap skips exactly one occurrence without completing first`, async t => {
        const metadata = task(), h = await fixture(t, doc([list(item("source", "Task", metadata))]), mobile);
        h.w.document.querySelector("label").click();
        h.w.document.querySelector("label").click();
        await wait();
        assert.equal(h.completions().length, 1);
        assert.equal(h.completions()[0].payload.skipped, true);
        const saved = { ...metadata, history: [{ id: metadata.occurrenceID, completedAt: Date.now() / 1000, outcome: "skipped" }] };
        assert.equal(await h.command("taskComplete", { blockId: "source", taskID: metadata.id,
            expectedOccurrenceID: metadata.occurrenceID, task: saved, checked: true }), true);
        assert.equal(h.w.document.querySelector("input").checked, true);
        assert.equal(h.w.document.querySelector("input").indeterminate, true);
        const json = await h.command("getDocument", {});
        assert.equal(json.content[0].content[0].attrs.checked, true, "terminal skips must not become outstanding reminders");
        assert.equal(json.content[0].content[0].attrs.trackedTask.history[0].outcome, "skipped");
    });
}

test("green-dot link targets the stable task-history route without changing content or task state", async t => {
    const metadata = task(), h = await fixture(t, doc([list(item("source", "Task", metadata))]));
    const before = copy(await h.command("getDocument", {}));
    const link = h.w.document.querySelector(".vellix-task-history");
    assert.equal(link.hidden, false);
    assert(link.querySelector("i"));
    link.click();
    assert.equal(h.events.findLast(e => e.kind === "pageOpenRequest").payload.documentId, "vellix-task-page:" + metadata.id);
    assert.deepEqual(copy(await h.command("getDocument", {})), before);
    assert.equal(h.completions().length, 0);
    await h.command("taskConvert", { blockId: "source", enabled: false });
    assert.equal(h.w.document.querySelector(".vellix-task-history").hidden, true);
});

test("reminder timestamps explicitly use AM/PM with the recurrence time zone", async t => {
    const metadata = { ...task(), reminderEnabled: true, scheduledAt: Date.parse("2026-10-20T21:20:00Z") / 1000,
        recurrence: { frequency: "daily", interval: 1, timeZoneID: "UTC" } };
    const h = await fixture(t, doc([list(item("source", "Task", metadata))]));
    assert.match(h.w.document.querySelector(".vellix-task-metadata").textContent, /9:20 PM/);
});

test("task edits during the tap window do not cancel the action; deleting the block does cancel it", async t => {
    const h = await fixture(t, doc([list(item("source", "Task", task())), p("tail", "Tail")]));
    h.w.document.querySelector("label").click();
    h.editor.commands.setTextSelection(3); h.editor.commands.insertContent("New ");
    await wait();
    assert.equal(h.completions().length, 1);
    assert.match(h.completions()[0].payload.text, /New/);
    await h.command("taskRelease", { blockId: "source" });
    h.w.document.querySelector("label").click();
    h.editor.commands.setContent(doc([p("tail", "Tail")]));
    await wait();
    assert.equal(h.completions().length, 1);
});

function historyDocument(taskID, occurrences, text = "Recorded entry") {
    return { type: "doc", attrs: { taskHistoryProjection: { taskID, sourceTitle: "Task", occurrences } },
        content: [p("notes", "My notes"), ...occurrences.map(id => list(item(id, text)))] };
}

test("legacy stored history documents retain edits and projection watermarks through save/reload", async t => {
    const id = randomUUID(), occurrence = randomUUID(), h = await fixture(t, historyDocument(id, [occurrence]));
    h.editor.commands.setTextSelection(2); h.editor.commands.insertContent("Edited ");
    h.w.document.querySelector("label").click();
    assert.equal(h.w.document.querySelector("input").checked, true, "recorded checklist entries remain editable");
    assert.equal(h.completions().length, 0, "record edits must not schedule a new tracked task");
    const saved = await h.command("getDocument", {});
    assert.equal(saved.attrs.taskHistoryProjection.taskID, id);
    assert.deepEqual(copy(saved.attrs.taskHistoryProjection.occurrences), [occurrence]);
    await h.command("setContent", { document: saved });
    assert.match(h.editor.state.doc.textContent, /Edited/);
    assert.deepEqual(copy((await h.command("getDocument", {})).attrs), copy(saved.attrs));
});

test("live history append preserves edited records, pending typing, marks and caret instead of replacing the document", async t => {
    const id = randomUUID(), old = randomUUID(), next = randomUUID();
    const h = await fixture(t, historyDocument(id, [old], "Edited recorded text"));
    h.editor.commands.setTextSelection(2);
    h.editor.commands.toggleBold(); h.editor.commands.insertContent("Unsaved typing ");
    const selection = h.editor.state.selection;
    const incoming = historyDocument(id, [old, next], "Original automated text");
    assert.equal(await h.command("taskHistoryRefresh", { document: incoming }), true);
    assert.match(h.editor.state.doc.textContent, /Unsaved typing/);
    assert.match(h.editor.state.doc.textContent, /Edited recorded text/);
    assert.equal(h.editor.state.selection.from, selection.from);
    assert.equal(h.editor.state.selection.to, selection.to);
    assert.equal(h.w.document.querySelectorAll("label").length, 2);
    assert(h.w.document.querySelector("strong"));
    await h.command("taskHistoryRefresh", { document: incoming });
    assert.equal(h.w.document.querySelectorAll("label").length, 2, "delivery is idempotent");
    const snapshots = h.events.filter(event => event.kind === "taskSnapshot").length;
    incoming.attrs.taskHistoryProjection = { occurrences: [next, old], taskID: id, sourceTitle: "Task" };
    await h.command("taskHistoryRefresh", { document: incoming });
    assert.equal(h.events.filter(event => event.kind === "taskSnapshot").length, snapshots,
        "bridge dictionary/occurrence ordering must not create a save-refresh loop");
});

test("deleted history entries are not resurrected, and source undo retracts only recorded occurrences", async t => {
    const id = randomUUID(), old = randomUUID(), h = await fixture(t, historyDocument(id, [old]));
    let target;
    h.editor.state.doc.descendants((node, pos) => { if (node.attrs.id === old) target = { pos, size: node.nodeSize }; });
    h.editor.view.dispatch(h.editor.state.tr.deleteRange(target.pos, target.pos + target.size));
    await h.command("taskHistoryRefresh", { document: historyDocument(id, [old]) });
    assert.equal(h.w.document.querySelectorAll("label").length, 0);
    const next = randomUUID();
    await h.command("taskHistoryRefresh", { document: historyDocument(id, [old, next]) });
    assert.equal(h.w.document.querySelectorAll("label").length, 1);
    await h.command("taskHistoryRefresh", { document: historyDocument(id, []) });
    assert.equal(h.w.document.querySelectorAll("label").length, 0);
    assert.match(h.editor.state.doc.textContent, /My notes/);
});

test("ordinary document serialization does not gain projection metadata", async t => {
    const h = await fixture(t, doc([p("text", "Ordinary document")]));
    const saved = await h.command("getDocument", {});
    assert.equal(saved.attrs.taskHistoryProjection, null);
});

test("history is a non-editable shared Penned sheet titled with the actual task text", async () => {
    const sheet = await readFile(join(root, "Vellix/Tasks/TaskHistorySheet.swift"), "utf8");
    assert.match(sheet, /private var title: String \{ task\.text\.trimmedNonEmpty \?\? "Untitled Task" \}/);
    assert.match(sheet, /\.pennedSheet\(title: title, close: \{ dismiss\(\) \}\)/);
    assert.match(sheet, /\.pennedSheetField\(\)/);
    assert.match(sheet, /PennedSheetStyle\.accent/);
    assert.match(sheet, /VellixSurface\.coral/);
    assert.match(sheet, /\.font\(\.system\(\.body, design: \.rounded\)\.weight\(\.black\)\)/);
    assert.match(sheet, /"checkwavy" : "xmarkwavy"/);
    assert.doesNotMatch(sheet, /TextField|TextEditor|DatePicker|Toggle\(|TapGesture|onTapGesture|setTaskCompleted|setCompleted\(|saveEditorJSON|\.rename\(|TipTapWebView|\.setContent\(/);
});

test("task-history publisher consumers explicitly import Combine", async () => {
    for (const file of ["Vellix/Tasks/TaskHistorySheet.swift", "Vellix/Editor/DocumentEditorView.swift", "PennedMac/Editor/MacDocumentEditorContainer.swift"]) {
        const source = await readFile(join(root, file), "utf8");
        assert.match(source, /\.receive\(on: RunLoop\.main\)/, file);
        assert.match(source, /^import Combine$/m, file);
    }
});

test("pending Calendar repeat circles stay tappable and send the selected occurrence identity", async () => {
    const agenda = await readFile(join(root, "Vellix/Calendar/CalendarAgenda.swift"), "utf8");
    const rows = await readFile(join(root, "Vellix/Calendar/CalendarAgendaRows.swift"), "utf8");
    const model = await readFile(join(root, "Vellix/Calendar/CalendarModel.swift"), "utf8");
    const circle = await readFile(join(root, "Vellix/Tasks/TaskCompletionCircle.swift"), "utf8");
    assert.match(agenda, /var canComplete: Bool \{ kind != \.completed \}/);
    assert.match(agenda, /occurrenceID: DocumentTaskMetadata\.projectedOccurrenceID\(for: next\)/);
    assert.match(rows, /TaskCompletionCircle\(isChecked: entry\.isCompleted, isSkipped: entry\.isSkipped/);
    assert.match(rows, /isEnabled: entry\.canComplete && !isCompleting/);
    assert.match(rows, /Task \{ await model\.complete\(entry, skipped: skipped\) \}/);
    assert.match(circle, /var hitSize: CGFloat = 44/);
    assert.match(circle, /\.frame\(width: hitSize, height: hitSize, alignment: alignment\)\s+\.contentShape\(Rectangle\(\)\)/);
    assert.match(rows, /calendar-task-completion-/);
    assert.doesNotMatch(rows, /Future occurrence|Complete the current occurrence first|becomes available after/);
    assert.match(model, /try await completeTask\(entry\.task\.id, entry\.occurrenceID, skipped \|\| !entry\.isCompleted, skipped\)/);
    assert.match(model, /!completingTasks\.contains\(entry\.task\.id\)/);
});

test("Calendar and task-page circles share exclusive single-complete/double-skip gestures and document-sized check/X visuals", async () => {
    const circle = await readFile(join(root, "Vellix/Tasks/TaskCompletionCircle.swift"), "utf8");
    const header = await readFile(join(root, "Vellix/Tasks/TaskHistoryPageHeader.swift"), "utf8");
    const agenda = await readFile(join(root, "Vellix/Calendar/CalendarAgenda.swift"), "utf8");
    assert.match(header, /TaskCompletionCircle\(isChecked: task\.checked, isSkipped: task\.metadata\.isSkipped/);
    assert.match(header, /finish\(skipped: \$0\)/);
    assert.match(circle, /TapGesture\(count: 2\)\.exclusively\(before: TapGesture\(\)\)/);
    assert.match(circle, /case \.first: finish\(true\)\s+case \.second: finish\(false\)/);
    assert.match(circle, /guard isEnabled else \{ return \}/);
    assert.match(circle, /\.allowsHitTesting\(isEnabled\)/);
    assert.match(circle, /\.accessibilityAction \{ if isEnabled \{ finish\(false\) \} \}/);
    assert.match(circle, /\.accessibilityAction\(named: Text\("Skip occurrence"\)\) \{ if isEnabled \{ finish\(true\) \} \}/);
    assert.match(circle, /\.frame\(width: 19, height: 19\)/);
    assert.match(circle, /isSkipped \? "xmarkwavy" : "checkwavy", size: 13/);
    assert.match(circle, /Circle\(\)\.fill\(isMarked \? PennedSheetStyle\.accent : \.clear\)/);
    assert.doesNotMatch(circle, /simultaneousGesture|highPriorityGesture|DragGesture|Task\.sleep|asyncAfter|ProgressView/);
    assert.match(agenda, /var isSkipped: Bool \{ task\.metadata\.history\.contains \{ \$0\.id == occurrenceID && \$0\.outcome == \.skipped \} \}/);
});

test("iPhone, iPad and Mac Calendar callbacks all forward skip outcomes to the document completion path", async () => {
    const model = await readFile(join(root, "Vellix/Calendar/CalendarModel.swift"), "utf8");
    assert.match(model, /var completeTask: \(\(String, String, Bool, Bool\) async throws -> Void\)\?/);
    assert.match(model, /func complete\(_ entry: CalendarTaskEntry, skipped: Bool = false\)/);
    for (const file of ["Vellix/App/AppEnvironment.swift", "Vellix/App/PadWorkspaceView.swift", "PennedMac/Workspace/MacWorkspaceModel.swift"]) {
        const source = await readFile(join(root, file), "utf8");
        const start = source.indexOf("calendar.completeTask =");
        const callback = source.slice(start, source.indexOf("\n        }", start));
        assert.match(callback, /completed, skipped in/, file);
        assert.match(callback, /setTaskCompleted\(id: id, completed: completed, expectedOccurrenceID: (?:occurrenceID|occurrence), skipped: skipped\)/, file);
    }
});

test("Calendar completion preserves source saves, Space guards, selected dates, editor sync and reminder flushing", async () => {
    const source = await readFile(join(root, "Vellix/App/AppEnvironment.swift"), "utf8");
    const action = source.slice(source.indexOf("func setTaskCompleted("), source.indexOf("func openCalendarDocument("));
    assert.match(action, /try await model\.captureAndSave\(\)/);
    assert.match(action, /try await page\.captureAndSave\(\)/);
    assert.match(action, /guard generation == workspaceGeneration, !isSwitchingSpace/);
    assert.match(action, /let occurrenceID = expectedOccurrenceID \?\? current\.metadata\.occurrenceID/);
    assert.match(action, /tasks\.setCompleted\(taskID: id, occurrenceID: occurrenceID, completed: completed, skipped: skipped\)/);
    assert.match(action, /receiveExternalTaskChange\(saved\)/);
    assert.match(action, /await taskNotifications\.flush\(\)/);
    assert.doesNotMatch(action, /expectedOccurrenceID != current\.metadata\.occurrenceID/);
    const repository = await readFile(join(root, "Vellix/Tasks/DocumentTaskRepository.swift"), "utf8");
    const write = repository.slice(repository.indexOf("func setCompleted("));
    assert.match(write, /try database\.write/);
    assert.match(write, /SpaceOwnership\.document\(document\.id, scope: spaceID/);
    assert.match(write, /metadata\.completingOccurrence\(occurrenceID, completed: completed, skipped: skipped/);
    assert.match(write, /DocumentTaskIndex\.updating\(document\.tipTapJSON/);
});

test("selected Calendar dates are validated and appended without advancing an earlier unfinished occurrence", async () => {
    const source = await readFile(join(root, "Vellix/Tasks/DocumentTask.swift"), "utf8");
    const action = source.slice(source.indexOf("func completingOccurrence("), source.indexOf("func independent()"));
    assert.match(action, /timestamp\.isFinite/);
    assert.match(action, /requestedID == Self\.projectedOccurrenceID\(for: scheduled\)/);
    assert.match(action, /!history\.contains\(where: \{ \$0\.scheduledAt == timestamp \}\)/);
    assert.match(action, /if scheduled == current \{\s+return try completing\(/);
    assert.match(action, /try recurrence\.containsOccurrence\(scheduled, after: current\)/);
    assert.match(action, /occurrence\.occurrenceID = UUID\(\)\.uuidString/);
    assert.match(action, /let result = try occurrence\.completing\(completed, skipped: skipped, text: text, at: date\)/);
    assert.match(action, /var copy = self\s+copy\.history = result\.metadata\.history\s+return \(copy, false\)/);
    assert.doesNotMatch(action, /copy\.scheduledAt\s*=|copy\.occurrenceID\s*=/);
    const validation = source.slice(source.indexOf("func containsOccurrence("), source.indexOf("nonisolated enum TaskOccurrenceOutcome"));
    assert.match(validation, /var candidate = try next\(after: current\)/);
    assert.match(validation, /while candidate < date/);
    assert.match(validation, /return candidate == date/);
});

test("recorded Calendar dates cannot recur as pending rows or become the next reminder again", async () => {
    const source = await readFile(join(root, "Vellix/Tasks/DocumentTask.swift"), "utf8");
    const agenda = await readFile(join(root, "Vellix/Calendar/CalendarAgenda.swift"), "utf8");
    assert.match(source, /let recordedDates = Set\(copy\.history\.compactMap\(\\\.scheduledAt\)\)/);
    assert.match(source, /while recordedDates\.contains\(next\.timeIntervalSince1970\)/);
    assert.match(source, /let following = try recurrence\.next\(after: next\)/);
    assert.match(source, /copy\.scheduledAt = next\.timeIntervalSince1970/);
    assert.match(agenda, /let recordedDates = Set\(metadata\.history\.compactMap\(\\\.scheduledAt\)\)/);
    assert.match(agenda, /if next >= range\.start && !recordedDates\.contains\(next\.timeIntervalSince1970\)/);
});

test("editor presentations use bounded expressions and an explicitly typed error binding", async () => {
    const source = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
    const stages = [
        ["editorPrimaryPresentations", "editorContent"],
        ["editorAppearancePresentations", "editorPrimaryPresentations"],
        ["editorBlockPresentations", "editorAppearancePresentations"],
        ["editorUtilityPresentations", "editorBlockPresentations"],
        ["editorBlockActionDialogs", "editorUtilityPresentations"],
        ["editorPageActionDialogs", "editorBlockActionDialogs"],
    ];
    for (let index = 0; index < stages.length; index++) {
        const [name, input] = stages[index];
        const next = index + 1 < stages.length
            ? `private var ${stages[index + 1][0]}: some View`
            : "private var editorErrorPresentation: Binding<Bool>";
        const start = source.indexOf(`private var ${name}: some View`);
        const end = source.indexOf(next, start);
        assert(start >= 0 && end > start, name);
        const stage = source.slice(start, end);
        assert(stage.includes(`{\n        ${input}\n`), `${name} retains the modifier order`);
        const modifiers = stage.match(/^        \.(?:modifier|fileImporter|sheet|onChange|confirmationDialog|alert)\(/gm) ?? [];
        assert(modifiers.length > 0 && modifiers.length <= 8, `${name} has a bounded modifier expression`);
        assert.doesNotMatch(stage, /AnyView\(|Group\s*\{|ZStack\s*\{/);
    }
    const binding = source.slice(source.indexOf("private var editorErrorPresentation: Binding<Bool>"), source.indexOf("    var body: some View {"));
    assert.match(binding, /Binding<Bool>\(/);
    assert.match(binding, /model\.tableEditorRequest == nil && model\.taskEditorRequest == nil/);
    assert.match(binding, /model\.errorMessage != nil \|\| model\.session\.bridgeErrorMessage != nil/);
    assert.match(binding, /if !isPresented\s*\{\s+model\.errorMessage = nil\s+model\.session\.bridgeErrorMessage = nil/);
    const body = source.slice(source.indexOf("    var body: some View {"), source.indexOf("private func documentWorkspace("));
    assert.match(body, /editorPageActionDialogs\s+\.alert\("Editor", isPresented: editorErrorPresentation\)/);
    assert.match(body, /\.vellixHideEditorNavigationBar\(isActive: environment\.selectedDocumentID != nil\)/);
    assert.doesNotMatch(body, /\.sheet\(|\.confirmationDialog\(|\.fileImporter\(|Binding\(/);
});

test("mobile workspace controls use separate expressions and explicitly typed optional callbacks", async () => {
    const source = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
    const workspace = source.slice(source.indexOf("private func documentWorkspace("), source.indexOf("private func documentTopControls("));
    const controls = source.slice(source.indexOf("private func documentTopControls("), source.indexOf("@ViewBuilder private func documentTitle("));
    assert.match(workspace, /documentTopControls\(document, appearance: appearance, isCompact: isCompact\)/);
    assert.match(workspace, /#if os\(iOS\)\s+@ViewBuilder private var documentKeyboardToolbar: some View\s*\{\s*if isEditingDocument[^]*?keyboardFormattingToolbar/);
    assert.doesNotMatch(workspace, /EditorTopControls\(|EditorKeyboardFormattingToolbar\(|taskAction:|templateComponentAction:/);
    assert.match(controls, /EditorTopControls\(/);
    assert.match(controls, /#if os\(iOS\)\s+private var keyboardFormattingToolbar: some View/);
    assert.match(controls, /let taskAction: \(\(\) -> Void\)\? = model\.taskContext == nil \? nil : \{\s+model\.openTaskScheduling\(\)\s+dismissKeyboard\(\)/);
    assert.match(controls, /let templateComponentAction: \(\(TemplateComponentKind\) -> Void\)\?/);
    assert.match(controls, /taskAction: taskAction/);
    assert.match(controls, /templateComponentAction: templateComponentAction/);
    assert.match(workspace, /\.coordinateSpace\(name: DocumentEditorCoordinateSpace\.workspace\)/);
    assert.match(workspace, /\.background\(documentScrollFinder\(\)\)/);
});

test("the geometry closure only composes independently checked workspace sections without changing scroll or overlay wiring", async () => {
    const source = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
    const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end));
    const geometry = section("private func documentWorkspace(", "private func documentWorkspaceLayers(");
    assert.match(geometry, /return GeometryReader \{ proxy in\s+documentWorkspaceLayers\(document, appearance: appearance, proxy: proxy\)\s+\}/);
    assert.doesNotMatch(geometry, /ScrollView\(|VStack\(|ZStack\(|\.padding\(|\.safeAreaInset\(/);

    const layers = section("private func documentWorkspaceLayers(", "private func documentScrollView(");
    const orderedLayers = ["DocumentBackgroundLayer(", "documentScrollView(", "documentTopControls(", "documentStatusBanner(", "documentBlockControls(", "documentKeyboardToolbar", "documentSlashMenu("];
    let previous = -1;
    for (const layer of orderedLayers) {
        const position = layers.indexOf(layer);
        assert(position > previous, `${layer} retains its existing stacking order`);
        previous = position;
    }
    assert.match(layers, /\.coordinateSpace\(name: DocumentEditorCoordinateSpace\.workspace\)/);
    assert.match(layers, /\.onChange\(of: proxy\.size\)[^]*?model\.session\.requestCaretVisibility\(\)/);

    const scroll = section("private func documentScrollView(", "private func documentScrollContent(");
    assert.match(scroll, /let scrollWidth: CGFloat\? = workspace == nil \? nil : size\.width/);
    assert.match(scroll, /let scrollHeight: CGFloat\? = workspace == nil \? nil : size\.height/);
    assert.match(scroll, /ScrollView\(showsIndicators: false\)\s*\{\s+documentScrollContent\(/);
    assert.match(scroll, /\.frame\(width: scrollWidth, height: scrollHeight\)/);
    assert.match(scroll, /\.safeAreaInset\(edge: \.bottom, spacing: 0\)\s*\{\s+documentKeyboardInset/);
    assert.match(scroll, /\.onPreferenceChange\(EditorSurfaceFramePreferenceKey\.self\)/);
    assert.match(scroll, /documentScrollProxy\.pendingCaretRevision != nil \{ queueCaretReveal\(\)/);
    assert.match(scroll, /scrollTableIntoView\(isCompact: isCompact\)/);

    const content = section("private func documentScrollContent(", "@ViewBuilder private var documentKeyboardInset:");
    assert.match(content, /let topPadding: CGFloat = isCompact \? 74 : 150/);
    assert.match(content, /let bottomPadding: CGFloat = isCompact \? 118 : 140/);
    assert.match(content, /let minimumHeight: CGFloat = max\(0, size\.height - topPadding - bottomPadding\)/);
    assert.match(content, /plainDocument\(document, appearance: appearance, isCompact: isCompact, minimumHeight: minimumHeight\)/);
    assert.match(content, /themedDocument\(document, appearance: appearance, isCompact: isCompact, bottomPadding: isCompact \? 4 : 8\)/);
    assert.match(content, /\.background\(documentScrollFinder\(\)\)/);
});

test("mobile and Mac task-history routes present sheets while ordinary nested pages still navigate", async () => {
    for (const file of ["Vellix/Editor/TipTapEditorSession.swift", "PennedMac/Editor/MacTipTapEditorSession.swift"]) {
        const source = await readFile(join(root, file), "utf8");
        const route = source.slice(source.indexOf("case .requestOpenPage(let documentID):"), source.indexOf("case .requestPageActions(let documentID):"));
        assert.match(source, /@Published var taskHistoryRequest: TaskHistorySheetRequest\?/);
        assert.match(route, /DocumentTaskPages\.taskID\(for: documentID\)/);
        assert.match(route, /documentRepository\.taskForHistoryPage\(id: documentID\)/);
        assert.match(route, /task\.documentID == self\.documentID \|\| DocumentTaskPages\.taskID\(for: self\.documentID\) == taskID/);
        assert.match(route, /taskHistoryRequest = TaskHistorySheetRequest\(task: task\)/);
        assert(route.indexOf("taskHistoryRequest =") < route.indexOf("nestedPageToOpen = child"));
        assert.match(route, /child\.parentDocumentID == document\?\.id/);
    }
    const mobile = await readFile(join(root, "Vellix/Editor/DocumentEditorView.swift"), "utf8");
    const mac = await readFile(join(root, "PennedMac/Editor/MacEditorPresentations.swift"), "utf8");
    for (const source of [mobile, mac]) assert.match(source, /\.sheet\(item: \$model\.taskHistoryRequest\)/);
    assert.match(mobile, /model\.taskHistoryRequest\?\.id\).*dismissKeyboard\(\)/);
    assert.match(mobile, /model\.taskHistoryRequest = nil\s+deactivateEditor\(\)/);
    assert.match(mac, /\.onChange\(of: workspace\.activeID\).*model\.taskHistoryRequest = nil/);
});

test("history timeline uses actual completed/skipped records, stable ordering and explicit AM/PM formatting", async () => {
    const sheet = await readFile(join(root, "Vellix/Tasks/TaskHistorySheet.swift"), "utf8");
    assert.match(sheet, /task\.metadata\.history\.sorted/);
    assert.match(sheet, /\$0\.completedAt > \$1\.completedAt/);
    assert.match(sheet, /\$0\.id < \$1\.id/);
    assert.match(sheet, /\$0\.outcome == \.completed/);
    assert.match(sheet, /\$0\.outcome == \.skipped/);
    assert.match(sheet, /Date\(timeIntervalSince1970: occurrence\.completedAt\)/);
    assert.match(sheet, /occurrence\.timeZoneID \?\? fallbackTimeZoneID/);
    assert.match(sheet, /formatter\.dateFormat = "h:mm a"/);
    assert.match(sheet, /formatter\.locale = Locale\(identifier: "en_US_POSIX"\)/);
    assert.match(sheet, /Text\("No History Yet"\)/);
    assert.match(sheet, /\.onReceive\(NotificationCenter\.default\.publisher\(for: \.vellixTasksChanged\)/);
    assert.match(sheet, /environment\.documents\.taskForHistoryPage/);
    assert.match(sheet, /\.onChange\(of: environment\.selectedSpaceID\).*dismiss\(\)/);
    assert.match(sheet, /ViewThatFits\(in: \.horizontal\)/);
});
