#if os(iOS)
import CoreGraphics

enum MobileBlockSelection {
    static let selectionGutter: CGFloat = 6

    static let script = #"""
(() => {
  if (window.PennedBlockSelection) return;
  let editor, key, mirrorMode, controller, closeHistory, post, skipNativeContentHistory = false, nativeContentHydrated = false;
  const empty = () => ({ mode: "off", selected: [], range: null, gesture: null, click: null, haptic: 0, dividerConverted: false });
  const now = () => performance.now();
  let canonicalNode = node => node, contactSequence = 0;
  const recordCache = new WeakMap();
  const recordIndexes = new WeakMap(), selectionPositionCache = new WeakMap();
  const unitIndexes = new WeakMap(), scrollableCache = new WeakMap();
  const isCalloutUnit = node => node.type.name === "callout" || node.type.name === "plainCallout";
  // Stable DOM markers identify gesture hosts without a permanent node
  // decoration on every block (DecorationSet.forChild scans all local spans).
  const unitSelector = 'p, h1, h2, h3, h4, h5, h6, pre, [data-vellix-block-id], .vellix-callout, .vellix-plain-callout, .vellix-table-wrapper';
  const selectableUnit = node => node.isBlock && (node.isTextblock || node.isAtom || node.type.name === "table" || isCalloutUnit(node));
  const descendUnit = node => isCalloutUnit(node);
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
      // Tables remain one unit so block actions never detach a cell from its row.
      // Callouts are a unit AND recurse, so the callout and the cards inside it are both selectable.
      const unit = isCalloutUnit(node) || (node.isBlock && (node.isTextblock || node.isAtom || node.type.name === "table"));
      if (unit) {
        result.push({ node, pos, index: result.length, path, key: `path:${path.join(".")}`,
          get json() { return canonicalNode(node.toJSON()); }, type: node.type.name,
          parentType: parent.type.name,
          get scrollable() { return scrollableContent(node); } });
      }
      if (isCalloutUnit(node) || (!unit && node.isBlock)) visit(node, pos, path);
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
  const canSelect = () => editor?.options.editable !== false && !editor?.view.composing;
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
      ...(state.selected.length && !collapsed.length ? { mode: "off", gesture: null, click: null } : {}) });
  }
  const facade = {
    get size() { return value()?.selected.length || 0; },
    has(name) { const record = editor && fromKey(name), state = value(); return !!record && !!state && selectedPositions(state.selected).has(record.pos); },
    add(name) { changeKey(name, true); return this; },
    delete(name) { const had = this.has(name); changeKey(name, false); return had; },
    clear() { if (value()?.selected.length) update({ selected: [], range: null }); },
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
    const boundNodes = new WeakMap();
    let lastMode, lastCount, lastCollectionSelection, lastHaptic = 0, destroyed = false, contactElement = null, pendingContact = null, releaseTarget = null;
    let scrollToken = null;
    let bindingsDoc = null, bindingsDirty = true, bindingGeneration = 0, lastSelectedDoc = null, lastSelected = null;
    let pendingBindingChanges = [], pendingBindingDoc = null;
    const removedBindingElements = new Set();
    const attachBinding = (element, position) => {
      const existing = bindings.get(element);
      if (existing) { existing.pos = position; return; }
      const binding = { pos: position, generation: bindingGeneration };
      const handlers = {
        touchstart: event => start(event, binding.pos, element),
        touchmove: event => move(event, element),
        touchend: event => end(event, binding.pos),
        touchcancel: cancel,
        contextmenu: cancel,
        click: event => click(event, binding.pos, element),
      };
      for (const [name, handler] of Object.entries(handlers)) element.addEventListener(name, handler,
        { capture: true, passive: name === "touchstart" || name === "touchcancel" || name === "contextmenu" });
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
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference))::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference))::after,
      blockquote:has(> .vellix-blockquote-content > .penned-block-selected:only-child)::after,
      .penned-block-selected.vellix-page-reference > .vellix-page-reference-button::after {
        content: ""; position: absolute; inset: -3px calc(-1 * var(--penned-selection-gutter)); pointer-events: none;
        border-radius: 8px; background: rgba(181,154,217,.18);
        box-shadow: inset 0 0 0 1px rgba(181,154,217,.26);
      }
      .penned-block-selected:is(pre, .penned-template-component)::after { inset: 0; border-radius: 16px; }
      .penned-block-selected:is(.vellix-callout, .vellix-plain-callout)::after { inset: 0; border-radius: inherit; }
      .penned-block-selected:is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break])::after { inset: 1px 0; }
      .vellix-callout:has(> .vellix-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference))::after,
      .vellix-plain-callout:has(> .vellix-plain-callout-text > .penned-block-selected:only-child:not(.vellix-page-reference))::after,
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
      /* WebKit inherits user-select from the editor surface. Apply it once at
         the gesture root rather than matching every block on first swipe. */
      .penned-block-selection-active,
      .penned-block-selection-arming { -webkit-user-select: none; user-select: none; }
      .penned-block-selection-active .penned-block-selected { touch-action: none !important; }
      @media (prefers-reduced-motion: reduce) { .penned-mobile-block-layout :is(p, h1, h2, h3, h4, h5, h6, pre, [data-vellix-block-id], .vellix-callout, .vellix-plain-callout, .vellix-table-wrapper) { transition: none !important; } }
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
    function targetAt(y, range) {
      // Gaps and block edges are sticky; only entering another block extends the range.
      const blocks = records(view.state.doc);
      const index = recordAt(view.state.doc, range.head.pos)?.index ?? -1;
      if (index < 0) return null;
      let target = blocks[index];
      const current = surface(target).getBoundingClientRect();
      const direction = y > current.bottom ? 1 : y < current.top ? -1 : 0;
      const alreadySelected = selectedPositions(value().selected);
      for (let next = index + direction; direction && next >= 0 && next < blocks.length; next += direction) {
        const block = blocks[next], rect = surface(block).getBoundingClientRect();
        if (!visible(block, rect)) continue;
        const inset = alreadySelected.has(block.pos) ? 0 : Math.min(4, rect.height / 4);
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
        // Native scroll-edge updates need only the first or last visible unit.
        // Avoid allocating an array of every visible block on each scroll tick.
        const blocks = records(view.state.doc);
        if (boundary === "start") {
          for (let index = 0; index < blocks.length; index++) {
            if (visible(blocks[index])) { target = blocks[index]; break; }
          }
        } else {
          for (let index = blocks.length - 1; index >= 0; index--) {
            if (visible(blocks[index])) { target = blocks[index]; break; }
          }
        }
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
      const state = value(), block = recordAt(view.state.doc, contact.origin.pos);
      if (!block || (contact.origin.id && block.node.attrs.id !== contact.origin.id) || !state || (state.mode === "off" && textSelectionActive())) return;
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
      const touch = event.touches[0], block = recordAt(editor.state.doc, position);
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
          // Warm the one-time document-wide selection style recalc during the pre-commit
          // window, so it does not stall the first frame of the block tracking the finger.
          if (Math.abs(dx) >= 4 && Math.abs(dx) > Math.abs(dy)) view.dom.classList.add("penned-block-selection-arming");
          if (Math.abs(dx) < (gesture.selectionActive ? 6 : 12) || Math.abs(dx) < Math.abs(dy) * 1.8) return;
        }
      }
      // Never attempt to take over a non-cancellable or already-scrolling stream.
      event.preventDefault();
      if (!event.defaultPrevented) { cancel(); return; }
      event.stopImmediatePropagation();
      const resuming = gesture.resuming || (!gesture.committed && verticalResume);
      const committed = gesture.committed || resuming || Math.abs(dx) >= (gesture.selectionActive ? 14 : 24);
      const extending = gesture.extending || resuming || (gesture.commitY !== null && Math.abs(touch.clientY - gesture.commitY) >= 6);
      let selected = state.selected, range = state.range;
      if (committed) {
        if (!gesture.committed) range = gesture.resume || { anchor: gesture.origin, head: gesture.origin, base: gesture.base };
        let target = recordAt(view.state.doc, range.head.pos);
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
      const block = recordAt(editor.state.doc, position);
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
      if (!state.gesture && !pendingContact) {
        if (contactElement && !contactElement.isConnected) bindingsDirty = true;
        contactElement = null; releaseTarget?.();
      }
      if (lastMode !== state.mode) {
        if (lastMode && state.mode === "off" && state.dividerConverted) {
          view.dom.blur();
          const native = window.getSelection();
          if (native && (view.dom.contains(native.anchorNode) || view.dom.contains(native.focusNode))) native.removeAllRanges();
        }
        mirrorMode?.(state.mode);
        document.documentElement.dataset.vellixSelectionMode = state.mode;
        document.body.dataset.vellixSelectionMode = state.mode;
        view.dom.classList.toggle("penned-block-selection-active", state.mode !== "off");
        lastMode = state.mode; post("selectionMode", { mode: state.mode });
        if (state.mode !== "off") window.tiptapCommand?.("mobileDismissSlashMenu");
      }
      // The arming warm-up is only needed before selection commits. Once the editor is
      // fully at rest it must come off, or text would stay unselectable while editing.
      if (state.mode === "off" && !state.gesture && !pendingContact && view.dom.classList.contains("penned-block-selection-arming")) view.dom.classList.remove("penned-block-selection-arming");
      if (lastCount !== state.selected.length) { lastCount = state.selected.length; post("selection", { count: state.selected.length }); }
      if (lastSelectedDoc !== view.state.doc || lastSelected !== state.selected) {
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
            attachBinding(element, block.pos);
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
        if (existing) { existing.pos = block.pos; existing.generation = generation; continue; }
        attachBinding(element, block.pos);
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
        let position;
        try { position = view.posAtDOM(element, 0); } catch { return; }
        const doc = view.state.doc;
        const resolved = doc.resolve(Math.max(0, Math.min(position, doc.content.size)));
        const candidates = [position, position - 1];
        for (let depth = resolved.depth; depth > 0; depth--) candidates.push(resolved.before(depth));
        for (const pos of candidates) {
          if (pos < 0 || view.nodeDOM(pos) !== element || !recordAt(doc, pos)) continue;
          attachBinding(element, pos);
          return;
        }
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
    controller = { refresh, cancelPending, scroll: continueDragScroll, mapPending(tr) {
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
          for (const binding of bindings.values()) {
            if (binding.pos < 0) continue;
            const mappedPosition = tr.mapping.mapResult(binding.pos, 1);
            binding.pos = mappedPosition.deleted ? -1 : mappedPosition.pos;
          }
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
      for (const binding of bindings.values()) binding.remove();
      bindings.clear(); view.dom.classList.remove("penned-mobile-block-layout"); style.remove(); controller = null;
    } };
  }
  window.PennedBlockSelection = {
    records, selectionFacade: () => facade,
    selectedRecords() {
      return (value()?.selected || []).map(item => recordAt(editor.state.doc, item.pos)).filter(Boolean);
    },
    continueDragScroll: payload => controller?.scroll(payload) ?? false,
    transformSelectedNested(transform) {
      const state = value();
      if (!state?.selected.length) return undefined;
      const positions = selectedPositions(state.selected);
      const selected = records(editor.state.doc).filter(block => positions.has(block.pos));
      if (!selected.some(block => block.path.length > 1)) return undefined;
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
        transaction.setMeta(key, { selected: [], range: null, gesture: null, click: null });
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
      for (const { block, node } of replacements.reverse()) transaction.replaceWith(block.pos, block.pos + block.node.nodeSize, node);
      transaction.doc.check();
      editor.view.dispatch(transaction);
      editor.view.dispatch(closeHistory(editor.state.tr));
      return true;
    },
    deleteSelected() {
      const state = value();
      if (!state?.selected.length) return false;
      const positions = selectedPositions(state.selected);
      const selected = records(editor.state.doc).filter(block => positions.has(block.pos));
      if (!selected.some(block => block.path.length > 1)) return false;
      let transaction = closeHistory(editor.state.tr);
      // A selected paragraph inside a list item represents that entire bullet
      // when it is the item's only child. Delete the listItem itself; deleting
      // just its required paragraph makes ProseMirror recreate an empty bullet.
      const ranges = selected.map(block => {
        const resolved = editor.state.doc.resolve(block.pos);
        if (resolved.parent.type.name === "listItem" && resolved.parent.childCount === 1) {
          const from = resolved.before(resolved.depth);
          return { from, to: from + resolved.parent.nodeSize };
        }
        return { from: block.pos, to: block.pos + block.node.nodeSize };
      });
      const unique = [...new Map(ranges.map(range => [range.from + ":" + range.to, range])).values()]
        .sort((a, b) => b.from - a.from);
      for (const range of unique) transaction.delete(range.from, range.to);
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
      if (name === "setContent" || (name === "setEditable" && args.editable === false)) { controller?.cancelPending(); update({ reset: true }); }
      if (name === "selectAllBlocks") {
        if (!canSelect()) return false;
        return update({ mode: "multi", selected: collapseNested(records(editor.state.doc).map(ref)), range: null, gesture: null });
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
          let decoratedDoc = null, decoratedSelection = null, selectedPaint = DecorationSet.empty;
          let paintedPosition = null, paintedDX = 0, movingPaint = DecorationSet.empty;
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
                let next = patch ? { ...state, ...patch, haptic: state.haptic } : state;
                if (previous.mode === "off" && next.mode !== "off") next = { ...next, dividerConverted: false };
                if (tr.getMeta("pennedDividerStyleConversion")) next = { ...next, dividerConverted: true };
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
                if (decoratedDoc !== state.doc || decoratedSelection !== selection.selected) {
                  const highlights = selection.selected.map(item => recordAt(state.doc, item.pos)).filter(Boolean)
                    .map(block => Decoration.node(block.pos, block.pos + block.node.nodeSize, { class: "penned-block-selected" }));
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
      })];
    },
  };
})();
"""#
}
#endif
