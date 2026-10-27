import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Mechanical, AST-located edits to the existing artifact, not an editor rebuild.
// Equivalent maintained-source hooks live in Vellix-backend/src/editor.js.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backend = process.env.PENNED_EDITOR_SOURCE ?? resolve(root, "../Vellix-backend");
const { parse } = await import(pathToFileURL(join(backend, "node_modules/acorn/dist/acorn.mjs")));
const path = join(root, "Vellix/VellixEditor.bundle/tiptap.bundle.js");
const source = await readFile(path, "utf8");
function normalizerFunction(records) {
    const calls = [];
    const walk = node => {
        if (!node || typeof node !== "object") return;
        if (node.type === "CallExpression" && node.callee.type === "Identifier" && node.arguments[0]?.type === "CallExpression" &&
            node.arguments[0].callee.type === "MemberExpression" && node.arguments[0].callee.property.name === "toJSON") calls.push(node);
        for (const child of Object.values(node)) if (Array.isArray(child)) child.forEach(walk); else if (child && typeof child === "object") walk(child);
    };
    walk(records);
    assert.equal(calls.length, 1, "reuse the established selected-block serialization normalizer");
    return calls[0].callee.name;
}
function historyFunction(ast) {
    const all = [];
    const walk = node => {
        if (!node || typeof node !== "object") return;
        if (node.type) all.push(node);
        for (const child of Object.values(node)) if (Array.isArray(child)) child.forEach(walk); else if (child && typeof child === "object") walk(child);
    };
    walk(ast);
    const keys = all.filter(n => n.type === "VariableDeclarator" && n.init?.type === "NewExpression" && n.init.arguments[0]?.value === "closeHistory");
    assert.equal(keys.length, 1, "one existing ProseMirror closeHistory key");
    const functions = all.filter(n => n.type === "FunctionDeclaration" && n.body.body.some(statement =>
        statement.type === "ReturnStatement" && statement.argument?.type === "CallExpression" &&
        statement.argument.callee.type === "MemberExpression" && statement.argument.callee.property.name === "setMeta" &&
        statement.argument.arguments[0]?.name === keys[0].id.name &&
        (statement.argument.arguments[1]?.value === true ||
         (statement.argument.arguments[1]?.type === "UnaryExpression" && statement.argument.arguments[1].operator === "!" && statement.argument.arguments[1].argument.value === 0))));
    assert.equal(functions.length, 1, "reuse the bundled ProseMirror closeHistory helper");
    return functions[0].id.name;
}
if (source.includes("window.PennedBlockSelection?.selectionFacade()")) {
    const ast = parse(source, { ecmaVersion: "latest" });
    const collect = (node, predicate) => {
        if (!node || typeof node !== "object") return [];
        return [...(predicate(node) ? [node] : []), ...Object.values(node).flatMap(child =>
            Array.isArray(child) ? child.flatMap(item => collect(item, predicate)) : child && typeof child === "object" ? collect(child, predicate) : [])];
    };
    const listeners = collect(ast, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.object.name === "document" && n.callee.property.name === "addEventListener" && n.arguments[0]?.value === "pointerdown");
    assert.equal(listeners.length, 1, "one legacy global handle listener");
    const calls = collect(listeners[0].arguments[1], n => n.type === "CallExpression" && n.callee.type === "Identifier");
    assert.equal(calls.length, 1);
    const handlers = collect(ast, n => n.type === "FunctionDeclaration" && n.id.name === calls[0].callee.name);
    assert.equal(handlers.length, 1);
    const handler = handlers[0], guard = "if(window.PennedBlockSelection)return false;";
    const extensionCalls = collect(ast, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "extensions" &&
        n.callee.object.type === "MemberExpression" && n.callee.object.property.name === "PennedBlockSelection");
    assert.equal(extensionCalls.length, 1);
    const environment = extensionCalls[0].arguments[0];
    const edits = [];
    const deletionCase = collect(ast, n => n.type === "SwitchCase" && n.test?.value === "deleteSelectedBlocks");
    assert.equal(deletionCase.length, 1);
    const deletionCall = collect(deletionCase[0], n => n.type === "CallExpression" && n.callee.type === "Identifier");
    assert.equal(deletionCall.length, 1);
    const deletion = collect(ast, n => n.type === "FunctionDeclaration" && n.id.name === deletionCall[0].callee.name);
    assert.equal(deletion.length, 1);
    const deletionSnapshots = collect(deletion[0], n => n.type === "CallExpression" && n.arguments[0]?.value === "snapshot");
    assert.ok(deletionSnapshots.length >= 1, "reuse the established immediate document-snapshot bridge");
    const snapshotCode = source.slice(deletionSnapshots[0].start, deletionSnapshots[0].end);
    if (!source.slice(deletion[0].body.start, deletion[0].body.end).includes("window.PennedBlockSelection?.deleteSelected()")) {
        edits.push({ at: deletion[0].body.start + 1,
            text: `if(window.PennedBlockSelection?.deleteSelected()){${snapshotCode};return;}` });
    }
    const transforms = collect(ast, n => n.type === "FunctionDeclaration" && n.params.length === 1 && n.params[0].type === "Identifier" &&
        collect(n.body, call => call.type === "CallExpression" && call.callee.type === "Identifier" && call.callee.name === n.params[0].name).length > 0 &&
        source.slice(n.body.start, n.body.end).includes("Select at least one block first."));
    assert.equal(transforms.length, 1, "one existing selected-block transformer");
    const transform = transforms[0];
    if (!source.slice(transform.body.start, transform.body.end).includes("window.PennedBlockSelection?.transformSelectedNested")) {
        edits.push({ at: transform.body.start + 1,
            text: `const mobileResult=window.PennedBlockSelection?.transformSelectedNested(${transform.params[0].name});if(mobileResult!==undefined){if(mobileResult)${snapshotCode};return mobileResult;}` });
    }
    const pointer = listeners[0], pointerGuard = "(!window.PennedBlockSelection&&";
    if (source.slice(pointer.start - pointerGuard.length, pointer.start) !== pointerGuard) {
        edits.push({ at: pointer.end, text: ")" }, { at: pointer.start, text: pointerGuard });
    }
    const highlight = collect(ast, n => n.type === "ObjectExpression" && n.properties.some(property => property.key?.name === "name" && property.value.value === "vellixTextSelectionHighlight"));
    assert.equal(highlight.length, 1, "one legacy text-selection decoration extension");
    const decoration = collect(highlight[0], n => n.type === "Property" && n.key.name === "decorations")[0].value;
    if (!source.slice(decoration.body.start, decoration.body.end).includes("window.PennedBlockSelection")) {
        const emptySet = collect(decoration, n => n.type === "MemberExpression" && n.property.name === "empty" && n.object.type === "Identifier");
        assert.equal(emptySet.length, 1);
        edits.push({ at: decoration.body.start + 1, text: `if(window.PennedBlockSelection)return ${source.slice(emptySet[0].start, emptySet[0].end)};` });
    }
    const registry = collect(ast, n => n.type === "FunctionDeclaration" && n.body.body.some(statement =>
        statement.type === "IfStatement" && statement.consequent.type === "ReturnStatement" &&
        statement.consequent.argument?.type === "CallExpression" && statement.consequent.argument.callee.type === "MemberExpression" &&
        statement.consequent.argument.callee.object.type === "MemberExpression" && statement.consequent.argument.callee.object.property.name === "PennedBlockSelection" &&
        statement.consequent.argument.callee.property.name === "records"));
    assert.equal(registry.length, 1, "one optional model registry bridge");
    const registryCall = registry[0].body.body.find(statement => statement.type === "IfStatement").consequent.argument;
    if (registryCall.arguments.length === 1) edits.push({ at: registryCall.end - 1, text: "," + normalizerFunction(registry[0]) });
    if (!environment.properties.some(property => property.key.name === "closeHistory")) {
        edits.push({ at: environment.end - 1, text: ",closeHistory:" + historyFunction(ast) });
    }
    if (!source.slice(handler.body.start, handler.body.end).includes(guard)) {
        edits.push({ at: handler.body.start + 1, text: guard });
    }
    if (edits.length) {
        let changed = source;
        for (const edit of edits.sort((a, b) => b.at - a.at)) changed = changed.slice(0, edit.at) + edit.text + changed.slice(edit.at);
        parse(changed, { ecmaVersion: "latest" });
        await writeFile(path, changed);
        console.log("Updated the optional mobile block-selection hooks. No bundler or compiler was run.");
    }
    console.log("Block-selection hooks already installed; JavaScript syntax checked.");
} else {
    const ast = parse(source, { ecmaVersion: "latest" });
    function nodes(node, predicate, found = []) {
        if (!node || typeof node !== "object") return found;
        if (predicate(node)) found.push(node);
        for (const [name, child] of Object.entries(node)) {
            if (["start", "end", "type"].includes(name)) continue;
            if (Array.isArray(child)) child.forEach(item => nodes(item, predicate, found));
            else if (child && typeof child === "object") nodes(child, predicate, found);
        }
        return found;
    }
    const one = (values, label) => { assert.equal(values.length, 1, label); return values[0]; };
    const bridge = one(nodes(ast, n => n.type === "AssignmentExpression" && n.left.type === "MemberExpression" &&
        n.left.object.name === "window" && n.left.property.name === "tiptapCommand" && n.right.async), "one editor bridge").right;
    const cases = nodes(bridge.body, n => n.type === "SwitchCase");
    const namedCase = name => one(cases.filter(n => n.test?.value === name), name);
    const modeCall = one(nodes(namedCase("setSelectionMode"), n => n.type === "CallExpression" && n.callee.type === "Identifier"), "mode command");
    const all = namedCase("selectAllBlocks");
    const clear = one(nodes(all, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "clear"), "selection set");
    const selection = clear.callee.object.name;
    const each = one(nodes(all, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "forEach"), "selection records");
    const recordsName = each.callee.object.callee.name;
    const calls = nodes(all, n => n.type === "CallExpression" && n.callee.type === "Identifier");
    const refreshName = calls.at(-1).callee.name;
    const declarations = nodes(ast, n => n.type === "FunctionDeclaration");
    const helper = name => one(declarations.filter(n => n.id.name === name), name);
    const mode = helper(modeCall.callee.name), refresh = helper(refreshName), records = helper(recordsName);
    const globalOff = nodes(ast, n => n.type === "VariableDeclarator" && n.init?.value === "off").map(n => n.id.name);
    const modeVariable = one(nodes(mode.body, n => n.type === "AssignmentExpression" && n.left.type === "Identifier" && globalOff.includes(n.left.name)), "derived legacy mode").left.name;
    const selectionInit = one(nodes(ast, n => n.type === "VariableDeclarator" && n.id.name === selection && n.init?.type === "NewExpression" && n.init.callee.name === "Set"), "legacy selection initializer").init;
    const tableEnvironment = one(nodes(ast, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.property.name === "createExtensions" &&
        n.callee.object.type === "MemberExpression" && n.callee.object.property.name === "VellixTables"), "existing ProseMirror dependency injection").arguments[0];
    const property = name => one(tableEnvironment.properties.filter(n => n.key.name === name), name).value;
    const editorOptions = one(nodes(ast, n => n.type === "NewExpression" && n.arguments[0]?.type === "ObjectExpression" &&
        n.arguments[0].properties.some(p => p.key?.name === "editorProps") && n.arguments[0].properties.some(p => p.key?.name === "extensions")), "existing editor instance").arguments[0];
    const extensions = one(editorOptions.properties.filter(p => p.key.name === "extensions"), "extensions").value;
    const bindings = ["Extension", "Plugin", "PluginKey", "Decoration", "DecorationSet", "post"].map(name => `${name}:${source.slice(property(name).start, property(name).end)}`);
    const param = node => node.type === "AssignmentPattern" ? node.left.name : node.name;
    const pointerListener = one(nodes(ast, n => n.type === "CallExpression" && n.callee.type === "MemberExpression" && n.callee.object.name === "document" && n.callee.property.name === "addEventListener" && n.arguments[0]?.value === "pointerdown"), "legacy handle listener");
    const handleName = one(nodes(pointerListener.arguments[1], n => n.type === "CallExpression" && n.callee.type === "Identifier"), "legacy handle callback").callee.name;
    const handle = helper(handleName);
    const deletion = helper(one(nodes(namedCase("deleteSelectedBlocks"), n => n.type === "CallExpression" && n.callee.type === "Identifier"), "block deletion command").callee.name);
    const deletionSnapshot = one(nodes(deletion, n => n.type === "CallExpression" && n.arguments[0]?.value === "snapshot"), "immediate deletion snapshot");
    const transform = one(declarations.filter(n => n.params.length === 1 && n.params[0].type === "Identifier" &&
        nodes(n.body, call => call.type === "CallExpression" && call.callee.type === "Identifier" && call.callee.name === n.params[0].name).length > 0 &&
        source.slice(n.body.start, n.body.end).includes("Select at least one block first.")), "existing selected-block transformer");
    const highlight = one(nodes(ast, n => n.type === "ObjectExpression" && n.properties.some(property => property.key?.name === "name" && property.value.value === "vellixTextSelectionHighlight")), "legacy selection decorations");
    const decoration = one(nodes(highlight, n => n.type === "Property" && n.key.name === "decorations"), "legacy decorations property").value;
    const edits = [
        { start: selectionInit.start, end: selectionInit.end, text: `window.PennedBlockSelection?.selectionFacade()??${source.slice(selectionInit.start, selectionInit.end)}` },
        { start: extensions.start + 1, end: extensions.start + 1, text: `...(window.PennedBlockSelection?.extensions({${bindings.join(",")},closeHistory:${historyFunction(ast)},modeChanged:mode=>{${modeVariable}=mode}})??[]),` },
        { start: records.body.start + 1, end: records.body.start + 1, text: `if(window.PennedBlockSelection)return window.PennedBlockSelection.records(${param(records.params[0])},${normalizerFunction(records)});` },
        { start: refresh.body.start + 1, end: refresh.body.start + 1, text: "if(window.PennedBlockSelection){window.PennedBlockSelection.refresh();return;}" },
        { start: mode.body.start + 1, end: mode.body.start + 1, text: `if(window.PennedBlockSelection){window.PennedBlockSelection.setMode(${param(mode.params[0])});return;}` },
        { start: bridge.body.start + 1, end: bridge.body.start + 1, text: `const pennedSelectionResult=window.PennedBlockSelection?.command(${param(bridge.params[0])},${param(bridge.params[1])});if(pennedSelectionResult!==undefined)return pennedSelectionResult;` },
        { start: handle.body.start + 1, end: handle.body.start + 1, text: "if(window.PennedBlockSelection)return false;" },
        { start: deletion.body.start + 1, end: deletion.body.start + 1,
          text: `if(window.PennedBlockSelection?.deleteSelected()){${source.slice(deletionSnapshot.start, deletionSnapshot.end)};return;}` },
        { start: transform.body.start + 1, end: transform.body.start + 1,
          text: `const mobileResult=window.PennedBlockSelection?.transformSelectedNested(${transform.params[0].name});if(mobileResult!==undefined){if(mobileResult)${source.slice(deletionSnapshot.start, deletionSnapshot.end)};return mobileResult;}` },
        { start: decoration.body.start + 1, end: decoration.body.start + 1, text: `if(window.PennedBlockSelection)return ${source.slice(property("DecorationSet").start, property("DecorationSet").end)}.empty;` },
        { start: pointerListener.end, end: pointerListener.end, text: ")" },
        { start: pointerListener.start, end: pointerListener.start, text: "(!window.PennedBlockSelection&&" },
    ];
    let changed = source;
    for (const edit of edits.sort((a, b) => b.start - a.start)) changed = changed.slice(0, edit.start) + edit.text + changed.slice(edit.end);
    parse(changed, { ecmaVersion: "latest" });
    await writeFile(path, changed);
    console.log(`Installed ${edits.length} optional mobile hooks in the existing artifact. No bundler or compiler was run.`);
}
