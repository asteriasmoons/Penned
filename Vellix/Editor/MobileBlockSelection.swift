#if os(iOS)
import CoreGraphics

enum MobileBlockSelection {
    static let selectionGutter: CGFloat = 6

    static let script = #"""
(() => {
  if (window.PennedBlockSelection) return;
  let editor, key, mirrorMode, controller, closeHistory, post, skipNativeContentHistory = false, nativeContentHydrated = false;
  const empty = () => ({ mode: "off", selected: [], range: null, gesture: null, click: null, haptic: 0 });
  const now = () => performance.now();
  let canonicalNode = node => node, contactSequence = 0;
  const recordCache = new WeakMap();
  const scrollableContent = node => {
    const types = ["codeBlock", "table", "collection", "attachment", "pageReference"];
    let found = types.includes(node.type.name);
    if (!found) node.descendants(child => { if (types.includes(child.type.name)) found = true; return !found; });
    return found;
  };
  const records = (doc, normalize) => {
    if (normalize) canonicalNode = normalize;
    if (recordCache.has(doc)) return recordCache.get(doc);
    const result = [];
    const visit = (parent, parentPos, parentPath) => parent.forEach((node, offset, index) => {
      const pos = parent.type.name === "doc" ? offset : parentPos + 1 + offset;
      const path = [...parentPath, index];
      // Containers keep their hierarchy; their editable children are independent units.
      // Tables remain one unit so block actions never detach a cell from its row.
      if (node.isBlock && (node.isTextblock || node.isAtom || node.type.name === "table")) {
        result.push({ node, pos, index: result.length, path, key: `path:${path.join(".")}`,
          get json() { return canonicalNode(node.toJSON()); }, type: node.type.name,
          parentType: parent.type.name, scrollable: scrollableContent(node) });
      } else if (node.isBlock) visit(node, pos, path);
    });
    visit(doc, 0, []);
    recordCache.set(doc, result);
    return result;
  };
  const ref = record => ({ pos: record.pos, id: record.node.attrs.id || null });
  const value = () => editor && key?.getState(editor.state);
  const same = (a, b) => a.length === b.length && a.every((item, index) => item.pos === b[index].pos && item.id === b[index].id);
  const canSelect = () => editor?.options.editable !== false && !editor?.view.composing;
  function mapped(selected, tr) {
    const next = records(tr.doc);
    return selected.flatMap(item => {
      const position = tr.mapping.mapResult(item.pos, 1);
      let record = !position.deleted && next.find(block => block.pos === position.pos && (!item.id || block.node.attrs.id === item.id));
      if (!record && item.id) {
        const matches = next.filter(block => block.node.attrs.id === item.id);
        if (matches.length === 1) record = matches[0];
      }
      return record ? [ref(record)] : [];
    }).filter((item, index, all) => all.findIndex(other => other.pos === item.pos) === index);
  }
  function mappedRange(range, tr) {
    if (!range) return null;
    const anchor = mapped([range.anchor], tr)[0], head = mapped([range.head], tr)[0];
    return anchor && head ? { anchor, head, base: mapped(range.base, tr) } : null;
  }
  function update(patch, haptic = false) {
    if (!value()) return false;
    editor.view.dispatch(editor.state.tr.setMeta(key, { ...patch, haptic }).setMeta("addToHistory", false));
    return true;
  }
  function setMode(mode) {
    if (!value()) return false;
    controller?.cancelPending();
    const next = ["single", "multi"].includes(mode) && canSelect() ? mode : "off";
    return update({ mode: next, selected: next === "off" ? [] : value().selected, range: null, gesture: null, click: null });
  }
  function fromKey(name) {
    return records(editor.state.doc).find(record => record.key === name);
  }
  function changeKey(name, selected) {
    const record = fromKey(name), state = value();
    if (!record || !state) return;
    const next = state.selected.filter(item => item.pos !== record.pos);
    if (selected) next.push(ref(record));
    update({ selected: next.sort((a, b) => a.pos - b.pos), range: null,
      ...(state.selected.length && !next.length ? { mode: "off", gesture: null, click: null } : {}) });
  }
  const facade = {
    get size() { return value()?.selected.length || 0; },
    has(name) { const record = editor && fromKey(name); return !!record && !!value()?.selected.some(item => item.pos === record.pos); },
    add(name) { changeKey(name, true); return this; },
    delete(name) { const had = this.has(name); changeKey(name, false); return had; },
    clear() { if (value()?.selected.length) update({ selected: [], range: null }); },
    *[Symbol.iterator]() { if (editor) for (const record of records(editor.state.doc)) if (this.has(record.key)) yield record.key; },
  };
  function rangeSelection(range, target, visible) {
    const blocks = records(editor.state.doc);
    const origin = blocks.findIndex(block => block.pos === range.anchor.pos);
    const end = blocks.findIndex(block => block.pos === target.pos);
    if (origin < 0 || end < 0) return range.base;
    const byPosition = new Map(range.base.map(item => [item.pos, item]));
    for (const block of blocks.slice(Math.min(origin, end), Math.max(origin, end) + 1)) {
      if (visible(block)) byPosition.set(block.pos, ref(block));
    }
    return [...byPosition.values()].sort((a, b) => a.pos - b.pos);
  }
  function blockedTarget(target, block) {
    if (!(target instanceof Element)) return true;
    const control = target.closest("button, a, input, textarea, select, audio, video, iframe, [role='button'], .vellix-table-resizers, .vellix-table-cell-menu");
    if (control && !control.matches(".vellix-page-reference-button, .penned-file-card, .vellix-property-name, .vellix-property-control")) return true;
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
  function createView(view, post) {
    const bindings = new Map();
    let lastMode, lastCount, lastCollectionSelection, lastHaptic = 0, destroyed = false, queued = false, contactElement = null, pendingContact = null, releaseTarget = null;
    let scrollToken = null;
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
      .penned-mobile-block-layout > :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-block: 0 !important; }
      .penned-mobile-block-layout > :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) + :not(:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout > .vellix-property + .vellix-property { margin-top: 4px !important; }
      .penned-mobile-block-layout :is(.vellix-toggle-content, .vellix-blockquote-content, li) > * { margin-block: 0 !important; }
      .penned-mobile-block-layout :is(.vellix-toggle-content, .vellix-blockquote-content, li) > * + * { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout :is(ul, ol) > li { margin-block: 0 !important; }
      .penned-mobile-block-layout :is(ul, ol) > li + li { margin-top: var(--penned-block-gap) !important; }
      .penned-mobile-block-layout > :is(.vellix-callout, .vellix-plain-callout):has(+ :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])) { margin-bottom: 20px !important; }
      .penned-mobile-block-layout > :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break]) + :is(.vellix-callout, .vellix-plain-callout) { margin-top: 20px !important; }
      .penned-swipe-block { transition: transform 120ms ease-out; }
      .penned-swipe-block:not(.penned-swipe-scrollable) { touch-action: pan-y pinch-zoom; }
      .penned-block-selected { position: relative; outline: none !important; }
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child) { position: relative; }
      .penned-block-selected::after,
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child)::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child)::after,
      blockquote:has(> .vellix-blockquote-content > .penned-block-selected:only-child)::after,
      .penned-block-selected.vellix-page-reference > .vellix-page-reference-button::after {
        content: ""; position: absolute; inset: -3px calc(-1 * var(--penned-selection-gutter)); pointer-events: none;
        border-radius: 8px; background: rgba(181,154,217,.18);
        box-shadow: inset 0 0 0 1px rgba(181,154,217,.26);
      }
      .penned-block-selected:is(pre, .penned-template-component)::after { inset: 0; border-radius: 16px; }
      .penned-block-selected:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])::after { inset: 1px 0; }
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child)::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child)::after,
      blockquote:has(> .vellix-blockquote-content > .penned-block-selected:only-child)::after { inset: 0; border-radius: inherit; }
      .vellix-callout-text > .penned-block-selected:only-child::after,
      .vellix-plain-callout-text > .penned-block-selected:only-child::after,
      .vellix-blockquote-content > .penned-block-selected:only-child::after,
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper, .vellix-page-reference)::after { display: none; }
      .penned-block-selected.vellix-page-reference > .vellix-page-reference-button { position: relative; }
      .penned-block-selected.vellix-page-card > .vellix-page-reference-button::after { inset: 0; border-radius: inherit; }
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper) :is(td, th) { box-shadow: inset 0 0 0 9999px rgba(181,154,217,.22); }
      .penned-block-selected:is(.tableWrapper, .vellix-table-wrapper) table { outline: none !important; }
      .penned-block-selection-active { caret-color: transparent; }
      .penned-block-selection-active .penned-swipe-block { -webkit-user-select: none; user-select: none; }
      .penned-block-selection-active .penned-block-selected { touch-action: none !important; }
      @media (prefers-reduced-motion: reduce) { .penned-swipe-block { transition: none !important; } }
    `;
    document.head.appendChild(style);
    view.dom.classList.add("penned-mobile-block-layout");
    const cancelPending = () => { pendingContact = null; };
    const stopScrolling = () => {
      if (scrollToken === null) return;
      const token = scrollToken;
      scrollToken = null;
      post("blockSelectionDrag", { token, active: false });
    };
    const cancel = () => {
      stopScrolling();
      cancelPending();
      if (value()?.gesture) update({ gesture: null });
      else { contactElement = null; releaseTarget?.(); }
    };
    const surface = block => {
      const element = view.nodeDOM(block.pos), table = block.type === "table" && element?.querySelector("table");
      return table && table.getBoundingClientRect().height > 0 ? table : element;
    };
    const visible = block => {
      const element = view.nodeDOM(block.pos);
      if (!(element instanceof HTMLElement) || !view.dom.contains(element)) return false;
      if (element.closest("[hidden]") || surface(block).getBoundingClientRect().height <= 0) return false;
      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return false;
      const closed = "[data-vellix-toggle][data-open='false']";
      for (let toggle = element.closest(closed); toggle; toggle = toggle.parentElement?.closest(closed)) {
        const title = toggle.querySelector("[data-vellix-toggle-content]")?.firstElementChild;
        if (title && title !== element && !title.contains(element)) return false;
      }
      return true;
    };
    function targetAt(y, range) {
      // Gaps and block edges are sticky; only entering another block extends the range.
      const blocks = records(view.state.doc);
      const index = blocks.findIndex(block => block.pos === range.head.pos);
      if (index < 0) return null;
      let target = blocks[index];
      const current = surface(target).getBoundingClientRect();
      const direction = y > current.bottom ? 1 : y < current.top ? -1 : 0;
      for (let next = index + direction; direction && next >= 0 && next < blocks.length; next += direction) {
        const block = blocks[next], rect = surface(block).getBoundingClientRect();
        if (!visible(block)) continue;
        const inset = value().selected.some(item => item.pos === block.pos) ? 0 : Math.min(4, rect.height / 4);
        if (direction > 0 ? y < rect.top + inset : y > rect.bottom - inset) break;
        target = block;
      }
      return target;
    }
    function continueDragScroll({ token, revision, y, boundary }) {
      const state = value(), gesture = state?.gesture, range = state?.range;
      if (destroyed || !canSelect() || !Number.isFinite(y) || !range || gesture?.token !== token ||
          gesture.phase !== "active" || !gesture.committed || !gesture.extending) return false;
      if (gesture.scrollRevision !== revision) return true;
      let target;
      if (boundary === "start" || boundary === "end") {
        const blocks = records(view.state.doc).filter(visible);
        target = boundary === "start" ? blocks[0] : blocks[blocks.length - 1];
      } else target = targetAt(y, range);
      if (target && target.pos !== range.head.pos) {
        update({ selected: rangeSelection(range, target, visible), range: { ...range, head: ref(target) } }, true);
      }
      return true;
    }
    function beginPending() {
      const contact = pendingContact;
      pendingContact = null;
      if (!contact || destroyed || !canSelect()) return;
      const state = value(), blocks = records(view.state.doc);
      const block = blocks.find(item => item.pos === contact.origin.pos && (!contact.origin.id || item.node.attrs.id === contact.origin.id));
      if (!block || !state || (state.mode === "off" && textSelectionActive())) return;
      const selected = state.selected.some(item => item.pos === block.pos);
      const resume = selected ? state.range || { anchor: ref(block), head: ref(block),
        base: state.selected.filter(item => item.pos !== block.pos) } : null;
      update({ gesture: { phase: "pending", identifier: contact.identifier, origin: ref(block),
        token: contact.token, screenY: contact.screenY, scrollRevision: 0,
        x: contact.x, y: contact.y, started: contact.started, dx: 0, base: state.selected,
        selectionActive: state.mode !== "off" && state.selected.length > 0,
        resume, editable: view.editable, committed: false, commitY: null }, click: null });
    }
    function start(event, position, element) {
      const state = value();
      if (event.touches.length !== 1) { cancel(); return; }
      if (!state || !canSelect() || blockedTarget(event.target, element) ||
          (state.mode === "off" && textSelectionActive()) || editor.state.selection.$anchorCell) return;
      const touch = event.touches[0], block = records(editor.state.doc).find(item => item.pos === position);
      if (!block) return;
      releaseTarget?.();
      contactElement = element;
      // WebKit keeps the initial touch target even if a mark's inline DOM is
      // detached during input reconciliation. Keep this contact block-local.
      if (event.target !== element) {
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
      const dx = touch.clientX - gesture.x, dy = touch.clientY - gesture.y;
      const screenY = Number.isFinite(touch.screenY) ? touch.screenY : touch.clientY;
      const deltaY = screenY - gesture.screenY;
      const scrollRevision = gesture.scrollRevision + (Math.abs(deltaY) > 0.25 ? 1 : 0);
      const verticalResume = gesture.resume && Math.abs(dy) >= 4 && Math.abs(dy) > Math.abs(dx) * 1.1;
      if (gesture.phase === "pending") {
        if ((!gesture.resume && now() - gesture.started > 320) || (state.mode === "off" && textSelectionActive())) { cancel(); return; }
        if (!verticalResume) {
          if (Math.abs(dy) >= 10 || (Math.abs(dy) >= 8 && Math.abs(dy) >= Math.abs(dx) / 1.8)) { cancel(); return; }
          if (Math.abs(dx) < (gesture.selectionActive ? 8 : 18) || Math.abs(dx) < Math.abs(dy) * 1.8) return;
        }
      }
      // Never attempt to take over a non-cancellable or already-scrolling stream.
      event.preventDefault();
      if (!event.defaultPrevented) { cancel(); return; }
      event.stopImmediatePropagation();
      const resuming = gesture.resuming || (!gesture.committed && verticalResume);
      const committed = gesture.committed || resuming || Math.abs(dx) >= (gesture.selectionActive ? 24 : 48);
      const extending = gesture.extending || resuming || (gesture.commitY !== null && Math.abs(touch.clientY - gesture.commitY) >= 6);
      let selected = state.selected, range = state.range;
      if (committed) {
        if (!gesture.committed) range = gesture.resume || { anchor: gesture.origin, head: gesture.origin, base: gesture.base };
        let target = records(view.state.doc).find(block => block.pos === range.head.pos);
        if (extending) target = targetAt(touch.clientY, range);
        if (target) {
          if (!gesture.committed || target.pos !== range.head.pos) selected = rangeSelection(range, target, visible);
          range = { ...range, head: ref(target) };
        }
      }
      update({ mode: committed ? "multi" : state.mode, selected, range,
        gesture: { ...gesture, phase: "active", screenY, scrollRevision, dx: resuming ? 0 : Math.max(-56, Math.min(56, dx * 0.6)),
          committed, resuming, extending, commitY: gesture.commitY ?? (committed ? touch.clientY : null) } }, committed);
      if (committed && extending && range && (scrollToken !== gesture.token || Math.abs(deltaY) > 0.25)) {
        scrollToken = gesture.token;
        post("blockSelectionDrag", { token: gesture.token, revision: scrollRevision, active: true, x: touch.clientX, y: touch.clientY, deltaY });
      }
    }
    function end(event, position) {
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
        if (gesture.committed) view.dom.blur();
      } else cancel();
    }
    function click(event, position, element) {
      const state = value();
      if (state?.click?.pos === position && now() < state.click.until) {
        event.preventDefault(); event.stopImmediatePropagation(); update({ click: null }); return;
      }
      if (!state || state.mode === "off" || !canSelect() || blockedTarget(event.target, element)) return;
      const block = records(editor.state.doc).find(item => item.pos === position);
      if (!block) return;
      event.preventDefault(); event.stopImmediatePropagation();
      const next = state.mode === "single" ? [] : state.selected.filter(item => item.pos !== position);
      if (!state.selected.some(item => item.pos === position)) next.push(ref(block));
      update({ mode: next.length ? state.mode : "off", selected: next.sort((a, b) => a.pos - b.pos),
        range: null, gesture: null, click: null }, true);
    }
    function refresh() {
      const state = key.getState(view.state);
      if (!state || !editor) return;
      if (!state.gesture?.committed || !state.gesture.extending || state.mode === "off") stopScrolling();
      if (!state.gesture && !pendingContact) { contactElement = null; releaseTarget?.(); }
      if (lastMode !== state.mode) {
        mirrorMode?.(state.mode);
        document.documentElement.dataset.vellixSelectionMode = state.mode;
        document.body.dataset.vellixSelectionMode = state.mode;
        view.dom.classList.toggle("penned-block-selection-active", state.mode !== "off");
        lastMode = state.mode; post("selectionMode", { mode: state.mode });
        if (state.mode !== "off") window.tiptapCommand?.("mobileDismissSlashMenu");
      }
      if (lastCount !== state.selected.length) { lastCount = state.selected.length; post("selection", { count: state.selected.length }); }
      const selectedPositions = new Set(state.selected.map(item => item.pos));
      const collectionBlockIDs = records(view.state.doc).filter(block => block.type === "collection" && selectedPositions.has(block.pos))
        .map(block => block.node.attrs.id).filter(Boolean);
      const collectionSelection = JSON.stringify(collectionBlockIDs);
      if (lastCollectionSelection !== collectionSelection) {
        lastCollectionSelection = collectionSelection;
        post("blockSelectionSurfaces", { collectionBlockIDs });
      }
      if (state.haptic > lastHaptic) post("haptic", { style: "light" });
      lastHaptic = state.haptic;
      const live = new Set();
      for (const block of records(view.state.doc)) {
        const element = view.nodeDOM(block.pos);
        if (!(element instanceof HTMLElement)) continue;
        live.add(element);
        const existing = bindings.get(element);
        if (existing?.pos === block.pos) continue;
        existing?.remove();
        const handlers = {
          touchstart: event => start(event, block.pos, element),
          touchmove: event => move(event, element),
          touchend: event => end(event, block.pos),
          touchcancel: cancel,
          contextmenu: cancel,
          click: event => click(event, block.pos, element),
        };
        for (const [name, handler] of Object.entries(handlers)) element.addEventListener(name, handler,
          { capture: true, passive: name === "touchstart" || name === "touchcancel" || name === "contextmenu" });
        bindings.set(element, { pos: block.pos, remove() {
          for (const [name, handler] of Object.entries(handlers)) element.removeEventListener(name, handler, true);
        } });
      }
      for (const [element, binding] of bindings) if (!live.has(element) && element !== contactElement) {
        binding.remove(); bindings.delete(element);
      }
    }
    // NodeViews can replace DOM without replacing the ProseMirror document. Reconcile
    // identities after DOM churn as well as state changes, never via global gestures.
    const observer = new MutationObserver(() => {
      if (queued || destroyed) return;
      queued = true;
      queueMicrotask(() => { queued = false; if (!destroyed) refresh(); });
    });
    observer.observe(view.dom, { childList: true, subtree: true });
    controller = { refresh, cancelPending, scroll: continueDragScroll, mapPending(tr) {
      if (!pendingContact) return;
      const origin = mapped([pendingContact.origin], tr)[0];
      pendingContact = origin ? { ...pendingContact, origin } : null;
    } };
    return { update: refresh, destroy() {
      destroyed = true; stopScrolling(); cancelPending(); releaseTarget?.(); observer.disconnect();
      for (const binding of bindings.values()) binding.remove();
      bindings.clear(); view.dom.classList.remove("penned-mobile-block-layout"); style.remove(); controller = null;
    } };
  }
  window.PennedBlockSelection = {
    records, selectionFacade: () => facade,
    continueDragScroll: payload => controller?.scroll(payload) ?? false,
    transformSelectedNested(transform) {
      const state = value();
      if (!state?.selected.length) return undefined;
      const selected = records(editor.state.doc).filter(block => state.selected.some(item => item.pos === block.pos));
      if (!selected.some(block => block.path.length > 1)) return undefined;
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
      for (const { block, node } of replacements.reverse()) transaction.replaceWith(block.pos, block.pos + block.node.nodeSize, node);
      transaction.doc.check();
      editor.view.dispatch(transaction);
      editor.view.dispatch(closeHistory(editor.state.tr));
      return true;
    },
    deleteSelected() {
      const state = value();
      if (!state?.selected.length) return false;
      const selected = records(editor.state.doc).filter(block => state.selected.some(item => item.pos === block.pos));
      if (!selected.some(block => block.path.length > 1)) return false;
      let transaction = closeHistory(editor.state.tr);
      // ProseMirror fits each replacement to its parent's content expression,
      // preserving required list paragraphs and the surrounding hierarchy.
      for (const block of selected.slice().reverse()) transaction.delete(block.pos, block.pos + block.node.nodeSize);
      transaction.doc.check();
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
      if (name === "setContent" || (name === "setEditable" && args.editable === false)) { controller?.cancelPending(); update({ reset: true }); }
      if (name === "selectAllBlocks") {
        if (!canSelect()) return false;
        return update({ mode: "multi", selected: records(editor.state.doc).map(ref), range: null, gesture: null });
      }
      if (value().selected.length && ["deleteSelectedBlocks", "duplicateSelectedBlocks", "cutSelectedBlocks",
          "formatSelectedBlocks", "setSelectedBlockType", "setSelectedCalloutColor", "updateCalloutIcon"].includes(name)) {
        editor.view.dispatch(closeHistory(editor.state.tr));
      }
      return undefined;
    },
    extensions({ Extension, Plugin, PluginKey, Decoration, DecorationSet, post: bridgePost, modeChanged, closeHistory: historyBoundary }) {
      post = bridgePost;
      closeHistory = historyBoundary;
      key = new PluginKey("pennedBlockSelection");
      return [Extension.create({ name: "pennedBlockSelection", priority: 1100,
        onBeforeCreate() { editor = this.editor; mirrorMode = modeChanged; },
        addProseMirrorPlugins() {
          return [new Plugin({ key,
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
                const next = patch ? { ...state, ...patch, haptic: state.haptic } : state;
                if (patch?.haptic && !same(state.selected, next.selected)) next.haptic += 1;
                return previous.selected.length && !next.selected.length
                  ? { ...next, mode: "off", range: null, gesture: null, click: null }
                  : next;
              },
            },
            props: {
              editable(state) { const selected = key.getState(state); return selected.mode === "off" || (selected.gesture?.phase === "active" && selected.gesture.editable); },
              decorations(state) {
                const selection = key.getState(state), moving = selection.gesture;
                const selectedPositions = new Set(selection.selected.map(item => item.pos));
                return DecorationSet.create(state.doc, records(state.doc).map(block => {
                  const selected = selectedPositions.has(block.pos);
                  const dx = moving?.phase === "active" && moving.origin.pos === block.pos ? moving.dx : 0;
                  return Decoration.node(block.pos, block.pos + block.node.nodeSize, {
                    class: "penned-swipe-block" + (block.scrollable ? " penned-swipe-scrollable" : "") + (selected ? " penned-block-selected" : ""),
                    ...(dx ? { style: `transform: translateX(${dx}px); transition: none;` } : {}),
                  });
                }));
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
      })];
    },
  };
})();
"""#
}
#endif
