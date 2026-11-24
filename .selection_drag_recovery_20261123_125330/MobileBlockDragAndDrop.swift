#if os(iOS)
enum MobileBlockDragAndDrop {
    static let holdDuration = 2.0
    static let script = #"""
(() => {
  if (window.PennedBlockDragAndDrop) return;
  let editor, view, post, closeHistory, Fragment, Selection, key, TransferStep;
  let contact = null, active = null, pending = null, suppressUntil = 0, liftingContact = null;
  let interaction = null, lastTap = null;
  const releasedNativeTokens = new Set();
  const HOLD_MS = \#(holdDuration * 1000);
  const root = () => view?.dom;
  const log = (event, values = {}) => post?.("blockDragDiagnostic", {
    event, browserTS: Date.now(), contactID: interaction?.id || '-',
    token: interaction?.nativeToken || '-', owner: interaction?.owner || 'none',
    elapsedMS: interaction ? Math.round(performance.now() - interaction.started) : 0, ...values,
  });
  const setState = value => view.dispatch(view.state.tr.setMeta(key, value).setMeta("addToHistory", false));
  const point = args => {
    const scale = window.innerWidth / args.width;
    return { x: args.x * scale, y: args.y * scale };
  };
  const visible = element => element instanceof HTMLElement && element.isConnected &&
    !element.closest('[hidden], [inert], [data-active="false"], [data-legacy-toggle-body="closed"]') &&
    getComputedStyle(element).visibility !== "hidden" && element.getBoundingClientRect().height > 0;
  function unit(record) {
    let pos = record.pos, node = record.node;
    const at = view.state.doc.resolve(pos);
    // A list's first paragraph represents its row, including the marker and descendants.
    if (["listItem", "taskItem", "toggleItem"].includes(at.parent.type.name) && at.index() === 0) {
      pos = at.before(); node = at.parent;
    }
    return { pos, node, to: pos + node.nodeSize, element: view.nodeDOM(pos) };
  }
  function units(records) {
    const sorted = records.map(unit).sort((a, b) => a.pos - b.pos || b.to - a.to);
    return sorted.filter((item, index) => !sorted.slice(0, index).some(parent => parent.pos <= item.pos && parent.to >= item.to));
  }
  function recordAtPoint(p, target) {
    const selected = window.PennedBlockSelection.selectedRecords();
    // Prefer an already selected outer surface over a nested editable child.
    const hit = record => {
      const dom = view.nodeDOM(record.pos);
      return dom instanceof Element && dom.contains(target) && visible(dom);
    };
    const chosen = selected.find(hit);
    if (chosen) return chosen;
    let position;
    try { position = view.posAtDOM(target, 0); } catch { return null; }
    const at = view.state.doc.resolve(Math.max(0, Math.min(view.state.doc.content.size, position)));
    const positions = [position];
    for (let depth = at.depth; depth > 0; depth--) positions.push(at.before(depth));
    for (const pos of positions) {
      const record = window.PennedBlockSelection.recordAtPosition(pos);
      if (record && hit(record)) return record;
    }
    for (const pos of positions) {
      const node = view.state.doc.nodeAt(pos);
      // A container's chrome can be draggable even when its editable children
      // are the selection units (for example Calendar). Never lift schema-only
      // wrappers such as a date panel, tab registry, or table row on their own.
      const block = node?.isBlock && (node.type.spec.group || '').split(/\s+/).includes('block');
      const record = block ? { pos, node } : null;
      if (record && hit(record)) return record;
    }
    return null;
  }
  function eligibilityReason(target) {
    if (!(target instanceof Element) || !root()?.contains(target)) return 'outside-editor';
    if (pending || active) return 'drag-or-transfer-busy';
    if (!editor.options.editable) return 'editor-read-only';
    if (editor.view.composing) return 'text-composition';
    if (target.closest('.penned-tabs-bar')) return 'dedicated-tab-control';
    if (target.closest('input, textarea, select')) return 'text-or-form-control';
    if (target.closest('audio, video, iframe')) return 'media-control';
    if (target.closest('.vellix-table-resizers, .vellix-task-metadata')) return 'resize-or-task-control';
    const control = target.closest('button, a, [role="button"]');
    return control && !control.closest('.vellix-page-reference, .penned-file-card, .penned-code-viewer, .vellix-property') ? 'dedicated-block-control' : null;
  }
  const eligible = target => !eligibilityReason(target);
  function transition(owner, reason) {
    if (!interaction || interaction.owner === owner) return;
    const previous = interaction.owner;
    interaction.owner = owner;
    log('owner-transition', { previous, reason });
  }
  function suppressSelection(current) {
    if (interaction !== current || current.owner !== 'pending' || !current.down || !current.reorderable) return;
    current.surface.classList.add('penned-reorder-hold-surface');
    root().classList.add('penned-reorder-arming');
    const element = current.target instanceof Element ? current.target : current.surface;
    const style = getComputedStyle(element), blockStyle = getComputedStyle(current.surface);
    log('text-suppression', { userSelect: style.webkitUserSelect || style.userSelect,
      blockUserSelect: blockStyle.webkitUserSelect || blockStyle.userSelect,
      effective: (style.webkitUserSelect || style.userSelect) === 'none', blockType: current.blockType });
  }
  function releaseSuppression(current = interaction) {
    clearTimeout(current?.suppressionTimer);
    current?.surface?.classList.remove('penned-reorder-hold-surface');
    root()?.classList.remove('penned-reorder-arming');
  }
  function beginContact(event) {
    if (!root()?.contains(event.target)) {
      log('contact-input-rejected', { source: event.source || 'touch', reason: root() ? 'outside-editor' : 'editor-root-unavailable' });
      return;
    }
    if (active || pending || liftingContact) { log('dom-contact-rejected', { reason: 'drag-or-transfer-busy' }); return; }
    if (event.touches.length !== 1) { cancelContact({ reason: 'additional-dom-touch' }); return; }
    const touch = event.touches[0], p = { x: touch.clientX, y: touch.clientY };
    if (interaction?.down && interaction.awaitingDOM && !releasedNativeTokens.has(interaction.nativeToken) && event.source !== 'native-hit-test' &&
        Math.hypot(p.x - interaction.x, p.y - interaction.y) <= 24) {
      interaction.identifier = touch.identifier; interaction.awaitingDOM = false;
      log('contact-input-joined', { source: event.source || 'touch', identifier: touch.identifier });
      return;
    }
    if (interaction?.down) cancelContact({ reason: 'contact-replaced' });
    releaseSuppression();
    const eligibility = eligibilityReason(event.target);
    const record = !eligibility ? recordAtPoint(p, event.target) : null;
    const selectedRecords = window.PennedBlockSelection.selectedRecords();
    const selected = record && selectedRecords.some(item => item.pos === record.pos);
    const multiTap = !selectedRecords.length && lastTap && performance.now() - lastTap.time < 350 && Math.hypot(p.x - lastTap.x, p.y - lastTap.y) < 24;
    const native = window.getSelection();
    const textRange = !selected && editor.isFocused && native && !native.isCollapsed && root().contains(native.anchorNode);
    const reorderable = !!record && !multiTap && !textRange;
    const origin = record && unit(record);
    const rejection = multiTap ? 'text-multitap' : textRange ? 'existing-text-selection' : eligibility || (!record ? 'no-selectable-block-at-contact' : null);
    interaction = { id: crypto.randomUUID(), nativeToken: null, identifier: touch.identifier, down: true,
      started: performance.now(), x: p.x, y: p.y, owner: reorderable ? 'pending' : 'control',
      sourceID: record?.node.attrs.id || event.target.closest?.('[data-vellix-block-id]')?.dataset.vellixBlockId || '-',
      blockType: origin?.node.type.name || 'control', rejection,
      sourcePos: record?.pos, selected: !!selected, target: event.target,
      surface: origin?.element, reorderable, awaitingDOM: event.source === 'native-hit-test', reported: new Set() };
    log(event.source === 'native-hit-test' ? 'native-hit-test-contact' : 'dom-contact-start', {
      source: event.source || 'touch', sourceID: interaction.sourceID, blockType: interaction.blockType, selected: !!selected,
      reorderable, count: selectedRecords.length, reason: rejection || 'block' });
    if (reorderable) {
      const current = interaction;
      current.suppressionTimer = setTimeout(() => suppressSelection(current), 320);
    }
  }
  function observeMovement(event) {
    if (!interaction?.down || interaction.owner !== 'pending') return;
    const touch = [...event.touches].find(item => item.identifier === interaction.identifier);
    if (!touch) return;
    const dx = touch.clientX - interaction.x, dy = touch.clientY - interaction.y;
    if (!interaction.selected && (Math.abs(dy) >= 10 || (Math.abs(dy) >= 8 && Math.abs(dy) >= Math.abs(dx) / 1.8))) {
      transition('scroll', 'vertical-motion-from-unselected-area'); releaseSuppression();
    }
  }
  function endContact(event) {
    if (!interaction?.down || ![...event.changedTouches].some(item => item.identifier === interaction.identifier)) return;
    // A native .began deliberately cancels DOM delivery; UIKit now tracks the finger.
    if (interaction.owner === 'reorder' || contact?.nativeRecognized ||
        (contact && interaction.owner === 'pending' && (event.type === 'touchcancel' || performance.now() - interaction.started >= HOLD_MS - 200))) {
      interaction.domEnded = true;
      log('dom-contact-cancel-delivered', { reason: 'native-reorder-retains-ownership' }); return;
    }
    interaction.down = false;
    releaseSuppression();
    const elapsed = performance.now() - interaction.started;
    if (event.type === 'touchcancel') transition('cancelled', 'dom-touch-cancelled');
    else if (interaction.owner === 'pending') {
      transition(elapsed < 320 ? 'tap' : 'cancelled', elapsed < 320 ? 'short-tap' : 'unrecognized-hold-released');
      if (elapsed < 320) lastTap = { time: performance.now(), x: interaction.x, y: interaction.y };
      else suppressUntil = performance.now() + 600;
    }
    log('dom-contact-end', { reason: event.type });
  }
  function arm(args) {
    const reject = reason => {
      log('arm-rejected', { token: args.token, reason });
      return { accepted: false, contactID: interaction?.id || '-', owner: interaction?.owner || 'none', reason };
    };
    if (releasedNativeTokens.has(args.token)) return reject('native-contact-already-released');
    if (!editor || !view || view.isDestroyed) return reject('editor-runtime-unavailable');
    if (active || pending || liftingContact) return reject('drag-or-transfer-busy');
    // UIKit starts a new token for a new single-finger contact. Do not join it
    // to a released contact whose terminal DOM event never reached the editor.
    if (interaction?.nativeToken && interaction.nativeToken !== args.token) {
      log('native-contact-rebased', { token: args.token, reason: 'new-native-contact' });
      cancelContact({ token: interaction.nativeToken, reason: 'new-native-contact' });
      window.PennedBlockSelection.cancelGestureForReorder();
      window.PennedBlockSelection.clearContactInput();
      interaction = null;
    }
    const p = point(args);
    const target = document.elementFromPoint(p.x, p.y);
    // UIKit already owns the physical contact. Resolve its block immediately;
    // a missing DOM TouchEvent must not make native hold recognition impossible.
    if (!interaction?.down) {
      if (!target) return reject('native-hit-test-empty');
      if (!root()?.contains(target)) return reject('native-contact-outside-editor');
      beginContact({ target, source: 'native-hit-test',
        touches: [{ identifier: 'native:' + args.token, clientX: p.x, clientY: p.y }] });
    }
    if (!interaction?.down) return reject('contact-unavailable-after-hit-test');
    if (Math.hypot(p.x - interaction.x, p.y - interaction.y) > 24) return reject('contact-coordinate-mismatch');
    interaction.nativeToken = args.token;
    if (interaction.owner !== 'pending' || !interaction.reorderable) return reject(interaction.rejection || 'contact-owned-by-' + interaction.owner);
    if (window.PennedBlockSelection.hasActiveGesture) return reject('selection-already-owns-contact');
    const record = recordAtPoint(p, target);
    if (!record) return reject('no-block-at-contact');
    if (interaction.sourceID !== '-' && record.node.attrs.id !== interaction.sourceID) return reject('contact-source-changed');
    const selected = window.PennedBlockSelection.selectedRecords();
    const source = units(interaction.selected ? selected : [record]);
    if (!source.length || source.some(item => !(item.element instanceof HTMLElement))) return reject('source-dom-unavailable');
    const origin = unit(record);
    interaction.target = target;
    interaction.surface = origin.element;
    contact = { token: args.token, doc: view.state.doc, source, origin: origin.pos, holdSurface: origin.element,
      owner: 'pending', started: interaction.started, point: p };
    log('arm-accepted', { count: source.length, selected: interaction.selected, blockType: origin.node.type.name, sourceID: interaction.sourceID });
    return { accepted: true, contactID: interaction.id, owner: interaction.owner };
  }
  function clearHoldSuppression(held) {
    if (!held) return;
    releaseSuppression();
    held.holdSurface.classList.remove('penned-reorder-hold-surface');
  }
  function authorizeSelection(source, details = {}) {
    let reason = null;
    const gesture = source === 'swipe' || source === 'range';
    if (active || pending || liftingContact || interaction?.owner === 'reorder') reason = 'reorder-or-transfer-owns-contact';
    else if (gesture) {
      if (!interaction?.down || interaction.identifier !== details.identifier) reason = 'no-matching-contact';
      else if (!['pending', 'selection'].includes(interaction.owner)) reason = 'contact-owned-by-' + interaction.owner;
      else if (interaction.owner !== 'selection' && performance.now() - interaction.started >= HOLD_MS) reason = 'hold-deadline-passed';
      else if (interaction.owner !== 'selection' && !interaction.selectionTracking && performance.now() - interaction.started > 320) reason = 'stationary-hold-reserved';
      else if (source === 'range' && !interaction.selected) reason = 'range-must-start-selected';
      else if (source === 'swipe' && details.dx >= 0) reason = 'selection-entry-requires-left-swipe';
    } else if (source === 'click') {
      if (interaction && (interaction.down || !['tap', 'control'].includes(interaction.owner)) && performance.now() - interaction.started < 3000) reason = 'not-a-completed-tap';
    } else if (!source.startsWith('command:')) reason = 'unauthorized-selection-entry';
    else if (interaction?.down && interaction.owner === 'pending') reason = 'hold-pending';
    const accepted = !reason;
    // Range movement calls this once when it commits, not once per frame.
    log('selection-entry-attempt', { source, accepted, reason: reason || 'authorized', ...details });
    if (accepted && gesture && interaction.owner !== 'selection') {
      transition('selection', source === 'range' ? 'selected-surface-range-motion' : 'left-swipe-committed');
      releaseSuppression();
      if (contact) contact.owner = 'selection';
      if (interaction.nativeToken) post('blockDragSelectionClaimed', { token: interaction.nativeToken });
    }
    return accepted;
  }
  function noteSelectionMotion(identifier) {
    if (!interaction?.down || interaction.identifier !== identifier || interaction.owner !== 'pending') return;
    if (interaction.selectionTracking || performance.now() - interaction.started > 320) return;
    interaction.selectionTracking = true;
    log('selection-motion-tracking', { reason: 'motion-before-hold-reservation' });
  }
  function releaseHold(args) {
    if (args.token) {
      releasedNativeTokens.add(args.token);
      if (releasedNativeTokens.size > 128) releasedNativeTokens.delete(releasedNativeTokens.values().next().value);
    }
    if (args.token && interaction?.nativeToken && interaction.nativeToken !== args.token) {
      log('stale-hold-release-discarded', { token: args.token, contactID: args.contactID || '-' }); return false;
    }
    if (contact && contact.token === args.token && !contact.nativeRecognized) {
      clearHoldSuppression(contact); contact = null;
    }
    if (interaction && interaction.nativeToken === args.token && interaction.owner === 'pending') {
      releaseSuppression();
      const motionOrTap = ['movement-before-hold', 'selection-committed', 'released-before-hold'].includes(args.reason);
      if (interaction.domEnded || interaction.awaitingDOM || !motionOrTap) {
        transition('cancelled', args.reason || 'native-hold-abandoned'); interaction.down = false;
      }
    }
    log('native-hold-released', { token: args.token, reason: args.reason });
    return true;
  }
  function cancelContact(args = {}) {
    if (args.token && interaction?.nativeToken !== args.token) {
      releaseHold(args);
      log('stale-contact-cancel-rejected', { token: args.token }); return false;
    }
    const live = interaction?.down || active || contact || liftingContact;
    // Document loading also cancels gestures before the first finger contact.
    if (!live && !args.token) return true;
    if (interaction && live) {
      transition('cancelled', args.reason || 'cancelled'); interaction.down = false;
      suppressUntil = performance.now() + 600;
    }
    const token = args.token || interaction?.nativeToken || contact?.token;
    releaseHold({ ...args, token }); cancel(args);
    if (live) log('ownership-released', { reason: args.reason || 'cancelled' });
    return true;
  }
  function allowBlockHold(event, source) {
    const target = event?.target;
    const touch = event?.pointerType === 'touch' || event?.type?.startsWith('touch') ||
      (event?.type === 'contextmenu' && event.pointerType !== 'mouse' && interaction && performance.now() - interaction.started < 3000);
    const blocked = touch && (active || liftingContact || (eligible(target) && recordAtPoint({ x: event.clientX || 0, y: event.clientY || 0 }, target)));
    if (touch && (!interaction || !interaction.reported.has('hold:' + source))) {
      interaction?.reported.add('hold:' + source);
      log(blocked ? 'competing-hold-rejected' : 'control-hold-permitted', { source, reason: blocked ? 'block-hold-reserved-for-reorder' : 'dedicated-control-or-nonreorder-surface' });
    }
    return !blocked;
  }
  function protectTextSelection(event) {
    if (!interaction?.down || !interaction.reorderable || !['pending', 'reorder'].includes(interaction.owner) ||
        performance.now() - interaction.started < 320) return;
    if (event.type === 'selectstart') {
      event.preventDefault(); log('native-text-selection-rejected', { source: 'selectstart', prevented: event.defaultPrevented });
    } else {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !root().contains(selection.anchorNode)) return;
      selection.removeAllRanges(); log('native-text-selection-rejected', { source: 'selectionchange' });
    }
  }
  function containerDOM(pos) {
    if (pos < 0) return root();
    const dom = view.domAtPos(pos + 1).node;
    return dom instanceof Element ? dom : dom.parentElement;
  }
  function destinationIndex(doc) {
    const containers = new Map(), pages = new Map();
    const add = (node, pos, depth) => {
      let element = pos < 0 ? root() : view.nodeDOM(pos);
      if (!(element instanceof HTMLElement)) return;
      if (node.type.name === 'pageReference' && node.attrs.documentID) pages.set(element, { node, pos, element });
      // Only actual block-content slots are destinations, never a tab's panel
      // registry, a table row, a title, or another schema's structural wrapper.
      if (!node.isTextblock && (node.type.name === 'doc' ||
          /\bblock[+*]?/.test(node.type.spec.content || ''))) {
        const content = containerDOM(pos);
        let expandPos = pos, collapsed = node.attrs.open === false || node.attrs.collapsible && node.attrs.collapsed;
        if (['informationCardBody', 'weekDayPanel'].includes(node.type.name)) {
          const at = doc.resolve(pos);
          for (let d = at.depth; d > 0; d--) {
            const owner = at.node(d);
            if (['informationCard', 'weekStrip'].includes(owner.type.name) && owner.attrs.collapsed === true) {
              if (node.type.name === 'weekDayPanel' && !element.hasAttribute('data-active')) return;
              expandPos = at.before(d); element = view.nodeDOM(expandPos); collapsed = true; break;
            }
          }
        }
        containers.set(element, { node, pos, depth, element, content, expandPos, collapsed, children: null, allowed: new Map() });
      }
    };
    add(doc, -1, 0);
    doc.descendants((node, pos) => { add(node, pos, doc.resolve(pos).depth + 1); });
    return { containers, pages };
  }
  function lift(args) {
    const reason = !contact ? 'no-armed-contact' : contact.token !== args.token ? 'contact-replaced' :
      contact.owner !== 'pending' || interaction?.owner !== 'pending' ? 'contact-owned-by-' + (interaction?.owner || 'none') : contact.doc !== view.state.doc ? 'source-document-changed' :
      pending ? 'transfer-pending' : null;
    log('javascript-lift-request', { token: args.token, accepted: !reason, reason: reason || 'native-hold-recognized' });
    if (reason) { log('lift-rejected', { token: args.token, reason }); cancelContact({ ...args, reason }); return false; }
    const held = contact;
    held.nativeRecognized = true;
    transition('reorder', 'native-long-press-recognized');
    held.owner = 'reorder'; liftingContact = held;
    contact = null;
    window.PennedBlockSelection.cancelGestureForReorder();
    // Existing blur handling removes unused tap-created caret slots. Finish
    // that cleanup before capturing move positions, never during the move.
    root().blur(); window.getSelection()?.removeAllRanges();
    if (view.state.doc !== held.doc) {
      const mapped = new Map(), ids = new Set(held.source.map(item => item.node.attrs.id));
      view.state.doc.descendants((node, pos) => {
        if (node.attrs.id && ids.has(node.attrs.id)) {
          if (mapped.has(node.attrs.id)) mapped.set(node.attrs.id, null);
          else mapped.set(node.attrs.id, { node, pos, to: pos + node.nodeSize, element: view.nodeDOM(pos) });
        }
      });
      const source = held.source.map(item => mapped.get(item.node.attrs.id));
      if (source.some(item => !item || !(item.element instanceof HTMLElement))) {
        clearHoldSuppression(held);
        log('lift-rejected', { token: args.token, reason: 'source-lost-during-blur-cleanup' }); cancel(); return false;
      }
      const origin = held.source.findIndex(item => item.pos === held.origin);
      held.origin = source[Math.max(0, origin)].pos;
      held.source = source; held.doc = view.state.doc;
    }
    contact = held;
    const preview = document.createElement('div');
    preview.className = 'penned-reorder-preview tiptap-editor';
    const appearance = getComputedStyle(root());
    for (const name of appearance) if (name.startsWith('--')) preview.style.setProperty(name, appearance.getPropertyValue(name));
    preview.style.font = appearance.font;
    preview.style.color = appearance.color;
    const source = contact.source;
    const rect = source[0].element.getBoundingClientRect();
    const width = Math.min(rect.width, window.innerWidth - 32);
    preview.style.width = `${width}px`;
    const clone = source[0].element.cloneNode(true);
    const cloneIDs = new Map(), prefix = `penned-drag-${crypto.randomUUID()}`;
    for (const element of [clone, ...clone.querySelectorAll('[id]')]) if (element.id) {
      const old = element.id, id = `${prefix}-${cloneIDs.size}`;
      cloneIDs.set(old, id); element.id = id;
    }
    for (const element of [clone, ...clone.querySelectorAll('*')]) for (const attribute of [...element.attributes]) {
      let value = attribute.value;
      for (const [old, id] of cloneIDs) {
        value = value.split(`url(#${old})`).join(`url(#${id})`);
        if (['href', 'xlink:href'].includes(attribute.name) && value === `#${old}`) value = `#${id}`;
      }
      if (value !== attribute.value) element.setAttribute(attribute.name, value);
    }
    const originalCanvases = source[0].element.querySelectorAll('canvas');
    clone.querySelectorAll('canvas').forEach((canvas, index) => {
      try { canvas.getContext('2d')?.drawImage(originalCanvases[index], 0, 0); } catch { /* Non-2D media can still use its surrounding block preview. */ }
    });
    clone.classList.remove('penned-block-selected', 'penned-callout-block-selected');
    clone.style.cssText += ';margin:0!important;width:100%!important;max-width:100%!important;transform:none!important';
    clone.querySelectorAll('audio,video,iframe').forEach(element => element.remove());
    preview.append(clone);
    if (source.length > 1) {
      preview.classList.add('penned-reorder-stack');
      const badge = document.createElement('span');
      badge.className = 'penned-reorder-count'; badge.textContent = String(source.length); preview.append(badge);
    }
    const indicator = document.createElement('div'); indicator.className = 'penned-reorder-insertion';
    indicator.hidden = true;
    document.body.append(preview, indicator);
    source.forEach(item => item.element.classList.add('penned-reorder-source'));
    active = { ...contact, ...destinationIndex(contact.doc), preview, indicator,
      fragments: new WeakMap(),
      anchorX: Math.min(width - 12, Math.max(12, contact.point.x - rect.left)),
      target: null, targetKey: null, pageElement: null, pageValidation: new Map() };
    contact = null;
    liftingContact = null;
    root().classList.add('penned-reorder-active');
    setState({ dragging: true, busy: false });
    log('lift', { token: args.token, count: source.length });
    move(args);
    return true;
  }
  function fragmentFor(parent, source) {
    if (active.fragments.has(parent)) return active.fragments.get(parent);
    const nodes = [];
    let previousList = null;
    for (const item of source) {
      let node = item.node;
      if (['listItem', 'taskItem'].includes(node.type.name) && !parent.type.validContent(Fragment.from(node))) {
        const at = active.doc.resolve(item.pos), list = at.parent;
        const previous = nodes[nodes.length - 1];
        if (previousList === list && previous?.type === list.type) {
          nodes[nodes.length - 1] = previous.copy(previous.content.append(Fragment.from(node)));
          continue;
        }
        const attrs = { ...list.attrs, id: crypto.randomUUID() };
        if (list.type.name === 'orderedList') attrs.start = (list.attrs.start || 1) + at.index();
        node = list.type.create(attrs, Fragment.from(node), list.marks);
        previousList = list;
      } else previousList = null;
      nodes.push(node);
    }
    const fragment = Fragment.fromArray(nodes);
    active.fragments.set(parent, fragment);
    return fragment;
  }
  const insideSource = pos => active.source.some(item => pos >= item.pos && pos < item.to);
  function chooseTarget(p) {
    const candidates = [], containers = [active.containers.get(root())], pages = [];
    // Hit-test once, then inspect only actual ancestors. Do not measure every
    // block in a long document on every display frame.
    for (let element = document.elementFromPoint(p.x, p.y); element; element = element.parentElement) {
      const container = active.containers.get(element), page = active.pages.get(element);
      if (container && container.pos >= 0) containers.push(container);
      if (page) pages.push(page);
      if (element === root()) break;
    }
    for (const page of pages) {
      if (insideSource(page.pos) || !visible(page.element)) continue;
      const r = page.element.getBoundingClientRect();
      if (p.x >= r.left && p.x <= r.right && p.y > r.top + Math.min(16, r.height / 4) && p.y < r.bottom - Math.min(16, r.height / 4)) {
        let validation = active.pageValidation.get(page.node.attrs.documentID);
        if (!validation) {
          const pageIDs = new Set();
          const collect = node => {
            if (['pageReference', 'collection'].includes(node.type.name) && node.attrs.documentID) pageIDs.add(node.attrs.documentID);
            node.forEach(collect);
          };
          active.source.forEach(item => collect(item.node));
          validation = { allowed: null };
          validation.promise = new Promise(resolve => { validation.resolve = resolve; });
          active.pageValidation.set(page.node.attrs.documentID, validation);
          post('blockDropValidate', { token: active.token, destinationID: page.node.attrs.documentID, pageIDs: [...pageIDs] });
        }
        active.awaitingValidation = validation.allowed === null ? validation : null;
        if (validation.allowed !== true) return null;
        return { kind: 'page', id: page.node.attrs.documentID, pos: page.pos, page,
          x: r.left + 12, y: r.top + 12, width: Math.max(24, r.width - 24), key: `page:${page.node.attrs.documentID}` };
      }
    }
    for (const container of containers) {
      if (!container) continue;
      if (container.pos >= 0 && (insideSource(container.pos) || !visible(container.element))) continue;
      const r = container.element.getBoundingClientRect();
      if (container.pos >= 0 && (p.y < r.top - 12 || p.y > r.bottom + 16 || p.x < r.left - 8 || p.x > r.right + 12)) continue;
      const start = container.pos + 1, collapsed = container.collapsed;
      const contentRect = collapsed ? { left: r.left + 16, right: r.right - 16, top: r.bottom - 8 } : container.content.getBoundingClientRect();
      const first = container.node.type.name === 'toggleItem' ? 1 :
        container.node.type.name === 'informationCardBody' && container.node.firstChild?.type.name === 'informationCardLabel' ? 1 : 0;
      const fragment = fragmentFor(container.node, active.source);
      const uniformBlocks = ['block+', 'block*', '(block | pageBoundary)+'].includes(container.node.type.spec.content);
      const fitsUniform = container.uniformFit ??= uniformBlocks && container.node.type.contentMatch.matchFragment(fragment)?.validEnd === true;
      if (!container.children) {
        container.boundaries = [start];
        container.children = [];
        container.node.forEach((node, childOffset, index) => {
          const pos = start + childOffset, element = view.nodeDOM(pos);
          container.boundaries.push(pos + node.nodeSize);
          if (element instanceof HTMLElement && visible(element)) container.children.push({ index, pos, element });
        });
      }
      const children = container.children;
      let low = 0, high = children.length;
      while (low < high) {
        const middle = (low + high) >> 1;
        if (children[middle].element.getBoundingClientRect().bottom < p.y) low = middle + 1;
        else high = middle;
      }
      const indexes = new Set(collapsed ? [container.node.childCount] : [first, container.node.childCount]);
      for (let i = Math.max(0, low - 1); i <= Math.min(children.length - 1, low + 1); i++) {
        indexes.add(children[i].index); indexes.add(children[i].index + 1);
      }
      for (const index of indexes) {
        const pos = container.boundaries[index];
        if (!container.allowed.has(index)) container.allowed.set(index, fitsUniform || container.node.canReplace(index, index, fragment));
        if (index >= first && (!collapsed || index === container.node.childCount) && container.allowed.get(index)) {
          let from = 0, to = children.length;
          while (from < to) {
            const middle = (from + to) >> 1;
            if (children[middle].index < index) from = middle + 1;
            else to = middle;
          }
          const before = children[from - 1], after = children[from];
          const beforeRect = before?.element.getBoundingClientRect(), afterRect = after?.element.getBoundingClientRect();
          const y = collapsed ? r.bottom - 6 : beforeRect && afterRect ? (beforeRect.bottom + afterRect.top) / 2 :
            afterRect ? afterRect.top : beforeRect ? beforeRect.bottom + 4 : contentRect.top + 12;
          const left = container.pos < 0 ? r.left : Math.max(r.left + 16, contentRect.left);
          const desiredDepth = Math.max(0, (p.x - root().getBoundingClientRect().left - 12) / 24);
          candidates.push({ kind: 'slot', pos, container, index, fragment, x: left, y,
            width: Math.max(24, Math.min(r.right, contentRect.right) - left),
            score: Math.abs(p.y - y) + Math.abs(desiredDepth - container.depth) * 12 - (collapsed && p.x >= left ? 24 : 0),
            key: `slot:${container.pos}:${index}` });
        }
      }
    }
    return candidates.sort((a, b) => a.score - b.score || b.container.depth - a.container.depth)[0] || null;
  }
  function move(args) {
    if (!active || active.token !== args.token) return false;
    if (active.doc !== view.state.doc) { cancel(); return false; }
    const p = point(args);
    active.lastArgs = args;
    active.awaitingValidation = null;
    active.preview.style.transform = `translate3d(${Math.max(8, Math.min(window.innerWidth - active.preview.offsetWidth - 8, p.x - active.anchorX))}px,${p.y - 24}px,0)`;
    const target = chooseTarget(p);
    if (active.pageElement !== target?.page?.element) {
      active.pageElement?.classList.remove('penned-reorder-page-target');
      active.pageElement = target?.page?.element || null;
      active.pageElement?.classList.add('penned-reorder-page-target');
    }
    active.target = target;
    active.indicator.hidden = !target;
    if (target) {
      Object.assign(active.indicator.style, { left: `${target.x}px`, top: `${target.y}px`, width: `${target.width}px` });
      if (target.key !== active.targetKey) {
        post('blockDragHaptic', { token: active.token, destination: target.key });
        log('destination', { token: active.token, kind: target.kind, depth: target.container?.depth ?? -1, position: target.pos });
      }
    }
    if (!target && active.targetKey) post('blockDragHaptic', { token: active.token, destination: '' });
    active.targetKey = target?.key || null;
    return true;
  }
  function removalTransaction(source, doc) {
    const ranges = source.map(item => ({ from: item.pos, to: item.to }));
    // Remove an exhausted list wrapper rather than leave an invalid empty list.
    doc.descendants((node, pos) => {
      if (!['bulletList', 'orderedList', 'taskList'].includes(node.type.name)) return;
      let all = true;
      node.forEach((child, offset) => { if (!ranges.some(range => range.from <= pos + 1 + offset && range.to >= pos + 1 + offset + child.nodeSize)) all = false; });
      if (all) ranges.push({ from: pos, to: pos + node.nodeSize });
    });
    const unique = ranges.sort((a, b) => a.from - b.from || b.to - a.to)
      .filter((range, index, all) => !all.slice(0, index).some(parent => parent.from <= range.from && parent.to >= range.to));
    const tr = closeHistory(view.state.tr);
    tr.setMeta('pennedPlaceholderDeletion', unique.map(range => ({ ...range })));
    for (const range of unique.reverse()) {
      const at = tr.doc.resolve(range.from), end = tr.doc.resolve(range.to);
      if (!at.sameParent(end)) throw new Error('The block structure changed during dragging.');
      const parent = at.parent, from = at.index(), to = end.index();
      const suffix = parent.content.cutByIndex(to, parent.childCount);
      const filler = parent.contentMatchAt(from).fillBefore(suffix, true);
      if (!filler) throw new Error('This container requires its structural content.');
      tr.replaceWith(range.from, range.to, filler);
    }
    tr.doc.check();
    return tr;
  }
  function requestTransfer(tr, token, forward, destinationID, blocks) {
    if (pending || !tr.before.eq(view.state.doc)) return false;
    // Honor existing template/placeholder and other transaction guards before
    // committing a cross-document write. Do not discover a rejection afterward.
    tr.setMeta('pennedDropApproved', token);
    for (const plugin of view.state.plugins) {
      if (plugin.spec.filterTransaction && !plugin.spec.filterTransaction.call(plugin, tr, view.state)) {
        post('error', { message: 'This block move is not allowed by the current document.' });
        log('transfer-filter-rejected', { token }); return false;
      }
    }
    pending = { tr, token, before: view.state.doc };
    setState({ dragging: false, busy: true });
    post('blockDropTransfer', { token, forward, destinationID: destinationID || null,
      sourceBefore: view.state.doc.toJSON(), sourceAfter: tr.doc.toJSON(), blocks: blocks || null });
    log('transfer-request', { token, forward });
    return true;
  }
  async function finish(args) {
    if (!active || active.token !== args.token) { cancel(); return false; }
    move(args);
    if (active?.awaitingValidation) {
      const waiting = active.awaitingValidation;
      let timeout;
      await Promise.race([waiting.promise, new Promise(resolve => { timeout = setTimeout(resolve, 2000); })]);
      clearTimeout(timeout);
      if (!active || active.token !== args.token) return false;
      move(args);
    }
    if (!active?.target) { cancel(); return false; }
    try {
      const drag = active, target = drag.target;
      if (target.kind === 'slot' && target.pos === drag.origin) {
        clearVisuals(); log('drop-original-position', { token: args.token }); return true;
      }
      const tr = removalTransaction(drag.source, drag.doc);
      if (target.kind === 'page') {
        const blocks = fragmentFor(view.state.doc, drag.source).toJSON();
        const token = crypto.randomUUID();
        tr.step(new TransferStep(token, true));
        clearVisuals();
        return requestTransfer(tr, token, true, target.id, blocks);
      }
      const destination = tr.mapping.map(target.pos, -1);
      const resolved = tr.doc.resolve(destination);
      if (!resolved.parent.canReplace(resolved.index(), resolved.index(), target.fragment)) throw new Error('This drop location changed.');
      tr.insert(destination, target.fragment);
      const containerPos = target.container.expandPos;
      if (containerPos >= 0) {
        const pos = tr.mapping.map(containerPos, -1), node = tr.doc.nodeAt(pos);
        if (node?.type.name === 'toggleItem' && node.attrs.open === false) tr.setNodeAttribute(pos, 'open', true);
        if ((node?.attrs.collapsible || node?.type.name === 'weekStrip') && node.attrs.collapsed) tr.setNodeAttribute(pos, 'collapsed', false);
      }
      tr.doc.check();
      const unchanged = tr.doc.eq(view.state.doc);
      clearVisuals();
      if (!unchanged) {
        tr.setSelection(Selection.near(tr.doc.resolve(Math.min(destination, tr.doc.content.size))));
        const before = view.state.doc;
        view.dispatch(tr.setMeta('pennedReorderCommit', true));
        if (view.state.doc === before) throw new Error('The current document did not accept this move.');
        view.dispatch(closeHistory(view.state.tr).setMeta('addToHistory', false));
        window.PennedBlockSelection.setMode('off');
      }
      log(unchanged ? 'drop-original-position' : 'drop-committed', { token: args.token, count: drag.source.length, depth: target.container.depth });
      return true;
    } catch (error) {
      cancel(); post('error', { message: error.message }); log('drop-rejected', { token: args.token }); return false;
    }
  }
  function clearVisuals() {
    const lifted = !!active;
    clearHoldSuppression(active || contact || liftingContact);
    active?.source.forEach(item => item.element.classList.remove('penned-reorder-source'));
    active?.pageElement?.classList.remove('penned-reorder-page-target');
    active?.preview.remove(); active?.indicator.remove();
    if (lifted && interaction?.owner === 'reorder') {
      transition('released', 'drag-completed'); interaction.down = false;
      log('ownership-released');
    }
    active = contact = null; liftingContact = null;
    root()?.classList.remove('penned-reorder-arming', 'penned-reorder-active');
    if (lifted) suppressUntil = performance.now() + 600;
    if (view && key && (lifted || key.getState(view.state)?.dragging)) setState({ dragging: false, busy: !!pending });
  }
  function cancel(args) {
    if (args?.token && (active || contact || liftingContact) && args.token !== (active || contact || liftingContact).token) return false;
    if (interaction && ['pending', 'reorder'].includes(interaction.owner)) {
      transition('cancelled', args?.reason || 'drag-invalidated'); interaction.down = false;
    }
    if (active) log('drag-cancelled', { token: active.token });
    clearVisuals();
    return true;
  }
  function validatePage(args) {
    if (!active || active.token !== args.token) return false;
    const validation = active.pageValidation.get(args.destinationID);
    if (!validation) return false;
    validation.allowed = args.allowed === true;
    validation.resolve();
    if (active.lastArgs) move(active.lastArgs);
    return true;
  }
  function applyExternal(args) {
    if (!view || pending || active) return false;
    const next = editor.schema.nodeFromJSON(args.document);
    next.check();
    const before = view.state.doc;
    // Keep the unchanged tail and its maps so earlier edits remain undoable.
    let oldEnd = before.content.size, newEnd = next.content.size;
    let oldIndex = before.childCount - 1, newIndex = next.childCount - 1;
    while (oldIndex >= 0 && newIndex >= 0 && before.child(oldIndex).eq(next.child(newIndex))) {
      oldEnd -= before.child(oldIndex--).nodeSize;
      newEnd -= next.child(newIndex--).nodeSize;
    }
    if (!oldEnd && !newEnd) return true;
    const tr = view.state.tr.replaceWith(0, oldEnd, next.content.cut(0, newEnd))
      .setMeta('addToHistory', false).setMeta('preventUpdate', true)
      .setMeta('pennedDropApproved', 'destination')
      .setMeta('pennedPlaceholderDeletion', oldEnd ? [{ from: 0, to: oldEnd }] : []);
    tr.doc.check();
    view.dispatch(tr);
    log('destination-prefix-applied');
    return view.state.doc.eq(next);
  }
  function resolveTransfer(args) {
    const request = pending;
    if (!request || request.token !== args.token) return false;
    pending = null;
    if (!args.success || request.before !== view.state.doc) {
      setState({ dragging: false, busy: false });
      post('error', { message: args.message || 'The document changed before the drop could complete.' });
      log('transfer-rejected', { token: args.token }); return false;
    }
    view.dispatch(request.tr.setMeta('pennedDropApproved', request.token));
    if (view.state.doc === request.before && !request.tr.doc.eq(request.before)) {
      setState({ dragging: false, busy: true });
      log('transfer-editor-rejected', { token: args.token }); return false;
    }
    view.dispatch(closeHistory(view.state.tr).setMeta('addToHistory', false));
    window.PennedBlockSelection.setMode('off');
    setState({ dragging: false, busy: false });
    log('transfer-committed', { token: args.token });
    return true;
  }
  window.PennedBlockDragAndDrop = {
    holdDurationMS: HOLD_MS,
    get busy() { return !!pending; },
    get handlingContact() { return !!contact || !!active; },
    get ownsReorder() { return !!active || !!liftingContact || contact?.owner === 'reorder'; },
    get reservesHold() { return !!active || !!liftingContact || contact?.owner === 'pending' || contact?.owner === 'reorder'; },
    authorizeSelection,
    noteSelectionMotion,
    allowBlockHold,
    diagnostic: log,
    cancelForLifecycle(reason) {
      cancelContact({ reason }); interaction = null; lastTap = null;
      window.PennedBlockSelection?.clearContactInput();
    },
    selectionContact(identifier, event) {
      // Selection can establish its contact from its own delivered event; it
      // never waits for a different sensor or an asynchronous native arm reply.
      if (!interaction?.down || interaction.awaitingDOM) beginContact(event);
      return interaction?.down && interaction.identifier === identifier && ['pending', 'selection'].includes(interaction.owner)
        ? { id: interaction.id, selected: interaction.selected } : false;
    },
    applyExternal,
    native(action, args) {
      const failed = error => {
        const frames = String(error?.stack || '').split('\n')
          .filter(line => /user-script|tiptap|vellix-editor|\.js/.test(line)).slice(0, 4).join(' | ');
        log('gesture-script-failed', { token: args?.token, reason: action, errorType: error?.name || 'unknown', frames });
        cancelContact({ ...args, reason: 'javascript-exception-' + action }); return false;
      };
      try {
        const result = ({ arm, lift, move, finish, cancel, cancelContact, releaseHold, resolveTransfer, validatePage })[action]?.(args) ?? false;
        return result?.then ? result.catch(failed) : result;
      } catch (error) { return failed(error); }
    },
    extensions(context) {
      ({ post, closeHistory, Fragment, Selection } = context);
      const { Extension, Plugin, PluginKey, Step, StepResult } = context;
      key = new PluginKey('pennedBlockReorder');
      TransferStep = class extends Step {
        constructor(token, forward) { super(); this.token = token; this.forward = forward; }
        apply(doc) { return StepResult.ok(doc); }
        invert() { return new TransferStep(this.token, !this.forward); }
        map() { return this; }
        toJSON() { return { stepType: 'pennedNestedBlockTransfer', token: this.token, forward: this.forward }; }
        static fromJSON(_schema, json) { return new TransferStep(json.token, json.forward); }
      };
      Step.jsonID('pennedNestedBlockTransfer', TransferStep);
      return [Extension.create({ name: 'pennedBlockReorder', priority: 1200,
        onBeforeCreate() { editor = this.editor; },
        addProseMirrorPlugins() {
          const owningEditor = this.editor;
          return [new Plugin({ key,
          state: { init: () => ({ dragging: false, busy: false }), apply: (tr, previous) => tr.getMeta(key) || previous },
          filterTransaction(tr) {
            if (tr.getMeta('pennedDropApproved')) return true;
            if (pending && tr.docChanged) return false;
            const step = tr.steps.find(step => step instanceof TransferStep);
            if (step) { queueMicrotask(() => requestTransfer(tr, step.token, step.forward)); return false; }
            return true;
          },
          props: {
            editable: state => !key.getState(state).dragging && !key.getState(state).busy,
            handleDOMEvents: {
              click(_view, event) {
                if (performance.now() >= suppressUntil && !active && !pending) return false;
                event.preventDefault(); event.stopImmediatePropagation(); return true;
              },
              contextmenu(_view, event) {
                if (!contact && !active) return false;
                event.preventDefault(); event.stopImmediatePropagation(); return true;
              },
            },
          },
          view(editorView) {
            // registerPlugin recreates PluginViews without firing beforeCreate.
            // Rebind both references on every mount, not only initial editor creation.
            editor = owningEditor;
            view = editorView;
            const style = document.createElement('style');
            style.textContent = `
              html .tiptap-editor.penned-reorder-arming,
              html .tiptap-editor.penned-reorder-active,
              html .tiptap-editor.penned-reorder-active *,
              html .tiptap-editor.penned-reorder-arming .penned-reorder-hold-surface,
              html .tiptap-editor.penned-reorder-arming .penned-reorder-hold-surface * { -webkit-user-select:none!important; user-select:none!important; -webkit-touch-callout:none!important; }
              .penned-reorder-source { opacity:.25!important; }
              .penned-reorder-preview { position:fixed; top:0; left:0; z-index:2147483645; pointer-events:none; max-height:124px; overflow:hidden; padding:10px; box-sizing:border-box; border:1px solid #b379ec; border-radius:10px; background:light-dark(#fff,#252329); color:light-dark(#17151c,#fff); box-shadow:0 12px 28px #0008; opacity:.96; font-family:inherit; }
              .penned-reorder-stack { max-height:100px; overflow:visible; box-shadow:0 5px 0 -1px #554468,0 9px 0 -2px #342c40,0 14px 25px #0008; }
              .penned-reorder-stack > :first-child { max-height:76px; overflow:hidden; }
              .penned-reorder-count { position:absolute; right:-10px; top:-14px; width:30px; height:30px; display:grid; place-items:center; border-radius:50%; background:#168be9; color:white; border:2px solid white; font:700 17px system-ui; }
              .penned-reorder-insertion { position:fixed; height:4px; border-radius:2px; background:#b875ff; box-shadow:0 0 0 1px #16101e,0 0 7px #b875ff; z-index:2147483646; pointer-events:none; }
              .penned-reorder-page-target { outline:3px solid #b875ff!important; outline-offset:3px; }
              .penned-reorder-active, .penned-reorder-active * { cursor:grabbing!important; }
            `;
            document.head.append(style);
            const inputNames = window.PennedBlockSelection.inputNames;
            const input = handler => event => { const contact = window.PennedBlockSelection.contactEvent(event); if (contact) handler(contact); };
            const listeners = [
              [inputNames.start, input(beginContact), true], [inputNames.move, input(observeMovement), true],
              [inputNames.end, input(endContact), true], [inputNames.cancel, input(endContact), true],
              ['selectstart', protectTextSelection, false], ['selectionchange', protectTextSelection, true],
            ];
            // Window capture precedes block-specific handlers and the selection
            // controller's document capture without blocking their event delivery.
            for (const [name, handler, passive] of listeners) window.addEventListener(name, handler, { capture: true, passive });
            log('controller-installed', { holdMS: HOLD_MS, source: inputNames.start,
              accepted: !!editor && root() === editorView.dom, reason: 'editor-reference-bound' });
            const blockOldHold = event => {
              if ((!contact && !active) || !root().contains(event.target)) return;
              if (event.type === 'contextmenu') event.preventDefault();
              event.stopImmediatePropagation();
            };
            document.addEventListener('contextmenu', blockOldHold, true);
            const click = event => { if ((active || performance.now() < suppressUntil) && root().contains(event.target)) { event.preventDefault(); event.stopImmediatePropagation(); } };
            document.addEventListener('click', click, true);
            return { update() {
              if (active && active.doc !== view.state.doc) cancel({ reason: 'source-document-changed-during-drag' });
              if (contact && contact.doc !== view.state.doc) cancel({ reason: 'source-document-changed-before-lift' });
            }, destroy() {
              log('controller-view-destroyed', { reason: 'plugin-view-release' });
              cancelContact({ reason: 'plugin-view-destroyed' }); pending = null;
              for (const [name, handler] of listeners) window.removeEventListener(name, handler, true);
              window.PennedBlockSelection.clearContactInput();
              document.removeEventListener('contextmenu', blockOldHold, true);
              document.removeEventListener('click', click, true);
              style.remove(); view = editor = null;
            } };
          },
        })]; },
      })];
    },
  };
})();
"""#
}
#endif
