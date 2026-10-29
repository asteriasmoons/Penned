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
    .tiptap-editor [data-vellix-divider]:is([data-divider-style="thinLine"], [data-divider-style="thickLine"]) { min-height: 20px !important; }
    .tiptap-editor [data-divider-style="thinLine"] .vellix-divider-line {
      width: calc(100% - 12px); height: 1px; border-radius: 1px;
      background: currentColor; opacity: 0.5;
    }
    .tiptap-editor [data-divider-style="thickLine"] .vellix-divider-line {
      width: calc(100% - 12px); height: 2px; border-radius: 1px;
      background: currentColor; opacity: 1;
    }
  `;
  document.head.appendChild(spacing);
  editor.on("destroy", () => spacing.remove());
  const command = window.tiptapCommand;
  let suppressedSlash = null;
  let closingSlash = false;
  let historySignature = null;

  const editable = () => editor.isEditable &&
    (document.documentElement.dataset.vellixSelectionMode || "off") === "off";

  function publishHistory(force = false) {
    const canUndo = editor.can().undo(), canRedo = editor.can().redo();
    const signature = `${canUndo}:${canRedo}`;
    if (force !== true && signature === historySignature) return;
    historySignature = signature;
    window.webkit.messageHandlers.tiptap.postMessage({
      kind: "mobileHistoryAvailability", payload: { canUndo, canRedo },
    });
  }

  function slashRange() {
    const { empty, $from } = editor.state.selection;
    if (!empty || !$from.parent.isTextblock) return null;
    const before = $from.parent.textBetween(0, $from.parentOffset, "\n", "\0");
    const match = before.match(/(?:^|\s)\/([a-zA-Z0-9]*)$/);
    return match ? { from: $from.pos - match[1].length - 1, to: $from.pos } : null;
  }

  function suppressSlash(from, force = false) {
    if (suppressedSlash === from && !force) return;
    suppressedSlash = from;
    window.webkit.messageHandlers.tiptap.postMessage({
      kind: "mobileSlashSuppression", payload: { suppressed: from !== null },
    });
  }

  function closeSlash() {
    // Escape closes the shared editor's private menu state without removing the slash.
    closingSlash = true;
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    closingSlash = false;
  }

  function dismissSlash() {
    suppressSlash(slashRange()?.from ?? null, true);
    closeSlash();
    return true;
  }

  function keepSlashDismissed() {
    if (suppressedSlash === null) return;
    if (slashRange()?.from === suppressedSlash) closeSlash();
    else suppressSlash(null);
  }
  // Release the native gate before the shared update listeners publish a new trigger.
  editor.on("transaction", () => {
    if (suppressedSlash !== null && slashRange()?.from !== suppressedSlash) suppressSlash(null);
    publishHistory();
  });
  editor.on("update", keepSlashDismissed);
  editor.on("selectionUpdate", keepSlashDismissed);
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && !closingSlash) dismissSlash();
  }, true);

  function dividerStyle(value) {
    if (value === "tinyDots") return "dottedCircles";
    if (value === "fourDots") return "fourCircles";
    return ["thinLine", "thickLine", "dottedCircles", "fourCircles"].includes(value) ? value : "thinLine";
  }

  function insertDivider(style, range = null) {
    if (!editable()) return false;
    const chain = editor.chain().focus();
    if (range) chain.deleteRange(range);
    return chain.command(({ tr, state, commands }) => {
      const { empty, $from } = tr.selection;
      const divider = state.schema.nodes.divider.create({ id: crypto.randomUUID(), style: dividerStyle(style) });
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

  function backspacePastDivider() {
    if (!editable() || editor.view.composing) return false;
    const { state } = editor;
    const { empty, $from, $cursor } = state.selection;
    if (!empty || !$cursor || !$from.parent.isTextblock ||
        $from.parent.content.size !== 0 || $from.parentOffset !== 0) return false;
    const start = $from.before();
    const boundary = state.doc.resolve(start);
    const divider = boundary.nodeBefore;
    if (!divider || !["divider", "horizontalRule"].includes(divider.type.name) ||
        !boundary.parent.canReplace(boundary.index(), boundary.index() + 1)) return false;

    const end = $from.after();
    const TextSelection = state.selection.constructor;
    editor.view.dom.blur();
    const handled = editor.chain().command(({ tr, commands }) => {
      tr.delete(start, end);
      const position = tr.doc.resolve(Math.min(start, tr.doc.content.size));
      const caret = TextSelection.findFrom(position, -1, true) || TextSelection.findFrom(position, 1, true);
      // Keep a valid unfocused selection without selecting an atomic divider or inserting content.
      if (caret) tr.setSelection(caret);
      else commands.selectAll();
      return true;
    }).blur().run();
    window.getSelection()?.removeAllRanges();
    return handled;
  }

  function backspaceIntoQuote() {
    if (!editable() || editor.view.composing) return false;
    const { state } = editor;
    const { empty, $from, $cursor } = state.selection;
    if (!empty || !$cursor || $from.parent.type.name !== "paragraph" ||
        $from.parent.content.size !== 0 || $from.parentOffset !== 0) return false;
    const start = $from.before();
    const quote = state.doc.resolve(start).nodeBefore;
    if (quote?.type.name !== "blockquote") return false;
    let target = null;
    quote.descendants((node, position) => {
      if (node.isTextblock) target = start - quote.nodeSize + position + 2 + node.content.size;
    });
    if (target === null) return false;
    // Delete only the empty paragraph and select text inside the quote in one undoable transaction.
    const tr = state.tr.delete(start, $from.after());
    tr.setSelection(state.selection.constructor.create(tr.doc, target));
    editor.view.dispatch(tr.scrollIntoView());
    return true;
  }

  function focusBelowDivider(event) {
    if (window.PennedBlockSelection?.consumesClick(event)) return false;
    if (!editable() || editor.view.composing || event.button !== 0 || event.defaultPrevented) return false;
    const target = event.target;
    if (!(target instanceof HTMLElement) || !editor.view.dom.contains(target)) return false;
    const divider = target.closest("[data-vellix-divider]");
    let position;
    if (divider) {
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

  editor.view.dom.addEventListener("keydown", event => {
    if (event.key !== "Backspace" || event.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
    if (backspacePastDivider() || backspaceIntoQuote()) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
  editor.view.dom.addEventListener("beforeinput", event => {
    if (event.inputType !== "deleteContentBackward" || event.isComposing || !event.cancelable) return;
    if (backspacePastDivider() || backspaceIntoQuote()) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);

  window.tiptapCommand = function (name, args = {}) {
    if (name === "mobileDismissSlashMenu") return dismissSlash();
    if (name === "setContent") {
      suppressSlash(null, true);
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
    if (name === "insertDivider") return insertDivider(args.style);
    if (name === "insertBlock" && /^divider(?::|$)/.test(args.blockType || "")) {
      return insertDivider(args.blockType.split(":")[1]);
    }
    if (name === "chooseSlashItem" && /^divider(?::|$)/.test(args.key || "")) {
      const range = slashRange();
      if (!range || suppressedSlash !== null) return false;
      closeSlash();
      return insertDivider(args.key.split(":")[1], range);
    }
    return command(name, args);
  };
  publishHistory(true);
})();
"""#
}
#endif
