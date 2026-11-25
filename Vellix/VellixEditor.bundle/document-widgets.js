(function (global) {
  const layout = JSON.parse(document.getElementById("penned-widget-layout").textContent);
  const selectionMode = () => document.documentElement.dataset.vellixSelectionMode || "off";
  function bindSettings({ dom, surface, editor, enabled, open, activate }) {
    let contact = null, suppressUntil = 0;
    const listeners = new AbortController();
    const on = (target, name, handler, options = {}) => target.addEventListener(name, handler, { ...options, signal: listeners.signal });
    const cancel = () => { clearTimeout(contact?.timer); contact = null; };
    const dismissInput = () => {
      editor.view.dom.blur();
      const native = document.getSelection();
      if (native && (editor.view.dom.contains(native.anchorNode) || editor.view.dom.contains(native.focusNode))) native.removeAllRanges();
    };
    const request = () => {
      if (!enabled() || !dom.isConnected) return false;
      suppressUntil = performance.now() + 750;
      dismissInput();
      return open();
    };
    const preventWidgetFocus = event => {
      if (enabled() && !event.target.closest?.("input")) event.preventDefault();
    };
    on(dom, "pointerdown", preventWidgetFocus);
    on(dom, "mousedown", preventWidgetFocus);
    on(surface, "pointerdown", event => {
      cancel();
      if (!event.isPrimary || event.button !== 0 || !enabled()) return;
      // Cancel focus/compatibility mouse defaults, not native pan-y scrolling.
      event.preventDefault();
      const next = { id: event.pointerId, x: event.clientX, y: event.clientY, held: false, timer: null };
      contact = next;
      next.timer = setTimeout(() => {
        if (contact === next) { next.held = true; request(); }
      }, 550);
    });
    on(surface, "mousedown", event => { if (enabled()) event.preventDefault(); });
    on(dom, "selectstart", event => { if (selectionMode() === "off") event.preventDefault(); });
    on(surface, "pointermove", event => {
      if (contact?.id === event.pointerId && Math.hypot(event.clientX - contact.x, event.clientY - contact.y) > 10) cancel();
    });
    on(surface, "touchend", event => {
      if (performance.now() < suppressUntil && event.cancelable) { event.preventDefault(); event.stopPropagation(); dismissInput(); }
    }, { passive: false });
    for (const name of ["pointerup", "pointercancel", "lostpointercapture", "pointerleave"]) on(surface, name, cancel);
    // Run before generic gap insertion/ProseMirror clicks. The slider is a
    // separate real control; selection mode keeps its existing capture path.
    on(global, "click", event => {
      if (selectionMode() !== "off" || !dom.contains(event.target) || event.target.closest?.("input")) return;
      if (global.PennedBlockSelection?.consumesClick(event)) return;
      event.preventDefault(); event.stopImmediatePropagation();
      if (performance.now() < suppressUntil) { dismissInput(); return; }
      if (activate?.(event)) return;
      if (event.detail === 0 && surface.contains(event.target)) request();
    }, { capture: true });
    on(surface, "contextmenu", event => {
      if (!enabled()) return;
      cancel(); event.preventDefault(); event.stopPropagation();
      if (performance.now() >= suppressUntil) request();
    });
    on(global, "blur", cancel);
    on(document, "visibilitychange", () => { if (document.hidden) cancel(); });
    return () => { cancel(); listeners.abort(); };
  }
  const style = document.createElement("style");
  style.textContent = `
    .penned-document-widget, .penned-document-widget * { user-select:none !important; -webkit-user-select:none !important; -webkit-touch-callout:none; }
    .penned-document-widget { --widget-height:${layout.fullHeight}px; --widget-pad:${layout.padding}px; --widget-gap:${layout.spacing}px;
      box-sizing:border-box; min-width:0; width:100%; max-width:100%; height:var(--widget-height); min-height:var(--widget-height); max-height:var(--widget-height);
      padding:var(--widget-pad); margin:var(--penned-block-gap,10px) 0; display:flex; flex-direction:column; gap:var(--widget-gap);
      container-type:size; overflow:hidden; }
    .penned-document-widget[data-widget-size="half"] { --widget-height:${layout.halfHeight}px; }
    :where(.tiptap-editor, .tiptap-editor *):has(> .penned-document-widget[data-widget-size="half"]) { column-gap:${layout.pairGap}px; }
    .penned-document-widget .penned-widget-settings-surface { touch-action:pan-y; color:inherit; font:inherit; text-align:inherit; }
    html[data-vellix-selection-mode]:not([data-vellix-selection-mode="off"]) .penned-document-widget :is(button,input) { pointer-events:none; touch-action:pan-y; }
    .penned-document-widget.penned-block-selected::after { inset:0; border-radius:inherit; }
    .tiptap-editor :not(.penned-document-widget[data-widget-size="half"]) + .penned-document-widget[data-widget-size="half"] { grid-column:1; }
    .tiptap-editor.penned-mobile-block-layout .penned-document-widget[data-widget-size="half"] { margin-top:var(--penned-block-gap,10px) !important; }
    .tiptap-editor.penned-mobile-block-layout .penned-document-widget[data-widget-size="half"]:first-child,
    .tiptap-editor.penned-mobile-block-layout .penned-document-widget[data-widget-size="half"]:first-child + .penned-document-widget[data-widget-size="half"] { margin-top:0 !important; }
  `;
  document.head.append(style);
  global.PennedDocumentWidgets = { bindSettings, selectionMode, layout };
})(globalThis);
