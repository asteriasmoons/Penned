import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const read = path => readFile(new URL("../" + path, import.meta.url), "utf8");
const native = await read("PennedMac/Editor/MacDocumentScrollBridge.swift");
const script = native.match(/static let wheelScript = """\n([\s\S]*?)\n    """/)[1];

function wheel(overrides = {}, { nested = [], bridgeAvailable = true } = {}) {
    let listener;
    const messages = [];
    class Element {
        constructor(values) { Object.assign(this, { overflowY: "visible", scrollTop: 0, scrollHeight: 100, clientHeight: 100 }, values); }
    }
    const document = { body: new Element(), documentElement: new Element() };
    const window = {
        webkit: bridgeAvailable ? { messageHandlers: { pennedMacDocumentScroll: { postMessage: value => messages.push(value) } } } : undefined,
        addEventListener(name, callback, options) {
            assert.equal(name, "wheel");
            assert.equal(options.passive, false);
            listener = callback;
        }
    };
    vm.runInNewContext(script, { window, document, Element, getComputedStyle: element => element });
    const event = {
        deltaY: 25, deltaX: 0, deltaMode: 0, cancelable: true,
        defaultPrevented: false, ctrlKey: false, shiftKey: false,
        composedPath: () => [...nested.map(value => new Element(value)), document.body, document.documentElement, window],
        preventDefault() { this.defaultPrevented = true; }, ...overrides
    };
    listener(event);
    return { event, messages };
}

test("Mac body wheel movement forwards both directions and preserves delta units", () => {
    for (const deltaY of [-90, -0.5, 0.5, 90]) {
        for (const deltaMode of [0, 1, 2]) {
            const { event, messages } = wheel({ deltaY, deltaMode });
            assert.equal(event.defaultPrevented, true);
            assert.equal(messages.length, 1);
            assert.equal(messages[0].deltaY, deltaY);
            assert.equal(messages[0].deltaMode, deltaMode);
        }
    }
});

test("nested collection and text scrolling stays inside the existing block until its edge", () => {
    const nested = [{ overflowY: "auto", scrollTop: 100, scrollHeight: 800, clientHeight: 200 }];
    for (const deltaY of [-25, 25]) assert.equal(wheel({ deltaY }, { nested }).messages.length, 0);
    assert.equal(wheel({ deltaY: -25 }, { nested: [{ ...nested[0], scrollTop: 0 }] }).messages.length, 1);
    assert.equal(wheel({ deltaY: 25 }, { nested: [{ ...nested[0], scrollTop: 600 }] }).messages.length, 1);
    assert.equal(wheel({ deltaY: 25 }, { nested: [{ ...nested[0], scrollTop: 600 }, nested[0]] }).messages.length, 0);
});

test("horizontal tables, shift-wheel, zoom and already handled wheel events are not intercepted", () => {
    for (const overrides of [{ deltaX: 60 }, { shiftKey: true }, { ctrlKey: true }, { defaultPrevented: true },
        { cancelable: false }, { deltaY: 0 }, { deltaY: NaN }, { deltaY: Infinity }]) {
        assert.equal(wheel(overrides).messages.length, 0);
    }
    const unavailable = wheel({}, { bridgeAvailable: false });
    assert.equal(unavailable.event.defaultPrevented, false);
});

test("the Mac-only bridge scrolls the enclosing native document without reloading or editing content", async () => {
    const host = await read("PennedMac/Editor/MacTipTapWebView.swift");
    assert.match(host, /#elseif os\(macOS\)\s+webView\.setValue\(false, forKey: "drawsBackground"\)\s+MacDocumentScrollBridge\.install\(on: webView\)/);
    assert.match(native, /private weak var webView/);
    assert.match(native, /forMainFrameOnly: true/);
    assert.match(native, /webView\.enclosingScrollView/);
    assert.match(native, /clip\.constrainBoundsRect\(bounds\)/);
    assert.match(native, /document\.isFlipped/);
    assert.match(native, /scroll\.reflectScrolledClipView\(clip\)/);
    assert.doesNotMatch(native, /loadHTMLString|setContent|saveEditorJSON|removeFromSuperview|makeFirstResponder/);
});

test("Mac gallery removes 35 percent from preview bottoms without changing width or the shared renderer", async () => {
    const browser = await read("PennedMac/Browser/MacDocumentBrowser.swift");
    assert.match(browser, /previewHeightFraction: CGFloat = 0\.65/);
    assert.match(browser, /LibraryDocumentPreview\(document: document, visibleHeightFraction: previewHeightFraction\)/);
    assert.match(browser, /heights\[column\] \+= .* \* previewHeightFraction/);
    assert.match(browser, /private var columns: Int \{ max\(1, Int\(\(width - 36 \+ 14\) \/ 224\)\) \}/);
    const preview = await read("Vellix/Documents/LibraryDocumentPreview.swift");
    assert.match(preview, /alignment: \.top\)/);
    assert.match(preview, /\/ min\(1, max\(0\.01, visibleHeightFraction\)\)/);
});
