import SwiftUI

nonisolated struct TipTapTextConversionState: Equatable {
    var token: String?
    var targets: Set<String> = []

    static func decode(_ payload: [String: Any]) -> Self {
        Self(token: payload["token"] as? String, targets: Set(payload["targets"] as? [String] ?? []))
    }
}

struct EditorTextConversionMenu: View {
    @ObservedObject var session: TipTapEditorSession
    var showsTitle = false
    var blockSelection = false
    var isCompact = true

    var body: some View {
        let selection = session.textConversionState
        Menu {
            option("Paragraph", target: "paragraph", selection: selection)
            option("Caption", target: "caption", selection: selection)
            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    option("H\(level)", target: "heading\(level)", selection: selection)
                }
            }
            Menu("Callout") {
                option("With Icon", target: "callout", selection: selection)
                option("Without Icon", target: "plainCallout", selection: selection)
            }
            option("Blockquote", target: "quote", selection: selection)
            option("Checklist", target: "checkListItem", selection: selection)
            option("Bullet List", target: "bulletListItem", selection: selection)
            option("Numbered List", target: "numberedListItem", selection: selection)
            Menu("Toggle") {
                option("Body", target: "toggleListItem", selection: selection)
                ForEach(1...6, id: \.self) { level in
                    option("H\(level)", target: "toggleHeading\(level)", selection: selection)
                }
            }
            option("Code Block", target: "codeBlock", selection: selection)
        } label: {
            if showsTitle {
                HStack(spacing: 8) {
                    icon
                    Text("Convert Selection")
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            } else {
                icon.frame(width: blockSelection ? (isCompact ? 42 : 50) : 44,
                           height: blockSelection ? (isCompact ? 36 : 42) : 44).contentShape(Rectangle())
            }
        }
        .pennedIconMenuStyle()
        .disabled((blockSelection ? session.selectedBlockCount == 0 || session.selectionMode == "off" :
                    selection.token == nil || selection.targets.isEmpty || session.selectionMode != "off") ||
                  session.isConvertingSelectedText || !session.isReady || session.isLoadingDocument || !session.editingEnabled)
        .help(blockSelection ? "Convert selected blocks" : "Convert selected text to another block type")
        .accessibilityLabel(blockSelection ? "Convert selected blocks" : "Convert selected text")
    }

    private var icon: some View {
        Image("addwavy").renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(VellixSurface.controlInk).frame(width: 22, height: 22)
    }

    private func option(_ title: String, target: String, selection: TipTapTextConversionState) -> some View {
        Button(title) {
            if blockSelection {
                guard session.selectedBlockCount > 0, session.selectionMode != "off",
                      session.isReady, !session.isLoadingDocument, session.editingEnabled else { return }
                if target.hasPrefix("toggleHeading"), let level = Int(target.dropFirst("toggleHeading".count)) {
                    session.setSelectedBlockType("toggleListItem", level: level)
                } else if target.hasPrefix("heading"), let level = Int(target.dropFirst("heading".count)) {
                    session.setSelectedBlockType("heading", level: level)
                } else {
                    session.setSelectedBlockType(target)
                }
                return
            }
            guard let token = selection.token else { return }
            session.convertSelectedText(to: target, token: token)
        }.disabled(!blockSelection && !selection.targets.contains(target))
    }
}

enum TextBlockConversion {
    // Shared native integration, independent of generated editor bundle updates.
    static let script = #"""
(() => {
  const editor = document.querySelector('.tiptap-editor')?.editor;
  if (!editor || editor.storage.pennedTextConversion) return;
  editor.storage.pennedTextConversion = true;
  // Register against the ProseMirror runtime already owned by this editor.
  const Plugin = editor.state.plugins[0]?.constructor;
  if (typeof Plugin !== 'function') return;
  const originalCommand = window.tiptapCommand;
  let frame = 0, signature = '', serial = 0, destroyed = false;
  const editable = () => editor.isEditable && !editor.view.composing &&
    (document.documentElement.dataset.vellixSelectionMode || 'off') === 'off';

  function capture(state, previous) {
    let selection = state.selection;
    if (!editable() || selection.empty || selection.toJSON().type !== 'text') return null;
    // A range ending at the next paragraph's first caret does not include it.
    if (selection.$to.parentOffset === 0 && selection.to > selection.from) {
      selection = selection.constructor.between(selection.$from, state.doc.resolve(selection.$to.before()), -1);
    }
    const text = state.doc.textBetween(selection.from, selection.to, '\n', '\uFFFC');
    if (!text.length) return null;
    let hasAtom = false;
    state.doc.nodesBetween(selection.from, selection.to, node => {
      if (node.isAtom && !node.isInline && !node.isTextblock) hasAtom = true;
    });
    if (hasAtom) return null;
    const token = previous?.from === selection.from && previous?.to === selection.to && previous.text === text
      ? previous.token : `text-convert-${++serial}-${crypto.randomUUID()}`;
    return { token, from: selection.from, to: selection.to, text, bookmark: selection.getBookmark() };
  }

  const plugin = new Plugin({
    state: {
      init: (_config, state) => capture(state, null),
      apply(tr, held, _old, next) {
        if (tr.getMeta(plugin)?.reset) return null;
        if (tr.getMeta(plugin)?.capture || (tr.selectionSet && editor.isFocused)) return capture(next, held);
        if (!held || !tr.docChanged) return held;
        try {
          const selection = held.bookmark.map(tr.mapping).resolve(tr.doc);
          const text = tr.doc.textBetween(selection.from, selection.to, '\n', '\uFFFC');
          if (selection.empty || text !== held.text) return null;
          return { ...held, from: selection.from, to: selection.to, bookmark: selection.getBookmark() };
        } catch { return null; }
      },
    },
    view: () => {
      destroyed = false;
      schedule();
      return { update: schedule, destroy: () => { destroyed = true; cancelAnimationFrame(frame); frame = 0; } };
    },
  });

  function supportedTargets() {
    const nodes = editor.schema.nodes, targets = ['paragraph'];
    if (nodes.caption) targets.push('caption');
    const levels = editor.extensionManager.extensions.find(extension => extension.name === 'heading')?.options.levels || [];
    if (nodes.heading) for (const level of levels) if (level >= 1 && level <= 6) targets.push('heading' + level);
    for (const [key, type] of [['callout', 'callout'], ['plainCallout', 'plainCallout'], ['quote', 'blockquote'],
      ['checkListItem', 'taskList'], ['bulletListItem', 'bulletList'], ['numberedListItem', 'orderedList'], ['codeBlock', 'codeBlock']]) {
      if (nodes[type]) targets.push(key);
    }
    if (nodes.toggleItem) {
      targets.push('toggleListItem');
      for (const level of levels) if (level >= 1 && level <= 6) targets.push('toggleHeading' + level);
    }
    return targets;
  }

  function schedule() {
    if (frame || destroyed) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const held = plugin.getState(editor.state);
      const payload = { token: editable() ? held?.token ?? null : null,
        targets: editable() && held ? supportedTargets().filter(target => {
          try { return convert(target, held, false); } catch { return false; }
        }) : [] };
      const next = JSON.stringify(payload);
      if (next === signature) return;
      signature = next;
      window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: 'textConversionState', payload });
    });
  }

  function enclosed(type, selection) {
    for (let depth = selection.$from.sharedDepth(selection.to); depth > 0; depth--) {
      if (selection.$from.node(depth).type.name === type) return true;
    }
    return false;
  }

  function convert(target, held, apply = true) {
    let selection;
    try { selection = held.bookmark.resolve(editor.state.doc); } catch { return false; }
    if (editor.state.doc.textBetween(selection.from, selection.to, '\n', '\uFFFC') !== held.text) return false;
    const blockText = node => node.textBetween(0, node.content.size, '', leaf =>
      leaf.type.name === 'inlineTag' ? '#' + (leaf.attrs.name || '') : leaf.type.name === 'hardBreak' ? '\n' : '\uFFFC');
    const nodes = [];
    editor.state.doc.nodesBetween(selection.from, selection.to, (node, pos) => {
      if (node.isTextblock) nodes.push({ pos, id: node.attrs.id, text: blockText(node) });
    });
    // A supplied transaction stays undispatched until the entire chain succeeds.
    const transaction = editor.state.tr;
    let chain = editor.commandManager.createChain(transaction).setTextSelection({ from: selection.from, to: selection.to });
    const heading = target.match(/^heading([1-6])$/), toggleHeading = target.match(/^toggleHeading([1-6])$/);
    if (target === 'paragraph' || target === 'caption' || target === 'codeBlock' || heading) {
      chain = chain.setNode(heading ? 'heading' : target, heading ? { level: Number(heading[1]) } : {});
    } else if (target === 'toggleListItem' || toggleHeading) {
      chain = chain.setNode(toggleHeading ? 'heading' : 'paragraph', toggleHeading ? { level: Number(toggleHeading[1]) } : {});
      if (!enclosed('toggleItem', selection)) chain = chain.wrapIn('toggleItem', { id: crypto.randomUUID(), open: true });
    } else if (['checkListItem', 'bulletListItem', 'numberedListItem'].includes(target)) {
      const type = { checkListItem: 'taskList', bulletListItem: 'bulletList', numberedListItem: 'orderedList' }[target];
      if (!enclosed(type, selection)) {
        chain = target === 'checkListItem' ? chain.toggleTaskList() : target === 'bulletListItem' ? chain.toggleBulletList() : chain.toggleOrderedList();
      }
    } else {
      const type = { quote: 'blockquote', callout: 'callout', plainCallout: 'plainCallout' }[target];
      if (!type) return false;
      if (!enclosed(type, selection)) chain = chain.wrapIn(type, { id: crypto.randomUUID(),
        ...(target === 'callout' ? { icon: 'sparkle', color: '#ffffff' } : target === 'plainCallout' ? { color: '#ffffff' } : {}) });
    }
    // Preserve existing block identities through schema-driven lifting/conversion.
    chain = chain.command(({ tr }) => {
      const restored = new Set();
      for (const original of nodes) {
        const position = tr.mapping.map(original.pos, 1);
        let node = tr.doc.nodeAt(position), pos = position;
        if (!node?.isTextblock) {
          const resolved = tr.doc.resolve(Math.min(position, tr.doc.content.size));
          for (let depth = resolved.depth; depth > 0; depth--) if (resolved.node(depth).isTextblock) {
            node = resolved.node(depth); pos = resolved.before(depth); break;
          }
        }
        if (!node?.isTextblock || restored.has(pos) || blockText(node) !== original.text) return false;
        restored.add(pos);
        if (original.id && node.attrs.id !== original.id) tr.setNodeMarkup(pos, undefined, { ...node.attrs, id: original.id });
      }
      tr.setMeta(plugin, { capture: true });
      tr.scrollIntoView();
      return true;
    });
    const applied = chain.run();
    if (applied && apply) { editor.view.dispatch(transaction); editor.view.focus(); schedule(); }
    return applied;
  }

  editor.registerPlugin(plugin);
  const captureFocus = () => editor.view.dispatch(editor.state.tr.setMeta(plugin, { capture: true }).setMeta('addToHistory', false));
  editor.on('focus', captureFocus);
  editor.on('blur', schedule);
  window.tiptapCommand = async (name, args = {}) => {
    if (name === 'setContent' || name === 'setSelectionMode' || (name === 'setEditable' && args.editable === false)) {
      editor.view.dispatch(editor.state.tr.setMeta(plugin, { reset: true }).setMeta('addToHistory', false));
    }
    if (name === 'convertSelectedText') {
      const held = plugin.getState(editor.state);
      if (!editable() || !held || held.token !== args.token || !supportedTargets().includes(args.target)) return false;
      return convert(args.target, held);
    }
    return originalCommand(name, args);
  };
  editor.on('destroy', () => {
    editor.off('focus', captureFocus); editor.off('blur', schedule);
    if (frame) cancelAnimationFrame(frame);
  });
  schedule();
})();
"""#
}
