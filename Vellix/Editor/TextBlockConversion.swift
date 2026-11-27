import SwiftUI

nonisolated struct TipTapTextConversionState: Equatable {
    var token: String?
    var targets: Set<String> = []

    static func decode(_ payload: [String: Any]) -> Self {
        Self(token: payload["token"] as? String, targets: Set(payload["targets"] as? [String] ?? []))
    }
}

nonisolated struct TipTapBlockConversionRequest: Equatable {
    var target: String
    var token: String
    var documentIDs: [String]
    var canonicalJSON: String?
}

struct EditorTextConversionMenu: View {
    @ObservedObject var session: TipTapEditorSession
    var showsTitle = false
    var blockSelection = false
    var isCompact = true
    var selectionTarget: String?

    var body: some View {
        let selection = session.textConversionState
        Menu {
            if session.templateEditing {
                Menu("Template Components") {
                    ForEach(TemplateComponentKind.allCases) { kind in
                        option(kind.title, target: "templateComponent:\(kind.rawValue)", selection: selection)
                    }
                }
            }
            Menu("Headings") {
                ForEach(1...4, id: \.self) { level in
                    Menu(DocumentTextStyleNames.heading(level)) {
                        option("Text", target: "textHeading\(level)", selection: selection)
                        option("Label", target: "labelHeading\(level)", selection: selection)
                    }
                }
            }
            Menu("Text Blocks") {
                option("Paragraph", target: "paragraph", selection: selection)
                option("Caption", target: "caption", selection: selection)
            }
            Menu("Content Blocks") {
                Menu("Callouts") {
                    option("Icon", target: "iconCallout", selection: selection)
                    option("Plain", target: "plainCallout", selection: selection)
                }
                option("Blockquote", target: "quote", selection: selection)
                option("Table", target: "table", selection: selection)
            }
            Menu("Links & Files") {
                option("Link", target: "link", selection: selection)
                option("File", target: "file", selection: selection)
            }
            Menu("Nested Content") {
                option("Page", target: "nestedPage", selection: selection)
                option("Card", target: "pageCard", selection: selection)
                option("Book", target: "pageBook", selection: selection)
            }
            option("Code Block", target: "codeBlock", selection: selection)
            Menu("Other Blocks") {
                option("List Grids", target: "listGrid", selection: selection)
                option("Fields", target: "fields", selection: selection)
                option("Tabs", target: "tabs", selection: selection)
                option("Infocards", target: "informationCard", selection: selection)
                option("Grid Cards", target: "gridCard", selection: selection)
                Menu("Planner") {
                    option("Calendar", target: "weekStrip", selection: selection)
                    option("Event", target: "existingEvent", selection: selection)
                }
            }
            option("Collection", target: "collection", selection: selection)
            Menu("Toggle") {
                option("Paragraph", target: "toggleListItem", selection: selection)
                ForEach(1...4, id: \.self) { level in
                    option(DocumentTextStyleNames.heading(level), target: "toggleHeading\(level)", selection: selection)
                }
            }
            Menu("Lists") {
                option("Checklist", target: "checkListItem", selection: selection)
                option("Bullet List", target: "bulletListItem", selection: selection)
                option("Numbered List", target: "numberedListItem", selection: selection)
            }
            Menu("Properties") {
                ForEach(InlinePropertyKind.allCases) { kind in
                    option(kind.title, target: "property:\(kind.rawValue)", selection: selection)
                }
            }
            Menu("Divider") {
                ForEach(VellixDividerStyle.allCases) { style in
                    option(style.title, target: "divider:\(style.rawValue)", selection: selection)
                }
                option("Page Break", target: "pageBreak", selection: selection)
            }
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
            if target == "existingEvent" {
                session.beginExistingEventConversion(blockSelection: blockSelection)
                return
            }
            if blockSelection {
                guard session.selectedBlockCount > 0, session.selectionMode != "off",
                      session.isReady, !session.isLoadingDocument, session.editingEnabled else { return }
                if target.hasPrefix("toggleHeading"), let level = Int(target.dropFirst("toggleHeading".count)) {
                    session.setSelectedBlockType("toggleListItem", level: level, selectionTarget: selectionTarget)
                } else {
                    session.setSelectedBlockType(target, selectionTarget: selectionTarget)
                }
                return
            }
            guard let token = selection.token else { return }
            session.convertSelectedText(to: target, token: token)
        }
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
  const pendingPages = new Map();
  let pendingUI = null;
  let frame = 0, signature = '', serial = 0, destroyed = false;
  let availabilityDoc = null, availabilityToken = null, availabilityEditable = null, availabilityDividers = '';
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
    const targets = ['paragraph', 'caption', 'plainCallout', 'iconCallout', 'quote', 'table',
      'link', 'file', 'nestedPage', 'pageCard', 'pageBook', 'codeBlock', 'listGrid', 'fields', 'tabs',
      'informationCard', 'gridCard', 'weekStrip', 'existingEvent', 'collection', 'toggleListItem', 'checkListItem',
      'bulletListItem', 'numberedListItem', 'pageBreak'];
    for (let level = 1; level <= 4; level++) targets.push('heading' + level, 'textHeading' + level,
      'labelHeading' + level, 'toggleHeading' + level);
    for (const kind of ['text', 'number', 'date', 'select', 'multiSelect', 'checkbox', 'url']) targets.push('property:' + kind);
    for (const kind of ['rating', 'singleSelect', 'multiSelect', 'slider']) targets.push('templateComponent:' + kind);
    for (const style of ['dottedCircles', 'fourCircles', 'thinLine', 'thickLine', 'washiTape']) targets.push('divider:' + style);
    return targets;
  }

  const postConversion = payload => window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: 'blockConversionRequest', payload });
  const fragment = values => editor.state.doc.content.constructor.fromArray(values);
  function make(type, attrs = {}, children) {
    const schemaType = editor.schema.nodes[type];
    if (!schemaType) throw new Error('This editor does not contain the ' + type + ' block.');
    const node = schemaType.createAndFill({ id: crypto.randomUUID(), ...attrs },
      children == null ? null : fragment(children.map(value => editor.schema.nodeFromJSON(value))));
    if (!node) throw new Error('The conversion could not preserve content in ' + type + '.');
    node.check();
    return node.toJSON();
  }
  const paragraph = content => make('paragraph', {}, content || []);
  function fresh(node) {
    return { ...node, ...(node.attrs ? { attrs: { ...node.attrs, id: crypto.randomUUID() } } : {}),
      ...(node.content ? { content: node.content.map(fresh) } : {}) };
  }
  function bodies(node) {
    const type = editor.schema.nodes[node.type];
    if (type?.isTextblock) return [type.isInGroup('block') ? fresh(node) : paragraph(node.content)];
    if (type?.isLeaf) return [fresh(node)];
    const content = (node.content || []).flatMap(child => {
      const childType = editor.schema.nodes[child.type];
      return childType?.isInGroup('block') ? [fresh(child)] : bodies(child);
    });
    if (node.type === 'gridCard' && node.attrs?.title) content.unshift(paragraph([{ type: 'text', text: node.attrs.title }]));
    return content.length ? content : [paragraph()];
  }
  function inline(blocks) {
    const result = [];
    function visit(node) {
      if (editor.schema.nodes[node.type]?.isTextblock) {
        if (result.length && node.content?.length) result.push({ type: 'hardBreak' });
        result.push(...(node.content || []));
      } else for (const child of node.content || []) visit(child);
    }
    blocks.forEach(visit);
    return result;
  }
  function atoms(blocks) {
    return blocks.flatMap(node => editor.schema.nodes[node.type]?.isLeaf && !editor.schema.nodes[node.type]?.isInline
      ? [node] : atoms(node.content || []));
  }
  const plainText = blocks => blocks.map(value => {
    const node = editor.schema.nodeFromJSON(value);
    return node.textBetween(0, node.content.size, '\n', leaf => leaf.type.name === 'hardBreak' ? '\n' : '');
  }).join('\n');
  function conversionNodes(source, target, payload) {
    const attrs = source.attrs || {}, blockID = attrs.id || crypto.randomUUID(), body = bodies(source), text = inline(body);
    const common = { id: blockID, indent: attrs.indent || 0, textAlign: attrs.textAlign, blockFont: attrs.blockFont };
    const heading = /^(?:text|label)?[Hh]eading([1-4])$/.exec(target);
    const toggle = /^toggleHeading([1-4])$/.exec(target);
    const targetType = { quote: 'blockquote', fields: 'minimalFields', toggleListItem: 'toggleItem',
      checkListItem: 'taskList', bulletListItem: 'bulletList', numberedListItem: 'orderedList' }[target] || target;
    if (source.type === targetType) return [source];
    const retainedAtoms = atoms(body);
    if (heading) return [make('heading', { ...common, level: Number(heading[1]),
      label: { ...(attrs.label || {}), presentation: target.startsWith('label') ? 'label' : 'text' } }, text), ...retainedAtoms];
    if (['paragraph', 'caption', 'codeBlock'].includes(target)) {
      const value = plainText(body);
      const content = target === 'codeBlock' ? (value ? [{ type: 'text', text: value }] : []) : text;
      return [make(target, common, content), ...retainedAtoms];
    }
    if (target === 'plainCallout') return [make('plainCallout', { ...common, color: attrs.color || attrs.backgroundColor || '#302d36', textColor: attrs.textColor }, body)];
    if (target === 'iconCallout') return [make('iconCallout', { ...common, ...Object.fromEntries(['icon', 'iconColor', 'imagePath', 'imageTint', 'textColor'].filter(key => attrs[key] != null).map(key => [key, attrs[key]])),
      backgroundColor: attrs.backgroundColor || attrs.color || '#302d36' }, body)];
    if (target === 'quote') return [make('blockquote', common, body)];
    if (target === 'gridCard') return [make('gridCard', { ...common, width: 'half', height: 140,
      backgroundColor: attrs.backgroundColor || attrs.color || '#c4e5de' }, body)];
    if (target === 'informationCard') return [make('informationCard', common, [
      make('informationCardTitle', {}, []), make('informationCardDescription', {}, []), make('informationCardBody', {}, body)])];
    const firstText = editor.schema.nodes[body[0]?.type]?.isTextblock;
    const firstContent = firstText ? body[0].content || [] : [];
    const rest = firstText ? body.slice(1) : body;
    if (target === 'toggleListItem' || toggle) return [make('toggleItem', { id: blockID, open: true }, [
      toggle ? make('heading', { level: Number(toggle[1]) }, firstContent) : paragraph(firstContent), ...rest])];
    if (['checkListItem', 'bulletListItem', 'numberedListItem'].includes(target)) {
      const task = target === 'checkListItem', list = task ? 'taskList' : target === 'bulletListItem' ? 'bulletList' : 'orderedList';
      return [make(list, { id: blockID }, [make(task ? 'taskItem' : 'listItem', task ? { checked: attrs.checked === true } : {},
        [paragraph(firstContent), ...rest])])];
    }
    if (target === 'weekStrip') {
      const today = new Date();
      const dateKey = date => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
      const start = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12);
      start.setDate(start.getDate() - start.getDay());
      const dates = Array.from({length: 7}, (_, index) => { const date = new Date(start); date.setDate(start.getDate() + index); return dateKey(date); });
      return [make('weekStrip', { ...common, selectedDate: dateKey(today), firstDayOfWeek: 0 }, dates.map(date =>
        make('weekDayPanel', { date }, date === dateKey(today) ? body : [paragraph()])))];
    }
    if (target === 'tabs') {
      const panel = make('tabPanel', { name: 'Tab 1' }, body);
      return [make('tabs', { ...common, activeTab: panel.attrs.id }, [panel])];
    }
    if (target === 'fields') return [make('minimalFields', common, [make('minimalRecord', {}, [
      make('minimalRecordTitle', {}, []), make('minimalField', {}, [make('minimalFieldLabel', {}, []), make('minimalFieldValue', {}, body)])])])];
    if (target === 'listGrid') return [make('listGrid', common, [make('listGridRow', {}, [
      make('listGridLabel', {}, [paragraph()]), make('listGridValue', {}, [paragraph(text)])])]),
      ...retainedAtoms];
    if (target === 'table') return [make('table', { ...common, rowCount: 1, columnCount: 1, headerRow: false }, [
      make('tableRow', {}, [make('tableCell', {}, body)])])];
    if (target.startsWith('property:')) return [make('inlineProperty', { ...common,
      property: { kind: target.slice(9), name: '', value: plainText(body) } }), ...retainedAtoms];
    if (target.startsWith('divider:') || target === 'pageBreak' || target === 'collection' || target.startsWith('templateComponent:')) {
      const type = target.startsWith('divider:') ? 'divider' : target.startsWith('templateComponent:') ? 'templateComponent' : target;
      const extra = type === 'divider' ? { ...attrs, style: target.slice(8) } : type === 'templateComponent'
        ? { definition: { kind: target.split(':')[1], label: '', minimum: 1, maximum: 5, step: 1, choices: [] } } : {};
      // Leaf targets cannot own rich content. Keep it adjacent rather than deleting it.
      return [make(type, { ...common, ...extra, id: blockID }), ...(source.type === type ? [] : body)];
    }
    throw new Error('Unknown conversion target: ' + target);
  }
  function currentRecords(records) {
    const result = [];
    for (const record of records) {
      let found = null;
      editor.state.doc.descendants((node, pos) => {
        if (node.attrs.id && node.attrs.id === record.node.attrs.id) { found = { node, pos }; return false; }
      });
      if (!found || !found.node.eq(record.node)) return null;
      result.push(found);
    }
    return result.sort((a, b) => a.pos - b.pos);
  }
  function replaceRecords(records, replacements, apply) {
    const tr = editor.state.tr;
    for (let index = records.length - 1; index >= 0; index--) {
      const block = records[index], nodes = replacements[index].map(value => editor.schema.nodeFromJSON(value));
      nodes.forEach(node => node.check());
      const at = tr.doc.resolve(block.pos), content = fragment(nodes);
      if (!at.parent.canReplace(at.index(), at.index() + 1, content)) throw new Error('This conversion does not fit this container without losing surrounding content.');
      tr.replaceWith(block.pos, block.pos + block.node.nodeSize, content);
    }
    tr.doc.check();
    if (apply) {
      editor.view.dispatch(tr.setMeta('pennedStyleConversion', true));
      void originalCommand('setSelectionMode', { mode: 'off' });
      void originalCommand('requestSnapshot', {});
    }
    return true;
  }
  function convertAny(records, target, apply = true, payload = {}) {
    if (!records.length) return false;
    if (['nestedPage', 'pageCard', 'pageBook'].includes(target)) {
      if (!apply) return true;
      if (records.every(block => block.node.type.name === 'pageReference' && block.node.attrs.documentID)) {
        postConversion({ target, token: crypto.randomUUID(), documentIDs: records.map(block => block.node.attrs.documentID) });
        return true;
      }
      const token = crypto.randomUUID();
      pendingPages.set(token, records);
      postConversion({ target, token, document: { type: 'doc', content: records.map(block => block.node.toJSON()) } });
      return true;
    }
    if (['link', 'file'].includes(target)) {
      if (!apply) return true;
      pendingUI = { target, records };
      void originalCommand('setSelectionMode', { mode: 'off' });
      editor.commands.setNodeSelection(records[0].pos);
      postConversion({ target, token: crypto.randomUUID() });
      return true;
    }
    const replacements = records.map(block => conversionNodes(block.node.toJSON(), target, payload));
    const applied = replaceRecords(records, replacements, apply);
    if (apply && target === 'collection') for (let index = 0; index < replacements.length; index++) {
      if (records[index].node.type.name !== 'collection') window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: 'collectionRequest',
        payload: { action: 'create', blockID: replacements[index][0].attrs.id } });
    }
    if (apply && target === 'divider:washiTape') {
      let pos = null;
      editor.state.doc.descendants((node, at) => { if (node.attrs.id === replacements[0][0].attrs.id) { pos = at; return false; } });
      if (pos != null) { editor.commands.setNodeSelection(pos); void originalCommand('requestBlockSettings', {}); }
    }
    return applied;
  }

  function selectedDividers() {
    if ((document.documentElement.dataset.vellixSelectionMode || 'off') === 'off') return [];
    const selected = window.PennedBlockSelection?.selectedRecords?.();
    if (selected) return selected.filter(block => ['divider', 'horizontalRule'].includes(block.node.type.name));
    const result = [];
    for (const element of editor.view.dom.querySelectorAll('[data-vellix-selected="true"][data-vellix-selection-node-type="divider"], [data-vellix-selected="true"][data-vellix-selection-node-type="horizontalRule"]')) {
      const pos = editor.view.posAtDOM(element, 0), node = editor.state.doc.nodeAt(pos);
      if (node && ['divider', 'horizontalRule'].includes(node.type.name)) result.push({ pos, node });
    }
    return result;
  }

  function schedule() {
    if (frame || destroyed) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const held = plugin.getState(editor.state);
      const enabled = editable();
      const dividers = selectedDividers();
      const dividerSignature = dividers.map(block => `${block.pos}:${block.node.attrs.style || ''}`).join('|');
      if (availabilityDoc === editor.state.doc && availabilityToken === held?.token &&
          availabilityEditable === enabled && availabilityDividers === dividerSignature) return;
      availabilityDoc = editor.state.doc; availabilityToken = held?.token; availabilityEditable = enabled;
      availabilityDividers = dividerSignature;
      const payload = { token: editable() ? held?.token ?? null : null,
        targets: dividers.length || (editable() && held) ? supportedTargets() : [] };
      const next = JSON.stringify(payload);
      if (next === signature) return;
      signature = next;
      window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: 'textConversionState', payload });
    });
  }

  function convert(target, held, apply = true) {
    let selection;
    try { selection = held.bookmark.resolve(editor.state.doc); } catch { return false; }
    if (editor.state.doc.textBetween(selection.from, selection.to, '\n', '\uFFFC') !== held.text) return false;
    const blockText = node => node.textBetween(0, node.content.size, '', leaf =>
      leaf.type.name === 'inlineTag' ? '#' + (leaf.attrs.name || '') : leaf.type.name === 'hardBreak' ? '\n' : '\uFFFC');
    const nodes = [];
    editor.state.doc.nodesBetween(selection.from, selection.to, (node, pos) => {
      if (node.isTextblock) nodes.push({ pos, node, id: node.attrs.id, text: blockText(node) });
    });
    return convertAny(nodes, target, apply);
  }

  editor.registerPlugin(plugin);
  const captureFocus = () => editor.view.dispatch(editor.state.tr.setMeta(plugin, { capture: true }).setMeta('addToHistory', false));
  editor.on('focus', captureFocus);
  editor.on('blur', schedule);
  window.tiptapCommand = async (name, args = {}) => {
    if (name === 'cancelBlockConversion') { pendingUI = null; pendingPages.clear(); return true; }
    if (['insertBlock', 'chooseSlashItem'].includes(name) && /^(?:heading|toggleHeading)[56]$/.test(args.blockType || args.key || '')) return false;
    if (name === 'setSelectedBlockType' && ['heading', 'toggleListItem'].includes(args.blockType) && Number(args.level) > 4) return false;
    if (name === 'setContent' || name === 'setSelectionMode' || (name === 'setEditable' && args.editable === false)) {
      if (name === 'setContent') { pendingPages.clear(); pendingUI = null; }
      editor.view.dispatch(editor.state.tr.setMeta(plugin, { reset: true }).setMeta('addToHistory', false));
    }
    if (name === 'setSelectedBlockType') {
      if (window.PennedBlockSelection?.command(name, args) === false) return false;
      const records = window.PennedBlockSelection?.selectedRecords?.() || [];
      if (records.length) {
        const target = args.blockType === 'toggleListItem' && args.level ? 'toggleHeading' + args.level
          : args.blockType === 'heading' ? 'textHeading' + (args.level || 1) : args.blockType;
        try { return convertAny(records, target, true, args); }
        catch (error) { window.webkit?.messageHandlers?.tiptap?.postMessage({ kind: 'error', payload: { message: error.message } }); return false; }
      }
    }
    if (name === 'finishBlockConversionPage') {
      const held = pendingPages.get(args.token), records = held && currentRecords(held);
      if (!records || !args.documentID) return false;
      const tr = editor.state.tr;
      for (let index = records.length - 1; index >= 0; index--) {
        const block = records[index];
        if (index === 0) tr.replaceWith(block.pos, block.pos + block.node.nodeSize,
          editor.schema.nodeFromJSON(make('pageReference', { id: block.node.attrs.id, documentID: args.documentID })));
        else tr.delete(block.pos, block.pos + block.node.nodeSize);
      }
      tr.doc.check(); editor.view.dispatch(tr.setMeta('pennedStyleConversion', true));
      pendingPages.delete(args.token);
      await originalCommand('setSelectionMode', { mode: 'off' });
      await originalCommand('requestSnapshot', {});
      return true;
    }
    if (name === 'convertSelectedText') {
      const held = plugin.getState(editor.state);
      if (!editable() || !held || held.token !== args.token || !supportedTargets().includes(args.target)) return false;
      return convert(args.target, held);
    }
    const result = await originalCommand(name, args);
    if (pendingUI && ((name === 'linksApply' && pendingUI.target === 'link') ||
        (name === 'attachmentInsert' && pendingUI.target === 'file')) && result === true) {
      const held = pendingUI; pendingUI = null;
      const tr = editor.state.tr, removals = [];
      for (const original of held.records) {
        if (!original.node.attrs.id) continue;
        editor.state.doc.descendants((node, pos) => {
          if (node.attrs.id === original.node.attrs.id && node.eq(original.node) && node.type.name !== 'pageReference') {
            let hasPage = false; node.descendants(child => { if (child.type.name === 'pageReference') hasPage = true; });
            if (!hasPage) removals.push({ pos, size: node.nodeSize });
            return false;
          }
        });
      }
      for (const block of removals.sort((a, b) => b.pos - a.pos)) tr.delete(block.pos, block.pos + block.size);
      if (tr.docChanged) { tr.doc.check(); editor.view.dispatch(tr); await originalCommand('requestSnapshot', {}); }
    }
    if (name === 'linksEnd' && pendingUI?.target === 'link') pendingUI = null;
    return result;
  };
  editor.on('destroy', () => {
    editor.off('focus', captureFocus); editor.off('blur', schedule);
    if (frame) cancelAnimationFrame(frame);
  });
  schedule();
})();
"""#
}
