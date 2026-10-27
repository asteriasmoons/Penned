import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Mechanical AST patch of the existing shipping artifact. No compiler or bundler.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../penned-editor");
const { parse } = await import(pathToFileURL(join(backend, "node_modules/acorn/dist/acorn.mjs")));
const file = join(root, "Vellix/VellixEditor.bundle/tiptap.bundle.js");
const artifact = await readFile(file, "utf8"), source = await readFile(join(backend, "src/text-color.js"), "utf8");
const ast = parse(artifact, { ecmaVersion: "latest" });
function nodes(node, predicate, found = []) {
    if (!node || typeof node !== "object") return found;
    if (predicate(node)) found.push(node);
    for (const value of Object.values(node)) {
        if (Array.isArray(value)) value.forEach(child => nodes(child, predicate, found));
        else if (value && typeof value === "object") nodes(value, predicate, found);
    }
    return found;
}
function one(values, label) { assert.equal(values.length, 1, label); return values[0]; }
const prop = (object, name) => one(object.properties.filter(p => p.key?.name === name), name).value;
const editorCall = one(nodes(ast, n => n.type === "NewExpression" && n.arguments[0]?.type === "ObjectExpression"
    && n.arguments[0].properties.some(p => p.key?.name === "extensions")), "editor construction");
const editorBinding = one(nodes(ast, n => n.type === "VariableDeclarator" && n.init === editorCall), "editor binding");
const editorName = editorBinding.id.name;
const tableFactory = one(nodes(editorCall, n => n.type === "CallExpression" && n.callee.property?.name === "createExtensions"), "table dependencies");
const deps = tableFactory.arguments[0];
const selectionFactory = one(nodes(editorCall, n => n.type === "CallExpression" && n.callee.property?.name === "extensions"), "selection dependencies");
const codeMark = one(nodes(ast, n => n.type === "CallExpression" && n.callee.property?.name === "create"
    && n.arguments[0]?.properties?.some(p => p.key?.name === "name" && p.value.value === "code")), "Mark constructor").callee.object.name;
const snapshots = nodes(ast, n => n.type === "Property" && n.key?.name === "snapshot" && n.value.type === "ArrowFunctionExpression"
    && n.value.body.type === "CallExpression" && n.value.body.callee.type === "Identifier");
assert(snapshots.length > 0);
const snapshot = snapshots[0].value.body.callee.name;
assert(snapshots.every(p => p.value.body.callee.name === snapshot));
const factory = one(nodes(parse(source, { ecmaVersion: "latest", sourceType: "module" }),
    n => n.type === "FunctionDeclaration" && n.id.name === "createTextColor"), "maintained factory");
const dependencies = { Mark: codeMark };
for (const name of ["Extension", "Plugin", "PluginKey", "TextSelection", "Decoration", "DecorationSet"]) dependencies[name] = artifact.slice(prop(deps, name).start, prop(deps, name).end);
dependencies.closeHistory = artifact.slice(prop(selectionFactory.arguments[0], "closeHistory").start, prop(selectionFactory.arguments[0], "closeHistory").end);
dependencies.post = artifact.slice(prop(deps, "post").start, prop(deps, "post").end);
dependencies.snapshot = `()=>${snapshot}()`;
dependencies.selectionActive = artifact.slice(prop(deps, "selectionActive").start, prop(deps, "selectionActive").end);
const instance = `(${source.slice(factory.start, factory.end)})({${Object.entries(dependencies).map(([k, v]) => `${k}:${v}`).join(",")}})`;
const factories = new Set(nodes(ast, n => n.type === "FunctionDeclaration" &&
    nodes(n.body, child => child.type === "Literal" && child.value === "vellixInlineTextColor").length > 0)
    .map(n => n.id.name));
const replacements = [], existing = nodes(ast, n => n.type === "VariableDeclarator" && (
    n.id.name === "__vellixTextColor" || (n.init?.type === "CallExpression" && (
        factories.has(n.init.callee.name) || n.init.callee.type === "FunctionExpression" && n.init.callee.id?.name === "createTextColor"
    ))));
if (existing.length) {
    const current = one(existing, "installed color factory");
    replacements.push({ start: current.init.start, end: current.init.end, text: instance });
} else {
    replacements.push({ start: editorBinding.start, end: editorBinding.start, text: `__vellixTextColor=${instance},` });
    const extensions = prop(editorCall.arguments[0], "extensions");
    replacements.push({ start: extensions.start + 1, end: extensions.start + 1,
        text: "__vellixTextColor.mark,__vellixTextColor.integration," });
    const format = one(nodes(ast, n => n.type === "FunctionDeclaration" && n.end - n.start < 2500
        && artifact.slice(n.start, n.end).includes('"formattingState"')), "formatting reporter");
    const state = one(nodes(format, n => n.type === "ObjectExpression" && n.properties.some(p => p.key?.name === "bold")), "formatting state");
    replacements.push({ start: state.start + 1, end: state.start + 1, text: `...__vellixTextColor.formattingState(${editorName}),` });
    const dispatcher = one(nodes(ast, n => n.type === "AssignmentExpression" && n.left.object?.name === "window"
        && n.left.property?.name === "tiptapCommand"), "native command dispatcher").right;
    const [name, args] = dispatcher.params.map(p => p.name ?? p.left.name);
    replacements.push({ start: dispatcher.body.start + 1, end: dispatcher.body.start + 1,
        text: `const __colorResult=__vellixTextColor.command(${editorName},${name},${args});if(__colorResult!==undefined)return __colorResult;` });
    const declaration = one(nodes(ast, n => n.type === "VariableDeclaration" && n.declarations.includes(editorBinding)), "editor declaration");
    replacements.push({ start: declaration.end, end: declaration.end, text: `;${editorName}.on("blur",()=>${format.id.name}());` });
}
let output = artifact;
for (const edit of replacements.sort((a, b) => b.start - a.start)) output = output.slice(0, edit.start) + edit.text + output.slice(edit.end);
parse(output, { ecmaVersion: "latest" });
await writeFile(file, output);
console.log("Installed inline text color in the existing artifact. No build was run.");
