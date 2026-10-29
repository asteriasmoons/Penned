(function (global) {
  "use strict";
  const F = () => global.VellixTableFormulas;
  const control = { editor: null, menu: false, selecting: false, bookmark: null, insertion: null, drag: null, signature: "" };
  const freshID = () => global.crypto.randomUUID();
  function resizeWidths(original, boundary, delta, left) {
    const widths = original.slice(); let offset = left;
    if (boundary === 0) {
      delta = Math.max(-left, Math.min(original[0] - 56, delta)); offset += delta; widths[0] -= delta;
    } else if (boundary === widths.length) widths[boundary - 1] = Math.max(56, Math.min(3000, original[boundary - 1] + delta));
    else {
      delta = Math.max(56 - original[boundary - 1], Math.min(original[boundary] - 56, delta));
      widths[boundary - 1] += delta; widths[boundary] -= delta;
    }
    return { widths, offset };
  }
  const color = value => /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(value || "") ? value : null;
  const fonts = { system: "system-ui,sans-serif", rounded: "ui-rounded,system-ui,sans-serif", serif: "ui-serif,Georgia,serif", mono: "ui-monospace,monospace", hachiMaruPop: '"HachiMaruPop",cursive' };
  let api, T;
  let availableFunctions;
  function functions() {
    return availableFunctions ||= Object.keys(new global.FormulaParser().functions).filter(name => name !== "WEBSERVICE").sort();
  }
  function post(kind, payload) { api.post(kind, payload); }
  function tdiag(event, extra) {
    try { post("diag", { message: "VELLIX-TABLES " + event + (extra ? " " + JSON.stringify(extra) : "") }); } catch (_) {}
  }
  function permanentText(node) {
    if (node.attrs?.placeholderProjection) return "";
    if (node.isText) return node.text;
    const parts = []; node.forEach(child => parts.push(permanentText(child)));
    return parts.join(node.inlineContent ? "" : "\n").trim();
  }
  function tableRecords(doc) {
    const records = [];
    doc.descendants((node, pos) => { if (node.type.spec.tableRole === "table") records.push({ node, pos }); });
    return records;
  }
  function grid(record) {
    const map = T.TableMap.get(record.node), cells = [];
    for (let row = 0; row < map.height; row++) {
      const line = [];
      for (let col = 0; col < map.width; col++) {
        const offset = map.map[row * map.width + col], node = record.node.nodeAt(offset);
        line.push({ id: node.attrs.id, value: permanentText(node), formula: node.attrs.formula,
          format: node.attrs.format, attrs: node.attrs, node, pos: record.pos + 1 + offset });
      }
      cells.push(line);
    }
    const columnless = record.node.attrs.columnless === true, rowless = record.node.attrs.rowless === true;
    const logical = columnless ? { rows: map.height, columns: 0 }
      : rowless ? { rows: 0, columns: map.width }
      : { rows: map.height, columns: map.width };
    const degenerate = columnless || rowless;
    return { id: record.node.attrs.id, name: record.node.attrs.name || "Table", cells, map, columnless, rowless, degenerate, logical, ...record };
  }
  function current(state = control.editor.state) {
    try {
      const rect = T.selectedRect(state);
      const record = { node: rect.table, pos: rect.tableStart - 1 };
      return { ...grid(record), rect };
    } catch (_) { return null; }
  }
  function selectedCells(table) {
    const positions = table.map.cellsInRect(table.rect);
    return positions.map(offset => ({ node: table.node.nodeAt(offset), pos: table.pos + 1 + offset,
      rect: table.map.findCell(offset) }));
  }
  function context() {
    const table = current();
    if (!table) return null;
    const selected = selectedCells(table), cell = selected[0], attrs = cell?.node.attrs || cellDefaults;
    const merged = table.cells.some(line => line.some(item => item.node.attrs.rowspan > 1 || item.node.attrs.colspan > 1));
    const contents = cell ? permanentText(cell.node) : "";
    return { tableID: table.id, cellID: attrs.id || "", name: table.name, row: cell?.rect.top || 0, column: cell?.rect.left || 0,
      rowCount: table.logical.rows, columnCount: table.logical.columns, selectedCount: selected.length,
      fromRow: table.rect.top, toRow: table.rect.bottom, fromColumn: table.rect.left, toColumn: table.rect.right,
      formula: attrs.formula || "", contents, result: attrs.calculated ?? F().display(F().scalar(contents, attrs.format), attrs),
      bold: attrs.bold ?? cell?.node.type.spec.tableRole === "header_cell", italic: attrs.italic === true,
      strike: attrs.strike === true, code: attrs.code === true, align: attrs.align || "left", font: attrs.font || "default",
      format: attrs.format || "text", decimals: attrs.decimals ?? 2, currency: attrs.currency || "USD",
      fillColor: attrs.fillColor || "", textColor: attrs.textColor || "", stripeColor: table.node.attrs.stripeColor || "",
      headerRow: table.degenerate ? false : table.node.firstChild?.firstChild?.type.spec.tableRole === "header_cell",
      headerColumn: !table.degenerate && table.node.content.content.every(row => row.firstChild?.type.spec.tableRole === "header_cell"),
      canDeleteRows: table.logical.rows > 0,
      canDeleteColumns: table.logical.columns > 0,
      canMerge: !table.degenerate && selected.length > 1 && T.mergeCells(control.editor.state),
      canSplit: !table.degenerate && T.splitCell(control.editor.state), canSort: !table.degenerate && !merged,
      functions: functions() };
  }
  function publish(force = false) {
    if (!control.editor) return;
    const value = context(), signature = JSON.stringify(value);
    if (force || signature !== control.signature) { control.signature = signature; post("tableState", value || {}); }
    const active = !!value && control.editor.isEditable && (control.editor.isFocused || control.menu || !!control.drag || control.selecting);
    control.editor.view.dom.querySelectorAll(".vellix-table-wrapper").forEach(wrapper => {
      const enabled = active && wrapper.dataset.tableId === value?.tableID;
      if (wrapper.classList.contains("vellix-table-active") !== enabled) wrapper.classList.toggle("vellix-table-active", enabled);
    });
  }
  function restore() {
    if (control.menu && control.bookmark) {
      try { control.editor.view.dispatch(control.editor.state.tr.setSelection(control.bookmark.resolve(control.editor.state.doc))); }
      catch (_) { control.bookmark = null; }
    }
  }
  function wrapperSurfaceTop(tableID) {
    try {
      const root = control.editor && control.editor.view && control.editor.view.dom;
      if (!root) return 0;
      const wrapper = root.querySelector('.vellix-table-wrapper[data-table-id="' + tableID + '"]');
      if (!wrapper) return 0;
      return Math.max(0, wrapper.getBoundingClientRect().top - root.getBoundingClientRect().top);
    } catch (_) { return 0; }
  }
  function openMenu() {
    control.menu = true;
    control.bookmark = control.editor.state.selection.getBookmark();
    const value = context();
    if (value) value.surfaceTop = wrapperSurfaceTop(value.tableID);
    tdiag("openMenu", { hasContext: !!value, tableID: value && value.tableID, surfaceTop: value && value.surfaceTop, editable: !!(control.editor && control.editor.isEditable), focused: !!(control.editor && control.editor.isFocused), selecting: !!control.selecting });
    if (value) post("tableMenuRequest", value);
    publish(true);
  }
  function menuButton() {
    tdiag("btn-created");
    const button = document.createElement("button"); button.className = "vellix-table-cell-menu"; button.contentEditable = "false";
    button.type = "button"; button.setAttribute("aria-label", "Table cell options");
    const preventFocus = event => { tdiag("btn-preventFocus", { type: event.type }); event.preventDefault(); };
    // Keep the tap from stealing editor focus/selection off the cell...
    button.addEventListener("pointerdown", preventFocus);
    button.addEventListener("mousedown", preventFocus);
    button.addEventListener("touchstart", preventFocus, { passive: false });
    // ...but open on pointerup: WKWebView suppresses the synthetic `click` when touchstart's
    // default is prevented, so a click-only handler misses almost every touch tap. pointerup still fires.
    let lastOpen = 0;
    const open = event => {
      event.preventDefault(); event.stopPropagation();
      const now = Date.now(), debounced = now - lastOpen < 400;
      tdiag("btn-open", { type: event.type, debounced });
      if (debounced) return; lastOpen = now;
      openMenu();
    };
    button.addEventListener("pointerup", open);
    button.addEventListener("touchend", open, { passive: false });
    button.addEventListener("click", open);
    return button;
  }
  function cellStyles(attrs) {
    const styles = [];
    if (color(attrs.fillColor)) styles.push(`background-color:${attrs.fillColor}`);
    if (color(attrs.textColor)) styles.push(`color:${attrs.textColor}`);
    if (fonts[attrs.font]) styles.push(`font-family:${fonts[attrs.font]}`);
    if (attrs.bold != null) styles.push(`font-weight:${attrs.bold ? 700 : 400}`);
    if (attrs.italic) styles.push("font-style:italic");
    if (attrs.strike) styles.push("text-decoration:line-through");
    if (attrs.code) styles.push(`font-family:${attrs.font === "hachiMaruPop" ? fonts.hachiMaruPop : "var(--vellix-code-font-family,ui-monospace),monospace"}`);
    if (["left", "center", "right", "justify"].includes(attrs.align)) styles.push(`text-align:${attrs.align}`);
    return styles.join(";");
  }
  const cellDefaults = { id: null, formula: null, calculated: null, fillColor: null, textColor: null,
    font: null, bold: null, italic: false, strike: false, code: false, align: "left",
    format: "text", decimals: 2, currency: "USD" };
  function createTable(rows, columns, header, width) {
    const names = new Set(tableRecords(control.editor.state.doc).map(record => record.node.attrs.name));
    let number = 1; while (names.has(`Table${number}`)) number++;
    rows = Math.max(0, Math.floor(rows)); columns = Math.max(0, Math.floor(columns));
    if (rows === 0 && columns === 0) { rows = 1; columns = 1; }
    const base = { id: freshID(), name: `Table${number}`, leftOffset: 0, stripeColor: null, headerRow: header, columnless: false, rowless: false, rowCount: rows, columnCount: columns };
    if (columns === 0) {
      return { type: "table", attrs: { ...base, columnless: true }, content: Array.from({ length: rows }, () => ({
        type: "tableRow", attrs: { id: freshID() }, content: [cellJSON(width)] })) };
    }
    if (rows === 0) {
      const cw = Math.max(56, Math.floor(width / columns));
      return { type: "table", attrs: { ...base, rowless: true }, content: [{ type: "tableRow", attrs: { id: freshID() },
        content: Array.from({ length: columns }, () => cellJSON(cw)) }] };
    }
    const cellWidth = Math.max(56, Math.floor(width / Math.max(1, columns)));
    return { type: "table", attrs: { ...base }, content: Array.from({ length: rows }, (_, row) => ({
      type: "tableRow", attrs: { id: freshID() }, content: Array.from({ length: columns }, () => ({
        type: header && row === 0 ? "tableHeader" : "tableCell", attrs: { id: freshID(), colwidth: [cellWidth] },
        content: [{ type: "paragraph", attrs: { id: freshID() } }]
      }))
    })) };
  }
  function setWidths(tr, record, widths, leftOffset) {
    const map = T.TableMap.get(record.node);
    for (const offset of new Set(map.map)) {
      const cell = record.node.nodeAt(offset), rect = map.findCell(offset);
      tr.setNodeMarkup(record.pos + 1 + offset, undefined, { ...cell.attrs, colwidth: widths.slice(rect.left, rect.right) });
    }
    if (leftOffset != null) tr.setNodeMarkup(record.pos, undefined, { ...record.node.attrs, leftOffset });
  }
  function editCell(tr, cell, value, formula = null) {
    const paragraph = control.editor.schema.nodes.paragraph.create({ id: freshID() }, value ? control.editor.schema.text(value) : null);
    tr.replaceWith(cell.pos + 1, cell.pos + cell.node.nodeSize - 1, paragraph);
    tr.setNodeMarkup(cell.pos, undefined, { ...cell.node.attrs, formula, calculated: null });
  }
  function preserveReferences(tr, before) {
    const after = tableRecords(tr.doc).find(record => record.node.attrs.id === before.id);
    if (!after) return;
    const next = grid(after), positions = new Map();
    next.cells.forEach((line, row) => line.forEach((cell, col) => { if (!positions.has(cell.id)) positions.set(cell.id, { row, col }); }));
    const mapping = (row, col) => {
      const old = before.cells[row]?.[col];
      if (!old) return { row, col };
      return positions.get(old.id) || null;
    };
    for (const record of tableRecords(tr.doc)) {
      record.node.descendants((cell, offset) => {
        if (cell.type.name === "table") return false;
        if (!cell.attrs.formula) return;
        const formula = F().rewriteReferences(cell.attrs.formula, record.node.attrs.name, before.name, mapping);
        if (formula !== cell.attrs.formula) tr.setNodeMarkup(record.pos + 1 + offset, undefined, { ...cell.attrs, formula });
      });
    }
  }
  function cellJSON(width) {
    return { type: "tableCell", attrs: { id: freshID(), colwidth: width ? [width] : null }, content: [{ type: "paragraph", attrs: { id: freshID() } }] };
  }
  function migrateLegacyTable(node) {
    const width = control.editor.view.dom.clientWidth || 320;
    const R = Math.max(0, Math.floor(Number(node.attrs.rowCount) || 0));
    const C = Math.max(0, Math.floor(Number(node.attrs.columnCount) || 0));
    const value = createTable(R, C, node.attrs.headerRow !== false, width);
    value.attrs = { ...value.attrs, id: node.attrs.id || value.attrs.id, name: node.attrs.name || value.attrs.name,
      leftOffset: node.attrs.leftOffset || 0, stripeColor: node.attrs.stripeColor || null };
    return control.editor.schema.nodeFromJSON(value);
  }
  function runTableCommand(cmd) {
    const editor = control.editor, ok = cmd(editor.state, editor.view.dispatch);
    if (ok) { control.bookmark = editor.state.selection.getBookmark(); publish(true); }
    return ok;
  }
  function setTableFlags(table, patch) {
    control.editor.view.dispatch(control.editor.state.tr.setNodeMarkup(table.pos, undefined, { ...table.node.attrs, ...patch }));
    publish(true); return true;
  }
  function deleteTableNode(table) {
    control.editor.view.dispatch(control.editor.state.tr.delete(table.pos, table.pos + table.node.nodeSize));
    publish(true); return true;
  }
  function collapseToRowless(table) {
    const editor = control.editor, node = table.node;
    const newTable = node.type.create({ ...node.attrs, rowless: true, columnless: false }, node.firstChild);
    const tr = editor.state.tr.replaceWith(table.pos, table.pos + node.nodeSize, newTable);
    tr.setSelection(api.TextSelection.near(tr.doc.resolve(table.pos + 3)));
    editor.view.dispatch(tr); publish(true); return true;
  }
  function collapseToColumnless(table) {
    const editor = control.editor, node = table.node, width = editor.view.dom.clientWidth || 320, rows = [];
    node.forEach(row => {
      const first = row.firstChild;
      rows.push(row.type.create(row.attrs, first.type.create({ ...first.attrs, colwidth: [width] }, first.content)));
    });
    const newTable = node.type.create({ ...node.attrs, columnless: true, rowless: false }, rows);
    const tr = editor.state.tr.replaceWith(table.pos, table.pos + node.nodeSize, newTable);
    tr.setSelection(api.TextSelection.near(tr.doc.resolve(table.pos + 3)));
    editor.view.dispatch(tr); publish(true); return true;
  }
  function structuralOp(operation, table) {
    const map = table.map;
    if (operation === "insertRow") {
      if (table.rowless) return setTableFlags(table, { rowless: false });
      return runTableCommand(T.addRowAfter);
    }
    if (operation === "insertColumn") {
      if (table.columnless) return setTableFlags(table, { columnless: false });
      return runTableCommand(T.addColumnAfter);
    }
    if (operation === "deleteRows") {
      if (table.rowless) return false;
      const removing = Math.max(1, table.rect.bottom - table.rect.top);
      if (map.height - removing >= 1) return runTableCommand(T.deleteRow);
      if (table.columnless) return deleteTableNode(table);
      return collapseToRowless(table);
    }
    if (operation === "deleteColumns") {
      if (table.columnless) return false;
      const removing = Math.max(1, table.rect.right - table.rect.left);
      if (map.width - removing >= 1) return runTableCommand(T.deleteColumn);
      if (table.rowless) return deleteTableNode(table);
      return collapseToColumnless(table);
    }
    return false;
  }
  function command(operation, args = {}) {
    const editor = control.editor;
    if (operation === "close") {
      control.menu = false; control.insertion = null; publish(true); return true;
    }
    if (!editor.isEditable || api.selectionActive()) return false;
    if (operation === "requestInsert") {
      control.insertion = editor.state.selection.getBookmark();
      post("tableCreateRequest", {}); return true;
    }
    if (operation === "insert") {
      const rows = Math.max(0, Math.min(200, Math.floor(Number(args.rows ?? 3)))), columns = Math.max(0, Math.min(32, Math.floor(Number(args.columns ?? 2))));
      if (!Number.isFinite(rows) || !Number.isFinite(columns)) return false;
      if (control.insertion) editor.view.dispatch(editor.state.tr.setSelection(control.insertion.resolve(editor.state.doc)));
      control.insertion = null;
      const value = createTable(rows, columns, args.header !== false, editor.view.dom.clientWidth || 320);
      if (!editor.commands.insertContent(value)) return false;
      const inserted = tableRecords(editor.state.doc).find(record => record.node.attrs.id === value.attrs.id);
      if (inserted) editor.view.dispatch(editor.state.tr.setSelection(api.TextSelection.near(editor.state.doc.resolve(inserted.pos + 3))));
      editor.view.focus(); publish(true); return true;
    }
    restore();
    const live = editor.state.selection;
    if (live.node?.type.name === "table") {
      editor.view.dispatch(editor.state.tr.setSelection(api.TextSelection.near(editor.state.doc.resolve(live.from + 2))));
    }
    const table = current(); if (!table || (args.tableID && table.id !== args.tableID)) return false;
    if (operation === "insertRow" || operation === "insertColumn" || operation === "deleteRows" || operation === "deleteColumns") return structuralOp(operation, table);
    if (operation === "formulaPreview") {
      const workbook = F().createWorkbook(tableRecords(editor.state.doc).map(grid));
      const value = workbook.preview(table.id, table.rect.top, table.rect.left, String(args.value || ""));
      post("tableFormulaPreview", { result: F().display(value, selectedCells(table)[0].node.attrs) }); return true;
    }
    if (operation === "selectCells") {
      control.selecting = true; control.menu = false;
      editor.view.dispatch(editor.state.tr.setSelection(T.CellSelection.create(editor.state.doc, selectedCells(table)[0].pos)));
      editor.view.focus(); publish(true); return true;
    }
    const state = editor.state, selected = selectedCells(table), tr = state.tr;
    const operations = { insertRow: T.addRowAfter, insertColumn: T.addColumnAfter,
      deleteRows: T.deleteRow, deleteColumns: T.deleteColumn, deleteTable: T.deleteTable,
      merge: T.mergeCells, split: T.splitCell, headerRow: T.toggleHeaderRow, headerColumn: T.toggleHeaderColumn };
    if (["moveRowUp", "moveRowDown", "moveColumnLeft", "moveColumnRight"].includes(operation)) {
      const isRow = operation.startsWith("moveRow"), direction = /Up|Left/.test(operation) ? -1 : 1;
      const first = isRow ? table.rect.top : table.rect.left, last = isRow ? table.rect.bottom : table.rect.right;
      const limit = isRow ? table.map.height : table.map.width;
      if (first + direction < 0 || last + direction > limit) return false;
      let working = state;
      const indexes = Array.from({ length: last - first }, (_, index) => first + index);
      if (direction > 0) indexes.reverse();
      for (const index of indexes) {
        const move = (isRow ? T.moveTableRow : T.moveTableColumn)({ from: index, to: index + direction, select: false });
        if (!move(working, transaction => {
          for (const step of transaction.steps) tr.step(step);
          working = working.apply(transaction);
        })) return false;
      }
      preserveReferences(tr, table);
      const record = tableRecords(tr.doc).find(value => value.node.attrs.id === table.id), map = T.TableMap.get(record.node);
      const top = table.rect.top + (isRow ? direction : 0), bottom = table.rect.bottom + (isRow ? direction : 0);
      const left = table.rect.left + (isRow ? 0 : direction), right = table.rect.right + (isRow ? 0 : direction);
      tr.setSelection(T.CellSelection.create(tr.doc, record.pos + 1 + map.map[top * map.width + left],
        record.pos + 1 + map.map[(bottom - 1) * map.width + right - 1]));
      editor.view.dispatch(tr); control.bookmark = editor.state.selection.getBookmark(); publish(true); return true;
    }
    if (operation === "moveRowUp" || operation === "moveRowDown") {
      operations[operation] = T.moveTableRow({ from: table.rect.top, to: table.rect.top + (operation === "moveRowUp" ? -1 : 1) });
    }
    if (operation === "moveColumnLeft" || operation === "moveColumnRight") {
      operations[operation] = T.moveTableColumn({ from: table.rect.left, to: table.rect.left + (operation === "moveColumnLeft" ? -1 : 1) });
    }
    if (operations[operation]) {
      const dispatched = transaction => { preserveReferences(transaction, table); editor.view.dispatch(transaction); };
      const success = operations[operation](state, dispatched, editor.view);
      if (success) { control.bookmark = editor.state.selection.getBookmark(); publish(true); }
      return success;
    }
    if (operation === "setCellStyle" || operation === "clearStyle") {
      const permitted = Object.keys(cellDefaults).filter(key => !["id", "formula", "calculated"].includes(key));
      for (const cell of selected) {
        const attrs = { ...cell.node.attrs };
        for (const key of permitted) {
          if (operation === "clearStyle") attrs[key] = cellDefaults[key];
          else if (Object.prototype.hasOwnProperty.call(args, key)) attrs[key] = args[key];
        }
        if (args.font === "default") attrs.font = null;
        if (args.fillColor != null) attrs.fillColor = color(args.fillColor);
        if (args.textColor != null) attrs.textColor = color(args.textColor);
        tr.setNodeMarkup(cell.pos, undefined, attrs);
        for (const mark of ["bold", "italic", "strike", "code"]) {
          if (operation !== "clearStyle" && !Object.prototype.hasOwnProperty.call(args, mark)) continue;
          const type = editor.schema.marks[mark];
          if (type) {
            if (operation !== "clearStyle" && args[mark]) tr.addMark(cell.pos + 1, cell.pos + cell.node.nodeSize - 1, type.create());
            else tr.removeMark(cell.pos + 1, cell.pos + cell.node.nodeSize - 1, type);
          }
        }
        if (args.align) cell.node.descendants((child, offset) => {
          if (child.type.name === "paragraph" || child.type.name === "heading") {
            tr.setNodeMarkup(cell.pos + 1 + offset, undefined, { ...child.attrs, textAlign: args.align });
          }
        });
      }
    } else if (operation === "stripeColor") {
      tr.setNodeMarkup(table.pos, undefined, { ...table.node.attrs, stripeColor: color(args.value) });
    } else if (operation === "rename") {
      const name = String(args.value || "").trim();
      if (!name || tableRecords(state.doc).some(record => record.node.attrs.id !== table.id && record.node.attrs.name.toLowerCase() === name.toLowerCase())) return false;
      const old = table.name;
      tr.setNodeMarkup(table.pos, undefined, { ...table.node.attrs, name });
      for (const record of tableRecords(tr.doc)) record.node.descendants((cell, offset) => {
        if (cell.type.name === "table") return false;
        if (!cell.attrs.formula) return;
        const formula = F().renameReferences(cell.attrs.formula, record.node.attrs.name, old, name);
        if (formula !== cell.attrs.formula) tr.setNodeMarkup(record.pos + 1 + offset, undefined, { ...cell.attrs, formula });
      });
    } else if (operation === "content" || operation === "formula" || operation === "clearContents") {
      for (const cell of selected.sort((a, b) => b.pos - a.pos)) {
        const formula = operation === "formula" ? String(args.value || "").trim() : null;
        if (formula && !formula.startsWith("=")) return false;
        editCell(tr, cell, operation === "content" ? String(args.value || "") : "", formula || null);
      }
    } else if (operation === "resetWidth") {
      const widths = Array.from({ length: table.map.width }, () => Math.max(56, Math.floor((editor.view.dom.clientWidth || 320) / table.map.width)));
      setWidths(tr, table, widths, 0);
    } else if (operation === "sortAscending" || operation === "sortDescending") {
      if (!context().canSort) return false;
      const workbook = F().createWorkbook(tableRecords(state.doc).map(grid));
      const rows = table.node.content.content.slice(), header = rows[0].firstChild.type.spec.tableRole === "header_cell" ? 1 : 0;
      const sortable = rows.slice(header).map((node, index) => ({ node, index, value: workbook.value(table.id, index + header, table.rect.left) }));
      sortable.sort((a, b) => {
        const comparison = typeof a.value === "number" && typeof b.value === "number" ? a.value - b.value : String(a.value ?? "").localeCompare(String(b.value ?? ""), undefined, { numeric: true });
        return (operation === "sortDescending" ? -comparison : comparison) || a.index - b.index;
      });
      tr.replaceWith(table.pos, table.pos + table.node.nodeSize, table.node.type.create(table.node.attrs, rows.slice(0, header).concat(sortable.map(row => row.node))));
      preserveReferences(tr, table);
    } else if (operation === "copy" || operation === "cut") {
      const text = table.cells.slice(table.rect.top, table.rect.bottom).map(line => line.slice(table.rect.left, table.rect.right).map(cell => cell.formula || cell.value).join("\t")).join("\n");
      post("tableClipboard", { text, cut: operation === "cut" }); return true;
    } else return false;
    editor.view.dispatch(tr);
    control.bookmark = editor.state.selection.getBookmark(); publish(true); return true;
  }
  function createExtensions(environment) {
    control.editor = null; control.menu = false; control.selecting = false; control.bookmark = null; control.insertion = null;
    api = environment;
    T = global.VellixTableLibrary(api.modules);
    const { Node, Extension, Plugin, PluginKey, Decoration, DecorationSet, TextSelection } = api;
    const specs = T.tableNodes({ tableGroup: "block", cellContent: "block+" });
    const names = { table: "table", table_row: "tableRow", table_cell: "tableCell", table_header: "tableHeader" };
    class TableView extends T.TableView {
      constructor(node, view, getPos) {
        super(node, 56, view);
        this.view = view; this.getPos = getPos; this.handles = document.createElement("div");
        this.handles.className = "vellix-table-resizers"; this.dom.appendChild(this.handles);
        this.dom.classList.add("vellix-table-wrapper"); this.refresh(node);
      }
      update(node) { if (!super.update(node)) return false; this.refresh(node); return true; }
      refresh(node) {
        if (this.dom.dataset.tableId !== node.attrs.id) this.dom.dataset.tableId = node.attrs.id || "";
        this.dom.classList.toggle("vellix-columnless", !!node.attrs.columnless);
        this.dom.classList.toggle("vellix-rowless", !!node.attrs.rowless);
        this.table.style.marginLeft = `${Math.max(0, Number(node.attrs.leftOffset) || 0)}px`;
        this.table.style.setProperty("--vellix-table-stripe", color(node.attrs.stripeColor) || "transparent");
        if (control.drag) return;
        this.handles.replaceChildren();
        if (node.attrs.columnless) return;
        const map = T.TableMap.get(node), attrWidths = [];
        for (let col = 0; col < map.width; col++) {
          const cell = node.nodeAt(map.map[col]), rect = map.findCell(map.map[col]);
          attrWidths.push(cell.attrs.colwidth?.[col - rect.left] || 100);
        }
        this._count = map.width; this._attrWidths = attrWidths;
        const handles = [];
        for (let boundary = 0; boundary <= map.width; boundary++) {
          const handle = document.createElement("span"); handle.className = "vellix-table-resize-line";
          handle.setAttribute("aria-label", boundary === 0 ? "Resize left edge" : boundary === map.width ? "Resize right edge" : `Resize column ${boundary}`);
          handle.addEventListener("pointerdown", event => this.startResize(event, boundary));
          // Stop iOS from turning the grab into a caret placement / edit-mode tap.
          handle.addEventListener("touchstart", event => event.preventDefault(), { passive: false });
          this.handles.appendChild(handle); handles.push(handle);
        }
        this.positionHandles(handles, attrWidths, Number(node.attrs.leftOffset) || 0);
      }
      // Pin each grab line to where the column border actually renders, not to stored
      // widths (which may be stale/null and leave the line sitting over cell text).
      positionHandles(handles, attrWidths, leftOffset) {
        const place = () => {
          const row = this.contentDOM && this.contentDOM.querySelector("tr");
          const cells = row ? Array.from(row.children) : [];
          if (cells.length === handles.length - 1 && cells.length) {
            const origin = this.handles.getBoundingClientRect().left;
            handles.forEach((handle, boundary) => {
              const ref = boundary < cells.length ? cells[boundary] : cells[cells.length - 1];
              const box = ref.getBoundingClientRect();
              handle.style.left = `${(boundary < cells.length ? box.left : box.right) - origin}px`;
            });
          } else {
            let x = leftOffset;
            handles.forEach((handle, boundary) => { handle.style.left = `${x}px`; if (boundary < attrWidths.length) x += attrWidths[boundary]; });
          }
        };
        requestAnimationFrame(place);
      }
      startResize(event, boundary) {
        if (!control.editor.isEditable || api.selectionActive()) return;
        event.preventDefault(); event.stopPropagation();
        const row = this.contentDOM && this.contentDOM.querySelector("tr");
        const cells = row ? Array.from(row.children) : [];
        const original = cells.length === this._count && cells.length
          ? cells.map(cell => cell.getBoundingClientRect().width)
          : this._attrWidths.slice();
        if (!original.length) return;
        const handle = event.currentTarget, start = event.clientX, left = Number(this.node.attrs.leftOffset) || 0;
        let widths = original.slice(), offset = left;
        control.drag = this; this.dom.classList.add("vellix-table-active"); handle.setPointerCapture(event.pointerId);
        const move = next => {
          ({ widths, offset } = resizeWidths(original, boundary, next.clientX - start, left));
          Array.from(this.colgroup.children).forEach((column, index) => column.style.width = `${widths[index]}px`);
          this.table.style.width = `${widths.reduce((a, b) => a + b, 0)}px`; this.table.style.marginLeft = `${offset}px`;
        };
        const finish = next => {
          handle.removeEventListener("pointermove", move); handle.removeEventListener("pointerup", finish); handle.removeEventListener("pointercancel", cancel);
          if (handle.hasPointerCapture(next.pointerId)) handle.releasePointerCapture(next.pointerId);
          control.drag = null;
          const pos = this.getPos(), node = this.view.state.doc.nodeAt(pos);
          if (node?.type.name === "table") { const tr = this.view.state.tr; setWidths(tr, { node, pos }, widths.map(w => Math.round(w)), offset); this.view.dispatch(tr); }
          publish(true);
        };
        const cancel = next => { widths = original.slice(); offset = left; finish(next); };
        handle.addEventListener("pointermove", move); handle.addEventListener("pointerup", finish); handle.addEventListener("pointercancel", cancel);
      }
      ignoreMutation(mutation) {
        if (mutation.type === "selection") return false;
        return !this.contentDOM.contains(mutation.target);
      }
      stopEvent(event) { return this.handles.contains(event.target); }
      destroy() { if (control.drag === this) control.drag = null; }
    }
    const nodes = Object.entries(names).map(([source, name]) => {
      const spec = specs[source], isCell = source === "table_cell" || source === "table_header";
      return Node.create({ name, group: spec.group, content: source === "table" ? "tableRow*" : source === "table_row" ? "(tableCell | tableHeader)+" : "block+",
        tableRole: spec.tableRole, isolating: source !== "table_row", selectable: source === "table",
        addAttributes() {
          const values = source === "table" ? { id: null, name: "Table", leftOffset: 0, stripeColor: null, columnless: false, rowless: false, rowCount: 0, columnCount: 0, headerRow: true }
            : source === "table_row" ? { id: null } : { ...Object.fromEntries(Object.entries(spec.attrs).map(([key, value]) => [key, value.default])), ...cellDefaults };
          return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, { default: value, rendered: false,
            parseHTML(element) {
              if (key === "colspan" || key === "rowspan") return Math.max(1, Math.min(200, Number(element.getAttribute(key)) || 1));
              if (key === "colwidth") { const widths = element.getAttribute("data-colwidth"); return widths ? widths.split(",").map(Number).map(width => Math.max(56, Math.min(3000, width || 56))) : null; }
              const stored = element.getAttribute(`data-vellix-${key}`); if (stored == null) return value;
              try { return JSON.parse(stored); } catch (_) { return value; }
            }
          }]));
        },
        parseHTML() { return [{ tag: source === "table" ? "table" : source === "table_row" ? "tr" : source === "table_header" ? "th" : "td" }]; },
        renderHTML({ node }) {
          const attrs = {};
          for (const [key, value] of Object.entries(node.attrs)) if (value != null) attrs[`data-vellix-${key}`] = JSON.stringify(value);
          if (isCell) { attrs.colspan = node.attrs.colspan; attrs.rowspan = node.attrs.rowspan; if (node.attrs.colwidth) attrs["data-colwidth"] = node.attrs.colwidth.join(","); attrs.style = cellStyles(node.attrs); }
          if (source === "table") return ["table", { ...attrs, class: "vellix-table" }, ["tbody", 0]];
          return [source === "table_row" ? "tr" : source === "table_header" ? "th" : "td", attrs, 0];
        },
        addNodeView: source === "table" ? () => ({ node, editor, getPos }) => new TableView(node, editor.view, getPos) : undefined,
      });
    });
    const key = new PluginKey("vellixTables");
    const extension = Extension.create({ name: "vellixTableControls",
      extendNodeSchema(extension) { return { tableRole: extension.config.tableRole }; },
      addKeyboardShortcuts() {
        const commit = () => {
          const table = current(); if (!table) return false;
          const cell = selectedCells(table)[0], value = permanentText(cell.node);
          if (!cell.node.attrs.formula && cell.node.childCount === 1 && value.startsWith("=")) return command("formula", { value });
          return false;
        };
        return {
          Enter: commit,
          Tab: () => { commit(); return T.goToNextCell(1)(this.editor.state, this.editor.view.dispatch); },
          "Shift-Tab": () => { commit(); return T.goToNextCell(-1)(this.editor.state, this.editor.view.dispatch); },
        };
      },
      addProseMirrorPlugins() {
        return [new Plugin({ key,
          state: { init: () => 0, apply(tr, value) {
            if (control.bookmark) control.bookmark = control.bookmark.map(tr.mapping);
            if (control.insertion) control.insertion = control.insertion.map(tr.mapping);
            return tr.docChanged || tr.selectionSet ? value + 1 : value;
          } },
          appendTransaction(transactions, old, state) {
            if (transactions.some(tr => tr.docChanged)) {
              const legacy = state.tr; let migrated = false;
              state.doc.descendants((node, pos) => {
                if (node.type.name === "table" && node.childCount === 0) {
                  legacy.replaceWith(legacy.mapping.map(pos), legacy.mapping.map(pos + node.nodeSize), migrateLegacyTable(node));
                  migrated = true;
                }
              });
              if (migrated) return legacy.setMeta(key, true).setMeta("addToHistory", false);
            }
            if (!transactions.some(tr => tr.docChanged && !tr.getMeta(key))) return null;
            const tr = state.tr, seen = new Set();
            for (const record of tableRecords(state.doc)) {
              const id = record.node.attrs.id;
              if (!id || seen.has(id)) tr.setNodeMarkup(record.pos, undefined, { ...record.node.attrs, id: freshID() });
              else seen.add(id);
              record.node.descendants((node, offset) => {
                if (node.type.name === "table") return false;
                if (node.attrs.formula && permanentText(node)) {
                  tr.setNodeMarkup(record.pos + 1 + offset, undefined, { ...node.attrs, formula: null, calculated: null });
                }
              });
            }
            const tables = tableRecords(tr.doc).map(grid);
            const workbook = F().createWorkbook(tables);
            for (const table of tables) {
              table.node.descendants((node, offset) => {
                if (node.type.name === "table") return false;
                if (!["tableRow", "tableCell", "tableHeader"].includes(node.type.name)) return;
                let attrs = { ...node.attrs }, changed = false;
                if (!attrs.id || seen.has(attrs.id)) { attrs.id = freshID(); changed = true; } seen.add(attrs.id);
                if (node.type.spec.tableRole === "cell" || node.type.spec.tableRole === "header_cell") {
                  const rect = table.map.findCell(offset), value = workbook.value(table.id, rect.top, rect.left);
                  const calculated = attrs.formula || attrs.format !== "text" ? F().display(value, attrs) : null;
                  if (attrs.calculated !== calculated) { attrs.calculated = calculated; changed = true; }
                }
                if (changed) tr.setNodeMarkup(table.pos + 1 + offset, undefined, attrs);
              });
            }
            return tr.steps.length ? tr.setMeta(key, true).setMeta("addToHistory", false) : null;
          },
          props: {
            decorations(state) {
              const decorations = [], active = current(state);
              for (const table of tableRecords(state.doc).map(grid)) {
                table.node.descendants((cell, offset) => {
                  if (cell.type.name === "table") return false;
                  if (!["cell", "header_cell"].includes(cell.type.spec.tableRole)) return;
                  const pos = table.pos + 1 + offset, selected = active?.id === table.id && selectedCells(active).some(value => value.pos === pos);
                  const editing = selected && control.editor?.isFocused && !cell.attrs.formula && !control.menu;
                  if (selected) decorations.push(Decoration.node(pos, pos + cell.nodeSize, { class: "vellix-table-selected-cell" }));
                  if (cell.attrs.calculated != null && !editing) {
                    decorations.push(Decoration.node(pos, pos + cell.nodeSize, { class: "vellix-table-computed-cell" }));
                    decorations.push(Decoration.widget(pos + 1, () => {
                      const result = document.createElement("span"); result.className = "vellix-table-result"; result.contentEditable = "false";
                      result.textContent = cell.attrs.calculated; return result;
                    }, { key: `value:${cell.attrs.id}:${cell.attrs.calculated}`, side: -1 }));
                  }
                  if (selected && control.editor?.isEditable && (control.editor.isFocused || control.menu || control.selecting)) {
                    decorations.push(Decoration.widget(pos + 1, menuButton, { key: `menu:${cell.attrs.id}`, side: -1,
                      stopEvent: event => !!event.target.closest?.(".vellix-table-cell-menu") }));
                  }
                });
              }
              return DecorationSet.create(state.doc, decorations);
            },
            handleDOMEvents: {
              focus() { requestAnimationFrame(() => { control.editor?.view.dispatch(control.editor.state.tr.setMeta(key, true)); publish(); }); return false; },
              blur() { requestAnimationFrame(() => { control.editor?.view.dispatch(control.editor.state.tr.setMeta(key, true)); publish(); }); return false; },
              pointerdown(view, event) {
                if (!control.selecting) return false;
                const cell = event.target.closest?.("td,th"); if (!cell) { control.selecting = false; return false; }
                const pos = view.posAtDOM(cell, 0) - 1;
                try {
                  view.dispatch(view.state.tr.setSelection(new T.CellSelection(view.state.selection.$anchorCell || view.state.doc.resolve(pos), view.state.doc.resolve(pos))));
                  control.cellPointer = event.pointerId; view.dom.setPointerCapture?.(event.pointerId);
                  event.preventDefault(); return true;
                }
                catch (_) { return false; }
              },
              pointermove(view, event) {
                if (!control.selecting || control.cellPointer !== event.pointerId) return false;
                const cell = document.elementFromPoint(event.clientX, event.clientY)?.closest?.("td,th");
                if (!cell || !view.dom.contains(cell)) return false;
                try {
                  const pos = view.posAtDOM(cell, 0) - 1;
                  view.dispatch(view.state.tr.setSelection(new T.CellSelection(view.state.selection.$anchorCell, view.state.doc.resolve(pos))));
                  event.preventDefault(); return true;
                } catch (_) { return false; }
              },
              pointerup(view, event) {
                if (control.cellPointer !== event.pointerId) return false;
                control.cellPointer = null;
                if (view.dom.hasPointerCapture?.(event.pointerId)) view.dom.releasePointerCapture(event.pointerId);
                return true;
              },
            },
          },
          view() { return { update() { publish(); } }; },
        }), T.tableEditing({ allowTableNodeSelection: true })];
      },
    });
    return [...nodes, extension];
  }
  function initialize(editor) {
    control.editor = editor;
    if (!control.diagBound) {
      control.diagBound = true;
      ["pointerdown", "touchstart", "pointerup", "touchend", "click"].forEach(type => {
        document.addEventListener(type, (e) => {
          const t = e.target;
          const onButton = !!(t && t.closest && t.closest(".vellix-table-cell-menu"));
          const onTable = !!(t && t.closest && t.closest(".vellix-table-wrapper"));
          if (onButton || onTable) tdiag("doc", { type, onButton, onTable, target: ((t && (t.className || t.tagName)) || "") + "", defaultPrevented: e.defaultPrevented });
        }, true);
      });
    }
    let savedTables = tableRecords(editor.state.doc).map(record => record.node);
    editor.on?.("update", () => {
      const tables = tableRecords(editor.state.doc).map(record => record.node);
      if (tables.length !== savedTables.length || tables.some((table, index) => table !== savedTables[index])) {
        savedTables = tables;
        post("tableSnapshot", { document: editor.getJSON() });
      }
    });
    const previous = global.tiptapCommand;
    global.tiptapCommand = async function (name, args = {}) {
      if (name === "tableAction") {
        const result = command(args.action, args);
        if (!result) post("error", { message: "This operation cannot be applied to the current table selection." });
        return result;
      }
      if (name === "insertBlock" && args.blockType === "table") return command("requestInsert");
      return previous(name, args);
    };
    publish(true);
  }
  global.VellixTables = { createExtensions, initialize, command, context, grid, cellStyles, createTable, resizeWidths, setWidths };
})(globalThis);
