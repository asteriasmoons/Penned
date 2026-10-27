import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Replace only the component factory in the existing artifact, without a bundler.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { parse } = await import(pathToFileURL(join(backend, "node_modules/acorn/dist/acorn.mjs")));
const file = join(root, "Vellix/VellixEditor.bundle/tiptap.bundle.js");
const artifact = await readFile(file, "utf8");
const source = await readFile(join(backend, "src/template-components.js"), "utf8");
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
const ast = parse(artifact, { ecmaVersion: "latest" });
const functions = nodes(ast, n => n.type === "FunctionDeclaration");
const factory = one(functions.filter(fn => {
    const text = artifact.slice(fn.start, fn.end);
    return text.includes('"penned-template-component"') && text.includes('"setTemplateEditing"');
}), "shipping component factory");
const definition = one(functions.filter(fn => artifact.slice(fn.start, fn.end).includes('"Choose a valid template component."')),
    "component definition validator");
const response = one(functions.filter(fn => {
    const text = artifact.slice(fn.start, fn.end);
    return text.includes('"multiSelect"') && text.includes(".toPrecision(15)") && !text.includes('"penned-template-component"');
}), "component response validator");
const currentAlias = nodes(factory, n => n.type === "VariableDeclarator" && n.id.name === "TextSelection");
let textSelection;
if (currentAlias.length) {
    const alias = one(currentAlias, "existing TextSelection alias");
    textSelection = artifact.slice(alias.init.start, alias.init.end);
} else {
    const selection = one(nodes(factory, n => n.type === "CallExpression" && n.callee.property?.name === "setSelection"), "component insertion selection");
    const constructor = selection.arguments[0].callee.object;
    textSelection = artifact.slice(constructor.start, constructor.end);
}
const sourceAST = parse(source, { ecmaVersion: "latest", sourceType: "module" });
const maintained = one(nodes(sourceAST,
    n => n.type === "FunctionDeclaration" && n.id.name === "createTemplateComponents"), "maintained component factory");
const titles = one(nodes(sourceAST, n => n.type === "VariableDeclarator" && n.id.name === "titles"), "component configuration labels");
const replacement = "function " + factory.id.name + source.slice(maintained.id.end, maintained.body.start + 1) +
    `const TextSelection=${textSelection},componentDefinition=${definition.id.name},componentResponse=${response.id.name},titles=${source.slice(titles.init.start, titles.init.end)};` +
    source.slice(maintained.body.start + 1, maintained.end);
const output = artifact.slice(0, factory.start) + replacement + artifact.slice(factory.end);
parse(output, { ecmaVersion: "latest" });
await writeFile(file, output);
console.log("Updated only the template component factory in the shipping artifact. No build was run.");
