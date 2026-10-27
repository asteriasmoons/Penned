import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

// Executes the shipping JavaScript directly. No build, compiler, app launch, or simulator.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { JSDOM } = await import(pathToFileURL(join(backend, "node_modules/jsdom/lib/api.js")));
const bundle = join(root, "Vellix/VellixEditor.bundle");
const files = ["vendor/formula-parser.min.js", "table-formulas.js",
  "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js"];
const scripts = await Promise.all(files.map(file => readFile(join(bundle, file), "utf8")));
const mobileSource = await readFile(join(root, "Vellix/Editor/MobileEditorInteractions.swift"), "utf8");
const mobileScript = mobileSource.match(/static let script = #"""\n([^]*?)\n"""#/);
assert.ok(mobileScript, "the iOS host must inject the exact tested mobile adapter");
scripts.push(mobileScript[1]);
const blockSelectionSource = await readFile(join(root, "Vellix/Editor/MobileBlockSelection.swift"), "utf8");
const blockSelectionScript = blockSelectionSource.match(/static let script = #"""\n([^]*?)\n"""#/)[1];
const paragraph = (id, text = "") => ({ type: "paragraph", attrs: { id },
  ...(text ? { content: [{ type: "text", text }] } : {}) });
const quote = content => ({ type: "blockquote", attrs: { id: "quote", color: "#12ABCD" }, content });
const json = value => JSON.parse(JSON.stringify(value));

async function fixture(t, content, mobile = true) {
  const dom = new JSDOM("<!doctype html><html><body><main class='vellix-editor-page'><div id='editor'></div></main></body></html>",
    { runScripts: "outside-only", pretendToBeVisual: true, url: "https://penned.test" });
  t.after(() => dom.window.close());
  const w = dom.window, events = [];
  let nativeSuppressed = false, nativeSlashMenu = null;
  let transactionTime = Date.now();
  w.Date.now = () => transactionTime;
  w.console.log = w.console.info = () => {};
  w.crypto.randomUUID = randomUUID;
  w.ResizeObserver = class { observe() {} disconnect() {} };
  w.webkit = { messageHandlers: { tiptap: { postMessage: event => {
    events.push(event);
    if (event.kind === "mobileSlashSuppression") {
      nativeSuppressed = event.payload.suppressed;
      if (nativeSuppressed) nativeSlashMenu = null;
    }
    if (event.kind === "slashMenu" && (!nativeSuppressed || !event.payload.visible)) {
      nativeSlashMenu = event.payload.visible ? event.payload : null;
    }
  } } } };
  w.scrollBy = () => {};
  w.Range.prototype.getClientRects = () => [];
  w.Range.prototype.getBoundingClientRect = () => ({ top: 300, left: 20, bottom: 324, right: 100 });
  if (mobile) w.eval(blockSelectionScript);
  for (let i = 0; i < scripts.length - (mobile ? 0 : 1); i++) w.eval(scripts[i]);
  await w.tiptapCommand("setContent", { document: { type: "doc", content } });
  // Keep document loading and the tested edit in separate history groups without a timer.
  transactionTime += 1000;
  const editor = w.document.querySelector(".tiptap-editor").editor;
  function caret(id, offset = 0) {
    let target;
    editor.state.doc.descendants((node, pos) => { if (node.attrs.id === id) target = pos + 1 + offset; });
    assert.notEqual(target, undefined, id);
    editor.commands.setTextSelection(target);
  }
  function backspace(type = "beforeinput") {
    const event = type === "beforeinput"
      ? new w.InputEvent(type, { inputType: "deleteContentBackward", bubbles: true, cancelable: true })
      : new w.KeyboardEvent(type, { key: "Backspace", bubbles: true, cancelable: true });
    editor.view.dom.dispatchEvent(event);
    return event;
  }
  return { w, editor, events, caret, backspace, nativeSlashMenu: () => nativeSlashMenu };
}

for (const style of ["thinLine", "thickLine", "dottedCircles", "fourCircles", "tinyDots", "fourDots"]) {
  test(`toolbar divider replaces the empty caret paragraph (${style})`, async t => {
    const { w, editor, caret } = await fixture(t, [paragraph("before", "Keep me"), paragraph("empty"), paragraph("after", "Also keep me")]);
    caret("empty");
    const before = json(editor.getJSON());
    assert.equal(await w.tiptapCommand("insertDivider", { style }), true);
    const nodes = json(editor.getJSON()).content;
    assert.deepEqual(nodes.map(node => node.type), ["paragraph", "divider", "paragraph", "paragraph"]);
    assert.deepEqual(json(nodes[0]), before.content[0]);
    assert.deepEqual(json(nodes[3]), before.content[2]);
    assert.equal(nodes[1].attrs.style, style === "tinyDots" ? "dottedCircles" : style === "fourDots" ? "fourCircles" : style);
    assert.equal(editor.state.selection.$from.parent.attrs.id, nodes[2].attrs.id);
    assert.equal(nodes.some(node => node.attrs.id === "empty"), false);
    assert.equal(editor.commands.undo(), true);
    assert.deepEqual(json(editor.getJSON()), before, "one Undo must restore the complete prior document");
  });
}

test("divider stays at the caret instead of appending to the document", async t => {
  const { w, editor, caret } = await fixture(t, [paragraph("text", "Hello world"), paragraph("tail", "Tail")]);
  caret("text", 5);
  assert.equal(await w.tiptapCommand("insertDivider", { style: "thickLine" }), true);
  assert.equal(editor.state.doc.textContent, "Hello worldTail");
  assert.deepEqual(json(editor.getJSON()).content.map(node => node.type), ["paragraph", "divider", "paragraph", "paragraph"]);
  assert.equal(editor.getJSON().content.at(-1).attrs.id, "tail");
});

test("slash divider consumes the slash paragraph without leaving a blank above", async t => {
  const { w, editor, caret } = await fixture(t, [paragraph("top", "Keep"), paragraph("slash", "/divider"), paragraph("tail", "Tail")]);
  caret("slash", 8);
  assert.equal(await w.tiptapCommand("chooseSlashItem", { key: "divider:thickLine" }), true);
  assert.deepEqual(json(editor.getJSON()).content.map(node => node.type), ["paragraph", "divider", "paragraph", "paragraph"]);
  assert.equal(editor.state.doc.textContent, "KeepTail");
});

const divider = (id, style = "thinLine") => ({ type: "divider", attrs: { id, style } });
function tapDivider(w, editor, id, y = 126) {
  const element = editor.view.dom.querySelector(`[data-vellix-divider][id="${id}"]`);
  assert.ok(element, "the shipping divider must be rendered");
  element.getBoundingClientRect = () => ({ top: 100, bottom: 130, left: 20, right: 300, width: 280, height: 30 });
  const event = new w.MouseEvent("click", { bubbles: true, cancelable: true, clientX: 80, clientY: y, button: 0 });
  (element.firstElementChild ?? element).dispatchEvent(event);
  return event;
}

for (const style of ["thinLine", "thickLine", "dottedCircles", "fourCircles"]) {
  test(`tapping below a reopened terminal divider creates and focuses a typing paragraph (${style})`, async t => {
    const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider", style)]);
    const saved = json(await w.tiptapCommand("getDocument"));
    await w.tiptapCommand("setContent", { document: saved });
    assert.equal(editor.state.doc.lastChild.type.name, "divider");
    const originalDivider = json(editor.getJSON().content[1]);
    assert.equal(tapDivider(w, editor, "divider").defaultPrevented, true);
    const nodes = json(editor.getJSON()).content;
    assert.deepEqual(nodes.map(node => node.type), ["paragraph", "divider", "paragraph"]);
    assert.equal(editor.state.selection.$from.parent.attrs.id, nodes[2].attrs.id);
    assert.equal(editor.state.selection.$from.parentOffset, 0);
    assert.equal(editor.view.hasFocus(), true);
    editor.commands.insertContent("After divider");
    assert.equal(editor.state.doc.lastChild.textContent, "After divider");
    assert.deepEqual(json(editor.getJSON().content[1]), originalDivider);
  });
}

test("tapping below a divider reuses its existing paragraph without creating blank lines", async t => {
  const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider"), paragraph("after"), paragraph("tail", "Tail")]);
  const before = json(editor.getJSON());
  tapDivider(w, editor, "divider");
  tapDivider(w, editor, "divider");
  assert.deepEqual(json(editor.getJSON()), before);
  assert.equal(editor.state.selection.$from.parent.attrs.id, "after");
});

test("tapping the empty paragraph below a divider places the caret there", async t => {
  const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider"), paragraph("after"), paragraph("tail", "Tail")]);
  let element;
  editor.state.doc.descendants((node, position) => { if (node.attrs.id === "after") element = editor.view.nodeDOM(position); });
  assert.ok(element);
  const before = json(editor.getJSON());
  element.dispatchEvent(new w.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(editor.state.selection.$from.parent.attrs.id, "after");
  assert.deepEqual(json(editor.getJSON()), before);
});

test("adjacent dividers get a typing paragraph between them without moving other content", async t => {
  const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider"), divider("second"), paragraph("tail", "Tail")]);
  tapDivider(w, editor, "divider");
  const nodes = json(editor.getJSON()).content;
  assert.deepEqual(nodes.map(node => node.type), ["paragraph", "divider", "paragraph", "divider", "paragraph"]);
  assert.equal(nodes[3].attrs.id, "second");
  assert.equal(editor.state.selection.$from.parent.attrs.id, nodes[2].attrs.id);
});

test("divider caret taps preserve existing following text and ignore the upper hit area", async t => {
  const { w, editor, caret } = await fixture(t, [paragraph("before", "Keep"), divider("divider"), paragraph("after", "Following text")]);
  caret("before", 2);
  const before = json(editor.getJSON());
  tapDivider(w, editor, "divider", 101);
  assert.equal(editor.state.selection.$from.parent.attrs.id, "before");
  tapDivider(w, editor, "divider");
  assert.equal(editor.state.selection.$from.parent.attrs.id, "after");
  assert.equal(editor.state.selection.$from.parentOffset, 0);
  assert.deepEqual(json(editor.getJSON()), before);
});

test("divider caret taps do not edit locked documents or block-selection mode", async t => {
  const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider")]);
  const before = json(editor.getJSON());
  editor.setEditable(false);
  tapDivider(w, editor, "divider");
  assert.deepEqual(json(editor.getJSON()), before);
  editor.setEditable(true);
  await w.tiptapCommand("setSelectionMode", { mode: "multi" });
  tapDivider(w, editor, "divider");
  assert.deepEqual(json(editor.getJSON()), before);
});

test("a selected divider can transition to a text caret and Undo restores the prior content", async t => {
  const { w, editor } = await fixture(t, [paragraph("before", "Keep"), divider("divider")]);
  const before = json(editor.getJSON());
  editor.commands.setNodeSelection(editor.state.doc.firstChild.nodeSize);
  assert.equal(editor.state.selection.node.type.name, "divider");
  tapDivider(w, editor, "divider");
  assert.ok(editor.state.selection.$cursor);
  assert.equal(editor.state.selection.$from.parent.type.name, "paragraph");
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(json(editor.getJSON()), before);
});

test("divider caret placement also works inside a quote without flattening its content", async t => {
  const { w, editor } = await fixture(t, [
    quote([paragraph("quoted", "Quote"), divider("divider")]), paragraph("tail", "Tail"),
  ]);
  tapDivider(w, editor, "divider");
  const content = json(editor.getJSON()).content;
  assert.deepEqual(content[0].content.map(node => node.type), ["paragraph", "divider", "paragraph"]);
  assert.equal(content[0].attrs.color, "#12ABCD");
  assert.equal(content[1].attrs.id, "tail");
  assert.equal(editor.state.selection.$from.node(1).attrs.id, "quote");
});

test("tap-away dismissal keeps literal slash and does not reopen on continued typing", async t => {
  const { w, editor, events, caret, nativeSlashMenu } = await fixture(t, [paragraph("slash", "/")]);
  caret("slash", 1);
  assert.equal(events.findLast(event => event.kind === "slashMenu")?.payload.visible, true);
  assert.equal(await w.tiptapCommand("mobileDismissSlashMenu"), true);
  assert.equal(editor.state.doc.textContent, "/");
  assert.equal(events.findLast(event => event.kind === "mobileSlashSuppression")?.payload.suppressed, true);
  assert.equal(nativeSlashMenu(), null);
  editor.commands.insertContent("path");
  assert.equal(editor.state.doc.textContent, "/path");
  assert.equal(events.findLast(event => event.kind === "slashMenu")?.payload.visible, false);
  assert.equal(nativeSlashMenu(), null);
  const enter = new w.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  w.document.dispatchEvent(enter);
  assert.equal(enter.defaultPrevented, false, "dismissed slash must not capture Enter as a menu choice");
  editor.commands.insertContent(" /");
  assert.equal(events.findLast(event => event.kind === "mobileSlashSuppression")?.payload.suppressed, false);
  assert.equal(events.findLast(event => event.kind === "slashMenu")?.payload.visible, true, "a new slash must still open the menu");
  assert.ok(nativeSlashMenu(), "the new menu must reach the native view on the first slash keystroke");
});

test("dismissal resets for a different document", async t => {
  const { w, events, caret } = await fixture(t, [paragraph("one", "/")]);
  caret("one", 1);
  await w.tiptapCommand("mobileDismissSlashMenu");
  await w.tiptapCommand("setContent", { document: { type: "doc", content: [paragraph("two", "/")] } });
  caret("two", 0);
  caret("two", 1);
  assert.equal(events.findLast(event => event.kind === "mobileSlashSuppression")?.payload.suppressed, false);
  assert.equal(events.findLast(event => event.kind === "slashMenu")?.payload.visible, true);
});

test("dismissal without a slash clears native suppression instead of disabling future menus", async t => {
  const { w, editor, events, caret } = await fixture(t, [paragraph("text", "Hello")]);
  caret("text", 5);
  await w.tiptapCommand("mobileDismissSlashMenu");
  assert.equal(events.findLast(event => event.kind === "mobileSlashSuppression")?.payload.suppressed, false);
  editor.commands.insertContent(" /");
  assert.equal(events.findLast(event => event.kind === "slashMenu")?.payload.visible, true);
});

test("divider insertion works in a list without breaking its required leading paragraph", async t => {
  const { w, editor, caret } = await fixture(t, [
    { type: "bulletList", attrs: { id: "list" }, content: [
      { type: "listItem", attrs: { id: "item" }, content: [paragraph("empty")] },
    ] }, paragraph("tail", "Tail"),
  ]);
  caret("empty");
  assert.equal(await w.tiptapCommand("insertDivider"), true);
  assert.equal(editor.getJSON().content[0].content[0].content[0].type, "paragraph");
  let dividers = 0;
  editor.state.doc.descendants(node => { if (node.type.name === "divider") dividers++; });
  assert.equal(dividers, 1);
  assert.equal(editor.state.doc.textContent, "Tail");
});

for (const input of ["beforeinput", "keydown"]) {
  test(`${input}: first Backspace below quote lands at end of quoted text`, async t => {
    const { editor, caret, backspace } = await fixture(t, [quote([paragraph("quoted", "Quote text")]), paragraph("empty"), paragraph("tail", "Tail")]);
    const before = json(editor.getJSON());
    caret("empty");
    assert.equal(backspace(input).defaultPrevented, true);
    assert.equal(editor.state.selection.$from.parent.attrs.id, "quoted");
    assert.equal(editor.state.selection.$from.parentOffset, "Quote text".length);
    assert.deepEqual(json(editor.getJSON().content[0]), before.content[0], "quote attributes and text must be untouched");
    assert.equal(editor.state.doc.textContent, "Quote textTail");
    if (input === "beforeinput") assert.equal(backspace(input).defaultPrevented, false, "next Backspace must use normal text deletion");
    else assert.equal(backspace("beforeinput").defaultPrevented, false, "native text deletion must be allowed inside the quote");
  });
}

test("quote transition handles the last paragraph and is undoable", async t => {
  const { editor, caret, backspace } = await fixture(t, [quote([paragraph("first", "First"), paragraph("last", "Last")]), paragraph("empty"), paragraph("tail", "Tail")]);
  const before = json(editor.getJSON());
  caret("empty");
  backspace();
  assert.equal(editor.state.selection.$from.parent.attrs.id, "last");
  assert.equal(editor.state.selection.$from.parentOffset, 4);
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(json(editor.getJSON()), before);
});

test("nonempty following paragraphs retain normal Backspace semantics", async t => {
  const { editor, caret, backspace } = await fixture(t, [quote([paragraph("quoted", "Quote")]), paragraph("text", "More")]);
  caret("text", 4);
  assert.equal(backspace().defaultPrevented, false);
  assert.equal(editor.state.selection.$from.parent.attrs.id, "text");
});

test("Backspace also handles an empty final paragraph below a quote", async t => {
  const { editor, backspace } = await fixture(t, [quote([paragraph("quoted", "Quote")])]);
  editor.commands.insertContentAt(editor.state.doc.content.size, paragraph("empty"));
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.equal(editor.state.selection.$from.parent.type.name, "paragraph");
  assert.equal(editor.state.selection.$from.parent.content.size, 0);
  assert.equal(backspace().defaultPrevented, true);
  assert.equal(editor.state.selection.$from.parent.attrs.id, "quoted");
  assert.equal(editor.state.selection.$from.parentOffset, 5);
});

test("quote Backspace does not intercept composing input or selected text", async t => {
  const { w, editor, caret, backspace } = await fixture(t, [quote([paragraph("quoted", "Quote")]), paragraph("empty"), paragraph("tail", "Tail")]);
  caret("empty");
  const composing = new w.InputEvent("beforeinput", { inputType: "deleteContentBackward", isComposing: true, bubbles: true, cancelable: true });
  editor.view.dom.dispatchEvent(composing);
  assert.equal(composing.defaultPrevented, false);
  caret("quoted", 0);
  editor.commands.setTextSelection({ from: editor.state.selection.from, to: editor.state.selection.from + 5 });
  assert.equal(backspace().defaultPrevented, false);
});

test("locked documents do not accept the mobile divider or quote edits", async t => {
  const { w, editor, caret, backspace } = await fixture(t, [quote([paragraph("quoted", "Quote")]), paragraph("empty"), paragraph("tail", "Tail")]);
  caret("empty");
  editor.setEditable(false);
  const before = json(editor.getJSON());
  assert.equal(await w.tiptapCommand("insertDivider"), false);
  assert.equal(backspace().defaultPrevented, false);
  assert.deepEqual(json(editor.getJSON()), before);
});

test("mobile edits round-trip through the existing document snapshot and load commands", async t => {
  const { w, editor, caret, backspace } = await fixture(t, [
    quote([paragraph("quoted", "Keep this quote")]), paragraph("empty"),
    paragraph("divider-location"), paragraph("tail", "Keep this text"),
  ]);
  caret("empty");
  backspace();
  caret("divider-location");
  await w.tiptapCommand("insertDivider", { style: "fourCircles" });
  const saved = json(await w.tiptapCommand("getDocument"));
  await w.tiptapCommand("setContent", { document: saved });
  assert.deepEqual(json(await w.tiptapCommand("getDocument")), saved);
  assert.equal(editor.state.doc.textContent, "Keep this quoteKeep this text");
  assert.equal(saved.content.find(node => node.type === "divider").attrs.style, "fourCircles");
});

test("without the iOS adapter the shipping editor bridge remains untouched", async t => {
  const { w, editor } = await fixture(t, [paragraph("empty")], false);
  assert.equal(editor.storage.pennedMobileInteractions, undefined);
  assert.equal(await w.tiptapCommand("mobileDismissSlashMenu"), false);
});

test("native mobile titles, tap-away and resource wiring are platform isolated", async () => {
  const read = path => readFile(join(root, path), "utf8");
  const view = await read("Vellix/Editor/DocumentEditorView.swift");
  assert.match(view, /TextField\(prompt, text: text\.singleLinePageTitle\)/);
  const titleInput = view.slice(view.indexOf("private func titleInput"), view.indexOf("private func plainDocument"));
  assert.match(titleInput, /lineLimit\(1\)/);
  assert.doesNotMatch(titleInput, /axis: \.vertical|lineLimit\(nil\)/);
  assert.match(view, /Color\.clear\s+\.contentShape\(Rectangle\(\)\)\s+\.onTapGesture \{ model\.session\.dismissSlashMenu\(\) \}/);
  assert.match(await read("Vellix/Editor/MobilePageTitle.swift"), /#if os\(iOS\)[\s\S]*split\(whereSeparator: \\\.isNewline\)/);
  for (const file of ["Vellix/Collections/CollectionKanbanView.swift", "Vellix/Collections/CollectionDocumentIntegration.swift"]) {
    assert.match(await read(file), /#if os\(iOS\)\s+TextField\([^]*?singleLinePageTitle[^]*?#else/);
  }
  const host = await read("Vellix/Editor/TipTapWebView.swift");
  assert.match(host, /#if os\(iOS\)\s+contentController\.addUserScript\(WKUserScript\(source: MobileBlockSelection\.script, injectionTime: \.atDocumentStart[^]*?source: MobileEditorInteractions\.script, injectionTime: \.atDocumentEnd[^]*?#endif/);
  const session = await read("Vellix/Editor/TipTapEditorSession.swift");
  assert.match(session, /if mobileSlashMenuSuppressed, state != nil \{ return \}/);
  for (const file of ["PennedMac/Editor/MacTipTapWebView.swift", "PennedMac/Editor/MacTipTapEditorSession.swift", "Vellix/VellixEditor.bundle/tiptap.html"]) {
    assert.doesNotMatch(await read(file), /MobileEditorInteractions|mobileDismissSlashMenu|singleLinePageTitle/);
  }
});
