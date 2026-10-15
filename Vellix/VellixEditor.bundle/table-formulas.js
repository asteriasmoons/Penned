(function (global) {
  "use strict";
  function columnName(index) {
    let value = index + 1, name = "";
    while (value > 0) { value--; name = String.fromCharCode(65 + value % 26) + name; value = Math.floor(value / 26); }
    return name;
  }
  function columnIndex(name) {
    return [...name.toUpperCase()].reduce((value, letter) => value * 26 + letter.charCodeAt(0) - 64, 0) - 1;
  }
  function scalar(value, format) {
    if (typeof value !== "string") return value ?? null;
    const text = value.trim();
    if (!text) return null;
    if (/^(TRUE|FALSE)$/i.test(text)) return text.toUpperCase() === "TRUE";
    if (/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?%?$/.test(text)) {
      return Number(text.replace(/%$/, "")) / (text.endsWith("%") ? 100 : 1);
    }
    if (format === "date" && /^\d{4}-\d{2}-\d{2}$/.test(text)) {
      const time = Date.parse(text + "T00:00:00Z");
      if (Number.isFinite(time)) return time / 86400000 + 25569;
    }
    return value;
  }
  function createWorkbook(tables, Parser = global.FormulaParser) {
    if (!Parser) throw new Error("The formula engine is unavailable.");
    const byName = new Map(), byID = new Map(), cache = new Map(), active = new Set(), parsers = [];
    let evaluations = 0;
    for (const table of tables) {
      byID.set(table.id, table);
      const name = table.name.toLowerCase();
      byName.set(name, byName.has(name) ? null : table);
    }
    const ErrorType = Parser.FormulaError;
    function referenceTable(ref, owner) {
      if (!ref.sheet || ref.sheet.toLowerCase() === owner.name.toLowerCase()) return owner;
      const table = byName.get(ref.sheet.toLowerCase());
      if (!table) throw ErrorType.REF;
      return table;
    }
    function value(table, row, col) {
      if (++evaluations > 50000 || active.size > 128) throw ErrorType.NUM;
      if (row < 0 || col < 0) throw ErrorType.REF;
      const cell = table.cells[row]?.[col];
      if (!cell) return null;
      const key = `${table.id}:${row}:${col}`;
      if (cache.has(key)) return cache.get(key);
      if (active.has(key)) return new ErrorType("#CYCLE!");
      if (!cell.formula) return scalar(cell.value, cell.format);
      if (cell.formula.length > 2048) throw ErrorType.NUM;
      active.add(key);
      try {
        // Reuse one parser per dependency depth; recursive formulas never mutate a parent's parser.
        const depth = active.size - 1;
        let parser = parsers[depth];
        if (!parser) parser = parsers[depth] = new Parser({
          onCell(ref) { return value(referenceTable(ref, parser.owner), ref.row - 1, ref.col - 1); },
          onRange(ref) {
            const target = referenceTable(ref, parser.owner);
            const lastRow = Math.min(ref.to.row, target.cells.length);
            const lastCol = Math.min(ref.to.col, target.cells[0]?.length || 0);
            if ((lastRow - ref.from.row + 1) * (lastCol - ref.from.col + 1) > 20000) throw ErrorType.NUM;
            const result = [];
            for (let r = ref.from.row - 1; r < lastRow; r++) {
              const line = [];
              for (let c = ref.from.col - 1; c < lastCol; c++) line.push(value(target, r, c));
              result.push(line);
            }
            return result.length ? result : [[null]];
          },
          functionsNeedContext: { WEBSERVICE() { throw ErrorType.NAME; } },
        });
        parser.owner = table;
        const result = parser.parse(cell.formula.replace(/^=/, ""), { row: row + 1, col: col + 1, sheet: table.name }, true);
        cache.set(key, result);
        return result;
      } catch (error) {
        while (error?.details instanceof ErrorType) error = error.details;
        const result = error instanceof ErrorType ? error : new ErrorType("#ERROR!", error.message);
        cache.set(key, result);
        return result;
      } finally { active.delete(key); }
    }
    return {
      value(tableID, row, col) {
        evaluations = 0;
        try { return value(byID.get(tableID), row, col); }
        catch (error) { return error; }
      },
      preview(tableID, row, col, formula) {
        const table = byID.get(tableID);
        const cells = table.cells.map(line => line.map(cell => ({ ...cell })));
        cells[row][col] = { ...cells[row][col], formula };
        return createWorkbook(tables.map(item => item.id === tableID ? { ...item, cells } : item), Parser).value(tableID, row, col);
      },
    };
  }
  function display(value, attrs = {}, Parser = global.FormulaParser) {
    if (value instanceof Error) return value.error || "#ERROR!";
    if (Array.isArray(value)) return value.map(line => Array.isArray(line) ? line.join(", ") : line).join("; ");
    if (value == null) return "";
    if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
    if (typeof value !== "number") return String(value);
    if (!Number.isFinite(value)) return "#NUM!";
    const digits = Math.max(0, Math.min(10, Number(attrs.decimals ?? 2)));
    if (attrs.format === "date") {
      try { return Parser.SSF.format("yyyy-mm-dd", value); } catch (_) { return "#VALUE!"; }
    }
    const options = { maximumFractionDigits: attrs.format === "text" ? 10 : digits };
    if (attrs.format === "percent") options.style = "percent";
    if (attrs.format === "currency") { options.style = "currency"; options.currency = attrs.currency || "USD"; }
    try { return new Intl.NumberFormat(undefined, options).format(value); }
    catch (_) { return String(value); }
  }
  function rewriteReferences(formula, owner, target, map, Parser = global.FormulaParser) {
    const source = formula.replace(/^=/, "");
    const parser = new Parser.DepParser();
    try { parser.parse(source, { row: 1, col: 1, sheet: owner }, true); } catch (_) { return formula; }
    const tokens = parser.parser.input, replacements = [];
    let sheet = owner;
    for (let index = 0; index < tokens.length; index++) {
      const token = tokens[index], type = token.tokenType.name;
      if (type === "Sheet" || type === "SheetQuoted") {
        sheet = token.image.replace(/!$/, "").replace(/^'|'$/g, "").replace(/''/g, "'");
        continue;
      }
      if (type === "Cell" && sheet.toLowerCase() === target.toLowerCase()) {
        const match = /^(\$?)([A-Za-z]+)(\$?)(\d+)$/.exec(token.image);
        if (match) {
          const moved = map(Number(match[4]) - 1, columnIndex(match[2]));
          const text = moved ? `${match[1]}${columnName(moved.col)}${match[3]}${moved.row + 1}` : "#REF!";
          replacements.push({ from: token.startOffset, to: token.endOffset + 1, text });
        }
      }
      // A range inherits the preceding explicit sheet; subsequent expressions do not.
      if (type !== "Cell" && type !== "Column" && type !== "Number" && type !== "Colon") sheet = owner;
      else if (tokens[index + 1]?.tokenType.name !== "Colon" && tokens[index - 1]?.tokenType.name !== "Colon") sheet = owner;
    }
    let result = source;
    for (const replacement of replacements.reverse()) result = result.slice(0, replacement.from) + replacement.text + result.slice(replacement.to);
    return "=" + result;
  }
  function renameReferences(formula, owner, oldName, newName, Parser = global.FormulaParser) {
    const source = formula.replace(/^=/, ""), parser = new Parser.DepParser();
    try { parser.parse(source, { row: 1, col: 1, sheet: owner }, true); } catch (_) { return formula; }
    const tokens = parser.parser.input.filter(token => ["Sheet", "SheetQuoted"].includes(token.tokenType.name));
    let result = source;
    for (const token of tokens.reverse()) {
      const name = token.image.replace(/!$/, "").replace(/^'|'$/g, "").replace(/''/g, "'");
      if (name.toLowerCase() !== oldName.toLowerCase()) continue;
      result = result.slice(0, token.startOffset) + `'${newName.replace(/'/g, "''")}'!` + result.slice(token.endOffset + 1);
    }
    return "=" + result;
  }
  global.VellixTableFormulas = { createWorkbook, display, scalar, columnName, columnIndex, rewriteReferences, renameReferences };
})(globalThis);
