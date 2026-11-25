// Loaded before the editor bundle so the native host and source editor share a schema.
(function (global) {
  const moods = ["miserable", "upset", "low", "neutral", "content", "happy", "ecstatic"];
  const defaults = { value: 3, width: "full", backgroundColor: "#151518", barColor: "#af72e9", borderColor: "#65606d", borderWidth: 2,
    buttonColor: "#151518", buttonBorderColor: "#ffffff" };
  const color = (value, fallback) => typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
  function setting(key, value) {
    if (key === "width") return ["half", "full"].includes(value) ? value : null;
    if (key === "value" || key === "borderWidth") {
      if (value === null || value === "" || !Number.isFinite(Number(value))) return null;
      return Math.max(0, Math.min(key === "value" ? 6 : 8, Math.round(Number(value))));
    }
    return ["backgroundColor", "barColor", "borderColor", "buttonColor", "buttonBorderColor"].includes(key) ? color(value, null) : null;
  }
  const settings = attrs => Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [key, setting(key, attrs?.[key]) ?? fallback]));
  const source = name => `vellix-icon://asset/${name}?tint=original&size=144`;
  const styleID = "penned-mood-bar-style";
  function installStyle() {
    if (document.getElementById(styleID)) return;
    const style = document.createElement("style");
    style.id = styleID;
    style.textContent = `
      .penned-mood-bar { position:relative; border-style:solid; border-radius:8px; --mood-track:clamp(22px,12cqi,26px); }
      .penned-mood-bar .penned-mood-art { display:block; position:relative; flex:1; min-height:0; width:100%; margin:0;
        padding:0; border:0; border-radius:0; background:transparent; box-shadow:none; cursor:default; touch-action:pan-y; }
      .penned-mood-bar .penned-mood-art img { position:absolute; width:100%; max-width:100%; height:100%;
        inset:0; margin:0; object-fit:contain; pointer-events:none; opacity:0; }
      .penned-mood-bar .penned-mood-art img[data-active] { opacity:1; }
      .penned-mood-bar .penned-mood-range { display:block; flex:none; box-sizing:border-box; width:100%; height:44px; margin:0;
        padding:0; border:0; background:transparent; appearance:none; -webkit-appearance:none; touch-action:none; cursor:ew-resize; }
      .penned-mood-bar .penned-mood-range::-webkit-slider-runnable-track { height:var(--mood-track); border-radius:14px; background:var(--mood-bar-color); }
      .penned-mood-bar .penned-mood-range::-webkit-slider-thumb { appearance:none; -webkit-appearance:none; width:30px; height:30px;
        margin-top:calc((var(--mood-track) - 30px)/2); border:3px solid var(--mood-button-border); border-radius:50%; background:var(--mood-button-color); box-shadow:0 1px 5px #0008; }
      .penned-mood-bar .penned-mood-range::-moz-range-track { height:var(--mood-track); border-radius:14px; background:var(--mood-bar-color); }
      .penned-mood-bar .penned-mood-range::-moz-range-thumb { box-sizing:border-box; width:30px; height:30px; border:3px solid var(--mood-button-border); border-radius:50%; background:var(--mood-button-color); }
      .penned-mood-bar .penned-mood-static-track { position:relative; flex:none; height:44px; }
      .penned-mood-static-track::before { content:""; position:absolute; left:0; right:0; top:calc((44px - var(--mood-track))/2); height:var(--mood-track); border-radius:14px; background:var(--mood-bar-color); }
      .penned-mood-static-thumb { position:absolute; top:7px; left:calc(var(--mood-value)*100% - var(--mood-value)*30px); width:30px; height:30px; box-sizing:border-box; border:3px solid var(--mood-button-border); border-radius:50%; background:var(--mood-button-color); }
      .penned-mood-bar :is(button,input):focus-visible { outline:2px solid white; outline-offset:3px; }
      html[data-vellix-selection-mode]:not([data-vellix-selection-mode="off"]) .penned-mood-bar :is(.penned-mood-art,.penned-mood-range) {
        pointer-events:none; touch-action:pan-y;
      }
      .penned-mood-bar.penned-block-selected::after { inset:0; border-radius:inherit; }
    `;
    document.head.append(style);
  }
  function createExtension({ Node, mergeAttributes, post }) {
    installStyle();
    return Node.create({
      name: "moodBar", group: "block", atom: true, selectable: true, draggable: true,
      addAttributes() {
        return {
          id: { default: null, parseHTML: element => element.getAttribute("data-vellix-block-id"),
            renderHTML: attrs => attrs.id ? { "data-vellix-block-id": attrs.id } : {} },
          ...Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [key, {
            default: fallback, rendered: false,
            parseHTML: element => setting(key, element.getAttribute(`data-mood-${key}`)) ?? fallback,
          }])),
        };
      },
      parseHTML() { return [{ tag: "div[data-mood-bar]" }]; },
      renderHTML({ node, HTMLAttributes }) {
        const attrs = settings(node.attrs);
        return ["div", mergeAttributes(HTMLAttributes, {
          "data-mood-bar": "", "data-widget-size": attrs.width, class: "penned-mood-bar penned-document-widget", contenteditable: "false",
          ...Object.fromEntries(Object.entries(attrs).map(([key, value]) => [`data-mood-${key}`, String(value)])),
          style: `background:${attrs.backgroundColor};border:${attrs.borderWidth}px solid ${attrs.borderColor};--mood-bar-color:${attrs.barColor};--mood-button-color:${attrs.buttonColor};--mood-button-border:${attrs.buttonBorderColor};--mood-value:${attrs.value / 6}`,
        }), ["div", { class: "penned-mood-art" }, ["img", { src: source(moods[attrs.value]), alt: moods[attrs.value], "data-active": "" }]],
        ["div", { class: "penned-mood-static-track" }, ["div", { class: "penned-mood-static-thumb" }]]];
      },
      addCommands() {
        return {
          moodBarSetAttr: ({ blockID, key, value }) => ({ tr, dispatch }) => {
            const normalized = setting(key, value);
            if (normalized === null || key === "value") return false;
            let found = null;
            tr.doc.descendants((node, pos) => {
              if (node.type.name === "moodBar" && node.attrs.id === blockID) { found = { node, pos }; return false; }
            });
            if (!found) return false;
            if (dispatch && found.node.attrs[key] !== normalized) tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, [key]: normalized });
            return true;
          },
        };
      },
      addNodeView() {
        return ({ node, getPos, editor, HTMLAttributes }) => {
          let current = node, draft = settings(node.attrs).value, dirty = false, destroyed = false;
          const dom = document.createElement("div");
          dom.className = "penned-mood-bar penned-document-widget";
          dom.contentEditable = "false";
          dom.setAttribute("data-mood-bar", "");
          const art = document.createElement("button");
          art.type = "button";
          art.className = "penned-mood-art penned-widget-settings-surface";
          art.setAttribute("aria-label", "Customize mood bar");
          const images = moods.map((name, index) => {
            const image = document.createElement("img");
            image.src = source(name); image.alt = ""; image.draggable = false;
            image.width = 144; image.height = 96; image.decoding = "async";
            image.addEventListener("load", () => { image.decode?.().catch(() => {}); }, { once: true });
            image.toggleAttribute("data-active", index === draft);
            art.append(image);
            return image;
          });
          const range = document.createElement("input");
          range.type = "range"; range.min = "0"; range.max = "6"; range.step = "1";
          range.className = "penned-mood-range";
          range.setAttribute("aria-label", "Mood");
          dom.append(art, range);
          const enabled = () => !destroyed && editor.isEditable &&
            (document.documentElement.dataset.vellixSelectionMode || "off") === "off" &&
            !global.PennedBlockDragAndDrop?.busy;
          const live = () => {
            const pos = getPos();
            const node = Number.isInteger(pos) ? editor.state.doc.nodeAt(pos) : null;
            return node?.type.name === "moodBar" && node.attrs.id === current.attrs.id ? { node, pos } : null;
          };
          const paint = value => {
            draft = value;
            images.forEach((image, index) => image.toggleAttribute("data-active", index === value));
            range.value = String(value);
            range.setAttribute("aria-valuetext", moods[value]);
          };
          const commit = () => {
            if (!dirty) return;
            dirty = false;
            const target = live();
            if (!target || !enabled()) { paint(settings(current.attrs).value); return; }
            if (settings(target.node.attrs).value !== draft) {
              editor.view.dispatch(editor.state.tr.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, value: draft }));
            }
          };
          const requestSettings = () => {
            if (!enabled()) return false;
            commit();
            const target = live();
            if (!target) return false;
            editor.view.dom.blur();
            post("moodBarSettings", { blockId: target.node.attrs.id, settings: settings(target.node.attrs) });
            return true;
          };
          const releaseSettings = global.PennedDocumentWidgets.bindSettings({ dom, surface: art, editor, enabled, open: requestSettings });
          range.addEventListener("pointerdown", event => {
            if (!enabled()) event.preventDefault();
            // Keep WebKit's real slider interaction; only stop the editor's
            // bubble handlers from interpreting this as a text caret tap.
            event.stopPropagation();
          });
          range.addEventListener("input", () => {
            if (!enabled()) { paint(settings(current.attrs).value); return; }
            const next = setting("value", range.value);
            if (next !== null) { dirty = true; paint(next); }
          });
          for (const name of ["change", "pointerup", "pointercancel", "blur"]) range.addEventListener(name, commit);
          range.addEventListener("click", event => event.stopPropagation());
          const hidden = () => { if (document.hidden) commit(); };
          document.addEventListener("visibilitychange", hidden);
          global.addEventListener("blur", commit);
          const render = () => {
            const attrs = settings(current.attrs);
            for (const [key, value] of Object.entries(HTMLAttributes)) {
              if (value != null && !["class", "style"].includes(key)) dom.setAttribute(key, value);
            }
            dom.dataset.vellixBlockId = current.attrs.id || "";
            dom.dataset.widgetSize = attrs.width;
            dom.dataset.vellixIndent = String(Math.max(0, Math.min(6, current.attrs.indent || 0)));
            dom.style.backgroundColor = attrs.backgroundColor;
            dom.style.borderColor = attrs.borderColor;
            dom.style.borderWidth = `${attrs.borderWidth}px`;
            dom.style.setProperty("--mood-bar-color", attrs.barColor);
            dom.style.setProperty("--mood-button-color", attrs.buttonColor);
            dom.style.setProperty("--mood-button-border", attrs.buttonBorderColor);
            if (!dirty) paint(attrs.value);
          };
          render();
          return {
            dom,
            update(next) {
              if (next.type !== current.type || next.attrs.id !== current.attrs.id) return false;
              if (next.attrs.value !== current.attrs.value) dirty = false;
              current = next; render(); return true;
            },
            stopEvent: event => (document.documentElement.dataset.vellixSelectionMode || "off") === "off" && !/^(drag|drop)/.test(event.type),
            ignoreMutation: () => true,
            destroy() {
              destroyed = true; releaseSettings();
              document.removeEventListener("visibilitychange", hidden);
              global.removeEventListener("blur", commit);
            },
          };
        };
      },
    });
  }
  global.PennedMoodBar = { createExtension, settings, moods };
})(globalThis);
