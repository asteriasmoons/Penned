// Native-host behavior for the Book presentation of the existing pageReference node.
enum BookPageInteractions {
    static let script = #"""
(() => {
  const editor = document.querySelector('.tiptap-editor')?.editor;
  if (!editor || typeof window.tiptapCommand !== 'function' || window.PennedBookPages) return;
  const root = editor.view.dom;
  const command = window.tiptapCommand;
  const listeners = new AbortController();
  let books = new Set(), press = null, consumed = null;
  let bookImages = new Map(), layouts = new WeakMap(), layoutSequence = 0;
  const selectionOff = () => (document.documentElement.dataset.vellixSelectionMode || 'off') === 'off';
  const post = (kind, payload) => window.webkit?.messageHandlers?.tiptap?.postMessage({kind, payload});
  const log = (event, reason) => post('blockDragDiagnostic', {event, reason, browserTS: Date.now(), source: 'book-settings'});
  const bookAt = target => target instanceof Element ? target.closest('[data-penned-book="true"]') : null;
  const enabled = book => !!book && root.contains(book) && books.has(book.dataset.pageId) &&
    editor.isEditable && !editor.isDestroyed && selectionOff() && document.visibilityState !== 'hidden';
  function cancel(reason) {
    if (!press) return;
    clearTimeout(press.timer);
    if (!press.requested) log('book-settings-hold-cancelled', reason);
    press = null;
  }
  function sizeDescription(book) {
    const source = bookImages.get(book.dataset.pageId);
    const button = book.querySelector('.vellix-page-reference-button');
    const image = button?.querySelector('.vellix-page-card-image');
    if (!source || !image || !book.isConnected) return;
    const width = Math.round(button.getBoundingClientRect().width / 4) * 4;
    if (!(width > 0)) return;
    const previous = layouts.get(book);
    if (previous?.source === source && previous.width === width) {
      if (previous.image && image.getAttribute('src') !== previous.image) image.src = previous.image;
      return;
    }
    const layout = {source, width, token: `book-description-${++layoutSequence}`};
    layouts.set(book, layout);
    if (width <= 196) { image.src = source; return; }
    post('bookDescriptionLayout', {documentID: book.dataset.pageId, width, token: layout.token});
  }
  const bookSizes = new ResizeObserver(entries => entries.forEach(entry => sizeDescription(entry.target)));
  function decorate(element) {
    if (!(element instanceof Element)) return;
    const mark = node => {
      if (books.has(node.dataset.pageId)) {
        node.dataset.pennedBook = 'true'; bookSizes.observe(node); sizeDescription(node);
      } else {
        node.removeAttribute('data-penned-book'); bookSizes.unobserve(node); layouts.delete(node);
      }
    };
    if (element.matches('.vellix-page-reference')) mark(element);
    element.querySelectorAll('.vellix-page-reference').forEach(mark);
  }
  function request(book) {
    if (!enabled(book) || window.PennedBlockSelection?.hasActiveGesture ||
        window.PennedBlockDragAndDrop?.ownsReorder) { cancel('selection-scroll-or-inactive'); return; }
    if (consumed?.id === book.dataset.pageId && consumed.until > performance.now()) return;
    if (press) { clearTimeout(press.timer); press.requested = true; }
    consumed = {id: book.dataset.pageId, until: Infinity};
    editor.commands.blur();
    post('pageCardSettingsRequest', {documentId: book.dataset.pageId});
    log('book-settings-requested', 'stationary-hold');
  }
  const on = (target, name, handler, passive = false) => target.addEventListener(name, handler,
    {capture: true, passive, signal: listeners.signal});
  on(root, 'pointerdown', event => {
    const book = bookAt(event.target);
    if (!enabled(book) || !event.isPrimary || event.button !== 0) return;
    cancel('new-contact'); consumed = null;
    // Stop the old Page actions timer, but not the selection engine's TouchEvents.
    event.stopPropagation();
    if (event.pointerType === 'mouse') event.preventDefault();
    const current = {book, pointer: event.pointerId, x: event.clientX, y: event.clientY, requested: false};
    press = current;
    current.timer = setTimeout(() => { if (press === current) request(book); }, 550);
    log('book-settings-hold-started', 'book-control');
  });
  on(window, 'pointermove', event => {
    if (press && (event.pointerId !== press.pointer || Math.hypot(event.clientX - press.x, event.clientY - press.y) > 10)) cancel('movement');
  }, true);
  const finish = event => {
    if (press && event.pointerId !== undefined && event.pointerId !== press.pointer) return;
    cancel(event.type);
    if (consumed) consumed.until = performance.now() + 700;
  };
  on(window, 'pointerup', finish, true);
  on(window, 'pointercancel', finish, true);
  on(window, 'touchcancel', finish, true);
  on(window, 'touchstart', event => { if (event.touches.length !== 1) cancel('additional-touch'); }, true);
  on(window, 'scroll', () => cancel('scroll'), true);
  on(window, 'pagehide', () => { cancel('page-hidden'); consumed = null; }, true);
  on(document, 'visibilitychange', () => { if (document.visibilityState === 'hidden') { cancel('app-hidden'); consumed = null; } }, true);
  on(root, 'contextmenu', event => {
    const book = bookAt(event.target);
    if (!enabled(book)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    request(book);
    if (consumed) consumed.until = performance.now() + 700;
  });
  on(root, 'click', event => {
    const book = bookAt(event.target);
    if (!book || consumed?.id !== book.dataset.pageId || consumed.until < performance.now()) return;
    event.preventDefault(); event.stopImmediatePropagation();
    log('book-settings-click-suppressed', 'settings-hold-consumed-contact');
  });
  const observer = new MutationObserver(changes => {
    for (const change of changes) {
      if (change.type === 'attributes') decorate(change.target);
      else {
        for (const node of change.removedNodes) {
          if (!(node instanceof Element) || node.isConnected) continue;
          if (node.matches('.vellix-page-reference')) bookSizes.unobserve(node);
          node.querySelectorAll('.vellix-page-reference').forEach(book => bookSizes.unobserve(book));
        }
        for (const node of change.addedNodes) decorate(node);
      }
    }
    if (press && !press.book.isConnected) cancel('book-detached');
  });
  observer.observe(root, {childList: true, subtree: true, attributes: true, attributeFilter: ['data-page-id']});
  const style = document.createElement('style');
  style.textContent = `[data-penned-book="true"], [data-penned-book="true"] * {
    -webkit-user-select:none !important; user-select:none !important; -webkit-touch-callout:none;
  }
  .tiptap-editor [data-penned-book="true"] > .vellix-page-reference-button { box-shadow:none; }`;
  document.head.appendChild(style);
  window.PennedBookPages = {isSettingsSurface: target => enabled(bookAt(target))};
  function dispatch(name, args = {}) {
    if (name === 'setBookDescriptionImage') {
      for (const book of root.querySelectorAll('[data-penned-book="true"]')) {
        const layout = layouts.get(book);
        if (!layout || book.dataset.pageId !== args.documentID || layout.token !== args.token) continue;
        const image = book.querySelector('.vellix-page-card-image');
        if (image && typeof args.image === 'string' && args.image.startsWith('data:image/png;base64,')) {
          layout.image = args.image; image.src = args.image;
        }
      }
      return true;
    }
    if (name === 'setContent' || (name === 'setEditable' && args.editable === false)) {
      cancel('document-or-editability-change'); consumed = null;
    }
    if (name !== 'setPageReferences' && name !== 'preparePresentation') return command.call(this, name, args);
    books = new Set((args.pages || []).filter(page => page.isBook === true).map(page => page.documentID));
    bookImages.clear();
    for (const page of args.pages || []) if (page.isBook === true) bookImages.set(page.documentID, page.cardImage);
    const result = command.call(this, name, args);
    const updated = value => { decorate(root); return value; };
    return result?.then ? result.then(updated) : updated(result);
  }
  window.tiptapCommand = dispatch;
  editor.on('destroy', () => {
    cancel('editor-destroyed'); listeners.abort(); observer.disconnect(); bookSizes.disconnect(); style.remove();
    if (window.tiptapCommand === dispatch) window.tiptapCommand = command;
    delete window.PennedBookPages;
  });
})();
"""#
}
