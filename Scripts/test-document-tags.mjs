import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";

// Real Swift/GRDB -> shipping editor -> Swift/GRDB -> reopened SQLite. No simulator.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const exchange = await mkdtemp(join(tmpdir(), "penned-tag-editor-exchange-"));
async function native() {
  await new Promise((done, reject) => {
    const child = spawn(process.execPath, [join(root, "Scripts/test-collections.mjs")], { cwd: root, stdio: "inherit",
      env: { ...process.env, PENNED_FULL_APP_TESTS: "1", PENNED_TAGS_EDITOR_EXCHANGE: exchange } });
    child.on("error", reject); child.on("exit", code => code === 0 ? done() : reject(new Error(`Native checks failed: ${code}`)));
  });
}
console.log(`Tag editor exchange: ${exchange}`);
await native();
const { JSDOM } = await import(pathToFileURL(join(backend, "node_modules/jsdom/lib/api.js")));
const fixture = JSON.parse(await readFile(join(exchange, "input.json"), "utf8"));
const dom = new JSDOM("<!doctype html><html><body><main class='vellix-editor-page'><div id='editor'></div></main></body></html>",
  { runScripts: "outside-only", pretendToBeVisual: true, url: "https://penned.test" });
const w = dom.window, events = [];
try {
  w.console.log = w.console.info = () => {};
  w.crypto.randomUUID = randomUUID; w.ResizeObserver = class { observe() {} disconnect() {} };
  w.webkit = { messageHandlers: { tiptap: { postMessage: event => events.push(event) } } };
  w.scrollBy = () => {}; w.Range.prototype.getClientRects = () => [];
  w.Range.prototype.getBoundingClientRect = () => ({ top: 300, left: 20, bottom: 324, right: 100 });
  const bundle = join(root, "Vellix/VellixEditor.bundle");
  for (const file of ["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js"])
    w.eval(await readFile(join(bundle, file), "utf8"));
  await w.tiptapCommand("setContent", { document: fixture.document });
  await w.tiptapCommand("tagCatalogue", { tags: fixture.tags });
  const third = fixture.document.content.find(node => node.attrs.id === "three");
  assert(await w.tiptapCommand("tagLocate", { blockID: "three", occurrenceID: third.content[0].attrs.id }));
  assert(await w.tiptapCommand("tagHighlight", { blockID: "three" }));
  const editor = w.document.querySelector(".tiptap-editor").editor;
  let target;
  editor.state.doc.descendants((node, pos) => { if (node.attrs.id === "three") target = { node, pos }; });
  editor.view.dispatch(editor.state.tr.delete(target.pos, target.pos + target.node.nodeSize));
  await w.tiptapCommand("focus");
  await new Promise(resolve => w.requestAnimationFrame(resolve));
  await new Promise(resolve => w.requestAnimationFrame(resolve));
  const choice = [...w.document.querySelectorAll(".penned-tag-suggestions button")].find(button => button.textContent === "Create #rituals");
  assert(choice, "Creating an inline tag must use the live editor suggestion flow"); choice.click();
  const request = events.findLast(event => event.kind === "tagRequest").payload;
  assert.equal(request.action, "commit");
  assert(await w.tiptapCommand("tagApply", { token: request.token, name: request.name }));
  const returned = await w.tiptapCommand("getDocument");
  assert.equal(returned.content.some(node => node.attrs.id === "three"), false);
  await w.tiptapCommand("setContent", { document: returned });
  assert.deepEqual(JSON.parse(JSON.stringify(await w.tiptapCommand("getDocument"))), JSON.parse(JSON.stringify(returned)));
  await writeFile(join(exchange, "response.json"), JSON.stringify(returned));
} finally { w.close(); }
await native();
console.log(`PASS: actual editor tags, deletion, AND filtering, counts, and exact targets persisted after SQLite reopening (${exchange})`);
