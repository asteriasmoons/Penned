// Only extension pages can invoke the native inbox. Page scripts/content scripts cannot.
browser.runtime.onMessage.addListener((request, sender) => {
    if (sender.id !== browser.runtime.id || sender.tab ||
        (sender.url && !sender.url.startsWith(browser.runtime.getURL("")))) return;
    return route(request).catch(error => ({ ok: false, error: error.message || "Penned could not complete this clip." }));
});

async function route(request) {
    if (request.action === "extract") {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (!tab?.id || !/^https?:\/\//i.test(tab.url || "")) throw new Error("Open an article webpage in Safari, then choose Penned.");
        await browser.scripting.executeScript({ target: { tabId: tab.id }, files: ["Readability.js", "content.js"] });
        const result = await browser.scripting.executeScript({ target: { tabId: tab.id }, func: () => globalThis.PennedClipperExtract() });
        const article = result.find(item => item.frameId === 0)?.result;
        if (!article) throw new Error("Safari did not allow Penned to read this page. Allow access to this website and try again.");
        if (article.error) throw new Error(article.error);
        return { ok: true, article };
    }
    if (!["catalogue", "save", "status"].includes(request.action)) throw new Error("Unsupported clipping action.");
    return browser.runtime.sendNativeMessage("im.lystaria.PennedWebClipper.Extension", request);
}
