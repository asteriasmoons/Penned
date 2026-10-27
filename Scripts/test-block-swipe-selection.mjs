import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { JSDOM } = await import(pathToFileURL(join(backend, "node_modules/jsdom/lib/api.js")));
const read = path => readFile(join(root, path), "utf8");
const source = await read("Vellix/Editor/MobileBlockSelection.swift");
const script = source.match(/static let script = #"""\n([^]*?)\n"""#/)[1];
const editorCSS = (await read("Vellix/VellixEditor.bundle/tiptap.html")).match(/<style>([^]*?)<\/style>/)[1]
    + await read("Vellix/VellixEditor.bundle/vellix-tables.css");
const mobileAdapter = (await read("Vellix/Editor/MobileEditorInteractions.swift")).match(/static let script = #"""\n([^]*?)\n"""#/)[1];
const bundleScripts = await Promise.all(["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js",
    "vendor/table-library.js", "tiptap.bundle.js"].map(file => read("Vellix/VellixEditor.bundle/" + file)));
const json = value => JSON.parse(JSON.stringify(value));
const paragraph = (id, text = "Text") => ({ type: "paragraph", attrs: { id }, content: text ? [{ type: "text", text }] : [] });
const defaults = () => [paragraph("one"), paragraph("two"), paragraph("three")];

async function fixture(t, content = defaults()) {
    const dom = new JSDOM("<!doctype html><html><head></head><body><main class='vellix-editor-page'><div id='editor'></div></main></body></html>",
        { runScripts: "outside-only", pretendToBeVisual: true, url: "https://penned.test" });
    const w = dom.window, events = [], copied = [];
    const style = w.document.createElement("style"); style.textContent = editorCSS; w.document.head.appendChild(style);
    t.after(() => w.close());
    let time = 1000;
    Object.defineProperty(w.performance, "now", { value: () => time });
    w.Date.now = () => 100000 + time;
    w.crypto.randomUUID = randomUUID;
    w.console.log = w.console.info = () => {};
    w.ResizeObserver = class { observe() {} disconnect() {} };
    w.scrollBy = () => {};
    w.Range.prototype.getClientRects = () => [];
    w.Range.prototype.getBoundingClientRect = () => ({ top: 20, bottom: 40, left: 20, right: 100, width: 80, height: 20 });
    w.webkit = { messageHandlers: { tiptap: { postMessage: event => events.push(json(event)) } } };
    Object.defineProperty(w.navigator, "clipboard", { value: { writeText: async text => copied.push(text) } });
    w.eval(script);
    for (const source of bundleScripts) w.eval(source);
    w.eval(mobileAdapter);
    await w.tiptapCommand("setContent", { document: { type: "doc", content } });
    time += 1000;
    const editor = w.document.querySelector(".tiptap-editor").editor;
    const pages = [];
    editor.state.doc.descendants(node => { if (node.type.name === "pageReference") pages.push({ documentID: node.attrs.documentID, title: "Page" }); });
    await w.tiptapCommand("setPageReferences", { pages });
    const plugin = editor.state.plugins.find(plugin => plugin.key.startsWith("pennedBlockSelection$"));
    assert.ok(plugin, "the shipping editor must install the real ProseMirror plugin");
    const rectangles = new Map();
    function blocks() {
        return w.PennedBlockSelection.records(editor.state.doc).map(({ node, pos, path }, index) => {
            const element = editor.view.nodeDOM(pos);
            element.getBoundingClientRect = () => rectangles.get(node.attrs.id) ?? ({ top: 20 + index * 80, bottom: 80 + index * 80,
                left: 20, right: 420, height: 60, width: 400 });
            return { node, pos, path, element, index };
        });
    }
    blocks();
    const state = () => plugin.getState(editor.state);
    function touch(type, index, x, y, options = {}) {
        const block = blocks()[index];
        const point = { identifier: options.identifier ?? 7, clientX: x, clientY: y };
        const event = new w.Event(type, { bubbles: true, cancelable: options.cancelable ?? true });
        Object.defineProperties(event, {
            touches: { value: type === "touchend" || type === "touchcancel" ? [] : options.multitouch ? [point, { ...point, identifier: 8 }] : [point] },
            changedTouches: { value: [point] },
        });
        (options.target ?? block.element).dispatchEvent(event);
        return event;
    }
    function swipe(index = 0, x = 150, direction = 1) {
        const y = 45 + index * 80;
        touch("touchstart", index, x, y);
        touch("touchmove", index, x + 60 * direction, y + 2);
        touch("touchend", index, x + 60 * direction, y + 2);
    }
    return { w, editor, events, copied, blocks, state, touch, swipe, tick: milliseconds => { time += milliseconds; },
        bounds: (id, bounds) => rectangles.set(id, { left: 20, right: 420, width: 400, ...bounds, height: bounds.bottom - bounds.top }),
        selected: () => json(state().selected.map(item => item.id)) };
}

for (const x of [25, 200, 410]) for (const direction of [-1, 1]) {
    test(`horizontal swipe selects from content x=${x}, direction=${direction}, without editing`, async t => {
        const h = await fixture(t), original = h.editor.state.doc;
        const before = json(h.editor.getJSON());
        h.swipe(0, x, direction);
        assert.deepEqual(h.selected(), ["one"]);
        assert.equal(h.state().mode, "multi");
        assert.equal(h.state().gesture, null);
        assert.equal(h.editor.state.doc, original);
        assert.deepEqual(json(h.editor.getJSON()), before);
        assert.ok(h.blocks()[0].element.classList.contains("penned-block-selected"));
        assert.equal(h.events.filter(event => event.kind === "haptic").length, 1);
    });
}

test("touch observation does not cancel taps, change the document, or blur the editor", async t => {
    const h = await fixture(t), original = h.editor.state.doc;
    h.editor.view.focus();
    assert.equal(h.touch("touchstart", 0, 100, 40).defaultPrevented, false);
    await Promise.resolve();
    assert.equal(h.state().gesture.phase, "pending");
    assert.equal(h.editor.view.hasFocus(), true);
    assert.equal(h.touch("touchend", 0, 100, 40).defaultPrevented, false);
    assert.equal(h.state().gesture, null);
    assert.equal(h.state().mode, "off");
    assert.equal(h.editor.state.doc, original);
    assert.equal(h.events.filter(event => event.kind === "haptic").length, 0);
});

test("vertical and diagonal scrolling are released before selection activates", async t => {
    const h = await fixture(t);
    for (const [dx, dy] of [[2, 45], [14, 20], [50, 70], [25, 12]]) {
        h.touch("touchstart", 0, 100, 40);
        assert.equal(h.touch("touchmove", 0, 100 + dx, 40 + dy).defaultPrevented, false);
        assert.equal(h.state().gesture, null);
        h.touch("touchmove", 0, 200, 40 + dy);
        assert.deepEqual(h.selected(), []);
    }
});

test("non-cancellable streams, multitouch, and long presses never become selection", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 0, 100, 40);
    assert.equal(h.touch("touchmove", 0, 170, 40, { cancelable: false }).defaultPrevented, false);
    assert.equal(h.state().gesture, null);
    h.touch("touchstart", 0, 100, 40);
    await Promise.resolve();
    h.tick(400);
    assert.equal(h.touch("touchmove", 0, 170, 40).defaultPrevented, false);
    assert.equal(h.state().gesture, null);
    h.touch("touchstart", 0, 100, 40, { multitouch: true });
    assert.equal(h.state().gesture, null);
    assert.deepEqual(h.selected(), []);
});

test("native text selections and IME composition keep control", async t => {
    const h = await fixture(t);
    h.editor.commands.setTextSelection({ from: 1, to: 3 });
    h.touch("touchstart", 0, 100, 40);
    assert.equal(h.state().gesture, null);
    h.editor.commands.setTextSelection(1);
    h.editor.view.input.composing = true;
    h.touch("touchstart", 0, 100, 40);
    assert.equal(h.state().gesture, null);
    h.editor.view.input.composing = false;
});

test("visual movement starts after intent, reverts below threshold, and never enters Undo", async t => {
    const h = await fixture(t), original = h.editor.state.doc;
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 105, 41);
    assert.equal(h.state().gesture.phase, "pending");
    h.touch("touchmove", 0, 125, 41);
    assert.equal(h.state().gesture.phase, "active");
    assert.match(h.blocks()[0].element.style.transform, /translateX\(15px\)/);
    assert.deepEqual(h.selected(), []);
    h.touch("touchend", 0, 125, 41);
    assert.equal(h.state().mode, "off");
    assert.equal(h.blocks()[0].element.style.transform, "");
    assert.equal(h.editor.state.doc, original);
    assert.equal(h.events.filter(event => event.kind === "haptic").length, 0);
});

test("continuous vertical extension selects and shrinks a range without haptic flooding", async t => {
    const h = await fixture(t), original = h.editor.state.doc;
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 160, 42);
    assert.deepEqual(h.selected(), ["one"]);
    h.touch("touchmove", 0, 161, 210);
    assert.deepEqual(h.selected(), ["one", "two", "three"]);
    h.touch("touchmove", 0, 162, 215);
    assert.equal(h.events.filter(event => event.kind === "haptic").length, 2);
    h.touch("touchmove", 0, 161, 100);
    assert.deepEqual(h.selected(), ["one", "two"]);
    h.touch("touchend", 0, 161, 100);
    assert.deepEqual(h.selected(), ["one", "two"]);
    assert.equal(h.editor.state.doc, original);
    assert.equal(h.editor.view.dom.querySelector(".vellix-selected-text-decoration"), null, "only the new plugin paints mobile block selection");
});

test("touch cancellation retains committed selection but removes the gesture transform", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 160, 40);
    h.touch("touchcancel", 0, 160, 40);
    assert.equal(h.state().gesture, null);
    assert.deepEqual(h.selected(), ["one"]);
    assert.equal(h.blocks()[0].element.style.transform, "");
});

test("a cancelled divider preview cannot create a paragraph through the mobile tap handler", async t => {
    const h = await fixture(t, [paragraph("before"), { type: "divider", attrs: { id: "divider", style: "thinLine" } }]);
    const before = h.editor.state.doc;
    h.touch("touchstart", 1, 100, 145);
    h.touch("touchmove", 1, 125, 145);
    h.touch("touchend", 1, 125, 145);
    h.blocks()[1].element.dispatchEvent(new h.w.MouseEvent("click", {
        bubbles: true, cancelable: true, clientX: 125, clientY: 145,
    }));
    assert.equal(h.editor.state.doc, before);
    assert.equal(h.state().mode, "off");
});

test("entering block selection closes the existing slash menu and releases its keyboard handling", async t => {
    const h = await fixture(t, [paragraph("slash", "/"), paragraph("tail")]);
    h.editor.commands.setTextSelection(2);
    assert.equal(h.events.findLast(event => event.kind === "slashMenu")?.payload.visible, true);
    const before = h.editor.state.doc;
    h.swipe(0);
    assert.equal(h.events.findLast(event => event.kind === "slashMenu")?.payload.visible, false);
    const enter = new h.w.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    h.w.document.dispatchEvent(enter);
    assert.equal(enter.defaultPrevented, false);
    assert.equal(h.editor.state.doc, before);
});

test("selection maps through edits and drops removed identities", async t => {
    const h = await fixture(t);
    h.swipe(1);
    const oldPosition = h.state().selected[0].pos;
    h.editor.commands.insertContentAt(0, paragraph("inserted"));
    assert.deepEqual(h.selected(), ["two"]);
    assert.ok(h.state().selected[0].pos > oldPosition);
    const block = h.blocks().find(block => block.node.attrs.id === "two");
    h.editor.view.dispatch(h.editor.state.tr.delete(block.pos, block.pos + block.node.nodeSize));
    assert.deepEqual(h.selected(), []);
});

test("native copy, duplicate, format and delete consume the same selected blocks", async t => {
    const h = await fixture(t);
    h.swipe(1);
    await h.w.tiptapCommand("copySelectedBlocks");
    assert.equal(h.copied.at(-1), "Text");
    await h.w.tiptapCommand("formatSelectedBlocks", { action: "bold" });
    const content = json(h.editor.getJSON()).content;
    assert.equal(content[0].content[0].marks, undefined);
    assert.equal(content[1].content[0].marks[0].type, "bold");
    assert.deepEqual(h.selected(), ["two"]);
    await h.w.tiptapCommand("duplicateSelectedBlocks");
    assert.equal(h.editor.state.doc.childCount, 4);
    await h.w.tiptapCommand("selectAllBlocks");
    assert.equal(h.state().selected.length, 4);
    await h.w.tiptapCommand("deleteSelectedBlocks");
    assert.equal(h.editor.state.doc.textContent, "");
    await h.w.tiptapCommand("undo");
    assert.equal(h.editor.state.doc.childCount, 4);
});

test("list and quote children are independent selections and retain their parents through commands", async t => {
    const h = await fixture(t, [
        { type: "bulletList", attrs: { id: "list" }, content: [
            { type: "listItem", attrs: { id: "item" }, content: [paragraph("nested"), paragraph("sibling")] },
        ] },
        { type: "blockquote", attrs: { id: "quote" }, content: [paragraph("quoted")] },
        { type: "divider", attrs: { id: "divider", style: "thinLine" } },
        { type: "pageReference", attrs: { id: "embedded", documentID: "child" } },
        paragraph("tail"),
    ]);
    h.swipe(0);
    assert.deepEqual(h.selected(), ["nested"]);
    await h.w.tiptapCommand("copySelectedBlocks");
    await h.w.tiptapCommand("formatSelectedBlocks", { action: "italic" });
    assert.equal(h.editor.state.doc.firstChild.firstChild.firstChild.firstChild.marks[0].type.name, "italic");
    assert.equal(h.editor.state.doc.firstChild.firstChild.child(1).firstChild.marks.length, 0);
    await h.w.tiptapCommand("deleteSelectedBlocks");
    assert.equal(h.editor.state.doc.firstChild.type.name, "bulletList");
    assert.equal(h.editor.state.doc.firstChild.firstChild.firstChild.attrs.id, "sibling");
    h.editor.state.doc.check();
    await h.w.tiptapCommand("clearBlockSelection");
    h.swipe(1);
    assert.deepEqual(h.selected(), ["quoted"]);
});

test("fitting tables are selected as a whole, not as a row or cell", async t => {
    const h = await fixture(t, [
        { type: "table", attrs: { id: "table" }, content: [
            { type: "tableRow", attrs: { id: "row" }, content: [
                { type: "tableCell", attrs: { id: "cell" }, content: [paragraph("cell-text")] },
            ] },
        ] }, paragraph("tail"),
    ]);
    const before = h.editor.state.doc;
    h.swipe(0);
    assert.deepEqual(h.selected(), ["table"]);
    assert.equal(h.editor.state.doc, before);
    await h.w.tiptapCommand("requestSelectedBlocksForSubpage");
    const request = h.events.findLast(event => event.kind === "selectedBlocksForSubpage");
    assert.equal(request.payload.document.content[0].type, "table");
    assert.equal(request.payload.document.content[0].content[0].content[0].attrs.id, "cell");
});

for (const block of [
    { type: "heading", attrs: { id: "heading", level: 2 }, content: [{ type: "text", text: "Heading" }] },
    { type: "divider", attrs: { id: "divider", style: "thinLine" } },
    { type: "pageBreak", attrs: { id: "break" } },
    { type: "codeBlock", attrs: { id: "code" }, content: [{ type: "text", text: "Code" }] },
    { type: "pageReference", attrs: { id: "embedded", documentID: "child" } },
]) {
    test(`${block.type} participates through the same top-level mechanism`, async t => {
        const h = await fixture(t, [block, paragraph("tail")]);
        const before = h.editor.state.doc;
        h.swipe(0);
        assert.deepEqual(h.selected(), [block.attrs.id]);
        assert.equal(h.editor.state.doc, before);
    });
}

test("Escape clears plugin selection through the DOM even when the editor is read-only for block actions", async t => {
    const h = await fixture(t);
    h.swipe();
    assert.equal(h.editor.isEditable, false);
    const event = new h.w.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    h.editor.view.dom.dispatchEvent(event);
    assert.equal(event.defaultPrevented, true);
    assert.equal(h.state().mode, "off");
    assert.equal(h.editor.isEditable, true);
    assert.deepEqual(h.selected(), []);
});

test("a following synthetic click is swallowed once, and deliberate taps toggle selection without a gutter", async t => {
    const h = await fixture(t);
    h.swipe();
    const first = h.blocks()[0].element;
    first.dispatchEvent(new h.w.MouseEvent("click", { bubbles: true, cancelable: true }));
    assert.deepEqual(h.selected(), ["one"]);
    h.tick(500);
    first.dispatchEvent(new h.w.MouseEvent("click", { bubbles: true, cancelable: true, clientX: 180 }));
    assert.deepEqual(h.selected(), []);
    const second = h.blocks()[1].element;
    second.dispatchEvent(new h.w.MouseEvent("click", { bubbles: true, cancelable: true, clientX: 30 }));
    assert.deepEqual(h.selected(), ["two"]);
});

test("editor destruction removes block listeners and the extension's stylesheet", async t => {
    const h = await fixture(t);
    const element = h.blocks()[0].element;
    const before = h.events.length;
    h.editor.destroy();
    element.dispatchEvent(new h.w.Event("touchstart", { bubbles: true }));
    assert.equal(h.events.length, before);
    assert.equal([...h.w.document.querySelectorAll("style")].some(style => style.textContent.includes("penned-swipe-block")), false);
});

test("locking or loading another document cancels selection and cannot retain foreign blocks", async t => {
    const h = await fixture(t);
    h.swipe();
    await h.w.tiptapCommand("setEditable", { editable: false });
    assert.equal(h.state().mode, "off");
    assert.deepEqual(h.selected(), []);
    h.swipe();
    assert.deepEqual(h.selected(), []);
    await h.w.tiptapCommand("setEditable", { editable: true });
    h.swipe();
    await h.w.tiptapCommand("setContent", { document: { type: "doc", content: [paragraph("other-owner")] } });
    assert.deepEqual(h.selected(), []);
    assert.equal(h.state().mode, "off");
});

test("leaving selection restores ordinary typing, formatting, undo and redo", async t => {
    const h = await fixture(t);
    h.swipe();
    await h.w.tiptapCommand("clearBlockSelection");
    assert.equal(h.editor.isEditable, true);
    h.editor.commands.setTextSelection(1);
    await h.w.tiptapCommand("formatCurrentSelection", { action: "italic" });
    h.editor.commands.insertContent("New");
    const edited = json(h.editor.getJSON());
    assert.equal(h.editor.state.doc.firstChild.textContent, "NewText");
    await h.w.tiptapCommand("undo");
    assert.equal(h.editor.state.doc.firstChild.textContent, "Text");
    await h.w.tiptapCommand("redo");
    assert.deepEqual(json(h.editor.getJSON()), edited);
});

test("typing followed immediately by a swipe survives WebKit's touchstart DOM-input flush", async t => {
    const h = await fixture(t);
    h.editor.commands.setTextSelection(5);
    h.editor.view.focus();
    const first = h.blocks()[0].element;
    first.firstChild.nodeValue = "Text typed on the keyboard";
    first.dispatchEvent(new h.w.InputEvent("input", { bubbles: true, inputType: "insertText", data: " typed on the keyboard" }));
    // ProseMirror's native touchstart handler flushes the still-pending input after
    // the passive block listener observes contact. The pending swipe must map.
    h.touch("touchstart", 0, 100, 40);
    await Promise.resolve();
    assert.equal(h.editor.state.doc.firstChild.textContent, "Text typed on the keyboard");
    assert.equal(h.state().gesture?.phase, "pending");
    h.touch("touchmove", 0, 160, 42);
    h.touch("touchend", 0, 160, 42);
    assert.deepEqual(h.selected(), ["one"]);
    assert.equal(h.editor.state.doc.firstChild.textContent, "Text typed on the keyboard");
});

test("newly split paragraphs and duplicate IDs resolve to the touched position after native input", async t => {
    const h = await fixture(t);
    h.editor.commands.setTextSelection(3);
    h.editor.commands.splitBlock();
    h.editor.view.focus();
    const typed = h.blocks()[1].element;
    typed.firstChild.nodeValue = "Newly typed text";
    typed.dispatchEvent(new h.w.InputEvent("input", { bubbles: true, inputType: "insertText", data: "Newly typed text" }));
    h.touch("touchstart", 1, 100, 120);
    await Promise.resolve(); // Native events have a microtask checkpoint between contacts/movement.
    h.touch("touchmove", 1, 160, 122);
    h.touch("touchend", 1, 160, 122);
    assert.equal(h.editor.state.doc.child(1).textContent, "Newly typed text");
    assert.equal(h.state().selected.length, 1);
    assert.equal(h.state().selected[0].pos, h.blocks()[1].pos);
    await h.w.tiptapCommand("clearBlockSelection");
    await h.w.tiptapCommand("setContent", { document: { type: "doc", content: [paragraph("same-id"), paragraph("same-id")] } });
    h.swipe(1);
    assert.equal(h.state().selected[0].pos, h.blocks()[1].pos);
    assert.equal(h.blocks()[0].element.classList.contains("penned-block-selected"), false);
});

test("pending swipes map through input transactions and active edits cancel only the transient drag", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 1, 100, 120);
    await Promise.resolve();
    h.editor.view.dispatch(h.editor.state.tr.insertText("Typed", 1));
    assert.equal(h.state().gesture?.phase, "pending");
    assert.equal(h.state().gesture.origin.pos, h.blocks()[1].pos);
    h.touch("touchmove", 1, 160, 122);
    assert.deepEqual(h.selected(), ["two"]);
    h.editor.view.dispatch(h.editor.state.tr.insertText("More", 1));
    assert.equal(h.state().gesture, null);
    assert.deepEqual(h.selected(), ["two"]);
    await h.w.tiptapCommand("clearBlockSelection");
    h.swipe(2);
    assert.deepEqual(h.selected(), ["three"]);
});

test("live DOM identities are rebound when NodeViews redraw without a document change", async t => {
    const h = await fixture(t), doc = h.editor.state.doc, old = h.blocks()[0].element;
    h.editor.view.setProps({ nodeViews: { ...h.editor.view.props.nodeViews, paragraph() {
        const dom = h.w.document.createElement("p");
        return { dom, contentDOM: dom };
    } } });
    assert.equal(h.editor.state.doc, doc);
    assert.notEqual(h.blocks()[0].element, old);
    assert.equal(old.isConnected, false);
    h.swipe();
    assert.deepEqual(h.selected(), ["one"]);
});

test("a contact on marked text survives replacement of its original inline touch target", async t => {
    const h = await fixture(t, [{ ...paragraph("marked"), content: [{ type: "text", text: "Text", marks: [{ type: "bold" }] }] }, paragraph("tail")]);
    const target = h.blocks()[0].element.querySelector("strong");
    assert.ok(target);
    h.touch("touchstart", 0, 100, 40, { target });
    await Promise.resolve();
    h.editor.view.dispatch(h.editor.state.tr.removeMark(1, 5, h.editor.schema.marks.bold));
    assert.equal(target.parentElement, null);
    assert.equal(h.state().gesture?.phase, "pending");
    h.touch("touchmove", 0, 160, 42, { target });
    h.touch("touchend", 0, 160, 42, { target });
    assert.deepEqual(h.selected(), ["marked"]);
    assert.equal(h.state().gesture, null);
    assert.equal(h.editor.view.dom.querySelectorAll(".penned-block-selected").length, 1);
});

test("typing, deleting, splitting and inserting blocks never require editor recreation before another swipe", async t => {
    const h = await fixture(t), view = h.editor.view;
    for (const edit of [
        () => h.editor.commands.insertContent("Typed"),
        () => h.editor.commands.deleteRange({ from: 1, to: 2 }),
        () => h.editor.commands.splitBlock(),
        () => h.editor.commands.insertContentAt(0, paragraph("inserted")),
        () => h.editor.commands.undo(),
        () => h.editor.commands.redo(),
    ]) {
        await h.w.tiptapCommand("clearBlockSelection");
        h.editor.commands.setTextSelection(2);
        edit();
        h.swipe(0);
        assert.equal(h.state().selected.length, 1);
        assert.equal(h.state().selected[0].pos, 0);
        assert.equal(h.editor.view, view);
    }
});

test("toggle heading, body paragraph and nested callout contents select independently without ancestor painting", async t => {
    const content = [{ type: "toggleItem", attrs: { id: "toggle", open: true }, content: [
        { type: "heading", attrs: { id: "title", level: 2 }, content: [{ type: "text", text: "Toggle heading" }] },
        paragraph("body", "Body paragraph"),
        { type: "callout", attrs: { id: "callout", icon: "sparkle" }, content: [paragraph("callout-text", "A callout")] },
    ] }, paragraph("outside")];
    const h = await fixture(t, content), original = h.editor.state.doc;
    assert.deepEqual(json(h.blocks().map(block => block.path)), [[0, 0], [0, 1], [0, 2, 0], [1]]);
    for (const [index, id] of ["title", "body", "callout-text"].entries()) {
        await h.w.tiptapCommand("clearBlockSelection");
        h.swipe(index);
        assert.deepEqual(h.selected(), [id]);
        assert.equal(h.editor.view.dom.querySelectorAll(".penned-block-selected").length, 1);
        assert.equal(h.blocks()[index].element.classList.contains("penned-block-selected"), true);
        assert.equal(h.editor.view.nodeDOM(0).classList.contains("penned-block-selected"), false);
        assert.equal(h.editor.state.doc, original);
    }
    await h.w.tiptapCommand("formatSelectedBlocks", { action: "bold" });
    assert.equal(h.editor.state.doc.firstChild.child(2).firstChild.firstChild.marks[0].type.name, "bold");
    assert.equal(h.editor.state.doc.firstChild.child(1).firstChild.marks.length, 0);
    await h.w.tiptapCommand("duplicateSelectedBlocks");
    assert.equal(h.editor.state.doc.firstChild.child(2).childCount, 2);
    assert.equal(h.editor.state.doc.firstChild.childCount, 3);
    h.editor.state.doc.check();
});

test("one horizontal commit stays on its origin despite layout movement or proximity to a neighbor", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 0, 100, 79);
    // Native keyboard/layout movement must not change the already-known origin.
    h.bounds("one", { top: -20, bottom: 40 });
    h.bounds("two", { top: 50, bottom: 110 });
    h.touch("touchmove", 0, 160, 81);
    assert.deepEqual(h.selected(), ["one"]);
    h.touch("touchmove", 0, 161, 84);
    h.touch("touchend", 0, 161, 84);
    assert.deepEqual(h.selected(), ["one"]);
});

test("range extension requires deliberate vertical entry and shrinks all the way back to the origin", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 0, 100, 75);
    h.touch("touchmove", 0, 160, 77);
    h.touch("touchmove", 0, 161, 103); // At the next block edge, not inside its selection surface.
    assert.deepEqual(h.selected(), ["one"]);
    h.touch("touchmove", 0, 161, 130);
    assert.deepEqual(h.selected(), ["one", "two"]);
    h.touch("touchmove", 0, 161, 210);
    assert.deepEqual(h.selected(), ["one", "two", "three"]);
    h.touch("touchmove", 0, 161, 76);
    assert.deepEqual(h.selected(), ["one"]);
});

test("a new vertical contact on selected content resumes, expands and shrinks the retained range", async t => {
    const h = await fixture(t), original = h.editor.state.doc;
    h.swipe(1);
    assert.deepEqual(h.selected(), ["two"]);
    assert.equal(h.editor.isEditable, false);
    h.touch("touchstart", 1, 160, 125);
    assert.equal(h.touch("touchmove", 1, 161, 210).defaultPrevented, true);
    assert.deepEqual(h.selected(), ["two", "three"]);
    assert.equal(h.editor.isEditable, false, "resuming a range must not reopen editing/the keyboard");
    h.touch("touchend", 1, 161, 210);
    h.touch("touchstart", 2, 161, 210);
    h.touch("touchmove", 2, 161, 125);
    assert.deepEqual(h.selected(), ["two"]);
    h.touch("touchmove", 2, 161, 45);
    assert.deepEqual(h.selected(), ["one", "two"]);
    h.touch("touchend", 2, 161, 45);
    assert.deepEqual(h.selected(), ["one", "two"]);
    assert.equal(h.editor.state.doc, original);
    h.touch("touchstart", 2, 100, 210); // Unselected content still allows scrolling.
    assert.equal(h.touch("touchmove", 2, 102, 160).defaultPrevented, false);
});

test("fast vertical drags cross skipped blocks, reach document edges and still reverse to shrink", async t => {
    const h = await fixture(t);
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 160, 42);
    h.touch("touchmove", 0, 160, 700);
    assert.deepEqual(h.selected(), ["one", "two", "three"]);
    h.touch("touchmove", 0, 160, 5);
    assert.deepEqual(h.selected(), ["one"]);
    h.touch("touchend", 0, 160, 5);
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 100, 125);
    h.touch("touchend", 0, 100, 125);
    assert.deepEqual(h.selected(), ["one", "two"]);
    // Re-swiping an already selected block must not turn its old range into an
    // unshrinkable base selection.
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 160, 42);
    h.touch("touchmove", 0, 160, 65);
    h.touch("touchend", 0, 160, 65);
    assert.deepEqual(h.selected(), ["one"]);
});

test("vertical ranges traverse nested visible blocks without selecting wrappers or collapsed contents", async t => {
    const h = await fixture(t, [{ type: "toggleItem", attrs: { id: "toggle", open: true }, content: [
        paragraph("title"), paragraph("body"),
        { type: "blockquote", attrs: { id: "quote" }, content: [paragraph("quoted"), paragraph("quoted-two")] },
    ] }, { type: "toggleItem", attrs: { id: "closed", open: false }, content: [paragraph("closed-title"), paragraph("hidden")] }, paragraph("outside")]);
    h.touch("touchstart", 0, 100, 40);
    h.touch("touchmove", 0, 160, 42);
    h.touch("touchmove", 0, 160, 525);
    assert.deepEqual(h.selected(), ["title", "body", "quoted", "quoted-two", "closed-title", "outside"]);
    h.touch("touchmove", 0, 160, 125);
    assert.deepEqual(h.selected(), ["title", "body"]);
    assert.equal(h.editor.view.nodeDOM(0).classList.contains("penned-block-selected"), false);
});

test("nested selected tables paint the actual table and cell surfaces, not the full-width scroll wrapper", async t => {
    const h = await fixture(t, [{ type: "toggleItem", attrs: { id: "toggle", open: true }, content: [
        paragraph("title"), { type: "table", attrs: { id: "table" }, content: [
            { type: "tableRow", content: [{ type: "tableCell", attrs: { backgroundColor: "#ffffff" }, content: [paragraph("cell")] }] },
        ] }, paragraph("tail"),
    ] }]);
    h.swipe(1);
    assert.deepEqual(h.selected(), ["table"]);
    const wrapper = h.blocks()[1].element, table = wrapper.querySelector("table"), cell = table.querySelector("td");
    assert.equal(wrapper.classList.contains("penned-block-selected"), true);
    assert.equal(h.w.getComputedStyle(wrapper).outline, "none");
    assert.match(h.w.getComputedStyle(table).outline, /2px solid #b59ad9/);
    assert.match(h.w.getComputedStyle(cell).boxShadow, /9999px/);
    assert.equal(h.editor.view.nodeDOM(0).classList.contains("penned-block-selected"), false);
    assert.equal(h.editor.view.dom.querySelectorAll(".penned-block-selected").length, 1);
    h.editor.view.dispatch(h.editor.state.tr.insertText("Edited title", 2));
    assert.deepEqual(h.selected(), ["table"]);
    assert.match(h.w.getComputedStyle(table).outline, /2px solid #b59ad9/);
});

test("deleting a nested leading list paragraph preserves the required paragraph and nested sibling hierarchy", async t => {
    const h = await fixture(t, [{ type: "bulletList", attrs: { id: "list" }, content: [
        { type: "listItem", attrs: { id: "item" }, content: [paragraph("parent-text"),
            { type: "bulletList", attrs: { id: "inner-list" }, content: [
                { type: "listItem", attrs: { id: "inner-item" }, content: [paragraph("inner-text")] },
            ] },
        ] },
    ] }, paragraph("tail")]);
    h.swipe(0);
    await h.w.tiptapCommand("deleteSelectedBlocks");
    h.editor.state.doc.check();
    const item = h.editor.state.doc.firstChild.firstChild;
    assert.equal(item.firstChild.type.name, "paragraph");
    assert.equal(item.child(1).attrs.id, "inner-list");
    assert.equal(item.child(1).firstChild.firstChild.attrs.id, "inner-text");
    assert.equal(h.events.findLast(event => event.kind === "snapshot").payload.document.content[0].content[0].content[1].attrs.id, "inner-list");
    await h.w.tiptapCommand("undo");
    assert.equal(h.editor.state.doc.firstChild.firstChild.firstChild.attrs.id, "parent-text");
    await h.w.tiptapCommand("redo");
    h.editor.state.doc.check();
    assert.equal(h.editor.state.doc.firstChild.firstChild.child(1).attrs.id, "inner-list");
});

test("cutting nested content uses the same schema-safe deletion path as Delete", async t => {
    const h = await fixture(t, [{ type: "blockquote", attrs: { id: "quote" }, content: [paragraph("quoted", "Copy me")] }, paragraph("tail")]);
    h.swipe(0);
    await h.w.tiptapCommand("cutSelectedBlocks");
    assert.equal(h.copied.at(-1), "Copy me");
    h.editor.state.doc.check();
    assert.equal(h.editor.state.doc.firstChild.type.name, "blockquote");
    assert.equal(h.editor.state.doc.firstChild.firstChild.type.name, "paragraph");
    assert.equal(h.editor.state.doc.firstChild.firstChild.textContent, "");
    assert.equal(h.editor.state.doc.child(1).attrs.id, "tail");
});

test("page and file surfaces recognize swipes on their main buttons without triggering native actions", async t => {
    const h = await fixture(t, [
        { type: "pageReference", attrs: { id: "page", documentID: "child" } },
        { type: "attachment", attrs: { id: "file", file: { name: "file.txt", relativePath: "file.txt" } } }, paragraph("tail"),
    ]);
    for (const [index, selector, id] of [[0, ".vellix-page-reference-button", "page"], [1, ".penned-file-card", "file"]]) {
        await h.w.tiptapCommand("clearBlockSelection");
        const target = h.blocks()[index].element.querySelector(selector), y = 40 + index * 80;
        assert.ok(target);
        h.touch("touchstart", index, 100, y, { target });
        h.touch("touchmove", index, 160, y + 2, { target });
        h.touch("touchend", index, 160, y + 2, { target });
        target.dispatchEvent(new h.w.MouseEvent("click", { bubbles: true, cancelable: true }));
        assert.deepEqual(h.selected(), [id]);
    }
    assert.equal(h.events.some(event => ["pageRequest", "attachmentMenu", "attachmentActions"].includes(event.kind)), false);
});

test("native nested block transforms never leave invalid container content", async t => {
    const h = await fixture(t, [{ type: "taskList", attrs: { id: "tasks" }, content: [
        { type: "taskItem", attrs: { id: "task" }, content: [paragraph("task-text"), paragraph("other")] },
    ] }, paragraph("tail")]);
    h.swipe(1);
    await h.w.tiptapCommand("setSelectedBlockType", { blockType: "heading", level: 2 });
    h.editor.state.doc.check();
    assert.equal(h.editor.state.doc.firstChild.type.name, "taskList");
    assert.equal(h.editor.state.doc.firstChild.firstChild.child(1).type.name, "heading");
    assert.equal(h.editor.state.doc.firstChild.firstChild.child(1).attrs.id, "other");
});

test("a type change forbidden by the real parent schema cannot corrupt a leading list paragraph", async t => {
    const h = await fixture(t, [{ type: "bulletList", attrs: { id: "list" }, content: [
        { type: "listItem", attrs: { id: "item" }, content: [paragraph("leading"), paragraph("other")] },
    ] }, paragraph("tail")]);
    h.swipe(0);
    const before = h.editor.state.doc;
    await h.w.tiptapCommand("setSelectedBlockType", { blockType: "heading", level: 2 });
    assert.equal(h.editor.state.doc, before);
    h.editor.state.doc.check();
    assert.match(h.events.findLast(event => event.kind === "error").payload.message, /not supported inside this container/);
    await h.w.tiptapCommand("formatSelectedBlocks", { action: "bold" });
    h.editor.state.doc.check();
    assert.equal(h.editor.state.doc.firstChild.firstChild.firstChild.firstChild.marks[0].type.name, "bold");
});

test("selection painting has no text-box estimates, offsets, borders or nested-container coordinates", async t => {
    const h = await fixture(t, [{ type: "blockquote", attrs: { id: "quote" }, content: [
        paragraph("short", "Short"), paragraph("wrapped", "A longer paragraph that wraps onto additional lines"),
    ] }, paragraph("tail")]);
    const before = h.editor.state.doc;
    h.bounds("wrapped", { top: 180, bottom: 300, left: 70, right: 330, width: 260 });
    h.touch("touchstart", 1, 100, 220);
    h.touch("touchmove", 1, 160, 222);
    h.touch("touchend", 1, 160, 222);
    const selected = h.editor.view.dom.querySelector(".penned-block-selected");
    assert.equal(selected, h.blocks()[1].element);
    assert.equal(selected.parentElement.classList.contains("penned-block-selected"), false);
    assert.equal(h.w.getComputedStyle(selected).outlineOffset, "-2px");
    assert.equal(selected.style.transform, "");
    assert.deepEqual(selected.getBoundingClientRect(), { top: 180, bottom: 300, left: 70, right: 330, width: 260, height: 120 });
    assert.equal(h.editor.state.doc, before);
    assert.doesNotMatch(source, /--vellix-selection-highlight|createRange\(|getClientRects\(|position:\s*absolute|padding:|border:\s/);
});

test("mobile tables gain twelve points only at adjoining nested-page or card boundaries", async t => {
    const table = id => ({ type: "table", attrs: { id }, content: [
        { type: "tableRow", content: [{ type: "tableCell", content: [paragraph(id + "-cell")] }] },
    ] });
    const h = await fixture(t, [table("above"), { type: "pageReference", attrs: { id: "page", documentID: "child" } },
        table("below"), paragraph("separation"), table("ordinary"), paragraph("tail")]);
    const [above, page, below, , ordinary] = h.blocks().map(block => block.element);
    for (const isCard of [false, true]) {
        page.classList.toggle("vellix-page-card", isCard);
        assert.equal(h.w.getComputedStyle(above).marginBottom, "26px");
        assert.equal(h.w.getComputedStyle(below).marginTop, "26px");
        assert.equal(h.w.getComputedStyle(ordinary).marginTop, "14px");
        assert.equal(h.w.getComputedStyle(ordinary).marginBottom, "14px");
        assert.equal(h.w.getComputedStyle(page).paddingTop, isCard ? "6px" : "2px");
        assert.equal(h.w.getComputedStyle(page).paddingBottom, isCard ? "6px" : "2px");
    }
    page.hidden = true;
    assert.equal(h.w.getComputedStyle(above).marginBottom, "14px");
    assert.equal(h.w.getComputedStyle(below).marginTop, "14px");
});

test("native fallback pages and cards have twelve points above the list in both mobile document layouts", async () => {
    const view = await read("Vellix/Editor/DocumentEditorView.swift");
    const unplaced = view.slice(view.indexOf("private func unplacedPages("), view.indexOf("private var hasUnplacedPages:"));
    assert.match(unplaced, /if !unplaced\.isEmpty \{\s+VStack\(spacing: 0\)/);
    assert.match(unplaced, /if let style = child\.cardStyle/);
    assert.match(unplaced, /NestedPageRow\(document: child/);
    assert.match(unplaced, /\n            \}\n            \.padding\(\.top, 12\)\n        \}\n    \}/);
    assert.equal((view.match(/unplacedPages\(appearance: appearance\)/g) ?? []).length, 2);
});

test("interactive controls, horizontal scrolling, and touches outside blocks are not captured", async t => {
    const h = await fixture(t);
    const first = h.blocks()[0].element;
    const button = h.w.document.createElement("button");
    first.appendChild(button);
    h.touch("touchstart", 0, 100, 40, { target: button });
    assert.equal(h.state().gesture, null);
    Object.defineProperty(first, "scrollWidth", { value: 600 });
    Object.defineProperty(first, "clientWidth", { value: 300 });
    first.style.overflowX = "auto";
    h.touch("touchstart", 0, 100, 40);
    assert.equal(h.state().gesture, null);
    h.touch("touchstart", 0, 100, 40, { target: h.editor.view.dom });
    assert.equal(h.state().gesture, null);
});

test("the gesture is plugin-owned and block-scoped, never a global pointer recognizer", async () => {
    assert.match(source, /new Plugin\(\{ key/);
    assert.match(source, /state: \{\s+init: empty,\s+apply\(tr, previous\)/);
    assert.match(source, /element\.addEventListener\(name, handler/);
    assert.match(source, /passive: name === "touchstart"/);
    assert.doesNotMatch(source, /(?:document|window|view\.dom)\.addEventListener\(|pointerdown|pointermove|setPointerCapture/);
    assert.match(source, /\.penned-block-selection-active \.penned-block-selected \{ touch-action: none !important; \}/);
    assert.doesNotMatch(source, /post\([^\n]*(?:gesture|dx|clientX|clientY)/);
    const host = await read("Vellix/Editor/TipTapWebView.swift");
    assert.match(host, /#if os\(iOS\)\s+contentController.addUserScript\(WKUserScript\(source: MobileBlockSelection.script, injectionTime: \.atDocumentStart/);
    assert.doesNotMatch(await read("PennedMac/Editor/MacTipTapWebView.swift"), /MobileBlockSelection/);
});
