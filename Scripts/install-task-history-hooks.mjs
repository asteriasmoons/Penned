import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Replace only AST-identified task functions in the existing artifact. No bundler
// or compiler is invoked; all other editor bytes are retained.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { parse } = await import(pathToFileURL(join(backend, "node_modules/acorn/dist/acorn.mjs")));
const file = join(root, "Vellix/VellixEditor.bundle/tiptap.bundle.js");
const artifact = await readFile(file, "utf8");
const maintained = await readFile(join(backend, "src/document-tasks.js"), "utf8");
const sourceAST = parse(maintained, { ecmaVersion: "latest", sourceType: "module" });
const ast = parse(artifact, { ecmaVersion: "latest" });
function nodes(node, predicate, found = []) {
    if (!node || typeof node !== "object") return found;
    if (predicate(node)) found.push(node);
    for (const child of Object.values(node)) {
        if (Array.isArray(child)) child.forEach(value => nodes(value, predicate, found));
        else if (child && typeof child === "object") nodes(child, predicate, found);
    }
    return found;
}
function one(values, label) { assert.equal(values.length, 1, label); return values[0]; }
const functions = nodes(ast, n => n.type === "FunctionDeclaration");
const find = marker => one(functions.filter(fn => artifact.slice(fn.start, fn.end).includes(marker)), marker);
const checklist = find("vellix-task-metadata"), integration = find("vellixTrackedTasks");
const command = find('"taskRelease"');
const reminder = find('"en-CA"');
const labelFunction = asset => one(nodes(checklist, n => n.type === "ArrayExpression" && n.elements[0]?.value === asset &&
    n.elements[1]?.type === "CallExpression"), asset).elements[1].callee.name;
function alias(fn, name) {
    const binding = nodes(fn, n => n.type === "VariableDeclarator" && n.id.name === name && n.init?.type === "Identifier")[0];
    return binding?.init.name ?? name;
}
const repeat = alias(checklist, labelFunction("repeatfill"));
assert.equal(alias(checklist, labelFunction("clockwavy")), reminder.id.name);
const fragment = one(nodes(integration, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "fromArray"), "Fragment").callee.object.name;
const slice = one(nodes(integration, n => n.type === "NewExpression" && n.arguments.length === 3 && n.arguments[1]?.property?.name === "openStart"), "Slice").callee.name;
const independent = one(nodes(integration, n => n.type === "CallExpression" && n.callee.type === "Identifier" &&
    n.arguments[0]?.type === "MemberExpression" && n.arguments[0].property.name === "trackedTask"), "independentTask").callee.name;
const dispatch = nodes(command, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "dispatch");
const historyDispatch = dispatch.filter(node => node.arguments[0]?.callee?.type === "Identifier");
assert.equal(historyDispatch.length, 2);
const closeHistory = alias(command, historyDispatch[0].arguments[0].callee.name);
const replacements = [];
function replace(name, target, aliases = "") {
    const fn = one(nodes(sourceAST, n => n.type === "FunctionDeclaration" && n.id.name === name), name);
    replacements.push({ start: target.start, end: target.end,
        text: "function " + target.id.name + maintained.slice(fn.id.end, fn.body.start + 1) + aliases + maintained.slice(fn.body.start + 1, fn.end) });
}
replace("reminderLabel", reminder);
replace("createChecklistItem", checklist, `const repeatLabel=${repeat},reminderLabel=${reminder.id.name};`);
replace("createTaskIntegration", integration, `const Fragment=${alias(integration, fragment)},Slice=${alias(integration, slice)},independentTask=${alias(integration, independent)};`);
replace("taskCommand", command, `/* vellix-task-history-v1 */const closeHistory=${closeHistory};`);
const normalizer = one(functions.filter(fn => nodes(fn, n => n.type === "ObjectExpression" &&
    n.properties.some(p => p.key?.name === "type" && p.value?.value === "doc")).length === 5 && fn.end - fn.start < 5000), "document normalizer");
const branch = one(nodes(normalizer, n => n.type === "IfStatement" && n.test.type === "BinaryExpression" &&
    n.test.left.property?.name === "type" && n.test.right.value === "doc"), "root document branch");
const returned = one(nodes(branch.consequent, n => n.type === "ReturnStatement" && n.argument.type === "ObjectExpression"), "normalized root").argument;
const value = normalizer.params[0].name;
if (!artifact.slice(returned.start, returned.end).includes("taskHistoryProjection")) {
    replacements.push({ start: returned.start + 1, end: returned.start + 1,
        text: `...(${value}.attrs?.taskHistoryProjection?{attrs:{taskHistoryProjection:${value}.attrs.taskHistoryProjection}}:{}),` });
}
const loadCase = one(nodes(ast, n => n.type === "SwitchCase" && n.test?.value === "setContent"), "native document load");
if (!artifact.slice(loadCase.start, loadCase.end).includes("vellix-task-page-load-v1")) {
    const call = one(nodes(loadCase, n => n.type === "CallExpression" && n.callee.property?.name === "setContent"), "setContent call");
    const editor = call.callee.object.object.name, document = call.arguments[0].name;
    replacements.push({ start: call.start, end: call.end,
        text: `${editor}.chain().setContent(${call.arguments.map(arg => artifact.slice(arg.start, arg.end)).join(",")}).command(({tr})=>{/* vellix-task-page-load-v1 */tr.setDocAttribute("taskHistoryProjection",${document}.attrs?.taskHistoryProjection??null);return true;}).run()` });
}
let output = artifact;
for (const edit of replacements.sort((a, b) => b.start - a.start)) output = output.slice(0, edit.start) + edit.text + output.slice(edit.end);
parse(output, { ecmaVersion: "latest" });
await writeFile(file, output);
console.log("Updated the existing task functions and root metadata normalizer. No build was run.");
