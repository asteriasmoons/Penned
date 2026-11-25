(function (global) {
  const units = ["months", "weeks", "days", "hours", "minutes"];
  const defaults = {
    width: "full", icon: "clockwavy", imagePath: null, originalIconColors: false, title: "Countdown", targetDate: null,
    showIcon: true, showTitle: true, showTargetDate: true,
    showMonths: true, showWeeks: true, showDays: true, showHours: true, showMinutes: true,
    completionMessage: "Time's up!", countUp: false,
    backgroundColor: "#151518", borderColor: "#65606d", borderWidth: 2,
    iconColor: "#c998f5", titleColor: "#ffffff", numberColor: "#ffffff", unitLabelColor: "#c8c4cf", tileColor: "#302a39",
  };
  const date = value => {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
    const parsed = new Date(value);
    return Number.isFinite(parsed.getTime()) && parsed.getFullYear() >= 1 && parsed.getFullYear() <= 9999 ? parsed : null;
  };
  function setting(key, value) {
    if (!(key in defaults)) return undefined;
    if (key === "width") return ["half", "full"].includes(value) ? value : undefined;
    if (key === "imagePath") return typeof value === "string" && value && !/[/\\\0]/.test(value) && ![".", ".."].includes(value) ? value : null;
    if (key === "targetDate") return date(value)?.toISOString() ?? (value === null ? null : undefined);
    if (key === "borderWidth") return Number.isFinite(value) ? Math.max(0, Math.min(8, Math.round(value))) : undefined;
    if (typeof defaults[key] === "boolean") return typeof value === "boolean" ? value : undefined;
    if (key.endsWith("Color")) return typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value : undefined;
    if (typeof value !== "string") return undefined;
    return value.slice(0, key === "completionMessage" ? 1000 : 240);
  }
  const settings = attrs => Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [key, setting(key, attrs?.[key]) ?? fallback]));
  const unitKey = unit => "show" + unit[0].toUpperCase() + unit.slice(1);
  function addMonths(value, count) {
    const next = new Date(value), day = next.getDate();
    next.setDate(1); next.setMonth(next.getMonth() + count);
    const last = new Date(next.getFullYear(), next.getMonth() + 1, 0).getDate();
    next.setDate(Math.min(day, last)); return next;
  }
  const addDays = (value, count) => { const next = new Date(value); next.setDate(next.getDate() + count); return next; };
  function wholeDays(from, to) {
    let count = Math.max(0, Math.floor((to - from) / 86400000));
    while (count && addDays(from, count) > to) count--;
    while (addDays(from, count + 1) <= to) count++;
    return count;
  }
  function clock(attrs, now = new Date()) {
    const target = date(attrs.targetDate), complete = !!target && now >= target;
    const enabled = units.filter(unit => attrs[unitKey(unit)]);
    if (complete && !attrs.countUp) return { complete, values: [] };
    let cursor = target && complete ? target : now;
    const end = target && complete ? now : target;
    const values = enabled.map(unit => {
      let value = 0;
      if (end) {
        if (unit === "months") {
          value = Math.max(0, (end.getFullYear() - cursor.getFullYear()) * 12 + end.getMonth() - cursor.getMonth());
          while (value && addMonths(cursor, value) > end) value--;
          cursor = addMonths(cursor, value);
        } else if (unit === "weeks" || unit === "days") {
          const factor = unit === "weeks" ? 7 : 1;
          value = Math.floor(wholeDays(cursor, end) / factor);
          cursor = addDays(cursor, value * factor);
        } else {
          const factor = unit === "hours" ? 3600000 : 60000;
          value = Math.max(0, Math.floor((end - cursor) / factor));
          cursor = new Date(cursor.getTime() + value * factor);
        }
      }
      return { unit, value };
    });
    return { complete, values };
  }
  function rows(values, width) {
    if (!values.length) return [];
    const count = Math.ceil(values.length / (width === "half" ? 3 : 5));
    const base = Math.floor(values.length / count), extra = values.length % count;
    let offset = 0;
    return Array.from({ length: count }, (_, index) => {
      const size = base + (index < extra ? 1 : 0);
      const row = values.slice(offset, offset + size); offset += size; return row;
    });
  }
  const targetLabel = attrs => {
    const value = date(attrs.targetDate);
    return value ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(value) : "";
  };
  function parts(attrs, now, renderIcon) {
    const state = clock(attrs, now);
    const header = [];
    if (attrs.showIcon && (attrs.imagePath || attrs.icon)) {
      header.push(["span", { class: "penned-countdown-icon" }, renderIcon({
        imagePath: attrs.imagePath, imageTint: attrs.originalIconColors ? null : attrs.iconColor,
        icon: attrs.icon, iconColor: attrs.originalIconColors ? "original" : attrs.iconColor,
      })]);
    }
    const labels = [];
    if (attrs.showTitle && attrs.title) labels.push(["div", { class: "penned-countdown-title", style: `color:${attrs.titleColor}` }, attrs.title]);
    if (attrs.showTargetDate && attrs.targetDate) labels.push(["div", { class: "penned-countdown-date", style: `color:${attrs.unitLabelColor}` }, targetLabel(attrs)]);
    if (labels.length) header.push(["div", { class: "penned-countdown-labels" }, ...labels]);
    const output = header.length ? [["div", { class: "penned-countdown-header" }, ...header]] : [];
    if (state.complete && attrs.completionMessage) output.push(["div", { class: "penned-countdown-completion", style: `color:${attrs.titleColor}` }, attrs.completionMessage]);
    for (const row of rows(state.values, attrs.width)) output.push(["div", {
      class: "penned-countdown-row", style: `grid-template-columns:repeat(${row.length},minmax(0,1fr))`,
    }, ...row.map(({ unit, value }) => ["div", { class: "penned-countdown-tile", style: `background:${attrs.tileColor}` },
      ["div", { class: "penned-countdown-tile-content", style: `--countdown-digits:${String(value).length};--countdown-label-length:${unit.length}` },
        ["div", { class: "penned-countdown-number", style: `color:${attrs.numberColor}` }, String(value)],
        ["div", { class: "penned-countdown-unit", style: `color:${attrs.unitLabelColor}` }, unit[0].toUpperCase() + unit.slice(1)]]])]);
    return output;
  }
  function appendSpec(parent, spec) {
    if (typeof spec === "string") { parent.append(document.createTextNode(spec)); return; }
    const [tag, attrs, ...children] = spec, element = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, value);
    children.forEach(child => appendSpec(element, child)); parent.append(element);
  }
  function createExtension({ Node, mergeAttributes, post, renderIcon }) {
    const style = document.createElement("style");
    style.textContent = `
      .penned-countdown { border-style:solid; border-radius:8px; }
      .penned-countdown .penned-countdown-surface { display:flex; flex:1; min-height:0; flex-direction:column; justify-content:flex-start; gap:var(--widget-gap); width:100%;
        box-sizing:border-box; padding:0; margin:0; border:0; border-radius:0; background:transparent; box-shadow:none; cursor:default; }
      .penned-countdown-header { display:flex; flex:none; align-items:center; gap:var(--widget-gap); min-width:0; width:100%; }
      .penned-countdown-icon { display:block; position:relative; width:clamp(18px,8cqi,22px); height:clamp(18px,8cqi,22px); flex:none; pointer-events:none; }
      .penned-countdown-icon > .penned-icon-callout-image { position:static; width:100%; height:100%; object-fit:contain; }
      .penned-countdown-icon { filter:drop-shadow(0.6px 0 0 var(--penned-callout-icon-outline,transparent)) drop-shadow(-0.6px 0 0 var(--penned-callout-icon-outline,transparent)) drop-shadow(0 0.6px 0 var(--penned-callout-icon-outline,transparent)) drop-shadow(0 -0.6px 0 var(--penned-callout-icon-outline,transparent)); }
      .penned-countdown-labels { flex:1; min-width:0; }
      .penned-countdown-title { font-family:ui-rounded,'SF Pro Rounded',system-ui; font-size:clamp(14px,6cqi,16px); line-height:1.2; font-weight:900; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .penned-countdown-date { font-size:clamp(9px,3.8cqi,10px); line-height:1.2; margin-top:2px; overflow:hidden; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; }
      .penned-countdown-completion { flex:none; width:100%; font-size:clamp(12px,5cqi,14px); font-weight:800; line-height:1.25; overflow-wrap:anywhere; white-space:pre-wrap; overflow:hidden; display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; }
      .penned-countdown-surface:has(.penned-countdown-row) .penned-countdown-completion { font-size:12px; -webkit-line-clamp:2; }
      .penned-countdown-row { display:grid; gap:min(3px,1.5cqi); width:100%; flex:1 1 0; min-height:0; }
      .penned-countdown-tile { position:relative; min-width:0; min-height:0; height:100%; box-sizing:border-box; border-radius:6px; container-type:size; }
      .penned-countdown-tile-content {
        --countdown-tile-pad:clamp(2px,min(6cqi,6cqh),6px);
        --countdown-tile-gap:clamp(2px,4cqh,6px);
        --countdown-unit-size:max(5px,min(15px,max(8px,min(22cqi,16cqh)),calc((100cqi - 2 * var(--countdown-tile-pad)) / (var(--countdown-label-length) * 0.56))));
        position:absolute; inset:0; display:flex; flex-direction:column; justify-content:center; align-items:center;
        padding:var(--countdown-tile-pad); gap:var(--countdown-tile-gap); box-sizing:border-box;
      }
      .penned-countdown-number { font-family:ui-rounded,'SF Pro Rounded',system-ui;
        font-size:max(5px,min(52px,max(16px,min(52cqi,44cqh)),calc((100cqi - 2 * var(--countdown-tile-pad)) / (var(--countdown-digits) * 0.68)),calc((100cqh - 2 * var(--countdown-tile-pad) - var(--countdown-tile-gap) - 1.2 * var(--countdown-unit-size)) / 1.1)));
        line-height:1.1; font-weight:900; white-space:nowrap; max-width:100%; }
      .penned-countdown-unit { font-size:var(--countdown-unit-size); line-height:1.2; max-width:100%; white-space:nowrap; }
    `;
    document.head.append(style);
    return Node.create({
      name: "countdown", group: "block", atom: true, selectable: true, draggable: true,
      addAttributes() {
        return { id: { default: null, parseHTML: element => element.getAttribute("data-vellix-block-id") },
          ...Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [key, { default: fallback, rendered: false,
            parseHTML: element => { try { return setting(key, JSON.parse(element.getAttribute("data-countdown-settings") || "{}")[key]) ?? fallback; } catch { return fallback; } },
          }])) };
      },
      parseHTML: () => [{ tag: "div[data-countdown]" }],
      renderHTML({ node, HTMLAttributes }) {
        const attrs = settings(node.attrs);
        return ["div", mergeAttributes(HTMLAttributes, { class: "penned-countdown penned-document-widget", "data-countdown": "",
          "data-callout-image": attrs.imagePath,
          "data-vellix-block-id": node.attrs.id, "data-widget-size": attrs.width, "data-countdown-settings": JSON.stringify(attrs), contenteditable: "false",
          style: `background:${attrs.backgroundColor};border:${attrs.borderWidth}px solid ${attrs.borderColor};--penned-callout-icon-outline:${attrs.originalIconColors ? "transparent" : attrs.iconColor}`,
        }), ["div", { class: "penned-countdown-surface" }, ...parts(attrs, new Date(), renderIcon)]];
      },
      addCommands() {
        return { countdownUpdate: args => ({ tr, dispatch }) => {
          let found = null;
          tr.doc.descendants((node, pos) => { if (node.type.name === "countdown" && node.attrs.id === args.blockID) { found = { node, pos }; return false; } });
          if (!found || JSON.stringify(settings(found.node.attrs)) !== JSON.stringify(settings(args.original))) return false;
          const next = settings(args.settings);
          if (JSON.stringify(settings(found.node.attrs)) === JSON.stringify(next)) return true;
          if (dispatch) tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, ...next });
          return true;
        } };
      },
      addNodeView() {
        return ({ node, getPos, editor }) => {
          let current = node, timer = null, destroyed = false, renderedSignature = "";
          const dom = document.createElement("div"), surface = document.createElement("button");
          dom.className = "penned-countdown penned-document-widget"; dom.contentEditable = "false"; dom.dataset.countdown = "";
          surface.type = "button"; surface.className = "penned-countdown-surface penned-widget-settings-surface";
          surface.setAttribute("aria-label", "Customize countdown"); dom.append(surface);
          const enabled = () => !destroyed && editor.isEditable && global.PennedDocumentWidgets.selectionMode() === "off" && !global.PennedBlockDragAndDrop?.busy;
          const open = () => {
            if (!enabled()) return false;
            const pos = getPos(), live = Number.isInteger(pos) ? editor.state.doc.nodeAt(pos) : null;
            if (live?.type.name !== "countdown" || live.attrs.id !== current.attrs.id) return false;
            post("countdownSettings", { blockId: live.attrs.id, settings: settings(live.attrs) }); return true;
          };
          const render = () => {
            clearTimeout(timer);
            if (destroyed) return;
            const attrs = settings(current.attrs), now = new Date();
            dom.dataset.vellixBlockId = current.attrs.id || ""; dom.dataset.widgetSize = attrs.width;
            if (attrs.imagePath) dom.dataset.calloutImage = attrs.imagePath; else delete dom.dataset.calloutImage;
            dom.style.setProperty("--penned-callout-icon-outline", attrs.originalIconColors ? "transparent" : attrs.iconColor);
            dom.dataset.vellixIndent = String(Math.max(0, Math.min(6, current.attrs.indent || 0)));
            dom.style.backgroundColor = attrs.backgroundColor; dom.style.borderColor = attrs.borderColor; dom.style.borderWidth = `${attrs.borderWidth}px`;
            if (!document.hidden) {
              const state = clock(attrs, now), signature = JSON.stringify([attrs, state.complete]);
              if (signature !== renderedSignature) {
                surface.replaceChildren(); parts(attrs, now, renderIcon).forEach(spec => appendSpec(surface, spec));
                renderedSignature = signature;
              } else {
                surface.querySelectorAll(".penned-countdown-number").forEach((element, index) => {
                  const text = String(state.values[index]?.value ?? 0);
                  if (element.textContent !== text) {
                    element.textContent = text;
                    element.parentElement.style.setProperty("--countdown-digits", String(text.length));
                  }
                });
              }
              surface.setAttribute("aria-label", [attrs.showTitle ? attrs.title : "Countdown", ...state.values.map(item => `${item.value} ${item.unit}`),
                state.complete ? attrs.completionMessage : "", "Customize countdown"].filter(Boolean).join(", "));
              const target = date(attrs.targetDate);
              if (target && (target > now || attrs.countUp)) {
                const distance = Math.abs(target - now), remainder = distance % 60000;
                const delay = target > now ? Math.min(distance, remainder || 60000) : 60000 - remainder;
                timer = setTimeout(render, Math.max(50, delay + 25));
              }
            }
          };
          const release = global.PennedDocumentWidgets.bindSettings({ dom, surface, editor, enabled, open });
          document.addEventListener("visibilitychange", render); global.addEventListener("pageshow", render);
          render();
          return { dom, update(next) { if (next.type !== current.type || next.attrs.id !== current.attrs.id) return false; current = next; render(); return true; },
            stopEvent: event => global.PennedDocumentWidgets.selectionMode() === "off" && !/^(drag|drop)/.test(event.type),
            ignoreMutation: () => true,
            destroy() { destroyed = true; clearTimeout(timer); release(); document.removeEventListener("visibilitychange", render); global.removeEventListener("pageshow", render); },
          };
        };
      },
    });
  }
  global.PennedCountdown = { createExtension, settings, clock, rows,
    newAttrs: () => ({ id: crypto.randomUUID(), ...defaults, targetDate: new Date(Date.now() + 86400000).toISOString() }) };
})(globalThis);
