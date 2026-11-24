#if os(iOS)
import CoreGraphics

enum MobileBlockSelection {
    static let selectionGutter: CGFloat = 6

    static let script = #"""
(() => {
  if (window.PennedBlockSelection) return;
  let editor, key, mirrorMode, controller, closeHistory, post, skipNativeContentHistory = false, nativeContentHydrated = false;
  const empty = () => ({ mode: "off", selected: [], range: null, gesture: null, click: null, haptic: 0, dividerConverted: false, formattingTarget: null });
  const now = () => performance.now();
  const pointerInput = typeof window.PointerEvent === "function";
  const inputNames = pointerInput
    ? { start: "pointerdown", move: "pointermove", end: "pointerup", cancel: "pointercancel" }
    : { start: "touchstart", move: "touchmove", end: "touchend", cancel: "touchcancel" };
  const inputPoints = new Map(), inputCache = new WeakMap();
  // Adapt real pointer input to the existing range engine's contact shape.
  // Do not dispatch synthetic DOM events or run both pointer and touch sensors.
  function contactEvent(event) {
    if (!event.type.startsWith("pointer")) return event;
    if (event.pointerType !== "touch") return null;
    if (inputCache.has(event)) return inputCache.get(event);
    // A new primary touch starts a new physical sequence. Native gesture
    // cancellation can consume the old pointer's terminal DOM event.
    if (event.type === "pointerdown" && event.isPrimary && inputPoints.size) {
      const count = inputPoints.size;
      inputPoints.clear();
      window.PennedBlockDragAndDrop?.diagnostic('input-sequence-rebased', {
        source: 'pointerdown', identifier: event.pointerId, count, reason: 'new-primary-pointer' });
    }
    const touch = { identifier: event.pointerId, clientX: event.clientX, clientY: event.clientY, screenY: event.screenY };
    const types = { pointerdown: "touchstart", pointermove: "touchmove", pointerup: "touchend", pointercancel: "touchcancel" };
    if (!types[event.type]) return null;
    if (event.type === "pointerdown" || (event.type === "pointermove" && inputPoints.has(event.pointerId))) inputPoints.set(event.pointerId, touch);
    else inputPoints.delete(event.pointerId);
    const normalized = { type: types[event.type], source: "pointer", target: event.target,
      touches: [...inputPoints.values()], changedTouches: [touch], cancelable: event.cancelable,
      get defaultPrevented() { return event.defaultPrevented; },
      preventDefault() { event.preventDefault(); },
      stopImmediatePropagation() { event.stopImmediatePropagation(); } };
    inputCache.set(event, normalized);
    return normalized;
  }
  let canonicalNode = node => node, contactSequence = 0;
  const recordCache = new WeakMap();
  const recordIndexes = new WeakMap(), selectionPositionCache = new WeakMap();
  const unitIndexes = new WeakMap(), scrollableCache = new WeakMap();
  const isCalloutUnit = node => ["callout", "plainCallout", "iconCallout"].includes(node.type.name);
  const isWholeCallout = node => isCalloutUnit(node) && !node.attrs.clipSource;
  // Stable DOM markers identify gesture hosts without a permanent node
  // decoration on every block (DecorationSet.forChild scans all local spans).
  const unitSelector = 'p, h1, h2, h3, h4, h5, h6, pre, [data-vellix-block-id], [data-list-grid], .vellix-callout, .vellix-plain-callout, .vellix-table-wrapper';
  const selectableUnit = node => node.isBlock && (node.isTextblock || node.isAtom ||
    node.type.name === "table" || node.type.name === "listGrid" || node.type.name === "tabs" ||
    node.type.name === "minimalFields" || node.type.name === "gridCard" || node.type.name === "informationCard" || isCalloutUnit(node));
  // Tabs and Minimal Fields are a unit AND recurse: the whole block is selectable
  // from its chrome, while the editable text inside each panel/field stays its own
  // unit so it can be selected and edited like any other text.
  const descendUnit = node => (isCalloutUnit(node) && !isWholeCallout(node)) || ["tabs", "minimalFields", "informationCard"].includes(node.type.name);
  const scrollableContent = node => {
    if (isCalloutUnit(node)) return false;
    if (scrollableCache.has(node)) return scrollableCache.get(node);
    const types = ["codeBlock", "table", "collection", "attachment", "pageReference"];
    let found = types.includes(node.type.name);
    // Textblocks only contain inline content, so they cannot contain any of
    // these block-level scrollable surfaces. Avoid walking their text/marks.
    if (!found && !node.isTextblock) node.descendants(child => { if (types.includes(child.type.name)) found = true; return !found; });
    scrollableCache.set(node, found);
    return found;
  };
  const records = (doc, normalize) => {
    if (normalize) canonicalNode = normalize;
    if (recordCache.has(doc)) return recordCache.get(doc);
    const result = [];
    const helper = window.PennedIncrementalNodes;
    if (helper) {
      const index = unitIndexes.get(doc) || helper.createNodeIndex(doc, selectableUnit, descendUnit);
      unitIndexes.set(doc, index);
      for (const { node, pos } of index.records) {
        let path;
        const resolved = () => doc.resolve(pos);
        result.push({ node, pos, index: result.length,
          get path() { return path ||= Array.from({ length: resolved().depth + 1 }, (_, depth) => resolved().index(depth)); },
          get key() { return `path:${this.path.join(".")}`; },
          get json() { return canonicalNode(node.toJSON()); }, type: node.type.name,
          get parentType() { return resolved().parent.type.name; },
          get scrollable() { return scrollableContent(node); } });
      }
    }
    const visit = (parent, parentPos, parentPath) => parent.forEach((node, offset, index) => {
      const pos = parent.type.name === "doc" ? offset : parentPos + 1 + offset;
      const path = [...parentPath, index];
      // Containers keep their hierarchy; their editable children are independent units.
      // Tables and List Grids remain one unit so block actions never detach a cell from its row.
      // Callout text is part of the block unit. Clipped pages keep their own interior controls.
      const unit = selectableUnit(node);
      if (unit) {
        result.push({ node, pos, index: result.length, path, key: `path:${path.join(".")}`,
          get json() { return canonicalNode(node.toJSON()); }, type: node.type.name,
          parentType: parent.type.name,
          get scrollable() { return scrollableContent(node); } });
      }
      if (descendUnit(node) || (!unit && node.isBlock)) visit(node, pos, path);
    });
    if (!helper) visit(doc, 0, []);
    recordCache.set(doc, result);
    recordIndexes.set(doc, { byPosition: new Map(result.map(block => [block.pos, block])),
      byKey: null, byID: null });
    return result;
  };
  const recordAt = (doc, position) => { records(doc); return recordIndexes.get(doc).byPosition.get(position); };
  const selectedPositions = selected => {
    if (!selectionPositionCache.has(selected)) selectionPositionCache.set(selected, new Set(selected.map(item => item.pos)));
    return selectionPositionCache.get(selected);
  };
  const ref = record => ({ pos: record.pos, id: record.node.attrs.id || null });
  const value = () => editor && key?.getState(editor.state);
  const same = (a, b) => a.length === b.length && a.every((item, index) => item.pos === b[index].pos && item.id === b[index].id);
  const canSelect = () => editor?.options.editable !== false && !editor?.view.composing && !window.PennedBlockDragAndDrop?.ownsReorder;
  function mapped(selected, tr) {
    if (!selected.length) return selected;
    records(tr.doc);
    const index = recordIndexes.get(tr.doc);
    // Build the ID lookup only when a mapped position actually needs recovery.
    // Otherwise each selected block could scan the entire document independently.
    const recoverByID = id => {
      if (!index.byID) {
        index.byID = new Map();
        for (const block of records(tr.doc)) {
          const blockID = block.node.attrs.id;
          if (!blockID) continue;
          const matches = index.byID.get(blockID) || [];
          matches.push(block);
          index.byID.set(blockID, matches);
        }
      }
      const matches = index.byID.get(id) || [];
      return matches.length === 1 ? matches[0] : null;
    };
    const seen = new Set();
    const result = [];
    for (const item of selected) {
      const position = tr.mapping.mapResult(item.pos, 1);
      let record = !position.deleted && recordAt(tr.doc, position.pos);
      if (record && item.id && record.node.attrs.id !== item.id) record = null;
      if (!record && item.id) record = recoverByID(item.id);
      if (record && !seen.has(record.pos)) {
        seen.add(record.pos);
        result.push(ref(record));
      }
    }
    return result;
  }
  function mappedRange(range, tr) {
    if (!range) return null;
    const anchor = mapped([range.anchor], tr)[0], head = mapped([range.head], tr)[0];
    return anchor && head ? { anchor, head, base: mapped(range.base, tr) } : null;
  }
  function update(patch, haptic = false, source = "internal", details = {}) {
    const state = value();
    if (!state) return false;
    const entering = state.mode === "off" && (patch.mode || state.mode) !== "off" && (patch.selected || state.selected).length > 0;
    const committing = patch.gesture?.committed && !state.gesture?.committed;
    if (entering || committing || source === "click") {
      const owner = window.PennedBlockDragAndDrop;
      if (!owner || !owner.authorizeSelection(source, details)) return false;
    }
    editor.view.dispatch(editor.state.tr.setMeta(key, { ...patch, haptic, entryAuthorized: entering, entrySource: source }).setMeta("addToHistory", false));
    return true;
  }
  function setMode(mode) {
    if (!value()) return false;
    if (["single", "multi"].includes(mode) && !canSelect()) {
      window.PennedBlockDragAndDrop?.diagnostic('selection-command-rejected', { source: 'command:set-mode', reason: 'selection-disabled-or-reorder-owned' });
      return false;
    }
    controller?.cancelPending();
    const next = ["single", "multi"].includes(mode) && canSelect() ? mode : "off";
    if (next !== "off") window.PennedBlockDragAndDrop?.diagnostic('selection-mode-request', { source: 'command:set-mode' });
    return update({ mode: next, selected: next === "off" ? [] : value().selected, range: null, gesture: null, click: null }, false, "command:set-mode");
  }
  function fromKey(name) {
    records(editor.state.doc);
    const index = recordIndexes.get(editor.state.doc);
    index.byKey ||= new Map(records(editor.state.doc).map(block => [block.key, block]));
    return index.byKey.get(name);
  }
  function changeKey(name, selected) {
    const record = fromKey(name), state = value();
    if (!record || !state) return;
    const next = state.selected.filter(item => item.pos !== record.pos);
    if (selected) next.push(ref(record));
    const collapsed = collapseNested(next);
    update({ selected: collapsed.sort((a, b) => a.pos - b.pos), range: null,
      ...(selected && collapsed.length && state.mode === "off" ? { mode: "multi" } : {}),
      ...(state.selected.length && !collapsed.length ? { mode: "off", gesture: null, click: null } : {}) }, false, "command:selection-facade");
  }
  const facade = {
    get size() { return value()?.selected.length || 0; },
    has(name) { const record = editor && fromKey(name), state = value(); return !!record && !!state && selectedPositions(state.selected).has(record.pos); },
    add(name) { changeKey(name, true); return this; },
    delete(name) { const had = this.has(name); changeKey(name, false); return had; },
    clear() {
      const state = value();
      if (state && (state.selected.length || state.mode !== "off")) setMode("off");
    },
    *[Symbol.iterator]() {
      const state = value();
      if (state) { const selected = selectedPositions(state.selected); for (const record of records(editor.state.doc)) if (selected.has(record.pos)) yield record.key; }
    },
  };
  // A selection must never hold both a callout and a card inside it: block
  // actions delete/replace by stale position and would run past the callout.
  // Keep the outermost of any nested pair.
  function collapseNested(items) {
    if (!items || items.length < 2) return items || [];
    const doc = editor.state.doc;
    const spans = items.map(item => {
      const record = recordAt(doc, item.pos);
      return { item, from: item.pos, to: item.pos + (record ? record.node.nodeSize : 1) };
    });
    return spans.filter(span => !spans.some(other =>
      other !== span && other.from <= span.from && span.to <= other.to &&
      (other.from !== span.from || other.to !== span.to))).map(span => span.item);
  }
  function rangeSelection(range, target, visible) {
    const blocks = records(editor.state.doc);
    const origin = recordAt(editor.state.doc, range.anchor.pos)?.index ?? -1;
    const end = recordAt(editor.state.doc, target.pos)?.index ?? -1;
    if (origin < 0 || end < 0) return range.base;
    const byPosition = new Map(range.base.map(item => [item.pos, item]));
    // Iterate the original registry instead of allocating a sliced array for
    // every movement during an active drag.
    for (let index = Math.min(origin, end); index <= Math.max(origin, end); index++) {
      const block = blocks[index];
      if (visible(block)) byPosition.set(block.pos, ref(block));
    }
    return collapseNested([...byPosition.values()].sort((a, b) => a.pos - b.pos));
  }
  function blockedTarget(target, block) {
    if (!(target instanceof Element)) return true;
    // Tabs: a swipe on the editable panel content selects text as usual; a swipe
    // on the bar, header, tab buttons or padding selects the whole tabs block.
    const tabsHost = target.closest(".penned-tabs");
    if (tabsHost && tabsHost === block) return !!target.closest(".penned-tab-panel");
    // Minimal Fields: a swipe on the editable title, label or value selects text;
    // a swipe on the accent rail, gaps or padding selects the whole block.
    const minimalHost = target.closest(".penned-minimal-fields");
    if (minimalHost && minimalHost === block) return !!target.closest(".penned-minimal-title, .penned-minimal-label, .penned-minimal-value");
    const infoCard = target.closest(".penned-information-card");
    if (infoCard === block && target.closest(".penned-information-card-title, .penned-information-card-description, .penned-information-card-body")) return true;
    const grid = target.closest("[data-list-grid]");
    if (grid && grid !== block && block.contains(grid)) return true;
    const control = target.closest("button, a, input, textarea, select, audio, video, iframe, [role='button'], .vellix-table-resizers, .vellix-table-cell-menu");
    // The code viewer's button is the block itself, not an embedded control.
    const codeBlockSurface = control === block && block.matches(".penned-code-viewer");
    if (control && !control.matches(".vellix-page-reference-button, .penned-file-card, .vellix-property-name, .vellix-property-control, .penned-rich-link-preview") &&
        !codeBlockSurface &&
        !(control.matches("a[href]") && control.closest("p, h1, h2, h3, h4, h5, h6, [data-type='caption']") && value()?.mode !== "off")) return true;
    // The grid itself is the swipe target, including both editable columns.
    if (grid === block) return false;
    for (let element = target; element && element !== block.parentElement; element = element.parentElement) {
      if (element.scrollWidth > element.clientWidth + 2 && /auto|scroll/.test(getComputedStyle(element).overflowX)) return true;
    }
    return false;
  }
  function textSelectionActive() {
    const dom = window.getSelection();
    return (!editor.state.selection.empty && !editor.state.selection.node) ||
      !!(dom && !dom.isCollapsed && dom.toString().length && editor.view.dom.contains(dom.anchorNode));
  }

  function adaptiveSelectionPaint(view) {
    const document = view.dom.ownerDocument;
    const sheet = document.createElement("style");
    document.head.appendChild(sheet);
    const black = [0, 0, 0], white = [255, 255, 255];
    const parsed = new Map();
    let canvasContext, frame = null, palettes = new WeakMap();
    const rgb = (color, alpha = 1) => `rgba(${color.slice(0, 3).map(Math.round).join(",")},${alpha})`;
    const mix = (a, b, amount) => a.slice(0, 3).map((channel, index) => channel + (b[index] - channel) * amount);
    const luminance = color => [0.2126, 0.7152, 0.0722].reduce((sum, weight, index) => {
      const value = color[index] / 255;
      return sum + weight * (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    }, 0);
    const contrast = (a, b) => {
      const x = luminance(a) + 0.05, y = luminance(b) + 0.05;
      return Math.max(x, y) / Math.min(x, y);
    };
    const endpoint = color => contrast(color, black) > contrast(color, white) ? black : white;
    const tone = (base, ratio) => {
      const target = endpoint(base);
      let low = 0, high = 1;
      for (let i = 0; i < 10; i++) {
        const mid = (low + high) / 2;
        if (contrast(base, mix(base, target, mid)) < ratio) low = mid;
        else high = mid;
      }
      return mix(base, target, high);
    };
    function color(raw) {
      if (parsed.has(raw)) return parsed.get(raw);
      let value = null;
      const rgba = raw.match(/^rgba?\((\d+(?:\.\d+)?)[, ]+(\d+(?:\.\d+)?)[, ]+(\d+(?:\.\d+)?)(?:[, /]+(\d+(?:\.\d+)?))?\)$/i);
      if (rgba) value = [+rgba[1], +rgba[2], +rgba[3], rgba[4] === undefined ? 1 : +rgba[4]];
      else if (/^#[\da-f]{6}$/i.test(raw)) value = [1, 3, 5].map(i => Number.parseInt(raw.slice(i, i + 2), 16)).concat(1);
      else if (raw === "transparent") value = [0, 0, 0, 0];
      else if (raw && raw !== "initial" && CSS.supports("color", raw)) {
        // Let WebKit resolve wide-gamut and CSS function colors. This canvas
        // contains only one solid swatch; it never reads images or the editor.
        if (!canvasContext) {
          const swatch = document.createElement("canvas");
          swatch.width = swatch.height = 1;
          canvasContext = swatch.getContext("2d", { willReadFrequently: true });
        }
        if (canvasContext) {
          canvasContext.clearRect(0, 0, 1, 1);
          canvasContext.fillStyle = "transparent";
          canvasContext.fillStyle = raw;
          canvasContext.fillRect(0, 0, 1, 1);
          const [r, g, b, a] = canvasContext.getImageData(0, 0, 1, 1).data;
          value = [r, g, b, a / 255];
        }
      }
      if (parsed.size >= 128) parsed.clear();
      parsed.set(raw, value);
      return value;
    }

    function paint() {
      frame = null;
      const selected = key.getState(view.state)?.selected;
      if (!selected?.length) { if (sheet.textContent) sheet.textContent = ""; return; }
      const root = getComputedStyle(document.documentElement);
      const paper = color(root.getPropertyValue("--vellix-page-background").trim());
      const fallback = {
        color: paper?.[3] === 1 ? paper : root.colorScheme === "light" ? white : [36, 36, 36],
        complex: paper?.[3] !== 1,
      };
      const samples = new WeakMap();
      function surface(element) {
        if (!element) return fallback;
        if (samples.has(element)) return samples.get(element);
        const style = getComputedStyle(element);
        // The selected callout uses an opaque adaptive fill. Its authored
        // background token remains unchanged and avoids sampling our own paint.
        const own = (element.matches(".penned-callout-block-selected") && color(style.getPropertyValue("--penned-grid-bg").trim()))
          || color(style.backgroundColor);
        const parent = own?.[3] === 1 ? fallback : surface(element.parentElement);
        const sample = { color: own ? mix(parent.color, own, own[3]) : parent.color,
          complex: style.backgroundImage !== "none" || (own?.[3] !== 1 && parent.complex) };
        samples.set(element, sample);
        return sample;
      }
      const rules = [];
      for (const { pos } of selected) {
        const element = view.nodeDOM(pos);
        if (!(element instanceof HTMLElement) || !element.classList.contains("penned-block-selected")) continue;
        const selector = `[data-penned-selection-paint="${pos}"]`;
        const parent = element.parentElement;
        const wrapper = parent?.matches(".vellix-blockquote-content, .vellix-callout-text, .vellix-plain-callout-text") &&
          parent.childElementCount === 1 && !element.matches(".vellix-page-reference, [data-list-grid], [data-vellix-divider], .vellix-property")
          ? parent.parentElement : null;
        const outlineTarget = wrapper ? `,${wrapper.localName}:has(> :is(.vellix-blockquote-content, .vellix-callout-text, .vellix-plain-callout-text) > ${selector}:only-child)` : "";
        let palette = palettes.get(element);
        if (!palette) {
          const panel = wrapper || element.querySelector(":scope > .vellix-page-reference-button, :scope > .penned-label-tile") || element;
          const original = surface(panel), outside = surface(panel.parentElement);
          const callout = element.classList.contains("penned-callout-block-selected");
          const artwork = original.complex || element.matches(".penned-attachment, [data-divider-style='washiTape'], .vellix-page-card, .tableWrapper, .vellix-table-wrapper") ||
            !!element.querySelector(":scope > img, :scope > video, :scope > figure");
          const veilInk = endpoint(original.color);
          const ink = color(getComputedStyle(panel).color);
          const tinted = mix(original.color, veilInk, 0.10);
          const veil = !artwork && (!ink || contrast(mix(tinted, ink, ink[3]), tinted) >= 4.5) ? 0.10 : 0;
          const fill = callout ? tone(original.color, 1.7) : mix(original.color, veilInk, veil);
          const innerEdge = artwork ? white : tone(fill, 3.25);
          const outerEdge = artwork || outside.complex ? black : tone(outside.color, 3.25);
          const authoredInk = callout ? color(getComputedStyle(element).getPropertyValue("--penned-callout-text").trim()) : null;
          const calloutInk = authoredInk?.[3] === 1 && contrast(authoredInk, fill) >= 4.5 ? authoredInk : endpoint(fill);
          palette = `--penned-block-edge:${rgb(innerEdge)};--penned-block-outer-edge:${rgb(outerEdge)};` +
            `--penned-block-veil:${rgb(veilInk, veil)};` +
            (callout ? `--penned-callout-selection-fill:${rgb(fill)};--penned-callout-selection-ink:${rgb(calloutInk)};` : "");
          palettes.set(element, palette);
        }
        rules.push(`${selector}${outlineTarget}{${palette}}`);
      }
      const css = rules.join("");
      if (sheet.textContent !== css) sheet.textContent = css;
    }
    const schedule = (invalidate = false) => {
      if (invalidate) palettes = new WeakMap();
      if (frame === null) frame = requestAnimationFrame(paint);
    };
    const appearance = new MutationObserver(() => {
      if (key.getState(view.state)?.selected.length) schedule(true);
    });
    appearance.observe(document.documentElement, { attributes: true, attributeFilter: ["style", "data-penned-document-scheme"] });
    return { schedule, destroy() { appearance.disconnect(); if (frame !== null) cancelAnimationFrame(frame); sheet.remove(); } };
  }

  function createView(view, post) {
    const bindings = new Map();
    const boundNodes = new WeakMap();
    let lastMode, lastCount, lastCollectionSelection, lastHaptic = 0, destroyed = false, contactElement = null, pendingContact = null, releaseTarget = null;
    let scrollToken = null;
    let bindingsDoc = null, bindingsDirty = true, bindingGeneration = 0, lastSelectedDoc = null, lastSelected = null;
    let pendingBindingChanges = [], pendingBindingDoc = null;
    const removedBindingElements = new Set();
    // Resolve a gesture host at contact time. Inline typing shifts the model
    // offsets of every following block but doesn't change their DOM handlers.
    const bindingPosition = element => {
      if (!view.dom.contains(element)) return null;
      let position;
      try { position = view.posAtDOM(element, 0); } catch { return null; }
      const doc = view.state.doc;
      const resolved = doc.resolve(Math.max(0, Math.min(position, doc.content.size)));
      const candidates = [position, position - 1];
      for (let depth = resolved.depth; depth > 0; depth--) candidates.push(resolved.before(depth));
      for (const pos of candidates) {
        if (pos < 0 || pos >= doc.content.size || view.nodeDOM(pos) !== element) continue;
        const node = doc.nodeAt(pos);
        if (!node || !selectableUnit(node)) continue;
        const at = doc.resolve(pos);
        let allowed = true;
        for (let depth = at.depth; depth > 0; depth--) {
          const ancestor = at.node(depth);
          if (selectableUnit(ancestor) && !descendUnit(ancestor)) { allowed = false; break; }
        }
        if (allowed) return pos;
      }
      return null;
    };
    const attachBinding = element => {
      if (bindings.has(element)) return;
      const binding = { generation: bindingGeneration };
      const input = handler => event => { const contact = contactEvent(event); if (contact) handler(contact, element); };
      const handlers = {
        [inputNames.start]: input(start),
        [inputNames.move]: input(move),
        [inputNames.end]: input(end),
        [inputNames.cancel]: input(cancel),
        contextmenu: cancel,
        click: event => click(event, element),
      };
      for (const [name, handler] of Object.entries(handlers)) element.addEventListener(name, handler,
        { capture: true, passive: name === inputNames.start || name === inputNames.cancel || name === "contextmenu" });
      binding.remove = () => {
        for (const [name, handler] of Object.entries(handlers)) element.removeEventListener(name, handler, true);
      };
      bindings.set(element, binding);
    };
    const detachBinding = element => {
      const binding = bindings.get(element);
      if (binding && element !== contactElement) { binding.remove(); bindings.delete(element); }
    };
    const seenEvents = new WeakSet();
    const style = document.createElement("style");
    style.textContent = `
      .vellix-editor-page:has(.penned-mobile-block-layout) {
        --penned-selection-gutter: \#(selectionGutter)px;
        box-sizing: border-box; padding-inline: var(--penned-selection-gutter);
        max-width: calc(720px + var(--penned-selection-gutter) + var(--penned-selection-gutter));
      }
      .penned-mobile-block-layout { --penned-block-gap: 10px; }
      .tiptap-editor.penned-mobile-block-layout { padding-top: 6px !important; }
      .tiptap-editor.penned-mobile-block-layout > .penned-list-grid {
        --penned-grid-outset: min(4px, var(--penned-selection-gutter, 0px));
        width: calc(100% + var(--penned-grid-outset) + var(--penned-grid-outset));
        max-width: none;
        margin-inline: calc(-1 * var(--penned-grid-outset));
      }
      .penned-mobile-block-layout > :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-block: 0 !important; }
      .penned-mobile-block-layout > :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) + :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout > .vellix-property + .vellix-property { margin-top: 4px !important; }
      .penned-mobile-block-layout :is(.vellix-toggle-content, .vellix-blockquote-content, li) > * { margin-block: 0 !important; }
      .penned-mobile-block-layout :is(.vellix-toggle-content, .vellix-blockquote-content, li:not([data-type="taskItem"])) > * + * { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout :is(ul, ol) > li { margin-block: 0 !important; }
      .penned-mobile-block-layout :is(ul, ol) > li + li { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout > :is(.vellix-callout, .vellix-plain-callout):has(+ :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-bottom: 20px !important; }
      .penned-mobile-block-layout > :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break]) + :is(.vellix-callout, .vellix-plain-callout) { margin-top: 20px !important; }
      .penned-mobile-block-layout :is(p, h1, h2, h3, h4, h5, h6, pre, [data-vellix-block-id], .vellix-callout, .vellix-plain-callout, .vellix-table-wrapper) { transition: transform 120ms ease-out; }
      .penned-mobile-block-layout :is(p, h1, h2, h3, h4, h5, h6, [data-vellix-block-id], .vellix-callout, .vellix-plain-callout):not(:is(pre, .penned-collection, .penned-attachment, .vellix-page-reference)):not(:is(pre *, .vellix-table-wrapper *, .penned-collection *, .penned-attachment *, .vellix-page-reference *)) { touch-action: pan-y pinch-zoom; }
      .penned-block-selected { position: relative; outline: none !important; }
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child) { position: relative; }
      .penned-block-selected::after,
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference, [data-list-grid], [data-vellix-divider], .vellix-property))::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference, [data-list-grid], [data-vellix-divider], .vellix-property))::after,
      blockquote:has(> .vellix-blockquote-content > .penned-block-selected:only-child:not([data-list-grid], [data-vellix-divider], .vellix-property))::after,
      .penned-block-selected.vellix-page-reference > .vellix-page-reference-button::after {
        content: ""; position: absolute; inset: -3px calc(-1 * var(--penned-selection-gutter)); pointer-events: none;
        border-radius: 8px; background: var(--penned-block-veil, transparent);
        box-shadow: inset 0 0 0 2px var(--penned-block-edge, light-dark(#25252b, #eeeeef)),
          0 0 0 1px var(--penned-block-outer-edge, transparent);
      }
      .penned-block-selected:is(pre, .penned-template-component)::after { inset: 0; border-radius: 16px; }
      .penned-block-selected:is(.vellix-callout, .vellix-plain-callout, [data-list-grid], .penned-tabs)::after { inset: 0; border-radius: inherit; }
      .penned-block-selected.penned-rich-link[data-link-layout="card"]::after { inset: 0; border-radius: inherit; }
      .penned-block-selected[data-vellix-divider]::after { display: none; }
      .penned-block-selected[data-vellix-divider] :is(.vellix-divider-line, .vellix-divider-dots, .vellix-divider-four-circles) {
        outline: 2px solid var(--penned-block-edge, light-dark(#25252b, #eeeeef)); outline-offset: 5px; border-radius: 999px;
        box-shadow: 0 0 0 5px var(--penned-block-veil, transparent);
      }
      .penned-block-selected[data-vellix-divider] .vellix-divider-four-circles { border-radius: 5px; }
      .penned-block-selected[data-vellix-divider] .vellix-divider-tape::before {
        /* Both strokes stay inside the cut shape. */
        content: ""; position: absolute; inset: 0; pointer-events: none;
        border-block: 2px solid var(--penned-block-edge, #ffffff); box-sizing: border-box; z-index: 1;
        box-shadow: inset 0 1px var(--penned-block-outer-edge, #000000), inset 0 -1px var(--penned-block-outer-edge, #000000);
      }
      .penned-block-selected.vellix-property::after {
        --property-paint-inset: 5px;
        inset: calc(var(--property-paint-inset) + var(--property-page-top, 0px)) 0
          calc(var(--property-paint-inset) + var(--property-page-bottom, 0px));
      }
      .penned-block-selected.vellix-property:has(.vellix-property-text)::after { --property-paint-inset: 9px; }
      .penned-mobile-block-layout > :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break]) + .vellix-property { --property-page-top: 20px; }
      .penned-mobile-block-layout > .vellix-property:has(+ :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { --property-page-bottom: 20px; }
      .penned-block-selected:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])::after {
        inset: 50% 0 auto; height: 2px; background: var(--penned-block-edge, light-dark(#25252b, #eeeeef)); box-shadow: none;
      }
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference, [data-list-grid], [data-vellix-divider], .vellix-property))::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference, [data-list-grid], [data-vellix-divider], .vellix-property))::after,
      blockquote:has(> .vellix-blockquote-content > .penned-block-selected:only-child:not([data-list-grid], [data-vellix-divider], .vellix-property))::after { inset: 0; border-radius: inherit; }
      .vellix-callout-text > .penned-block-selected:only-child:not([data-list-grid], .vellix-property)::after,
      .vellix-plain-callout-text > .penned-block-selected:only-child:not([data-list-grid], .vellix-property)::after,
      .vellix-blockquote-content > .penned-block-selected:only-child:not([data-list-grid], .vellix-property)::after,
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper, .vellix-page-reference)::after { display: none; }
      .penned-block-selected.vellix-page-reference > .vellix-page-reference-button { position: relative; }
      .penned-block-selected.vellix-page-card > .vellix-page-reference-button::after { inset: 0; border-radius: inherit; }
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper) :is(td, th) { box-shadow: inset 0 0 0 9999px var(--penned-block-veil, transparent); }
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper) table {
        outline: 2px solid var(--penned-block-edge, light-dark(#25252b, #eeeeef)) !important; outline-offset: -2px;
        box-shadow: 0 0 0 1px var(--penned-block-outer-edge, transparent);
      }
      .penned-block-selection-active { caret-color: transparent; }
      .tiptap-editor .penned-callout-block-selected {
        --vellix-primary-text: var(--penned-callout-selection-ink, var(--penned-callout-text, var(--penned-grid-ink))) !important;
        background-color: var(--penned-callout-selection-fill, var(--penned-grid-bg)) !important;
        color: var(--vellix-primary-text) !important;
      }
      .tiptap-editor .penned-callout-block-selected::after {
        inset: 0; border-radius: inherit; background: none;
      }
      .tiptap-editor .penned-callout-block-selected > :is(.vellix-callout-text, .vellix-plain-callout-text),
      .tiptap-editor .penned-callout-block-selected :is(p, h1, h2, h3, h4, h5, h6, [data-vellix-caption]),
      .tiptap-editor .penned-callout-block-selected :is(p, h1, h2, h3, h4, h5, h6, [data-vellix-caption]) * {
        color: var(--penned-callout-selection-ink, var(--vellix-primary-text)) !important;
      }
      /* WebKit inherits user-select from the editor surface. Apply it once at
         the gesture root rather than matching every block on first swipe. */
      .penned-block-selection-active,
      .penned-block-selection-arming { -webkit-user-select: none; user-select: none; }
      .tiptap-editor:is(.penned-block-selection-active, .penned-block-selection-arming) .penned-list-grid[data-list-grid],
      .tiptap-editor:is(.penned-block-selection-active, .penned-block-selection-arming) .penned-list-grid[data-list-grid] * {
        -webkit-user-select: none !important; user-select: none !important;
      }
      .tiptap-editor.penned-block-selection-active .penned-block-selected,
      .tiptap-editor.penned-block-selection-active .penned-block-selected * { touch-action: none !important; }
      @media (prefers-reduced-motion: reduce) { .penned-mobile-block-layout :is(p, h1, h2, h3, h4, h5, h6, pre, [data-vellix-block-id], .vellix-callout, .vellix-plain-callout, .vellix-table-wrapper) { transition: none !important; } }
    `;
    document.head.appendChild(style);
    view.dom.classList.add("penned-mobile-block-layout");
    const selectionPaint = adaptiveSelectionPaint(view);
    const cancelPending = () => { pendingContact = null; };
    const stopScrolling = () => {
      if (scrollToken === null) return;
      const token = scrollToken;
      scrollToken = null;
      post("blockSelectionDrag", { token, active: false });
    };
    const cancel = (cause = "selection-contact-cancelled") => {
      if (value()?.gesture || pendingContact) {
        window.PennedBlockDragAndDrop?.diagnostic('selection-contact-ended', {
          source: typeof cause === 'string' ? cause : cause?.type || 'event',
          phase: value()?.gesture?.phase || 'pending', committed: value()?.gesture?.committed === true });
      }
      stopScrolling();
      cancelPending();
      if (!value()?.selected.length) view.dom.classList.remove("penned-block-selection-arming");
      if (value()?.gesture) update({ gesture: null });
      else { contactElement = null; releaseTarget?.(); }
    };
    const surface = block => {
      const element = view.nodeDOM(block.pos), table = block.type === "table" && element?.querySelector("table");
      return table && table.getBoundingClientRect().height > 0 ? table : element;
    };
    const visible = (block, measuredRect = null) => {
      const element = view.nodeDOM(block.pos);
      if (!(element instanceof HTMLElement) || !view.dom.contains(element)) return false;
      if (element.closest("[hidden]") || (measuredRect || surface(block).getBoundingClientRect()).height <= 0) return false;
      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return false;
      const closed = "[data-vellix-toggle][data-open='false']";
      for (let toggle = element.closest(closed); toggle; toggle = toggle.parentElement?.closest(closed)) {
        const title = toggle.querySelector("[data-vellix-toggle-content]")?.firstElementChild;
        if (title && title !== element && !title.contains(element)) return false;
      }
      return true;
    };
    function targetAt(y, range, dragDirection = 0) {
      // Gaps and block edges are sticky; only entering another block extends the range.
      const blocks = records(view.state.doc);
      const index = recordAt(view.state.doc, range.head.pos)?.index ?? -1;
      if (index < 0) return null;
      let target = blocks[index];
      const current = surface(target)?.getBoundingClientRect();
      if (!current) return target;
      const direction = y > current.bottom ? 1 : y < current.top ? -1 : 0;
      if (dragDirection && direction !== dragDirection) return target;
      const alreadySelected = selectedPositions(value().selected);
      for (let next = index + direction; direction && next >= 0 && next < blocks.length; next += direction) {
        const block = blocks[next], rect = surface(block)?.getBoundingClientRect();
        if (!rect || !visible(block, rect)) continue;
        const inset = alreadySelected.has(block.pos) ? 0 : Math.min(4, rect.height / 4);
        if (direction > 0 ? y < rect.top + inset : y > rect.bottom - inset) break;
        target = block;
      }
      return target;
    }
    function continueDragScroll({ token, revision, y, direction }) {
      const state = value(), gesture = state?.gesture, range = state?.range;
      if (destroyed || !canSelect() || !Number.isFinite(y) || !range || gesture?.token !== token ||
          gesture.phase !== "active" || !gesture.committed || !gesture.extending) return false;
      if (gesture.scrollRevision !== revision || gesture.scroll?.direction !== direction) return true;
      const target = targetAt(y, range, direction);
      if (target && target.pos !== range.head.pos) {
        update({ selected: rangeSelection(range, target, visible), range: { ...range, head: ref(target) } }, true);
      }
      return true;
    }
    function beginPending() {
      const contact = pendingContact;
      pendingContact = null;
      if (!contact || destroyed || !canSelect()) return;
      const state = value(), block = recordAt(view.state.doc, contact.origin.pos);
      if (!block || (contact.origin.id && block.node.attrs.id !== contact.origin.id) || !state || (state.mode === "off" && textSelectionActive())) return;
      const selected = state.selected.some(item => item.pos === block.pos);
      // Only a selected surface resumes a vertical range drag. Unselected
      // surfaces keep native vertical scrolling, even while selection is on.
      const anchor = selected ? ref(block) : null;
      const resume = anchor ? state.range || { anchor, head: anchor,
        base: state.selected.filter(item => item.pos !== anchor.pos) } : null;
      update({ gesture: { phase: "pending", identifier: contact.identifier, origin: ref(block),
        token: contact.token, startScreenY: contact.screenY, scrollRevision: 0,
        x: contact.x, y: contact.y, started: contact.started, dx: 0, base: state.selected,
        selectionActive: state.mode !== "off" && state.selected.length > 0,
        resume, editable: view.editable, committed: false, commitScreenY: null }, click: null });
    }
    function start(event, element) {
      const state = value();
      if (event.touches.length !== 1) { cancel(); return; }
      if (!state || !canSelect() || blockedTarget(event.target, element) ||
          (state.mode === "off" && textSelectionActive()) || editor.state.selection.$anchorCell) return;
      const position = bindingPosition(element);
      if (position === null) return;
      const touch = event.touches[0], block = { pos: position, node: view.state.doc.nodeAt(position) };
      if (window.PennedBlockDragAndDrop?.selectionContact(touch.identifier, event) === false) return;
      window.PennedBlockDragAndDrop?.diagnostic('selection-contact-start', {
        source: event.source || 'touch', identifier: touch.identifier, position, selected: state.selected.some(item => item.pos === position) });
      releaseTarget?.();
      contactElement = element;
      // WebKit keeps the initial touch target even if a mark's inline DOM is
      // detached during input reconciliation. Keep this contact block-local.
      if (!pointerInput && event.target !== element) {
        const target = event.target;
        const handlers = { touchmove: move, touchend: end, touchcancel: cancel, contextmenu: cancel };
        for (const [name, handler] of Object.entries(handlers)) target.addEventListener(name, handler, { capture: true, passive: name === "touchcancel" || name === "contextmenu" });
        releaseTarget = () => {
          for (const [name, handler] of Object.entries(handlers)) target.removeEventListener(name, handler, true);
          releaseTarget = null;
        };
      }
      pendingContact = { identifier: touch.identifier, token: ++contactSequence,
        screenY: Number.isFinite(touch.screenY) ? touch.screenY : touch.clientY, origin: ref(block),
        x: touch.clientX, y: touch.clientY, started: now() };
      // Do not dispatch from touchstart capture: ProseMirror must first flush any
      // uncommitted native typing. Rendering stale state here can erase that input.
      queueMicrotask(beginPending);
    }
    function move(event, element) {
      if (seenEvents.has(event)) return;
      seenEvents.add(event);
      beginPending();
      const state = value(), gesture = state?.gesture;
      if (!gesture || !canSelect()) { cancel(); return; }
      const touch = Array.from(event.touches).find(item => item.identifier === gesture.identifier);
      if (!touch || event.touches.length !== 1 || !event.cancelable) { cancel(); return; }
      const dx = touch.clientX - gesture.x;
      const screenY = Number.isFinite(touch.screenY) ? touch.screenY : touch.clientY;
      const dy = screenY - gesture.startScreenY;
      const verticalResume = gesture.resume && Math.abs(dy) >= 8 && Math.abs(dy) > Math.abs(dx) * 1.1;
      if (!gesture.committed && now() - gesture.started >= (window.PennedBlockDragAndDrop?.holdDurationMS ?? 2000)) { cancel("hold-deadline-passed"); return; }
      if (gesture.phase === "pending") {
        // A completed hold belongs to reordering, even if its native bridge
        // reply is still pending. It must never fall back to range selection.
        if ((!gesture.resume && now() - gesture.started > 320) || (state.mode === "off" && textSelectionActive())) { cancel(); return; }
        if (!verticalResume) {
          if (Math.abs(dy) >= 10 || (Math.abs(dy) >= 8 && Math.abs(dy) >= Math.abs(dx) / 1.8)) { cancel(); return; }
          // Warm the one-time document-wide selection style recalc during the pre-commit
          // window, so it does not stall the first frame of the block tracking the finger.
          if (Math.abs(dx) >= 4 && Math.abs(dx) > Math.abs(dy)) view.dom.classList.add("penned-block-selection-arming");
          if (Math.abs(dx) < (gesture.selectionActive ? 6 : 12) || Math.abs(dx) < Math.abs(dy) * 1.8) return;
          if (dx >= 0) { cancel("right-swipe-not-selection"); return; }
        }
        window.PennedBlockDragAndDrop?.noteSelectionMotion(gesture.identifier);
      }
      // Never attempt to take over a non-cancellable or already-scrolling stream.
      event.preventDefault();
      if (!event.defaultPrevented) { cancel(); return; }
      event.stopImmediatePropagation();
      const resuming = gesture.resuming || (!gesture.committed && verticalResume);
      const committed = gesture.committed || resuming || Math.abs(dx) >= (gesture.selectionActive ? 14 : 24);
      const commitScreenY = gesture.commitScreenY ?? (committed ? screenY : null);
      const extending = gesture.extending || resuming || (committed && Math.abs(screenY - commitScreenY) >= 12);
      const lastY = gesture.directionAnchor ?? (resuming ? gesture.startScreenY : commitScreenY);
      const travel = extending ? screenY - lastY : 0;
      const directed = Math.abs(travel) >= 2;
      const scroll = directed ? { direction: Math.sign(travel), distance: Math.abs(travel) } : gesture.scroll;
      let selected = state.selected, range = state.range;
      if (committed) {
        if (!gesture.committed) range = gesture.resume || { anchor: gesture.origin, head: gesture.origin, base: gesture.base };
        let target = recordAt(view.state.doc, range.head.pos);
        if (extending && directed) target = targetAt(touch.clientY, range, Math.sign(travel));
        if (target) {
          if (!gesture.committed || target.pos !== range.head.pos) selected = rangeSelection(range, target, visible);
          range = { ...range, head: ref(target) };
        }
      }
      const sendScroll = extending && range && scroll?.direction &&
        (scrollToken !== gesture.token || scroll.direction !== gesture.scroll?.direction || Math.abs(screenY - gesture.postedScreenY) >= 0.5);
      const scrollRevision = gesture.scrollRevision + (sendScroll ? 1 : 0);
      if (!update({ mode: committed ? "multi" : state.mode, selected, range,
        gesture: { ...gesture, phase: "active", scroll, scrollRevision, postedScreenY: sendScroll ? screenY : gesture.postedScreenY,
          directionAnchor: directed ? screenY : gesture.directionAnchor,
          dx: resuming ? 0 : Math.max(-56, Math.min(56, dx * 0.6)), committed, resuming, extending, commitScreenY } }, committed,
          resuming ? "range" : "swipe", { identifier: gesture.identifier, dx })) { cancel(); return; }
      if (sendScroll) {
        scrollToken = gesture.token;
        post("blockSelectionDrag", { token: gesture.token, revision: scrollRevision, active: true,
          x: touch.clientX, y: touch.clientY, screenY, direction: scroll.direction, distance: scroll.distance });
      }
    }
    function end(event) {
      if (seenEvents.has(event)) return;
      seenEvents.add(event);
      beginPending();
      const state = value(), gesture = state?.gesture;
      if (!gesture) { cancel(); return; }
      if (!Array.from(event.changedTouches).some(touch => touch.identifier === gesture.identifier)) return;
      if (gesture.phase === "active") {
        if (event.cancelable) event.preventDefault();
        event.stopImmediatePropagation();
        stopScrolling();
        update({ gesture: null, click: { pos: gesture.origin.pos, until: now() + 450 } });
        if (gesture.committed) {
          window.PennedKeyboardTrace?.record("mobile.selection.blur", { source: "touch-commit" }, true);
          view.dom.blur();
        }
      } else cancel();
    }
    function click(event, element) {
      const state = value();
      if (!state || (state.mode === "off" && !state.click)) return;
      const position = bindingPosition(element);
      if (position === null) return;
      if (state?.click?.pos === position && now() < state.click.until) {
        event.preventDefault(); event.stopImmediatePropagation(); update({ click: null }); return;
      }
      if (event.target.closest?.(".penned-information-card-content") && textSelectionActive()) return;
      if (!state || state.mode === "off" || !canSelect() || blockedTarget(event.target, element)) return;
      const block = recordAt(editor.state.doc, position);
      if (!block) return;
      event.preventDefault(); event.stopImmediatePropagation();
      const next = state.mode === "single" ? [] : state.selected.filter(item => item.pos !== position);
      if (!state.selected.some(item => item.pos === position)) next.push(ref(block));
      update({ mode: next.length ? state.mode : "off", selected: next.sort((a, b) => a.pos - b.pos),
        range: null, gesture: null, click: null }, true, "click");
    }
    const selectionDocument = view.dom.ownerDocument;
    // Continue pointer tracking even if typing reconciliation replaced the
    // original inline target. Range math and native autoscroll stay unchanged.
    const pointerContinuation = pointerInput ? [
      [inputNames.move, event => { const contact = contactEvent(event); if (contact && (pendingContact || value()?.gesture)) move(contact, contactElement); }],
      [inputNames.end, event => { const contact = contactEvent(event); if (contact && (pendingContact || value()?.gesture)) end(contact); }],
      [inputNames.cancel, event => { const contact = contactEvent(event); if (contact && (pendingContact || value()?.gesture)) cancel(contact); }],
    ] : [];
    for (const [name, handler] of pointerContinuation) selectionDocument.addEventListener(name, handler, { capture: true, passive: false });
    // Native text ranges remain text ranges. Only the authorized swipe/command
    // paths may enter block selection; selectionchange never promotes a callout.
    function dismissOnBlankClick(event) {
      if (!value()?.selected.length || event.defaultPrevented || event.button !== 0) return;
      const target = event.target;
      if (target !== view.dom && !target.matches?.(".vellix-toggle-content, .vellix-editor-page, .vellix-editor-shell, #editor")) return;
      if (!view.dom.contains(target) && !target.contains(view.dom)) return;
      event.preventDefault();
      setMode("off");
    }
    selectionDocument.addEventListener("click", dismissOnBlankClick);
    function refresh() {
      const state = key.getState(view.state);
      if (!state || !editor) return;
      if (!state.gesture?.committed || !state.gesture.extending || state.mode === "off") stopScrolling();
      if (!state.gesture && !pendingContact) {
        if (contactElement && !contactElement.isConnected) bindingsDirty = true;
        contactElement = null; releaseTarget?.();
      }
      const modeChanged = lastMode !== state.mode;
      if (modeChanged) {
        if (lastMode && lastMode !== "off" && state.mode === "off") {
          window.PennedKeyboardTrace?.record("mobile.selection.blur", { source: "block-selection-exit" }, true);
          view.dom.blur();
          const native = window.getSelection();
          if (native && (view.dom.contains(native.anchorNode) || view.dom.contains(native.focusNode))) native.removeAllRanges();
        }
        mirrorMode?.(state.mode);
        document.documentElement.dataset.vellixSelectionMode = state.mode;
        document.body.dataset.vellixSelectionMode = state.mode;
        view.dom.classList.toggle("penned-block-selection-active", state.mode !== "off");
        lastMode = state.mode;
      }
      // The arming warm-up is only needed before selection commits. Once the editor is
      // fully at rest it must come off, or text would stay unselectable while editing.
      if (state.mode === "off" && !state.gesture && !pendingContact && view.dom.classList.contains("penned-block-selection-arming")) view.dom.classList.remove("penned-block-selection-arming");
      if (modeChanged || lastCount !== state.selected.length) {
        lastCount = state.selected.length;
        post("blockSelectionState", { mode: state.mode, count: lastCount });
      }
      if (modeChanged && state.mode !== "off") window.tiptapCommand?.("dismissSlashMenu");
      if (lastSelectedDoc !== view.state.doc || lastSelected !== state.selected) {
        if (state.selected.length || lastSelected?.length) selectionPaint.schedule(lastSelectedDoc !== view.state.doc);
        const collectionBlockIDs = state.selected.map(item => recordAt(view.state.doc, item.pos))
          .filter(block => block?.type === "collection").map(block => block.node.attrs.id).filter(Boolean);
        const collectionSelection = JSON.stringify(collectionBlockIDs);
        if (lastCollectionSelection !== collectionSelection) {
          lastCollectionSelection = collectionSelection;
          post("blockSelectionSurfaces", { collectionBlockIDs });
        }
        lastSelectedDoc = view.state.doc;
        lastSelected = state.selected;
      }
      if (state.haptic > lastHaptic) post("haptic", { style: "light" });
      lastHaptic = state.haptic;
      if (bindingsDoc === view.state.doc && !bindingsDirty) return;
      const incremental = !bindingsDirty && pendingBindingDoc === view.state.doc;
      bindingsDoc = view.state.doc;
      bindingsDirty = false;
      const changedBindings = pendingBindingChanges;
      pendingBindingChanges = [];
      pendingBindingDoc = null;
      if (incremental) {
        // Bind changed units directly; neither insertion nor replacement needs
        // a document-wide pass. Mutation records handle removed DOM targets.
        for (const block of changedBindings) {
          const element = view.nodeDOM(block.pos);
          if (element instanceof HTMLElement) {
            boundNodes.set(block.node, element);
            attachBinding(element);
          }
        }
        for (const element of removedBindingElements) detachBinding(element);
        removedBindingElements.clear();
        return;
      }
      // Mark bindings with a generation instead of allocating a document-sized
      // live-element Set every time ProseMirror updates the rendered nodes.
      const generation = ++bindingGeneration;
      for (const block of records(view.state.doc)) {
        const cachedElement = boundNodes.get(block.node);
        const cachedBinding = cachedElement && bindings.get(cachedElement);
        const element = cachedElement?.isConnected && cachedBinding?.generation !== generation
          ? cachedElement : view.nodeDOM(block.pos);
        if (!(element instanceof HTMLElement)) continue;
        boundNodes.set(block.node, element);
        const existing = bindings.get(element);
        if (existing) { existing.generation = generation; continue; }
        attachBinding(element);
        bindings.get(element).generation = generation;
      }
      for (const [element, binding] of bindings) if (binding.generation !== generation && element !== contactElement) {
        binding.remove(); bindings.delete(element);
      }
    }
    // Gesture metadata does not replace block DOM; actual NodeView churn still rebinds.
    const observer = new MutationObserver(mutations => {
      if (destroyed) return;
      // Inline formatting can replace spans inside an already-bound textblock.
      // Those changes do not replace the block's gesture target and must not
      // trigger a document-wide rebinding pass. Structural changes still do.
      const changesSelectableBlock = node => node.nodeType === 1 &&
        (node.matches?.(unitSelector) || node.querySelector?.(unitSelector));
      let needsRebind = false;
      for (const mutation of mutations) {
        const insideBoundBlock = mutation.target instanceof Element &&
          mutation.target.closest(unitSelector);
        if (!insideBoundBlock) {
          for (const node of mutation.addedNodes) if (node.nodeType === 1) { needsRebind = true; break; }
          if (!needsRebind) for (const node of mutation.removedNodes) if (node.nodeType === 1) { needsRebind = true; break; }
        } else {
          for (const node of mutation.addedNodes) if (changesSelectableBlock(node)) { needsRebind = true; break; }
          if (!needsRebind) for (const node of mutation.removedNodes) if (changesSelectableBlock(node)) { needsRebind = true; break; }
        }
        if (needsRebind) break;
      }
      if (!needsRebind) return;
      // Reconcile only nodes in mutated subtrees. Stable DOM markers are only
      // candidates; verify their selectable model position before attaching.
      const reconcile = element => {
        if (!(element instanceof HTMLElement) || !view.dom.contains(element) ||
            !element.matches(unitSelector)) return;
        if (bindingPosition(element) !== null) attachBinding(element);
      };
      for (const mutation of mutations) {
        for (const node of mutation.removedNodes) {
          if (!(node instanceof Element)) continue;
          if (bindings.has(node)) removedBindingElements.add(node);
          node.querySelectorAll?.(unitSelector).forEach(element => {
            if (bindings.has(element)) removedBindingElements.add(element);
          });
        }
        for (const node of mutation.addedNodes) {
          if (!(node instanceof Element)) continue;
          reconcile(node);
          node.querySelectorAll?.(unitSelector).forEach(reconcile);
        }
      }
      for (const element of removedBindingElements) if (!view.dom.contains(element)) detachBinding(element);
      removedBindingElements.clear();
    });
    observer.observe(view.dom, { childList: true, subtree: true });
    controller = { refresh, cancelPending, cancel, scroll: continueDragScroll, classifyContact(target) {
      if (!canSelect() || (value()?.mode === "off" && textSelectionActive())) return { eligible: false };
      for (let element = target; element && element !== view.dom; element = element.parentElement) {
        if (!bindings.has(element)) continue;
        const position = bindingPosition(element);
        if (position === null || blockedTarget(target, element)) continue;
        return { eligible: true, selected: value().selected.some(item => item.pos === position) };
      }
      return { eligible: false };
    }, skipInlineRebind(tr) {
      if (bindingsDirty || bindingsDoc !== tr.before || pendingContact || contactElement) return false;
      bindingsDoc = tr.doc;
      return true;
    }, mapPending(tr) {
      if (tr.docChanged) {
        const helper = window.PennedIncrementalNodes;
        const index = helper && unitIndexes.get(tr.doc);
        if (!index) {
          // The initial document or a missing index still uses the one-time
          // complete binding pass. Normal edits use the indexed delta.
          bindingsDirty = true;
          pendingBindingChanges = [];
          pendingBindingDoc = null;
        } else {
          // Map handler positions without querying DOM. If several transactions
          // arrive before the view refresh, carry earlier changes forward too.
          const carried = pendingBindingDoc === tr.before ? pendingBindingChanges.flatMap(block => {
            const mappedPosition = tr.mapping.mapResult(block.pos, 1);
            if (mappedPosition.deleted) return [];
            const record = recordAt(tr.doc, mappedPosition.pos);
            return record ? [record] : [];
          }) : [];
          pendingBindingChanges = [...carried, ...index.changed];
          pendingBindingDoc = tr.doc;
        }
      }
      if (!pendingContact) return;
      const origin = mapped([pendingContact.origin], tr)[0];
      pendingContact = origin ? { ...pendingContact, origin } : null;
    } };
    return { update: refresh, destroy() {
      destroyed = true; stopScrolling(); cancelPending(); releaseTarget?.(); observer.disconnect();
      for (const [name, handler] of pointerContinuation) selectionDocument.removeEventListener(name, handler, true);
      inputPoints.clear();
      selectionDocument.removeEventListener("click", dismissOnBlankClick);
      selectionPaint.destroy();
      for (const binding of bindings.values()) binding.remove();
      bindings.clear(); view.dom.classList.remove("penned-mobile-block-layout"); style.remove(); controller = null;
    } };
  }
  window.PennedBlockSelection = {
    inputNames, contactEvent,
    clearContactInput() { inputPoints.clear(); },
    classifyContactAtPoint({ x, y, width }) {
      const scale = window.innerWidth / width;
      return controller?.classifyContact(document.elementFromPoint(x * scale, y * scale)) ?? { eligible: false };
    },
    get hasActiveGesture() { return value()?.gesture?.phase === "active"; },
    records, selectionFacade: () => facade,
    formattingTarget: () => value()?.formattingTarget ?? null,
    selectedRecords() {
      return (value()?.selected || []).map(item => recordAt(editor.state.doc, item.pos)).filter(Boolean);
    },
    recordAtPosition(position) { return recordAt(editor.state.doc, position); },
    continueDragScroll: payload => controller?.scroll(payload) ?? false,
    cancelGestureForReorder() { controller?.cancel(); },
    transformSelectedNested(transform, includeTopLevel = false) {
      const state = value();
      if (!state?.selected.length) return undefined;
      const positions = selectedPositions(state.selected);
      const selected = records(editor.state.doc).filter(block => positions.has(block.pos));
      if (!includeTopLevel && !selected.some(block => block.path.length > 1)) return undefined;
      // Converting selected list entries to a callout must wrap the list as a
      // block, not replace the required paragraph within each listItem.
      const firstTarget = transform(selected[0].json, selected[0]);
      if (["plainCallout", "callout"].includes(firstTarget?.type) && selected.some(block => block.parentType === "listItem")) {
        const doc = editor.state.doc;
        const topLevel = new Map();
        for (const block of selected) {
          const resolved = doc.resolve(block.pos);
          const topIndex = resolved.index(0);
          const topNode = doc.child(topIndex);
          if (!topLevel.has(topIndex)) topLevel.set(topIndex, { index: topIndex, node: topNode });
        }
        const indices = [...topLevel.keys()].sort((a,b) => a-b);
        if (indices.some((index, i) => i && index !== indices[i-1] + 1)) {
          post("error", { message: "Select adjacent blocks to put them in one callout." });
          return false;
        }
        const from = indices.slice(0, 1).reduce((pos, index) => {
          let offset = 0; for (let i = 0; i < index; i++) offset += doc.child(i).nodeSize;
          return offset;
        }, 0);
        const to = from + indices.reduce((size, index) => size + doc.child(index).nodeSize, 0);
        const contents = indices.map(index => doc.child(index).toJSON());
        const callout = editor.schema.nodeFromJSON({
          type: firstTarget.type,
          attrs: { id: crypto.randomUUID(), color: firstTarget.attrs?.color || "#ffffff",
            ...(firstTarget.type === "callout" ? { icon: firstTarget.attrs?.icon || "sparkle" } : {}) },
          content: contents
        });
        callout.check();
        let transaction = closeHistory(editor.state.tr);
        transaction.replaceWith(from, to, callout);
        transaction.doc.check();
        transaction.setMeta(key, { selected: [{ pos: from, id: callout.attrs.id }], range: null, gesture: null, click: null });
        if (includeTopLevel) transaction.setMeta("pennedStyleConversion", true);
        editor.view.dispatch(transaction);
        editor.view.dispatch(closeHistory(editor.state.tr));
        return true;
      }
      const replacements = selected.map(block => ({ block, node: editor.schema.nodeFromJSON(transform(block.json, block)) }));
      for (const { block, node } of replacements) {
        node.check();
        const parent = editor.state.doc.resolve(block.pos);
        if (!parent.parent.canReplaceWith(parent.index(), parent.index() + 1, node.type, node.marks)) {
          post("error", { message: "This block type is not supported inside this container." });
          return false;
        }
      }
      let transaction = closeHistory(editor.state.tr);
      for (const { block, node } of replacements.slice().reverse()) {
        if (!block.node.eq(node)) transaction.replaceWith(block.pos, block.pos + block.node.nodeSize, node);
      }
      if (!transaction.docChanged) return true;
      transaction.doc.check();
      // Select the replacement in the same transaction. A converted block may
      // now be a list or toggle whose selectable unit is its first text block.
      const next = replacements.flatMap(({ block, node }) => {
        const start = transaction.mapping.map(block.pos, -1);
        let unit = recordAt(transaction.doc, start);
        if (!unit) node.descendants((_child, offset) => {
          unit ||= recordAt(transaction.doc, start + 1 + offset);
          return !unit;
        });
        return unit ? [ref(unit)] : [];
      });
      transaction.setMeta(key, { selected: next, range: null, gesture: null, click: null });
      if (includeTopLevel) transaction.setMeta("pennedStyleConversion", true);
      editor.view.dispatch(transaction);
      editor.view.dispatch(closeHistory(editor.state.tr));
      return true;
    },
    deleteSelected(removeListRows = false) {
      const state = value();
      if (!state?.selected.length) return false;
      const positions = selectedPositions(state.selected);
      const doc = editor.state.doc;
      const selected = records(doc).filter(block => positions.has(block.pos));
      // Delete a single top-level List Grid by its node range too, not by
      // replacing the entire document. Nested grids already use this path.
      const singleGrid = selected.length === 1 && selected[0].type === "listGrid";
      if (!singleGrid && !selected.some(block => block.path.length > 1)) return false;
      let transaction = closeHistory(editor.state.tr);
      const rows = new Set(), lists = new Map();
      // Explicit Delete removes the row. Cut and grouping must not delete
      // unselected descendants that were not copied to their destinations.
      const ranges = selected.map(block => {
        const resolved = doc.resolve(block.pos);
        if (["listItem", "taskItem"].includes(resolved.parent.type.name) && resolved.index() === 0 &&
            (removeListRows || resolved.parent.childCount === 1)) {
          const from = resolved.before();
          const listDepth = resolved.depth - 1;
          if (listDepth > 0) lists.set(resolved.before(listDepth), resolved.node(listDepth));
          rows.add(from);
          return { from, to: from + resolved.parent.nodeSize };
        }
        return { from: block.pos, to: block.pos + block.node.nodeSize };
      });
      // Removing the last selected row must remove its empty list wrapper too.
      for (const [from, list] of lists) {
        let allRowsSelected = true;
        list.forEach((_, offset) => { if (!rows.has(from + 1 + offset)) allRowsSelected = false; });
        if (allRowsSelected) ranges.push({ from, to: from + list.nodeSize });
      }
      const unique = [];
      for (const range of ranges.sort((a, b) => a.from - b.from || b.to - a.to)) {
        const previous = unique[unique.length - 1];
        if (previous && range.from < previous.to) previous.to = Math.max(previous.to, range.to);
        else unique.push(range);
      }
      unique.reverse();
      for (const range of unique) {
        if (range.from === 0 && range.to === transaction.doc.content.size) {
          transaction.replaceWith(range.from, range.to, editor.schema.nodes.paragraph.create());
        } else {
          transaction.delete(range.from, range.to);
        }
      }
      transaction.doc.check();
      transaction.setMeta("pennedPlaceholderDeletion", unique);
      transaction.setMeta(key, { selected: [], range: null, gesture: null, click: null });
      editor.view.dispatch(transaction);
      editor.view.dispatch(closeHistory(editor.state.tr));
      return true;
    },
    consumesClick(event) {
      const click = value()?.click;
      if (!click || now() >= click.until) return false;
      return !!editor.view.nodeDOM(click.pos)?.contains(event.target);
    },
    refresh() { controller?.refresh(); },
    setMode,
    command(name, args) {
      if (!value()) return undefined;
      if (name === "setContent" && !nativeContentHydrated) skipNativeContentHistory = true;
      if (name === "setContent" || (name === "setEditable" && args.editable === false)) {
        window.PennedBlockDragAndDrop?.cancelForLifecycle(name);
        window.PennedKeyboardTrace?.record("mobile.selection.command",
          { source: name, preserving: Number(args.preservingBlockSelection === true) });
        controller?.cancelPending();
        if (name === "setEditable" && args.preservingBlockSelection === true) update({ range: null, gesture: null, click: null });
        else update({ reset: true });
      }
      if (["formatSelectedBlocks", "setSelectedBlockType"].includes(name) &&
          (!canSelect() || (args.selectionTarget != null && args.selectionTarget !== value().formattingTarget))) return false;
      if (name === "selectAllBlocks") {
        if (!canSelect()) {
          window.PennedBlockDragAndDrop?.diagnostic('selection-command-rejected', { source: 'command:select-all', reason: 'selection-disabled-or-reorder-owned' });
          return false;
        }
        return update({ mode: "multi", selected: collapseNested(records(editor.state.doc).map(ref)), range: null, gesture: null }, false, "command:select-all");
      }
      if (value().selected.length && ["deleteSelectedBlocks", "duplicateSelectedBlocks", "cutSelectedBlocks",
          "formatSelectedBlocks", "setSelectedBlockType", "setSelectedCalloutColor", "updateCalloutIcon"].includes(name)) {
        editor.view.dispatch(closeHistory(editor.state.tr));
      }
      return undefined;
    },
    extensions(context) {
      const { Extension, Plugin, PluginKey, Decoration, DecorationSet, post: bridgePost, modeChanged, closeHistory: historyBoundary } = context;
      post = bridgePost;
      closeHistory = historyBoundary;
      key = new PluginKey("pennedBlockSelection");
      return [Extension.create({ name: "pennedBlockSelection", priority: 1100,
        onBeforeCreate() { editor = this.editor; mirrorMode = modeChanged; },
        addProseMirrorPlugins() {
          let decoratedDoc = null, decoratedSelection = null, selectedPaint = DecorationSet.empty;
          let paintedPosition = null, paintedDX = 0, movingPaint = DecorationSet.empty;
          return [new Plugin({ key,
            appendTransaction(transactions, oldState, state) {
              const { selection, doc } = state;
              if (key.getState(state).mode !== "off") return null;
              const exited = key.getState(oldState).mode !== "off";
              const touchedDivider = selection.node?.type.name === "divider" &&
                transactions.some(tr => tr.getMeta("pointer"));
              if ((!exited && !touchedDivider) || (!selection.node && selection.empty)) return null;
              const caret = selection.constructor.findFrom(doc.resolve(selection.to), 1, true) ||
                selection.constructor.findFrom(doc.resolve(selection.from), -1, true);
              return caret ? state.tr.setSelection(caret).setMeta("addToHistory", false) : null;
            },
            filterTransaction(tr) {
              if (skipNativeContentHistory && tr.docChanged) {
                // Hydrating the initial saved document is not a user edit.
                tr.setMeta("addToHistory", false);
                skipNativeContentHistory = false;
                nativeContentHydrated = true;
              }
              return true;
            },
            state: {
              init: empty,
              apply(tr, previous) {
                const patch = tr.getMeta(key);
                const skip = !patch && previous.mode === "off" && !previous.gesture && !previous.click &&
                  window.PennedIncrementalNodes?.inlineTextEdit?.(tr) && controller?.skipInlineRebind(tr);
                if (skip) return previous;
                if (tr.docChanged && window.PennedIncrementalNodes) {
                  const helper = window.PennedIncrementalNodes;
                  const index = helper.updateNodeIndex(unitIndexes.get(tr.before), tr, selectableUnit, descendUnit);
                  unitIndexes.set(tr.doc, index);
                }
                if (patch?.reset) return empty();
                let state = previous;
                if (tr.docChanged) {
                  controller?.mapPending(tr);
                  let gesture = null;
                  // WebKit may flush the preceding keystroke on touchstart. Preserve
                  // that pending contact through mapping instead of silently losing it.
                  if (previous.gesture?.phase === "pending") {
                    const origin = mapped([previous.gesture.origin], tr)[0];
                    if (origin) gesture = { ...previous.gesture, origin, base: mapped(previous.gesture.base, tr), resume: mappedRange(previous.gesture.resume, tr) };
                  }
                  state = { ...previous, selected: mapped(previous.selected, tr), range: mappedRange(previous.range, tr), gesture, click: null };
                }
                const { entryAuthorized, entrySource, ...changes } = patch || {};
                let next = patch ? { ...state, ...changes, haptic: state.haptic } : state;
                if (previous.mode === "off" && next.mode !== "off" && next.selected.length && !entryAuthorized) {
                  window.PennedBlockDragAndDrop?.diagnostic('selection-entry-rejected', { source: entrySource || 'transaction', reason: 'missing-ownership-permission' });
                  next = { ...next, mode: "off", selected: [], range: null, gesture: null, click: null };
                }
                if (previous.mode === "off" && next.mode !== "off") next = { ...next, dividerConverted: false };
                if (tr.getMeta("pennedDividerStyleConversion")) next = { ...next, dividerConverted: true };
                if (patch?.haptic && !same(state.selected, next.selected)) next.haptic += 1;
                if (!next.selected.length) return next.mode !== "off" || previous.mode !== "off" || previous.selected.length
                  ? { ...next, mode: "off", range: null, gesture: null, click: null, formattingTarget: null } : next;
                // Formatting can replace its own selected nodes, but a different
                // user selection (even with the same count) invalidates queued taps.
                const retargeted = !tr.getMeta("pennedStyleConversion") && (
                  next.mode !== previous.mode || next.selected.length !== previous.selected.length ||
                  (patch?.selected && !same(state.selected, next.selected)));
                return !previous.formattingTarget || retargeted ? { ...next, formattingTarget: crypto.randomUUID() } : next;
              },
            },
            props: {
              editable(state) { const selected = key.getState(state); return selected.mode === "off" || (selected.gesture?.phase === "active" && selected.gesture.editable); },
              decorations(state) {
                const selection = key.getState(state), moving = selection.gesture;
                if (decoratedDoc !== state.doc || decoratedSelection !== selection.selected) {
                  const highlights = selection.selected.map(item => recordAt(state.doc, item.pos)).filter(Boolean)
                    .map(block => Decoration.node(block.pos, block.pos + block.node.nodeSize, {
                      class: isWholeCallout(block.node) ? "penned-block-selected penned-callout-block-selected" : "penned-block-selected",
                      "data-penned-selection-paint": String(block.pos),
                    }));
                  selectedPaint = highlights.length ? DecorationSet.create(state.doc, highlights) : DecorationSet.empty;
                  decoratedDoc = state.doc;
                  decoratedSelection = selection.selected;
                  paintedPosition = null;
                }
                const block = moving?.phase === "active" && moving.dx ? recordAt(state.doc, moving.origin.pos) : null;
                if (!block) return selectedPaint;
                if (paintedPosition !== block.pos || paintedDX !== moving.dx) {
                  movingPaint = selectedPaint.add(state.doc, [Decoration.node(block.pos, block.pos + block.node.nodeSize,
                    { style: `transform: translateX(${moving.dx}px); transition: none;` })]);
                  paintedPosition = block.pos;
                  paintedDX = moving.dx;
                }
                return movingPaint;
              },
              handleTextInput(view) { return key.getState(view.state).mode !== "off"; },
              handleDOMEvents: { keydown(view, event) {
                const state = key.getState(view.state);
                if (state.mode === "off") return false;
                if (event.key === "Escape") { event.preventDefault(); return setMode("off"); }
                if ((event.key === "Backspace" || event.key === "Delete") && state.selected.length) {
                  event.preventDefault(); window.tiptapCommand("deleteSelectedBlocks"); return true;
                }
                if ((event.metaKey || event.ctrlKey) && state.selected.length) {
                  const command = { c: "copySelectedBlocks", x: "cutSelectedBlocks", a: "selectAllBlocks" }[event.key.toLowerCase()];
                  if (command) { event.preventDefault(); window.tiptapCommand(command); return true; }
                }
                return false;
              } },
            },
            view: view => createView(view, post),
          })];
        },
      }), ...(window.PennedBlockDragAndDrop?.extensions(context) ?? [])];
    },
  };
})();
"""#
}
#endif
