import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, mkdir } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

// Browser plugin not available. Render the shipping resources in isolated headless Chromium.
const { chromium } = await import(resolve(homedir(), ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs"));
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundle = join(root, "Vellix/VellixEditor.bundle");
const output = process.env.PENNED_COMPONENT_SCREENSHOTS || "/tmp/vellix-component-layout";
await mkdir(output, { recursive: true });
const mobileScript = async file => (await readFile(join(root, "Vellix/Editor/" + file), "utf8"))
    .match(/static let script = #"""\n([^]*?)\n"""#/)[1];
const server = createServer(async (request, response) => {
    try {
        const pathname = new URL(request.url, "http://localhost").pathname;
        const path = resolve(bundle, "." + pathname);
        if (!path.startsWith(bundle + "/")) { response.writeHead(403).end(); return; }
        const data = await readFile(path);
        response.writeHead(200, { "Content-Type": ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] || "application/octet-stream" });
        response.end(data);
    } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
    browser = await chromium.launch({ executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true });
    for (const [name, width, touch] of [["phone", 390, true], ["tablet", 834, true], ["desktop", 1100, false]]) {
        const context = await browser.newContext({ viewport: { width, height: 844 }, hasTouch: touch, isMobile: touch });
        const page = await context.newPage(), errors = [];
        page.on("pageerror", error => errors.push(error.message));
        await page.addInitScript(() => {
            window.events = [];
            window.webkit = { messageHandlers: { tiptap: { postMessage: event => window.events.push(event) } } };
        });
        if (touch) await page.addInitScript(await mobileScript("MobileBlockSelection.swift"));
        await page.goto(`http://127.0.0.1:${server.address().port}/tiptap.html`);
        assert.equal(await page.title(), "Vellix TipTap");
        await page.waitForFunction(() => typeof window.tiptapCommand === "function");
        if (touch) await page.evaluate(await mobileScript("MobileEditorInteractions.swift"));
        await page.addStyleTag({ content: "html { background: #0b0b0b !important; } :root { --vellix-primary-text: #7ee7c4; } .tiptap-editor { padding: 18px !important; }" });
        await page.evaluate(async () => {
            const paragraph = text => ({ type: "paragraph", attrs: { id: crypto.randomUUID() }, content: [{ type: "text", text }] });
            const component = (kind, label, response) => ({ type: "templateComponent", attrs: { id: kind, response,
                definition: { kind, label, minimum: 1, maximum: 5, step: 1, minimumLabel: "1", maximumLabel: "5",
                    choices: ["Joyful", "Productive", "Grateful", "Thoughtful", "Inspired", "Neutral", "Sad"].map((label, index) => ({ id: "choice-" + index, label })) } } });
            await window.tiptapCommand("setContent", { document: { type: "doc", content: [paragraph("Ordinary editable text"),
                component("slider", "Energy Level", 3), component("rating", "Rating", 3),
                component("multiSelect", "Mood Board", ["choice-1"]), component("singleSelect", "Activities", "choice-0"),
                ...Array.from({ length: 20 }, () => paragraph("Document scrolling and ordinary typing stay available below these components."))] } });
        });
        const slider = page.locator('[data-vellix-block-id="slider"]');
        const metrics = await slider.evaluate(host => {
            const track = host.querySelector("input").getBoundingClientRect(), output = host.querySelector("output"), value = output.getBoundingClientRect();
            return { trackCenter: (track.left + track.right) / 2, valueCenter: (value.left + value.right) / 2,
                trackBottom: track.bottom, valueTop: value.top, weight: getComputedStyle(output).fontWeight,
                height: host.getBoundingClientRect().height, selection: getComputedStyle(host).userSelect };
        });
        assert(Math.abs(metrics.trackCenter - metrics.valueCenter) < 1, `${name}: value is centered`);
        assert(metrics.valueTop >= metrics.trackBottom - 1, `${name}: value is below the track`);
        assert.equal(metrics.weight, "700");
        assert.equal(metrics.selection, "none");
        assert(metrics.height < 105, `${name}: component remains compact`);
        await page.screenshot({ path: join(output, name + ".png"), fullPage: false });

        for (const kind of ["rating", "singleSelect", "multiSelect"]) {
            const button = page.locator(`[data-vellix-block-id="${kind}"] .penned-component-choices button`).last();
            await page.evaluate(() => { document.activeElement?.blur(); window.events = []; });
            const before = await page.evaluate(() => JSON.stringify(document.querySelector(".tiptap-editor").editor.state.selection.toJSON()));
            if (touch) await button.tap(); else await button.click();
            const state = await page.evaluate(() => ({ focused: document.querySelector(".tiptap-editor").editor.view.hasFocus(),
                selection: JSON.stringify(document.querySelector(".tiptap-editor").editor.state.selection.toJSON()),
                writes: window.events.filter(event => event.kind === "snapshot").length,
                editEvents: window.events.filter(event => event.kind === "focus" && event.payload.focused).length }));
            assert.equal(state.focused, false, name + ": " + kind);
            assert.equal(state.selection, before);
            assert.equal(state.writes, 1, `${name}: ${kind} saves once`);
            assert.equal(state.editEvents, 0);
        }
        if (touch) {
            await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });
            const before = await page.evaluate(() => JSON.stringify(document.querySelector(".tiptap-editor").editor.getJSON()));
            const button = await page.locator('[data-vellix-block-id="multiSelect"] button').first().boundingBox();
            const client = await context.newCDPSession(page);
            const x = button.x + button.width / 2, y = button.y + button.height / 2;
            await client.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] });
            for (let step = 1; step <= 8; step++) {
                await client.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y - step * 16 }] });
                await page.waitForTimeout(20);
            }
            await client.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
            assert(await page.evaluate(() => window.scrollY > 20), `${name}: document scroll starts on a component`);
            assert.equal(await page.evaluate(() => JSON.stringify(document.querySelector(".tiptap-editor").editor.getJSON())), before);
            assert.equal(await page.evaluate(() => document.querySelector(".tiptap-editor").editor.view.hasFocus()), false);
            await client.detach();
        }
        await slider.locator("input").focus();
        await page.keyboard.press("ArrowRight");
        assert.equal(await slider.locator("output").textContent(), "4");
        assert.equal(await page.evaluate(() => document.querySelector(".tiptap-editor").editor.view.hasFocus()), false);
        const range = slider.locator("input");
        await range.scrollIntoViewIfNeeded();
        const bounds = await range.boundingBox();
        if (touch) {
            await range.tap({ position: { x: bounds.width * 0.2, y: bounds.height / 2 } });
        } else {
            await page.mouse.move(bounds.x + bounds.width * 0.73, bounds.y + bounds.height / 2);
            await page.mouse.down();
            await page.mouse.move(bounds.x + bounds.width * 0.2, bounds.y + bounds.height / 2, { steps: 8 });
            await page.mouse.up();
        }
        assert(Number(await range.inputValue()) < 4, `${name}: native range gesture updates the answer`);
        assert.equal(await page.evaluate(() => document.querySelector(".tiptap-editor").editor.view.hasFocus()), false);
        await page.locator(".tiptap-editor p").first().click();
        await page.keyboard.type(" Still editable");
        assert((await page.locator(".tiptap-editor p").first().textContent()).includes("Still editable"));
        assert.deepEqual(errors, []);
        console.log(`${name}: compact centered value, component controls, native range touch/drag and keyboard adjustment, unchanged caret, and ordinary typing passed`);
        await context.close();
    }
} finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
}
