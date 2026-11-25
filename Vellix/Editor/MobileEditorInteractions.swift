#if os(iOS)
enum MobileEditorInteractions {
    // Installed only by the mobile host, independently of shared editor bundle updates.
    static let script = #"""
(() => {
  const editor = document.querySelector(".tiptap-editor")?.editor;
  if (!editor || editor.storage.pennedMobileInteractions) return;
  editor.storage.pennedMobileInteractions = true;
  const spacing = document.createElement("style");
  spacing.textContent = `
    .tiptap-editor .vellix-table-wrapper:has(+ .vellix-page-reference:not([hidden])) { margin-bottom: 26px; }
    .tiptap-editor .vellix-page-reference:not([hidden]) + .vellix-table-wrapper { margin-top: 26px; }
    .tiptap-editor.penned-mobile-block-layout [data-vellix-divider] {
      -webkit-user-select: none !important;
      user-select: none !important;
      -webkit-touch-callout: none;
    }
    .tiptap-editor [data-vellix-divider]:is([data-divider-style="thinLine"], [data-divider-style="thickLine"]) { min-height: 20px !important; }
    .tiptap-editor [data-divider-style="thinLine"] .vellix-divider-line {
      width: calc(100% - 12px); height: 1px; border-radius: 1px;
      background: currentColor; opacity: 0.5;
    }
    .tiptap-editor [data-divider-style="thickLine"] .vellix-divider-line {
      width: calc(100% - 12px); height: 2px; border-radius: 1px;
      background: currentColor; opacity: 1;
    }
    .tiptap-editor [data-divider-style="thinLine"][data-divider-color] .vellix-divider-line { opacity: 1; }
  `;
  document.head.appendChild(spacing);
  editor.on("destroy", () => spacing.remove());
  const command = window.tiptapCommand;
  let historySignature = null;
  let templateEditing = false;

  const editable = () => editor.isEditable &&
    (document.documentElement.dataset.vellixSelectionMode || "off") === "off";

  let handledNestedReturn = false;
  const clearNestedReturn = () => { handledNestedReturn = false; };
  function nestedCalendarList() {
    if (!editable() || editor.view.composing || !editor.view.hasFocus()) return null;
    const { empty, $from } = editor.state.selection;
    if (!empty || $from.depth < 3 || $from.parent.type.name !== "paragraph" ||
        editor.storage?.vellixStructuredPlaceholders?.isProtected?.($from.parent)) return null;
    const item = $from.node(-1), list = $from.node(-2);
    if (!(item.type.name === "taskItem" && list.type.name === "taskList") &&
        !(item.type.name === "listItem" && ["orderedList", "bulletList"].includes(list.type.name))) return null;
    let callout = false, calendar = false;
    for (let depth = $from.depth - 3; depth > 0; depth--) {
      const node = $from.node(depth);
      if (["plainCallout", "iconCallout", "callout", "gridCard"].includes(node.type.name)) callout = true;
      if (node.type.name === "weekStrip") calendar = true;
      if (node.type.name === "weekDayPanel" && !callout) return null;
    }
    if (!callout || !calendar) return null;
    const rejected = reason => {
      traceNestedReturn("nested-return.skipped", { reason, itemType: item.type.name, listType: list.type.name });
      return null;
    };
    // Never run a model command against native typing that has not reconciled
    // yet, or a WebKit caret that disagrees with ProseMirror's current caret.
    const paragraph = editor.view.nodeDOM($from.before());
    const native = document.getSelection();
    if (!(paragraph instanceof HTMLElement) || paragraph.closest("[inert], [hidden]")) return rejected("paragraph-unavailable-or-hidden");
    if (paragraph.textContent !== $from.parent.textContent) return rejected("native-text-not-reconciled");
    if (!native?.isCollapsed || !paragraph.contains(native.anchorNode)) return rejected("native-caret-outside-paragraph");
    try {
      if (editor.view.posAtDOM(native.anchorNode, native.anchorOffset) !== $from.pos) return rejected("native-caret-model-mismatch");
    } catch { return rejected("native-caret-unmappable"); }
    return { itemType: item.type.name, listType: list.type.name };
  }
  function traceNestedReturn(event, details) {
    try { editor.storage.pennedListDiagnosticRecord?.(event, details); } catch {}
  }
  function nestedReturnKey(event) {
    if (event.key !== "Enter" && event.keyCode !== 13) return;
    clearNestedReturn();
    if (event.defaultPrevented || event.isComposing || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
    const context = nestedCalendarList();
    if (!context) return;
    // Use the real event and the normal ordered keymaps, including TaskItem's
    // splitListItem command. Do not synthesize a key or change list semantics.
    const handled = !!editor.view.someProp("handleKeyDown", handler => handler(editor.view, event));
    if (!handled) { traceNestedReturn("nested-return.not-handled", context); return; }
    handledNestedReturn = !event.defaultPrevented;
    // Leave the key's native default intact for the iOS keyboard. Stop it from
    // also arming ProseMirror's deferred iOS Enter fallback; beforeinput below
    // consumes the native insertion for this already-handled key exactly once.
    event.stopImmediatePropagation();
    traceNestedReturn("nested-return.handled", { ...context, expectsNativeInput: handledNestedReturn });
  }
  function nestedReturnInput(event) {
    if (!handledNestedReturn) return;
    clearNestedReturn();
    if (!["insertParagraph", "insertLineBreak"].includes(event.inputType) || event.isComposing || !event.cancelable || event.defaultPrevented) {
      traceNestedReturn("nested-return.native-unhandled", { input: event.inputType, cancelable: event.cancelable });
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    traceNestedReturn("nested-return.native-suppressed", { input: event.inputType });
  }
  editor.view.dom.addEventListener("keydown", nestedReturnKey, true);
  editor.view.dom.addEventListener("beforeinput", nestedReturnInput, true);
  editor.view.dom.addEventListener("keyup", clearNestedReturn, true);
  editor.view.dom.addEventListener("pointerdown", clearNestedReturn, true);
  editor.view.dom.addEventListener("compositionstart", clearNestedReturn, true);
  editor.on("destroy", () => {
    clearNestedReturn();
    editor.view.dom.removeEventListener("keydown", nestedReturnKey, true);
    editor.view.dom.removeEventListener("beforeinput", nestedReturnInput, true);
    editor.view.dom.removeEventListener("keyup", clearNestedReturn, true);
    editor.view.dom.removeEventListener("pointerdown", clearNestedReturn, true);
    editor.view.dom.removeEventListener("compositionstart", clearNestedReturn, true);
  });

  function textAtTap(event, allowEmptyTemplate = false) {
    const { view } = editor;
    const hit = view.posAtCoords({ left: event.clientX, top: event.clientY });
    if (!hit) return null;
    const position = view.state.doc.resolve(hit.pos);
    if (!position.parent.isTextblock ||
        editor.storage?.vellixStructuredPlaceholders?.isProtected?.(position.parent)) return null;
    const textDOM = view.nodeDOM(position.before());
    if (!(textDOM instanceof HTMLElement) || textDOM.closest("[inert], [hidden]")) return null;
    const bounds = textDOM.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) return null;
    const emptyTemplate = allowEmptyTemplate && view.state.doc.childCount === 1 &&
      position.parent.type.name === "paragraph" && view.state.doc.firstChild === position.parent && !position.parent.content.size;
    if (!emptyTemplate && (event.clientX < bounds.left || event.clientX > bounds.right ||
        event.clientY < bounds.top || event.clientY > bounds.bottom ||
        (!textDOM.contains(event.target) && !event.target.contains(textDOM)))) return null;
    return { hit, position };
  }

  let caretContact = null, completedCaretContact = null, caretTapSequence = 0;
  const caretListeners = new AbortController();
  const trackCaretContact = (type, handler) => window.addEventListener(type, handler,
    { capture: true, passive: true, signal: caretListeners.signal });
  trackCaretContact("touchstart", event => {
    completedCaretContact = null;
    const touch = event.touches[0];
    caretContact = event.touches.length === 1 && editor.view.dom.contains(event.target)
      ? { tap: ++caretTapSequence, id: touch.identifier, x: touch.clientX, y: touch.clientY, started: performance.now(), moved: false } : null;
  });
  trackCaretContact("touchmove", event => {
    if (!caretContact) return;
    const touch = [...event.touches].find(item => item.identifier === caretContact.id);
    if (event.touches.length !== 1 || !touch || Math.hypot(touch.clientX - caretContact.x, touch.clientY - caretContact.y) > 8) {
      caretContact.moved = true;
    }
  });
  const finishCaretContact = event => {
    if (!caretContact || ![...event.changedTouches].some(item => item.identifier === caretContact.id)) return;
    completedCaretContact = { ...caretContact, ended: performance.now(), cancelled: event.type === "touchcancel" };
    caretContact = null;
    if (!completedCaretContact.moved) caretDiagnostic(completedCaretContact.cancelled ? "contact-cancelled" : "contact-ended",
      completedCaretContact.tap, { durationMS: Math.round(completedCaretContact.ended - completedCaretContact.started) });
  };
  trackCaretContact("touchend", finishCaretContact);
  trackCaretContact("touchcancel", finishCaretContact);

  function caretDiagnostic(event, tap, details = {}) {
    if (window.PENNED_CARET_DIAGNOSTICS !== true) return;
    const native = document.getSelection(), selection = editor.state.selection;
    try { window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: "caretTapDiagnostic", payload: {
      ts: Date.now(), tap, event, focused: editor.view.hasFocus(), editable: editor.isEditable,
      composing: editor.view.composing, from: selection.from, to: selection.to,
      holdSuppression: editor.view.dom.classList.contains("penned-reorder-arming"),
      nativeCollapsed: native?.isCollapsed ?? true,
      nativeInside: !!native?.anchorNode && editor.view.dom.contains(native.anchorNode),
      mode: document.documentElement.dataset.vellixSelectionMode || "off", ...details,
    } }); } catch {}
  }

  function focusTextAtTap(event) {
    const target = event.target;
    if (!(target instanceof Element) || !editor.view.dom.contains(target)) return;
    const contact = completedCaretContact && performance.now() - completedCaretContact.ended < 700 ? completedCaretContact : null;
    const tap = contact?.tap ?? ++caretTapSequence;
    const skipped = reason => caretDiagnostic("tap-skipped", tap, { reason, target: target.tagName });
    caretDiagnostic("tap-received", tap, { target: target.tagName, detail: event.detail });
    if (event.defaultPrevented || event.button !== 0 || event.detail !== 1 ||
        !editable() || editor.view.composing || window.PennedBlockSelection?.consumesClick(event) ||
        window.PennedBlockDragAndDrop?.ownsReorder || window.PennedBlockDragAndDrop?.busy) {
      skipped(event.defaultPrevented ? "event-consumed" : event.button !== 0 ? "non-primary-button" : event.detail !== 1 ? "native-multitap"
        : !editable() ? "read-only-or-block-selection" : editor.view.composing ? "composition"
        : window.PennedBlockSelection?.consumesClick(event) ? "selection-gesture-click" : "reorder-or-transfer");
      return;
    }
    if (contact && (contact.cancelled || contact.moved || contact.ended - contact.started > 320)) {
      skipped(contact.cancelled ? "cancelled-contact" : contact.moved ? "scroll-or-drag" : "long-press"); return;
    }
    if (target.closest(
      "button, a, input, textarea, select, audio, video, iframe, [role='button'], [role='checkbox'], [contenteditable='false'], [inert], [hidden]",
    )) { skipped("control-or-noneditable-content"); return; }
    const panel = target.closest(".penned-week-day-panel[data-active]");
    const calendar = panel?.closest(".penned-week-strip");
    if (calendar && (calendar.dataset.collapsed === "true" ||
        target.closest(".penned-week-strip") !== calendar)) { skipped("inactive-calendar-panel"); return; }
    const native = document.getSelection();
    if (native && !native.isCollapsed) { skipped("native-text-range"); return; }
    const view = editor.view;
    const text = textAtTap(event, templateEditing);
    if (!text) { skipped("not-visible-editable-text-use-existing-gap-handler"); return; }
    const { hit, position } = text;
    if (calendar) {
      let inPanel = false;
      for (let depth = position.depth; depth > 0; depth--) {
        if (position.node(depth).type.name === "weekDayPanel") {
          inPanel = view.nodeDOM(position.before(depth)) === panel;
          break;
        }
      }
      if (!inPanel) { skipped("calendar-panel-mismatch"); return; }
    }
    let nativeMatches = false;
    try {
      nativeMatches = !!native?.anchorNode && view.posAtDOM(native.anchorNode, native.anchorOffset) === hit.pos;
    } catch { /* A stale native caret is the recovery case. */ }
    if (view.hasFocus() && view.state.selection.empty && view.state.selection.from === hit.pos && nativeMatches) {
      caretDiagnostic("tap-already-ready", tap, { expected: hit.pos, type: position.parent.type.name }); return;
    }
    // Change only the caret. Do not append content or reuse the last date's caret.
    const applied = editor.chain().setTextSelection(hit.pos).command(({ tr }) => {
      tr.setMeta("pointer", true).setMeta("addToHistory", false);
      return true;
    }).run();
    if (!applied) { skipped("selection-command-rejected"); return; }
    view.focus();
    event.preventDefault();
    // Run before generic gap/click handlers, which must not retarget a caret
    // already placed in existing text during this same user activation.
    event.stopImmediatePropagation();
    caretDiagnostic("tap-reconciled", tap, { expected: hit.pos, type: position.parent.type.name,
      context: templateEditing ? "template" : calendar ? "calendar" : "document" });
    if (window.PENNED_CARET_DIAGNOSTICS === true) {
      const expectedDoc = view.state.doc;
      requestAnimationFrame(() => {
        if (editor.isDestroyed || view.state.doc !== expectedDoc || caretTapSequence !== tap) return;
        const range = document.getSelection();
        let nativePosition = -1;
        try { if (range?.isCollapsed && view.dom.contains(range.anchorNode)) nativePosition = view.posAtDOM(range.anchorNode, range.anchorOffset); } catch {}
        const ready = view.hasFocus() && view.state.selection.empty && view.state.selection.from === hit.pos && nativePosition === hit.pos;
        caretDiagnostic(ready ? "tap-verified" : "tap-not-ready", tap, { expected: hit.pos, nativePosition });
      });
    }
    if (calendar) window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: "calendarDiagnostic", payload: {
      stage: "nested-text-caret", blockID: calendar.dataset.vellixBlockId,
      date: panel.getAttribute("data-week-date"), pos: hit.pos, type: position.parent.type.name,
    } });
  }
  window.addEventListener("click", focusTextAtTap, true);
  editor.on("destroy", () => {
    window.removeEventListener("click", focusTextAtTap, true);
    caretListeners.abort(); caretContact = null; completedCaretContact = null;
  });

  function publishHistory(force = false) {
    const canUndo = editor.can().undo(), canRedo = editor.can().redo();
    const signature = `${canUndo}:${canRedo}`;
    if (force !== true && signature === historySignature) return;
    historySignature = signature;
    window.webkit.messageHandlers.tiptap.postMessage({
      kind: "mobileHistoryAvailability", payload: { canUndo, canRedo },
    });
  }

  editor.on("transaction", () => publishHistory());

  function dividerStyle(value) {
    if (value === "tinyDots") return "dottedCircles";
    if (value === "fourDots") return "fourCircles";
    return ["thinLine", "thickLine", "dottedCircles", "fourCircles", "washiTape"].includes(value) ? value : "thinLine";
  }

  function insertDivider(style, range = null, blockID = crypto.randomUUID()) {
    if (!editable()) return false;
    const chain = editor.chain();
    if (style !== "washiTape") chain.focus();
    if (range) chain.deleteRange(range);
    return chain.command(({ tr, state, commands }) => {
      const { empty, $from } = tr.selection;
      const divider = state.schema.nodes.divider.create({ id: blockID, style: dividerStyle(style) });
      if (!empty || $from.parent.type.name !== "paragraph" || $from.parent.content.size !== 0) {
        return commands.insertContent(divider.toJSON());
      }
      const start = $from.before();
      const end = $from.after();
      const next = state.schema.nodes.paragraph.create({ ...$from.parent.attrs, id: crypto.randomUUID() });
      const parent = $from.node($from.depth - 1);
      const index = $from.index($from.depth - 1);
      const replacement = state.schema.nodes.doc.create(null, [divider, next]).content;
      if (!parent.canReplace(index, index + 1, replacement)) return commands.insertContent(divider.toJSON());
      tr.replaceWith(start, end, replacement);
      tr.setSelection(tr.selection.constructor.near(tr.doc.resolve(start + divider.nodeSize + 1), 1));
      return true;
    }).run();
  }

  function ordinaryTextBlock(node) {
    return !!node && (["paragraph", "caption"].includes(node.type.name) ||
      (node.type.name === "heading" && node.attrs.label?.presentation !== "label"));
  }

  function ordinaryKeyboardBlock(node) {
    if (ordinaryTextBlock(node)) return true;
    if (!node || !["bulletList", "orderedList", "taskList", "listItem", "taskItem"].includes(node.type.name)) return false;
    let ordinary = true;
    node.forEach(child => { if (!ordinaryKeyboardBlock(child)) ordinary = false; });
    return ordinary;
  }

  function dismissProtectedCaret() {
    editor.view.dom.blur();
    const native = document.getSelection();
    if (native && (editor.view.dom.contains(native.anchorNode) || editor.view.dom.contains(native.focusNode))) {
      native.removeAllRanges();
    }
  }

  function protectedOwners(position) {
    const owners = [];
    for (let depth = 1; depth <= position.depth; depth++) {
      const node = position.node(depth);
      if (!ordinaryTextBlock(node) && !["bulletList", "orderedList", "taskList", "listItem", "taskItem"].includes(node.type.name)) {
        owners.push(position.before(depth));
      }
    }
    return owners;
  }

  // Guard both hardware keys and iOS beforeinput before join/select-node
  // commands can consume an adjacent custom block. Explicit block deletion
  // uses Penned's selection commands and does not pass through this guard.
  function protectedMobileDeletion(direction) {
    if (!editable() || editor.view.composing) return null;
    const { selection, doc } = editor.state;
    const { $from, $to, empty } = selection;
    if (!empty) {
      if (selection.node && !ordinaryKeyboardBlock(selection.node)) return "protected-node-selection";
      const fromOwners = protectedOwners($from), toOwners = protectedOwners($to);
      if (fromOwners.length !== toOwners.length || fromOwners.some((pos, index) => pos !== toOwners[index])) {
        return "selection-crosses-container-boundary";
      }
      let protectedBlock = null;
      doc.nodesBetween(selection.from, selection.to, (node, pos) => {
        if (!node.isText && !node.isInline && !ordinaryKeyboardBlock(node) &&
            selection.from <= pos && selection.to >= pos + node.nodeSize) protectedBlock = node.type.name;
        return !protectedBlock;
      });
      return protectedBlock ? "selection-contains-" + protectedBlock : null;
    }
    if (!$from.parent.isTextblock) return "non-text-caret";
    const atEdge = direction === "backward"
      ? $from.parentOffset === 0
      : $from.parentOffset === $from.parent.content.size;
    if (!atEdge) return null;
    if (!ordinaryTextBlock($from.parent)) return "protected-text-block-boundary";
    for (let depth = $from.depth - 1; depth >= 0; depth--) {
      const parent = $from.node(depth);
      const index = $from.index(depth) + (direction === "forward" ? 1 : 0);
      const adjacent = direction === "backward" ? parent.maybeChild(index - 1) : parent.maybeChild(index);
      if (adjacent) return ordinaryKeyboardBlock(adjacent) ? null : "adjacent-" + adjacent.type.name;
      // No sibling remains in this direction. Crossing the edge of a custom
      // container must not lift its last paragraph out or delete its shell.
      if (depth > 0 && !["bulletList", "orderedList", "taskList", "listItem", "taskItem"].includes(parent.type.name)) {
        return "container-edge-" + parent.type.name;
      }
    }
    return null;
  }

  function focusBelowDivider(event) {
    if (window.PennedBlockSelection?.consumesClick(event)) return false;
    if (!editable() || editor.view.composing || event.button !== 0 || event.defaultPrevented) return false;
    const target = event.target;
    if (!(target instanceof HTMLElement) || !editor.view.dom.contains(target)) return false;
    const divider = target.closest("[data-vellix-divider]");
    let position;
    if (divider) {
      if (divider.dataset.dividerStyle === "washiTape") return false;
      const rect = divider.getBoundingClientRect();
      if (rect.height <= 0 || event.clientY < rect.top + rect.height / 2) return false;
      position = editor.view.posAtDOM(divider, 0);
      const node = editor.state.doc.nodeAt(position);
      if (node?.type.name !== "divider") return false;
      position += node.nodeSize;
    } else {
      const paragraph = target.closest("p");
      if (!paragraph || target.closest("button, a, input, textarea, select, [contenteditable='false']")) return false;
      const resolved = editor.state.doc.resolve(editor.view.posAtDOM(paragraph, 0));
      if (resolved.parent.type.name !== "paragraph" || resolved.parent.content.size !== 0 ||
          editor.state.doc.resolve(resolved.before()).nodeBefore?.type.name !== "divider") return false;
      position = resolved.start();
    }

    const handled = editor.chain().command(({ tr, state, commands }) => {
      const resolved = tr.doc.resolve(position);
      let caret = position;
      if (!resolved.parent.isTextblock) {
        if (!resolved.nodeAfter?.isTextblock) {
          const paragraph = state.schema.nodes.paragraph;
          if (!resolved.parent.canReplaceWith(resolved.index(), resolved.index(), paragraph)) return false;
          tr.insert(position, paragraph.create({ id: crypto.randomUUID() }));
        }
        caret += 1;
      }
      if (!commands.setTextSelection(caret)) return false;
      tr.setMeta("pointer", true).scrollIntoView();
      return true;
    }).run();
    if (handled) editor.view.focus();
    return handled;
  }

  document.addEventListener("click", event => {
    if (focusBelowDivider(event)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);

  // Dividers use Penned block selection, not WebKit's native atom selection.
  // Keep the existing click-to-type behavior below the divider.
  editor.view.dom.addEventListener("mousedown", event => {
    if (event.button === 0 && editable() && event.target.closest?.("[data-vellix-divider]")) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);

  editor.view.dom.addEventListener("keydown", event => {
    if (!["Backspace", "Delete"].includes(event.key) || event.isComposing) return;
    if (event.target.closest?.("input, textarea, select, button, .penned-week-strip-chrome, .penned-tabs-header, .penned-tabs-bar")) return;
    const backward = event.key === "Backspace";
    const reason = protectedMobileDeletion(backward ? "backward" : "forward");
    if (reason) {
      event.preventDefault();
      event.stopImmediatePropagation();
      dismissProtectedCaret();
    }
  }, true);
  editor.view.dom.addEventListener("beforeinput", event => {
    if (!["deleteContentBackward", "deleteContentForward", "deleteWordBackward", "deleteWordForward", "deleteSoftLineBackward", "deleteSoftLineForward", "deleteHardLineBackward", "deleteHardLineForward"].includes(event.inputType)) return;
    if (event.target.closest?.("input, textarea, select, button, .penned-week-strip-chrome, .penned-tabs-header, .penned-tabs-bar")) return;
    const backward = event.inputType.endsWith("Backward");
    if (event.isComposing || !event.cancelable) return;
    const reason = protectedMobileDeletion(backward ? "backward" : "forward");
    if (reason) {
      event.preventDefault();
      event.stopImmediatePropagation();
      dismissProtectedCaret();
    }
  }, true);

  editor.storage.pennedMobileInsertDivider = insertDivider;
  window.tiptapCommand = function (name, args = {}) {
    if (name === "setTemplateEditing") {
      return Promise.resolve(command(name, args)).then(result => {
        if (result !== false) templateEditing = args.enabled === true;
        return result;
      });
    }
    if (name === "mobileSuspendInput") {
      editor.view.dom.blur();
      const selection = window.getSelection();
      if (selection && (editor.view.dom.contains(selection.anchorNode) ||
          editor.view.dom.contains(selection.focusNode))) selection.removeAllRanges();
      return true;
    }
    if (name === "setContent") {
      return Promise.resolve(command(name, args)).then(result => { publishHistory(true); return result; });
    }
    if (name === "undo" || name === "redo") {
      if (!editable()) return false;
      const wasFocused = editor.isFocused;
      const result = editor.commands[name]();
      if (!wasFocused) window.getSelection()?.removeAllRanges();
      publishHistory();
      return result;
    }
    if (name === "mobilePreparePaste") {
      if (!editable()) return false;
      const focused = editor.state.selection.$from.parent.inlineContent
        ? editor.commands.focus() : command("focusDocumentEnd");
      return Promise.resolve(focused).then(result => result === false ? false : new Promise(resolve => {
        requestAnimationFrame(() => resolve(!editor.isDestroyed && editor.view.hasFocus()));
      }));
    }
    if (name === "insertDivider" && args.style !== "washiTape") return insertDivider(args.style);
    if (name === "insertBlock" && args.blockType !== "divider:washiTape" && /^divider(?::|$)/.test(args.blockType || "")) {
      return insertDivider(args.blockType.split(":")[1]);
    }
    return command(name, args);
  };
  publishHistory(true);
})();
"""#

    #if DEBUG
    // Temporary, read-only list diagnostics. Installed by the native host, not the JS bundle.
    static let listDiagnosticsScript = #"""
(() => {
  const editor = document.querySelector(".tiptap-editor")?.editor;
  if (!editor || editor.storage.pennedListDiagnostics) return;
  editor.storage.pennedListDiagnostics = true;
  const root = editor.view.dom;
  const originalCommand = window.tiptapCommand;
  let count = 0, frame = null, pending = null, selectionBudget = 0;
  let returnSequence = 0, activeReturn = null, returnTimer = null;
  const listType = name => ["orderedList", "bulletList", "taskList"].includes(name);
  const safe = fn => { try { return fn(); } catch { return null; } };
  const rect = element => {
    const r = element?.getBoundingClientRect();
    return r ? [r.x, r.y, r.width, r.height].map(n => Math.round(n * 100) / 100) : null;
  };
  const brief = node => node ? {
    type: node.type.name, size: node.nodeSize, children: node.childCount,
    indent: node.attrs.indent ?? null, align: node.attrs.textAlign ?? null,
    placeholder: node.attrs.placeholderEnabled === true,
    projection: node.attrs.placeholderProjection === true,
    clipSource: !!node.attrs.clipSource,
  } : null;
  function path(position) {
    return Array.from({ length: Math.min(position.depth + 1, 12) }, (_, depth) => ({
      ...brief(position.node(depth)), index: position.index(depth),
    }));
  }
  function domPath(node) {
    const result = [];
    let element = node instanceof Element ? node : node?.parentElement;
    for (; element && result.length < 16; element = element.parentElement) {
      result.push({ tag: element.tagName, classes: [...element.classList].slice(0, 6),
        editable: element.getAttribute("contenteditable"), inert: element.hasAttribute("inert"),
        active: element.hasAttribute("data-active"), collapsed: element.getAttribute("data-collapsed") });
      if (element === root) break;
    }
    return result;
  }
  const inlineInfo = child => ({ type: child.type.name, size: child.nodeSize,
    textLength: child.isText ? child.text.length : 0,
    newlineOnly: child.isText ? /^[\r\n]+$/.test(child.text) : false,
    endsWithNewline: child.isText ? /[\r\n]$/.test(child.text) : false });
  function elementInfo(element) {
    if (!(element instanceof Element)) return null;
    const style = getComputedStyle(element), before = getComputedStyle(element, "::before");
    return {
      tag: element.tagName, classes: [...element.classList].slice(0, 8), rect: rect(element),
      editable: element.getAttribute("contenteditable"),
      display: style.display, height: style.height, minHeight: style.minHeight,
      lineHeight: style.lineHeight, whiteSpace: style.whiteSpace,
      margin: [style.marginTop, style.marginLeft], padding: [style.paddingTop, style.paddingLeft],
      before: { display: before.display, float: before.cssFloat, height: before.height,
        width: before.width, contentLength: before.content?.length ?? 0 },
    };
  }
  function nativeSelection() {
    const selection = window.getSelection();
    const describe = (node, offset) => node ? {
      node: node.nodeName, parent: node.parentElement?.tagName ?? null, offset,
      pos: safe(() => editor.view.posAtDOM(node, offset)), ancestors: domPath(node),
    } : null;
    return selection ? {
      anchor: describe(selection.anchorNode, selection.anchorOffset),
      focus: describe(selection.focusNode, selection.focusOffset),
      rect: safe(() => rect(selection.rangeCount ? selection.getRangeAt(0) : null)),
    } : null;
  }
  function write(event, extra = {}) {
    if (count >= 120 || editor.isDestroyed) return;
    try {
      const { selection } = editor.state, position = selection.$from;
      const dom = position.depth ? editor.view.nodeDOM(position.before()) : root;
      const element = dom instanceof Element ? dom : dom?.parentElement;
      const parent = position.depth ? position.node(-1) : position.parent;
      const index = position.depth ? position.index(position.depth - 1) : 0;
      const neighbors = [];
      for (let i = Math.max(0, index - 1); i < Math.min(parent.childCount, index + 2); i++) {
        neighbors.push({ index: i, ...brief(parent.child(i)) });
      }
      const inline = [];
      for (let i = 0; i < Math.min(position.parent.childCount, 6); i++) {
        inline.push(inlineInfo(position.parent.child(i)));
      }
      const inlineTail = [];
      for (let i = Math.max(0, position.parent.childCount - 6); i < position.parent.childCount; i++) {
        inlineTail.push(inlineInfo(position.parent.child(i)));
      }
      const calendar = element?.closest?.(".penned-week-strip");
      const dayPanel = element?.closest?.(".penned-week-day-panel");
      window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: "listCaretDiagnostic", payload: {
        version: "list-caret-v1", revision: "nested-list-return-v2", sequence: ++count, event,
        timestamp: Date.now(), returnID: activeReturn?.id ?? null,
        returnElapsedMS: activeReturn ? Math.round(performance.now() - activeReturn.started) : null,
        selection: selection.toJSON(), offset: position.parentOffset,
        path: path(position), block: brief(position.parent), inline, inlineTail, neighbors,
        ancestors: domPath(element), calendar: calendar ? {
          inChrome: !!element.closest(".penned-week-strip-chrome"),
          collapsed: calendar.dataset.collapsed === "true", panelActive: dayPanel?.hasAttribute("data-active") ?? false,
          matchesVisibleDate: !!dayPanel && dayPanel.getAttribute("data-week-date") === calendar.dataset.activeDate,
        } : null,
        numbered: editor.isActive("orderedList"), bulleted: editor.isActive("bulletList"),
        checklist: editor.isActive("taskList"), focused: editor.view.hasFocus(),
        composing: editor.view.composing, authoring: root.classList.contains("vellix-placeholder-authoring"),
        dom: elementInfo(element), item: elementInfo(element?.closest("li")),
        caret: safe(() => {
          const r = editor.view.coordsAtPos(selection.head);
          return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
        }), native: nativeSelection(), ...extra,
      } });
    } catch {
      // Diagnostics must never interrupt an editing event or command.
    }
  }
  function after(event, extra = {}) {
    if (pending && event === "selection.after" && pending.event !== "selection.after") return;
    pending = { event, extra, trace: activeReturn };
    if (frame !== null) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      const next = pending;
      pending = null;
      if (next) write(next.event, { ...next.extra, returnID: next.trace?.id ?? null,
        returnElapsedMS: next.trace ? Math.round(performance.now() - next.trace.started) : null });
    });
  }
  function nearbyList(position = editor.state.selection.$from) {
    for (let depth = position.depth; depth > 0; depth--) {
      if (listType(position.node(depth).type.name)) return true;
    }
    return !!safe(() => listType(position.doc.resolve(position.before()).nodeBefore?.type.name));
  }
  function pointer(event) {
    if (!(event.target instanceof Element) || !root.contains(event.target)) return;
    const hit = safe(() => editor.view.posAtCoords({ left: event.clientX, top: event.clientY }));
    if (!event.target.closest("ol, ul") && !nearbyList() && !(hit && nearbyList(editor.state.doc.resolve(hit.pos)))) return;
    selectionBudget = 4;
    const extra = { point: [event.clientX, event.clientY], target: event.target.tagName,
      hit: hit ? { ...hit, path: path(editor.state.doc.resolve(hit.pos)) } : null };
    write("tap.before", extra);
    after("tap.after", extra);
  }
  function key(event) {
    const keyName = event.keyCode === 13 ? "Enter" : event.key;
    if (!["Enter", "Backspace"].includes(keyName) || !nearbyList()) return;
    if (keyName === "Enter") beginReturn("key");
    selectionBudget = 4;
    const extra = { key: keyName, nativeKey: event.key, shift: event.shiftKey, alt: event.altKey,
      control: event.ctrlKey, meta: event.metaKey, composing: event.isComposing,
      defaultPrevented: event.defaultPrevented };
    write("key.before", extra);
    after("key.after", extra);
  }
  function input(event) {
    if (!["insertParagraph", "insertLineBreak", "deleteContentBackward"].includes(event.inputType) || !nearbyList()) return;
    if (event.inputType === "insertParagraph" || event.inputType === "insertLineBreak") beginReturn("input");
    selectionBudget = 4;
    write("input.before", { input: event.inputType, cancelable: event.cancelable,
      composing: event.isComposing, defaultPrevented: event.defaultPrevented });
    after("input.after", { input: event.inputType });
  }
  function beginReturn(source) {
    const now = performance.now();
    if (source === "key" || !activeReturn || activeReturn.inputSeen || now - activeReturn.started > 500) {
      activeReturn = { id: ++returnSequence, started: now, inputSeen: false,
        beforePath: path(editor.state.selection.$from), remaining: 4, steps: [] };
    }
    if (source === "input") activeReturn.inputSeen = true;
    const trace = activeReturn;
    if (returnTimer !== null) clearTimeout(returnTimer);
    // ProseMirror deliberately defers iOS Return handling. Observe its settled
    // result as well as the first frame, without dispatching or changing input.
    returnTimer = setTimeout(() => {
      returnTimer = null;
      if (activeReturn !== trace || editor.isDestroyed) return;
      write("return.settled", { beforePath: trace.beforePath, steps: trace.steps });
      activeReturn = null;
    }, 350);
  }
  function returned({ transaction }) {
    try {
      const trace = activeReturn;
      if (!trace || !transaction.docChanged || !trace.remaining ||
          performance.now() - trace.started > 1000 || editor.isDestroyed) return;
      trace.remaining--;
      for (const step of transaction.steps.slice(0, 6)) {
        if (trace.steps.length >= 12) break;
        trace.steps.push({ kind: step.constructor.name, from: step.from ?? null, to: step.to ?? null,
          openStart: step.slice?.openStart ?? null, openEnd: step.slice?.openEnd ?? null,
          insertedTypes: step.slice?.content?.content?.slice(0, 6).map(node => node.type.name) ?? [] });
      }
      after("return.transaction", { beforePath: trace.beforePath, steps: trace.steps.slice() });
    } catch {
      // This observer must not affect the transaction or input handlers.
    }
  }
  function changed() {
    if (!selectionBudget) return;
    selectionBudget--;
    after("selection.after");
  }
  function command(name, args) {
    const category = { numberList: "number", bulletList: "bullet", checkList: "checklist" }[args?.action];
    if (name !== "formatCurrentSelection" || !category) return originalCommand(name, args);
    const oldDoc = editor.state.doc, oldSelection = editor.state.selection;
    selectionBudget = 4;
    write(category + ".before");
    const finish = result => {
      const extra = { result: typeof result === "boolean" ? result : typeof result,
        documentChanged: editor.state.doc !== oldDoc, selectionChanged: !editor.state.selection.eq(oldSelection) };
      write(category + ".after", extra);
      after(category + ".frame", extra);
      return result;
    };
    const fail = error => { write(category + ".error", { error: error?.name || "Error" }); throw error; };
    try {
      const result = originalCommand(name, args);
      return result && typeof result.then === "function" ? result.then(finish, fail) : finish(result);
    } catch (error) { return fail(error); }
  }
  window.tiptapCommand = command;
  document.addEventListener("pointerup", pointer, true);
  document.addEventListener("keydown", key, true);
  document.addEventListener("beforeinput", input, true);
  editor.on("selectionUpdate", changed);
  editor.on("transaction", returned);
  editor.storage.pennedListDiagnosticRecord = write;
  editor.on("destroy", () => {
    if (frame !== null) cancelAnimationFrame(frame);
    if (returnTimer !== null) clearTimeout(returnTimer);
    activeReturn = null; pending = null;
    document.removeEventListener("pointerup", pointer, true);
    document.removeEventListener("keydown", key, true);
    document.removeEventListener("beforeinput", input, true);
    editor.off("selectionUpdate", changed);
    editor.off("transaction", returned);
    if (window.tiptapCommand === command) window.tiptapCommand = originalCommand;
    delete editor.storage.pennedListDiagnostics;
    delete editor.storage.pennedListDiagnosticRecord;
  });
  write("installed");
})();
"""#
    #endif
}
#endif
