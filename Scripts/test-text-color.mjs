import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

// Shipping JavaScript and source checks only. No app build, launch or simulator.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { JSDOM } = await import(pathToFileURL(join(backend, "node_modules/jsdom/lib/api.js")));
const read = file => readFile(join(root, file), "utf8");
const scripts = await Promise.all(["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js"]
    .map(file => read("Vellix/VellixEditor.bundle/" + file)));
const p = (text, attrs = {}) => ({ type: "paragraph", attrs: { id: randomUUID(), ...attrs }, content: [{ type: "text", text }] });
const doc = (...content) => ({ type: "doc", content });
const solid = { kind: "solid", start: "#F15A70" };
const gradient = { kind: "gradient", start: "#BC76FF", end: "#42C4D5", angle: 90 };
const plain = value => JSON.parse(JSON.stringify(value));
async function fixture(t, content = doc(p("Before selected after")), mobile = true) {
    const dom = new JSDOM("<!doctype html><html><body><main class='vellix-editor-page'><div id='editor'></div></main></body></html>",
        { runScripts: "outside-only", pretendToBeVisual: true, url: "https://vellix.test" });
    t.after(() => dom.window.close());
    const w = dom.window, events = [];
    w.console.log = w.console.info = () => {};
    w.ResizeObserver = class { observe() {} disconnect() {} };
    w.scrollBy = () => {};
    w.Range.prototype.getClientRects = () => [];
    w.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 100, bottom: 24 });
    w.crypto.randomUUID = randomUUID;
    w.webkit = { messageHandlers: { tiptap: { postMessage: e => events.push(e) } } };
    if (mobile) w.eval((await read("Vellix/Editor/MobileBlockSelection.swift")).match(/static let script = #"""\n([^]*?)\n"""#/)[1]);
    scripts.forEach(source => w.eval(source));
    const command = (name, args = {}) => w.tiptapCommand(name, args);
    await command("setContent", { document: content });
    const editor = w.document.querySelector(".tiptap-editor").editor;
    function select(text) {
        let range;
        editor.state.doc.descendants((node, pos) => {
            if (!range && node.isText && node.text.includes(text)) range = { from: pos + node.text.indexOf(text), to: pos + node.text.indexOf(text) + text.length };
        });
        assert(range, "selected text exists: " + text);
        editor.view.focus(); editor.commands.setTextSelection(range);
        return range;
    }
    return { w, editor, events, command, select, state: () => events.findLast(e => e.kind === "formattingState")?.payload,
        begin: () => command("textColorBegin"), apply: (request, style) => command("textColorApply", { token: request.token, style }) };
}
const textNodes = editor => { const result = []; editor.state.doc.descendants(n => { if (n.isText) result.push(n); }); return result; };

test("paintbrush state requires editable, focused, nonempty text selection; selecting does not save", async t => {
    const h = await fixture(t);
    h.editor.view.focus(); h.editor.commands.setTextSelection(1);
    assert.equal(h.state().hasTextSelection, false);
    const saves = () => h.events.filter(e => ["update", "snapshot"].includes(e.kind)).length;
    const before = saves();
    h.select("selected"); assert.equal(h.state().hasTextSelection, true);
    assert.equal(saves(), before);
    h.editor.view.dom.blur(); assert.equal(h.state().hasTextSelection, false);
    h.select("selected"); await h.command("setEditable", { editable: false });
    assert.equal(h.state().hasTextSelection, false); assert.equal(await h.begin(), null);
});

for (const value of [solid, gradient]) {
    test(`${value.kind}: colors only selected text, retains bold/italic, restores range and focus on sheet dismissal`, async t => {
        const h = await fixture(t);
        const range = h.select("selected");
        h.editor.commands.toggleBold(); h.editor.commands.toggleItalic();
        const request = await h.begin();
        assert.equal(request.text, "selected");
        h.editor.view.dom.blur(); h.editor.commands.setTextSelection(1);
        assert.equal(await h.apply(request, value), true);
        const runs = textNodes(h.editor);
        assert.deepEqual(runs.map(n => n.text), ["Before ", "selected", " after"]);
        assert.equal(runs[0].marks.length, 0); assert.equal(runs[2].marks.length, 0);
        assert(runs[1].marks.some(m => m.type.name === "bold")); assert(runs[1].marks.some(m => m.type.name === "italic"));
        const attrs = runs[1].marks.find(m => m.type.name === "textStyle").attrs;
        if (value.kind === "solid") assert.equal(attrs.color, value.start);
        else assert.deepEqual(plain(attrs.gradient), { start: value.start, end: value.end, angle: value.angle });
        assert.equal(h.editor.isFocused, false, "do not reopen keyboard under sheet");
        assert.equal(await h.command("textColorEnd", { token: request.token, restoreFocus: true }), true);
        assert.equal(h.editor.isFocused, true); assert.equal(h.editor.state.selection.from, range.from);
        assert.equal(h.editor.state.selection.to, range.to);
        assert.equal(await h.apply(request, solid), false, "closed token is revoked");
    });
}

test("gradient survives JSON save/reload and HTML copy/paste; switching solid/default removes only its mark", async t => {
    const h = await fixture(t); h.select("selected");
    assert.equal(await h.apply(await h.begin(), gradient), true);
    const saved = plain(await h.command("getDocument"));
    const html = h.editor.getHTML();
    assert.match(html, /linear-gradient\(90deg/); assert.match(html, /-webkit-text-fill-color:\s*transparent/);
    await h.command("setContent", { document: saved });
    assert.equal(h.w.document.querySelector("[data-vellix-gradient]").textContent, "selected");
    h.editor.commands.setContent(html);
    assert.deepEqual(plain(textNodes(h.editor)[1].marks[0].attrs.gradient), { start: gradient.start, end: gradient.end, angle: 90 });
    h.select("selected"); const request = await h.begin();
    await h.apply(request, solid);
    assert.equal(h.w.document.querySelectorAll("[data-vellix-gradient]").length, 0);
    assert.equal(textNodes(h.editor)[1].marks[0].attrs.color, solid.start);
    await h.apply(request, null);
    assert.equal(textNodes(h.editor).filter(n => n.marks.some(m => m.type.name === "textStyle")).length, 0);
});

test("color apply is one undo step separate from typing and supports redo", async t => {
    const h = await fixture(t);
    h.editor.commands.setTextSelection(1); h.editor.commands.insertContent("Typed ");
    h.select("selected"); await h.apply(await h.begin(), gradient);
    assert.equal(h.editor.commands.undo(), true);
    assert.match(h.editor.state.doc.textContent, /^Typed /);
    assert.equal(h.w.document.querySelector("[data-vellix-gradient]"), null);
    assert.equal(h.editor.commands.redo(), true); assert(h.w.document.querySelector("[data-vellix-gradient]"));
});

test("typing, deletion, insertions and repeated keyboard focus changes do not disable color selection", async t => {
    const h = await fixture(t);
    for (let i = 0; i < 4; i++) {
        h.editor.commands.setTextSelection(1); h.editor.commands.insertContent("X");
        h.editor.commands.deleteRange({ from: 1, to: 2 });
        h.editor.commands.insertContent(p("Added"));
        h.editor.view.dom.blur(); h.select("selected");
        assert.equal(h.state().hasTextSelection, true);
        const request = await h.begin(); assert(request);
        assert.equal(await h.apply(request, i % 2 ? solid : gradient), true);
        await h.command("textColorEnd", { token: request.token, restoreFocus: true });
    }
});

test("held range maps prefix edits but rejects selected-text edits and replacement documents", async t => {
    const h = await fixture(t); h.select("selected"); let request = await h.begin();
    h.editor.commands.insertContentAt(1, "Prefix ");
    assert.equal(await h.apply(request, solid), true);
    assert.equal(textNodes(h.editor).find(n => n.marks.some(m => m.type.name === "textStyle")).text, "selected");
    h.select("selected"); request = await h.begin(); h.editor.commands.insertContent("Replacement");
    assert.equal(await h.apply(request, gradient), false);
    h.select("Replacement"); request = await h.begin();
    await h.command("setContent", { document: doc(p("Replacement in another page")) });
    assert.equal(await h.apply(request, solid), false);
});

test("old tokens, locked documents, node selections, and block-selection mode cannot apply text color", async t => {
    const h = await fixture(t); h.select("selected"); const old = await h.begin(), current = await h.begin();
    assert.equal(await h.apply(old, solid), false);
    await h.command("setEditable", { editable: false });
    assert.equal(await h.apply(current, solid), false);
    await h.command("setEditable", { editable: true });
    h.select("selected"); const request = await h.begin();
    await h.command("setSelectionMode", { mode: "multi" });
    assert.equal(h.state().hasTextSelection, false); assert.equal(await h.apply(request, solid), false);
    await h.command("setSelectionMode", { mode: "off" });
    h.editor.commands.setNodeSelection(0);
    assert.equal(h.state().hasTextSelection, false); assert.equal(await h.begin(), null);
});

test("nested quotes, toggles, lists and table-cell text use the same color mark without rewriting hierarchy", async t => {
    const content = doc(
        { type: "blockquote", content: [p("Quoted words")] },
        { type: "toggleItem", attrs: { id: "toggle", open: true }, content: [p("Toggle words"), p("Nested words")] },
        { type: "bulletList", content: [{ type: "listItem", content: [p("List words")] }] },
        { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [p("Cell words")] }] }] });
    const h = await fixture(t, content);
    const structure = n => ({ type: n.type, content: n.content?.filter(n => n.type !== "text").map(structure) });
    const before = structure(plain(h.editor.getJSON()));
    for (const text of ["Quoted words", "Toggle words", "Nested words", "List words", "Cell words"]) {
        h.select(text); assert.equal(await h.apply(await h.begin(), gradient), true, text);
    }
    assert.equal(h.w.document.querySelectorAll("[data-vellix-gradient]").length, 5);
    assert.deepEqual(structure(plain(h.editor.getJSON())), before);
});

test("multi-paragraph selection supports mixed colors without rewriting blocks", async t => {
    const h = await fixture(t, doc(p("First paragraph"), p("Second paragraph")));
    h.select("First"); await h.apply(await h.begin(), solid);
    h.editor.commands.selectAll();
    // SelectAll is deliberately not treated as a text selection; use a real range.
    h.editor.commands.setTextSelection({ from: 1, to: h.editor.state.doc.content.size - 1 });
    const request = await h.begin(); assert.equal(request.mixed, true);
    assert.equal(await h.apply(request, gradient), true);
    assert.equal(h.w.document.querySelectorAll("[data-vellix-gradient]").length, 2);
    assert.equal(h.editor.state.doc.childCount, 2);
});

test("coloring skips inline atoms, preserves link/inline-code marks and does not leak into later typing", async t => {
    const content = doc({ type: "paragraph", content: [
        { type: "text", text: "Linked", marks: [{ type: "link", attrs: { href: "https://example.test" } }] },
        { type: "inlineTag", attrs: { id: "tag", name: "keep" } },
        { type: "text", text: "Code", marks: [{ type: "code" }] },
    ] });
    const h = await fixture(t, content);
    h.editor.view.focus(); h.editor.commands.setTextSelection({ from: 1, to: h.editor.state.doc.content.size - 1 });
    const request = await h.begin(); assert.equal(await h.apply(request, gradient), true);
    assert(h.w.document.querySelector("a > span[data-vellix-gradient]"), "color is inside the link, not overridden by link styling");
    assert(h.w.document.querySelector("code > span[data-vellix-gradient]"));
    let atom; h.editor.state.doc.descendants(n => { if (n.type.name === "inlineTag") atom = n; });
    assert.equal(atom.attrs.name, "keep"); assert.equal(atom.marks.length, 0);
    await h.command("textColorEnd", { token: request.token });
    h.editor.commands.setTextSelection(h.editor.state.doc.content.size - 1); h.editor.commands.insertContent("New");
    assert(!textNodes(h.editor).at(-1).marks.some(m => m.type.name === "textStyle"));
});

test("canceling the color editor changes no content and solid colors survive HTML serialization", async t => {
    const h = await fixture(t); h.select("selected");
    const before = plain(h.editor.getJSON()); const request = await h.begin();
    await h.command("textColorEnd", { token: request.token, restoreFocus: true });
    assert.deepEqual(plain(h.editor.getJSON()), before);
    await h.apply(await h.begin(), solid);
    h.editor.commands.setContent(h.editor.getHTML());
    assert.equal(textNodes(h.editor)[1].marks.find(m => m.type.name === "textStyle").attrs.color, solid.start);
});

test("validation rejects unsafe or malformed CSS and normalizes hex, RGB and angles", async t => {
    const h = await fixture(t); h.select("selected"); const request = await h.begin();
    for (const value of [{ kind: "solid", start: "url(evil)" }, { ...gradient, angle: "90" },
        { ...gradient, end: "var(--injected)" }, { ...gradient, angle: Infinity }, { kind: "solid", start: "rgb(999,0,0)" }]) {
        assert.equal(await h.apply(request, value), false);
    }
    assert.equal(await h.apply(request, { kind: "solid", start: "#abc" }), true);
    assert.equal(textNodes(h.editor)[1].marks[0].attrs.color, "#AABBCC");
    assert.equal(await h.apply(request, { ...gradient, start: "rgb(10, 20, 30)", angle: -90 }), true);
    assert.equal(textNodes(h.editor)[1].marks[0].attrs.gradient.angle, 270);
    assert.equal(textNodes(h.editor)[1].marks[0].attrs.gradient.start, "#0A141E");
});

test("Mac editor renders saved marks without introducing a Mac formatting bar or touch changes", async t => {
    const h = await fixture(t, doc(p("Mac words")), false);
    h.select("Mac"); assert.equal(await h.apply(await h.begin(), gradient), true);
    assert(h.w.document.querySelector("[data-vellix-gradient]"));
    assert.doesNotMatch(await read("PennedMac/Editor/MacDocumentEditorContainer.swift"), /InlineTextColorSheet|textColorAction/);
});

for (const value of [solid, gradient]) {
    test(`Mac sidebar ${value.kind}: opens after blur, retains its range through picker focus and restores focus on Apply`, async t => {
        const h = await fixture(t, doc(p("Before selected after")), false);
        const range = h.select("selected");
        h.editor.view.dom.blur();
        assert.equal(h.state().hasTextSelection, false, "the mobile brush must remain focus-gated");
        assert.equal(h.state().canColorText, true, "the Mac sidebar must stay enabled after taking focus");
        const request = await h.command("textColorBegin", { trackSelection: true });
        assert(request); assert.equal(h.state().textColorToken, request.token);
        h.editor.commands.setTextSelection(1);
        assert.equal(h.state().textColorToken, request.token, "native focus/caret collapse does not revoke the held range");
        assert.equal(await h.apply(request, value), true);
        const marked = textNodes(h.editor).filter(n => n.marks.some(m => m.type.name === "textStyle"));
        assert.equal(marked.length, 1); assert.equal(marked[0].text, "selected");
        assert.deepEqual(plain(h.state().textColor), value);
        assert.equal(h.editor.isFocused, false);
        await h.command("textColorEnd", { token: request.token, restoreFocus: true });
        assert.equal(h.editor.isFocused, true); assert.equal(h.editor.state.selection.from, range.from);
        assert.equal(h.editor.state.selection.to, range.to); assert.equal(h.state().textColorToken, null);
        const saved = plain(await h.command("getDocument"));
        h.editor.commands.undo(); assert(!h.w.document.querySelector("span[style]"));
        h.editor.commands.redo(); assert(h.w.document.querySelector("span[style]"));
        await h.command("setContent", { document: saved });
        assert(textNodes(h.editor).some(n => n.text === "selected" && n.marks.some(m => m.type.name === "textStyle")));
    });
}

test("Mac sidebar invalidates its token when the user returns to the editor and selects different text", async t => {
    const h = await fixture(t, doc(p("Before selected after")), false);
    h.select("selected"); const old = await h.command("textColorBegin", { trackSelection: true });
    h.editor.view.dom.blur();
    assert.equal(h.state().textColorToken, old.token);
    h.select("after");
    assert.equal(h.state().textColorToken, null); assert.equal(await h.apply(old, gradient), false);
    assert.equal(h.state().canColorText, true);
    const next = await h.command("textColorBegin", { trackSelection: true });
    h.editor.view.dom.blur(); assert.equal(await h.apply(next, solid), true);
    assert.equal(textNodes(h.editor).find(n => n.marks.some(m => m.type.name === "textStyle")).text, "after");
});

test("Mac held selections still map safe prefix edits and reject deletion of selected text", async t => {
    const h = await fixture(t, doc(p("Before selected after")), false);
    h.select("selected"); let request = await h.command("textColorBegin", { trackSelection: true });
    h.editor.view.dom.blur(); h.editor.commands.insertContentAt(1, "Prefix ");
    assert.equal(await h.apply(request, gradient), true);
    h.select("selected"); request = await h.command("textColorBegin", { trackSelection: true });
    h.editor.commands.insertContent("Replaced");
    assert.equal(h.state().textColorToken, null); assert.equal(await h.apply(request, solid), false);
});

test("Mac sidebar selection is revoked by document replacement and lock, while Cancel makes no edit", async t => {
    const h = await fixture(t, doc(p("Mac selection")), false);
    h.select("selection"); let request = await h.command("textColorBegin", { trackSelection: true });
    const before = plain(h.editor.getJSON()); h.editor.view.dom.blur();
    await h.command("textColorEnd", { token: request.token, restoreFocus: false });
    assert.deepEqual(plain(h.editor.getJSON()), before); assert.equal(h.editor.isFocused, false);
    h.select("selection"); request = await h.command("textColorBegin", { trackSelection: true });
    await h.command("setEditable", { editable: false });
    assert.equal(h.state().canColorText, false); assert.equal(h.state().textColorToken, null);
    assert.equal(await h.apply(request, solid), false);
    await h.command("setEditable", { editable: true });
    h.select("selection"); request = await h.command("textColorBegin", { trackSelection: true });
    await h.command("setContent", { document: doc(p("Another document")) });
    assert.equal(h.state().textColorToken, null); assert.equal(await h.apply(request, gradient), false);
});

test("Mac selected-text colors are in Format under Inline Formatting, with existing custom pickers and no bottom toolbar", async () => {
    const format = await read("PennedMac/Inspector/MacFormatInspector.swift");
    assert.match(await read("PennedMac/Inspector/MacDocumentInspector.swift"), /case \.format: MacFormatInspector\(workspace: workspace, session: model\.session\)/);
    const placement = format.indexOf("MacTextColorInspector(workspace: workspace, session: session)");
    assert(placement > format.indexOf('title: "Inline Formatting"') && placement < format.indexOf('title: "Lists"'));
    const control = await read("PennedMac/Inspector/MacTextColorInspector.swift");
    assert.match(control, /title: "Selected Text Color"/);
    assert.match(control, /MacSegmentedControl\("Selected Text Color"/);
    assert.match(control, /MacColorRow\(title: mode == \.solid \? "Color Picker" : "Start Color", selection: colorBinding\(end: false\)\)/);
    assert.match(control, /MacColorRow\(title: "End Color", selection: colorBinding\(end: true\)\)/);
    assert.match(control, /MacSlider\(value: \$angle, in: 0\.\.\.359, step: 1\)/);
    assert.match(control, /session\.applyTextColor\(value, request: request\)/);
    assert.match(control, /Button\("Default Text Color"\)/);
    assert.match(control, /Button\("Cancel", action: finished\)/);
    assert.doesNotMatch(control, /\bColorPicker\(|NSColorPanel|UIColorPicker/);
    assert.match(await read("PennedMac/Appearance/MacStyleWidgets.swift"), /CardThreeModeColorPicker\(selection: \$selection, title: title, embedded: true\)/);
    assert.doesNotMatch(await read("PennedMac/Editor/MacDocumentEditorContainer.swift"), /MacTextColorInspector|keyboardFormattingToolbar/);
});

test("Mac bridge and inspector guard document, load/request generations, ownership and stale cleanup", async () => {
    const session = await read("PennedMac/Editor/MacTipTapEditorSession.swift");
    assert.match(session, /formattingState\.canColorText/);
    assert.match(session, /"trackSelection": true/);
    assert.match(session, /requestGeneration == textColorRequestGeneration/);
    assert.match(session, /textColorContext\?\.generation == loadGeneration/);
    assert.match(session, /if let requestID, textColorContext\?\.token != requestID \{ return \}/);
    const control = await read("PennedMac/Inspector/MacTextColorInspector.swift");
    assert.match(control, /workspace\.isAuthorized && workspace\.activeEditor\?\.session === session/);
    assert.match(control, /session\.formattingState\.textColorToken/);
    assert.match(control, /\.onDisappear \{ close\(restoreFocus: false\) \}/);
    assert.match(control, /capturedGeneration == generation/);
    assert.match(control, /next\.documentID == workspace\.activeEditor\?\.documentID/);
    assert.doesNotMatch(control, /\.onChange\(of: session\.formattingState\.hasTextSelection/);
});

test("Mac text-color inspector has explicit Mac-only source membership without synchronized duplication", async () => {
    const project = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(root, "Vellix.xcodeproj/project.pbxproj")], { encoding: "utf8" })).objects;
    const sourceIDs = target => project[target].buildPhases.flatMap(id => project[id].isa === "PBXSourcesBuildPhase" ? project[id].files : []);
    assert.equal(sourceIDs("CF8C0EA6308548190058BF74").filter(id => project[id].fileRef === "CFB7E11430E1300000A17001").length, 1);
    assert(!sourceIDs("CFA16D66301AC182007825F0").includes("CFB7E10530E1300000A17001"));
    assert(project.D00100000000000000000004.membershipExceptions.includes("Inspector/MacTextColorInspector.swift"));
    assert.equal(project.CFB7E12130E1300000A17001.path, "PennedMac");
    assert(project.CFB7E12130E1300000A17001.children.includes("CFB7E11430E1300000A17001"));
});

test("native wiring uses custom controls, document-owned sheet, existing paintbrush and selection gate", async () => {
    const editor = await read("Vellix/Editor/DocumentEditorView.swift");
    assert.match(editor, /if session\.formattingState\.hasTextSelection \{\s+toolbarButton\("Text Color", assetName: "paintbrush"/);
    assert.match(editor, /\.modifier\(InlineTextColorPresentation/);
    const sheet = await read("Vellix/Editor/InlineTextColorSheet.swift");
    assert.match(sheet, /"Solid" : "Gradient"/); assert.match(sheet, /session\.applyTextColor/);
    assert.match(sheet, /CardThreeModeColorPicker\(selection: pickerSelection\(target\), title: target\.title\)/);
    assert.doesNotMatch(sheet, /UIColorPickerViewController|UIViewControllerRepresentable/);
    const session = await read("Vellix/Editor/TipTapEditorSession.swift");
    assert.match(session, /textColorContext\?\.generation == loadGeneration/);
    assert.match(session, /context\.documentID == loadedDocumentID/);
    assert.match(await read("Vellix/Documents/ImmediateDocumentPreview.swift"), /InlineTextPreview\.text/);
    assert.match(await read("Vellix/Documents/ImmediateTablePreview.swift"), /InlineTextPreview\.text/);
    const maintained = await readFile(join(backend, "src/text-color.js"), "utf8");
    const factory = maintained.slice(maintained.indexOf("export function createTextColor") + "export ".length, maintained.indexOf("\nexport const textColorDependencies")).trim();
    assert(scripts.at(-1).includes(factory), "shipping artifact uses the maintained factory exactly");
});

test("Solid and both Gradient endpoints open the existing full color picker", async () => {
    const source = await read("Vellix/Editor/InlineTextColorSheet.swift");
    assert.match(source, /@State private var colorPickerTarget: InlineTextColorPickerTarget\?/);
    assert.match(source, /if mode == \.gradient \{ gradientControls \}\s+colorPickerButton\s+swatches/);
    assert.match(source, /mode == \.solid \? \.solid : \(endpoint == 1 \? \.end : \.start\)/);
    assert.match(source, /Button \{ colorPickerTarget = target \}/);
    assert.match(source, /Text\("Color Picker"\)/);
    assert.match(source, /endpoint = index\s+colorPickerTarget = index == 0 \? \.start : \.end/);
    assert.match(source, /\.sheet\(item: \$colorPickerTarget\) \{ target in\s+CardThreeModeColorPicker/);
    const picker = await read("Vellix/Editor/CardThreeModeColorPicker.swift");
    assert.match(picker, /SheetNativeColorPicker\(selection: \$selection\)/);
    assert.match(picker, /UIColorPickerViewController\(\)/);
    assert.match(picker, /supportsAlpha = false/);
    assert((await read("Vellix/Assets.xcassets/colorpicker.imageset/Contents.json")).length > 0);
});

test("picker binds to a captured endpoint and changes only the draft until the outer Apply", async () => {
    const source = await read("Vellix/Editor/InlineTextColorSheet.swift");
    const binding = source.slice(source.indexOf("private func pickerSelection"), source.indexOf("private var swatches"));
    assert.match(binding, /let hex: Binding<String> = target == \.end \? \$end : \$start/);
    assert.match(binding, /InlineTextColor\.normalizedHex\(hex\.wrappedValue\)/);
    assert.match(binding, /hex\.wrappedValue = color\.vellixHexString\(fallback: hex\.wrappedValue\)/);
    assert.doesNotMatch(binding, /activeHex|session\.|apply\(|dismiss\(/);
    assert.equal((source.match(/session\.applyTextColor\(/g) ?? []).length, 1);
    assert.match(source, /Button\("Apply"\) \{ if let color \{ apply\(color\) \} \}/);
    assert.match(source, /case solid, start, end/);
});

test("color files have explicit app source membership with no synchronized duplicate or Mac UI inclusion", async () => {
    const project = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(root, "Vellix.xcodeproj/project.pbxproj")], { encoding: "utf8" })).objects;
    const sources = target => project[target].buildPhases.flatMap(id => project[id].isa === "PBXSourcesBuildPhase"
        ? project[id].files.map(file => project[project[file].fileRef].path) : []);
    const mobileSources = sources("CFA16D66301AC182007825F0");
    const macSources = sources("CF8C0EA6308548190058BF74");
    const group = project.CFB7E12030E1300000A17001;
    assert.equal(group.path, "Vellix");
    for (const path of ["Documents/InlineTextColor.swift", "Editor/InlineTextColorSheet.swift", "Editor/InlineTextColorPresentation.swift"]) {
        assert.equal(mobileSources.filter(source => source === path).length, 1, path);
        assert(project.CFA16DA5301AC3D4007825F0.membershipExceptions.includes(path), "exclude explicit file from automatic app discovery: " + path);
        assert(group.children.some(id => project[id].path === path), "reference resolves inside Vellix: " + path);
        assert((await read("Vellix/" + path)).length > 0);
        assert(project.D00100000000000000000003.membershipExceptions.includes(path), "exclude automatic Mac inclusion: " + path);
    }
    assert.equal(macSources.filter(source => source === "Documents/InlineTextColor.swift").length, 1);
    assert(!macSources.includes("Editor/InlineTextColorSheet.swift"));
    assert(!macSources.includes("Editor/InlineTextColorPresentation.swift"));
});

test("editor observer chain is split into bounded expressions without replacing its root or duplicating handlers", async () => {
    const source = await read("Vellix/Editor/DocumentEditorView.swift");
    const names = ["editorLifecycleContent", "editorViewportContent", "editorSelectionContent", "editorRequestContent", "editorContent"];
    const start = source.indexOf("private var " + names[0]), end = source.indexOf("private var editorPrimaryPresentations");
    const chain = source.slice(start, end);
    assert.equal((chain.match(/ZStack \{/g) ?? []).length, 1);
    for (const [index, name] of names.entries()) {
        const head = "private var " + name + ": some View {";
        assert.equal(chain.split(head).length, 2, name + " is declared once");
        const body = chain.slice(chain.indexOf(head) + head.length).split("private var ")[0];
        if (index > 0) assert(body.trimStart().startsWith(names[index - 1]), name + " wraps the previous expression");
        assert((body.match(/\.(?:onReceive|onChange|onAppear|onDisappear|onPreferenceChange|task)\b/g) ?? []).length <= 20, name + " has a bounded modifier chain");
    }
    assert.equal((chain.match(/\.onReceive\(model\.\$propertyEditorRequest\)/g) ?? []).length, 1);
    assert.equal((chain.match(/\.onReceive\(model\.session\.caretUpdates\)/g) ?? []).length, 1);
    assert.doesNotMatch(chain, /AnyView|\.id\(/);
    assert.match(source, /private var editorPrimaryPresentations: some View \{\s+editorContent/);
});
