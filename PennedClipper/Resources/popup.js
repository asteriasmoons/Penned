const $ = id => document.getElementById(id);
let catalogue = null, article = null, spaceID = null, folderID = null, tagIDs = new Set();
let route = "main", detail = "main", saving = false, saved = false, clipID = crypto.randomUUID(), pickerReturn = "main";
let extractionError = null, connectionError = null;
const native = async value => {
    const result = await browser.runtime.sendMessage(value);
    if (!result?.ok) throw new Error(result?.error || "Penned is unavailable. Open the app and try again.");
    return result;
};
const selectedSpace = () => catalogue?.spaces.find(space => space.id === spaceID);
const status = (message, error = false) => { $("status").hidden = !message; $("status").textContent = message; $("status").dataset.error = String(error); };
function icons(root = document) {
    root.querySelectorAll("[data-icon]").forEach(element => {
        const source = catalogue?.icons[element.dataset.icon];
        if (source && /^data:image\/png;base64,/.test(source)) element.style.setProperty("--icon", `url("${source}")`);
    });
}
function image(element, source) {
    element.src = source && /^data:image\/(png|jpeg);base64,/.test(source) ? source : browser.runtime.getURL("images/icon-512.png");
}
function display() {
    const connected = !!catalogue;
    $("loading").hidden = true;
    $("connect").hidden = connected;
    $("article").hidden = !connected || route !== "main";
    $("picker").hidden = !connected || !["spaces", "folders"].includes(route);
    $("preferences").hidden = !connected || route !== "settings";
    $("settings").hidden = !connected || route !== "main";
    $("space").hidden = connected && route !== "main";
    $("back").hidden = !connected || route === "main";
    $("save").hidden = !connected || route !== "main" || detail !== "main";
    $("save").disabled = saving || saved || !article || !selectedSpace() || !$("title").value.trim();
    $("save").textContent = saving ? "Saving Clip…" : saved ? "Clip Saved" : "Save Clip";
    $("done").hidden = !connected || route !== "main" || detail === "main";
    $("destination-panel").hidden = detail !== "main";
    $("tags-panel").hidden = detail !== "tags";
    $("info-panel").hidden = detail !== "info";
    $("retry").hidden = !connectionError && !extractionError;
    $("notes-toggle").setAttribute("aria-pressed", String(!$("notes").hidden));
    $("tags-toggle").setAttribute("aria-pressed", String(detail === "tags"));
    $("info-toggle").setAttribute("aria-pressed", String(detail === "info"));
    $("tag-count").hidden = !tagIDs.size; $("tag-count").textContent = String(tagIDs.size);
    const space = selectedSpace();
    $("space-name").textContent = space?.title || "Penned"; image($("space-image"), space?.image);
    $("settings-space-name").textContent = space?.title || "Choose Space"; image($("settings-space-image"), space?.image);
    $("folder-name").textContent = catalogue?.folders.find(folder => folder.id === folderID && folder.spaceID === spaceID)?.title || "Unsorted";
    if (catalogue) {
        $("account-name").textContent = catalogue.accountName;
        $("avatar").hidden = !catalogue.avatar; if (catalogue.avatar) image($("avatar"), catalogue.avatar);
    }
    for (const id of ["title", "author", "website", "notes", "space", "settings", "destination", "notes-toggle", "tags-toggle", "info-toggle"]) $(id).disabled = saving || saved;
    $("close").disabled = saving;
    document.querySelectorAll("button[aria-label]").forEach(button => { button.title = button.getAttribute("aria-label"); });
    icons();
}
function row(title, source, selected, action, depth = 0) {
    const button = document.createElement("button"); button.className = "row";
    button.setAttribute("aria-selected", String(selected));
    button.style.paddingLeft = `${12 + Math.min(depth, 6) * 12}px`;
    if (source) { const picture = document.createElement("img"); image(picture, source); picture.alt = ""; button.append(picture); }
    const label = document.createElement("span"); label.className = "grow"; label.textContent = title; button.append(label);
    if (selected) { const check = document.createElement("i"); check.dataset.icon = "checkwavy"; check.className = "selected"; button.append(check); }
    button.addEventListener("click", action); return button;
}
function empty(list, text) { const label = document.createElement("p"); label.className = "empty"; label.textContent = text; list.append(label); }
function picker(type, from = route) {
    pickerReturn = from === "settings" ? "settings" : "main";
    route = type; $("picker-search").value = ""; renderPicker(); display();
}
function renderPicker() {
    $("picker-title").textContent = route === "spaces" ? "Choose Space" : "Add to…";
    const list = $("picker-list"), query = $("picker-search").value.trim().toLocaleLowerCase(); list.replaceChildren();
    if (route === "spaces") {
        const spaces = catalogue.spaces.filter(space => space.title.toLocaleLowerCase().includes(query));
        for (const space of spaces) list.append(row(space.title, space.image, space.id === spaceID, () => {
            if (spaceID !== space.id) { spaceID = space.id; folderID = null; tagIDs.clear(); renderTags(); }
            route = pickerReturn; persistDestination(); display();
        }));
        if (!spaces.length) empty(list, "No matching Spaces");
    } else {
        if (!query || "unsorted".includes(query)) list.append(row("Unsorted", catalogue.icons.linesfolderfill, !folderID, () => { folderID = null; route = "main"; persistDestination(); display(); }));
        const folders = catalogue.folders.filter(folder => folder.spaceID === spaceID);
        function path(folder) {
            const names = [folder.title], seen = new Set([folder.id]); let parent = folder.parentID;
            while (parent && !seen.has(parent)) { seen.add(parent); const value = folders.find(item => item.id === parent); if (!value) break; names.unshift(value.title); parent = value.parentID; }
            return names;
        }
        const matching = folders.map(folder => ({ folder, names: path(folder) })).filter(item => item.names.join(" / ").toLocaleLowerCase().includes(query));
        matching.sort((a, b) => a.names.join("/").localeCompare(b.names.join("/")));
        for (const { folder, names } of matching) list.append(row(query ? names.join(" / ") : folder.title, folder.image || catalogue.icons.linesfolderfill, folder.id === folderID,
            () => { folderID = folder.id; route = "main"; persistDestination(); display(); }, query ? 0 : names.length - 1));
        if (!list.childElementCount) empty(list, "No matching folders");
    }
    icons(list);
}
function renderTags() {
    const list = $("tag-list"), query = $("tag-search").value.trim().replace(/^#/, "").toLocaleLowerCase(); list.replaceChildren();
    const tags = catalogue?.tags.filter(tag => tag.spaceID === spaceID && tag.title.toLocaleLowerCase().includes(query)) || [];
    for (const tag of tags) {
        const label = document.createElement("label"); label.className = "tag";
        const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.checked = tagIDs.has(tag.id); checkbox.disabled = saving || saved;
        const text = document.createElement("span"); text.textContent = tag.title; label.append(checkbox, text);
        checkbox.addEventListener("change", () => { if (checkbox.checked) tagIDs.add(tag.id); else tagIDs.delete(tag.id); display(); }); list.append(label);
    }
    if (!tags.length) empty(list, query ? "No matching tags" : "No existing tags in this Space");
}
function persistDestination() {
    // Remember the Space, but every new clip starts in the built-in Unsorted folder.
    if (catalogue) browser.storage.local.set({ destination: { sessionID: catalogue.sessionID, spaceID } }).catch(() => {});
}
async function loadCatalogue() {
    try {
        const response = await native({ action: "catalogue" }); connectionError = null;
        const previous = catalogue?.sessionID;
        catalogue = response.connected ? response.catalogue : null;
        if (!catalogue) { spaceID = null; folderID = null; tagIDs.clear(); return; }
        if (previous && previous !== catalogue.sessionID) { spaceID = null; folderID = null; tagIDs.clear(); saved = false; clipID = crypto.randomUUID(); }
        const stored = (await browser.storage.local.get("destination")).destination;
        if (!catalogue.spaces.some(space => space.id === spaceID)) {
            spaceID = (stored?.sessionID === catalogue.sessionID && catalogue.spaces.some(space => space.id === stored.spaceID) ? stored.spaceID : null)
                || catalogue.selectedSpaceID || catalogue.spaces[0]?.id || null;
            folderID = null;
        }
        if (folderID !== null && !catalogue.folders.some(folder => folder.id === folderID && folder.spaceID === spaceID)) folderID = null;
        tagIDs = new Set([...tagIDs].filter(id => catalogue.tags.some(tag => tag.id === id && tag.spaceID === spaceID)));
        renderTags();
    } catch (error) { connectionError = error.message; catalogue = null; }
}
async function extract() {
    try {
        article = (await native({ action: "extract" })).article; extractionError = null;
        $("title").value = article.title; $("author").value = article.author; $("website").value = article.siteName;
        $("source").textContent = article.sourceURL; $("source").href = article.sourceURL;
    } catch (error) { extractionError = error.message; article = null; }
}
async function start() {
    $("loading").hidden = false; status("");
    await Promise.all([loadCatalogue(), extract()]); display();
    status(connectionError || extractionError || (!catalogue ? "" : !catalogue.spaces.length ? "Create a Space in Penned, then refresh the clipper." : ""), !!(connectionError || extractionError));
}
async function save() {
    if (saving || saved || !article || !catalogue) return;
    saving = true; status("Saving article and images…"); display();
    const sessionID = catalogue.sessionID;
    try {
        await native({ action: "save", clip: { id: clipID, sessionID, spaceID, folderID, tagIDs: [...tagIDs], title: $("title").value.trim(),
            author: $("author").value.trim(), siteName: $("website").value.trim(), sourceURL: article.sourceURL, notes: $("notes").value,
            content: article.content, thumbnailURL: article.thumbnailURL || null } });
        saved = true;
        status("Clip and images saved securely. They will appear in Penned when the app next opens.");
        // An already-running Penned imports on the inbox notification. A queued receipt
        // is durable success, not a claim that iOS launched a suspended application.
        for (let index = 0; index < 4; index++) {
            const result = await native({ action: "status", id: clipID, sessionID });
            if (result.state === "imported") { status("Saved to " + selectedSpace().title + "."); break; }
            if (result.state === "error") { saved = false; throw new Error(result.message || "Open Penned to finish importing this clip."); }
            await new Promise(resolve => setTimeout(resolve, 500));
        }
    } catch (error) { status(error.message, true); }
    finally { saving = false; display(); }
}
$("space").addEventListener("click", () => catalogue && picker("spaces", "main"));
$("settings-space").addEventListener("click", () => picker("spaces", "settings"));
$("destination").addEventListener("click", () => picker("folders"));
$("settings").addEventListener("click", () => { route = "settings"; display(); });
$("back").addEventListener("click", () => { route = ["spaces", "folders"].includes(route) ? pickerReturn : "main"; display(); });
$("close").addEventListener("click", () => window.close());
$("notes-toggle").addEventListener("click", () => { $("notes").hidden = !$("notes").hidden; display(); if (!$("notes").hidden) $("notes").focus(); });
$("tags-toggle").addEventListener("click", () => { detail = detail === "tags" ? "main" : "tags"; renderTags(); display(); });
$("info-toggle").addEventListener("click", () => { detail = detail === "info" ? "main" : "info"; display(); });
$("done").addEventListener("click", () => { detail = "main"; display(); });
$("picker-search").addEventListener("input", renderPicker); $("tag-search").addEventListener("input", renderTags);
$("title").addEventListener("input", display); $("save").addEventListener("click", save);
$("retry").addEventListener("click", start);
$("reconnect").addEventListener("click", async () => { await loadCatalogue(); display(); status(connectionError || "", !!connectionError); });
function theme(value) {
    document.documentElement.dataset.theme = value;
    document.querySelectorAll("[data-theme]").forEach(button => { if (button.tagName === "BUTTON") button.setAttribute("aria-pressed", String(button.dataset.theme === value)); });
}
$("theme").addEventListener("click", event => {
    const button = event.target.closest("button[data-theme]"); if (!button) return;
    theme(button.dataset.theme); browser.storage.local.set({ theme: button.dataset.theme }).catch(() => {});
});
browser.storage.local.get("theme").then(value => theme(["dark", "light", "system"].includes(value.theme) ? value.theme : "dark"));
start();
