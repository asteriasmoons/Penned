(function (global) {
  const defaults = {
    width: "full", backgroundColor: "#151518", borderColor: "#65606d", borderWidth: 2, cornerRadius: 8,
    displayBackground: "#09090c", displayBorder: "#45454e", displayBorderWidth: 1, displayRadius: 6,
    calculationColor: "#bcbcc8", resultColor: "#ffffff", displayFont: "rounded", displayWeight: 700, displaySize: 34, calculationSize: 13,
    buttonFont: "rounded", buttonWeight: 600, buttonSize: 21,
    numberBackground: "#303039", numberBorder: "#4a4a55", numberText: "#ffffff", numberBorderWidth: 1, numberRadius: 6,
    operatorBackground: "#245769", operatorBorder: "#468294", operatorText: "#ffffff", operatorBorderWidth: 1, operatorRadius: 6,
    functionBackground: "#41404b", functionBorder: "#62616f", functionText: "#ffffff", functionBorderWidth: 1, functionRadius: 6,
    equalsBackground: "#b285e0", equalsBorder: "#d4b2f7", equalsText: "#130c1b", equalsBorderWidth: 1, equalsRadius: 6,
    copyBackground: "#202027", copyBorder: "#45454e", copyText: "#d8c4ee",
    soundEnabled: false, sound: "soft", volume: 0.4, hapticsEnabled: false,
  };
  const numeric = /^-?\d+(?:\.\d*)?(?:e[+-]?\d+)?$/i;
  const operators = ["+", "-", "*", "/"];
  const labels = { "*": "\u00d7", "/": "\u00f7", "-": "\u2212", sign: "\u00b1", back: "\u232b", clear: "AC" };
  const keys = [["clear", "sign", "%", "/"], ["7", "8", "9", "*"], ["4", "5", "6", "-"], ["1", "2", "3", "+"], ["back", "0", ".", "="]];
  const role = key => key === "=" ? "equals" : operators.includes(key) ? "operator" : /^\d$|^\.$/.test(key) ? "number" : "function";
  const validNumber = value => typeof value === "string" && value.length <= 80 && numeric.test(value) && Number.isFinite(Number(value));
  const initialState = () => ({ entry: "0", accumulator: null, operation: null, waiting: false, evaluated: false,
    calculation: "", result: "0", error: "", repeatOperation: null, repeatOperand: null });
  function state(raw) {
    const value = raw && typeof raw === "object" ? raw : {}, result = initialState();
    for (const key of ["entry", "result"]) if (validNumber(value[key])) result[key] = value[key];
    for (const key of ["accumulator", "repeatOperand"]) if (validNumber(value[key])) result[key] = value[key];
    for (const key of ["operation", "repeatOperation"]) if (operators.includes(value[key])) result[key] = value[key];
    for (const key of ["waiting", "evaluated"]) result[key] = value[key] === true;
    if (typeof value.calculation === "string") result.calculation = value.calculation.slice(0, 240);
    if (["division-zero", "overflow", "unavailable", "invalid"].includes(value.error)) result.error = value.error;
    return result;
  }
  const ranges = { borderWidth: [0, 8], cornerRadius: [0, 48], displayBorderWidth: [0, 8], displayRadius: [0, 32],
    displayWeight: [100, 900], buttonWeight: [100, 900], displaySize: [12, 72], calculationSize: [8, 30], buttonSize: [10, 40], volume: [0, 1] };
  function setting(key, value) {
    const fallback = defaults[key];
    if (typeof fallback === "boolean") return typeof value === "boolean" ? value : fallback;
    if (typeof fallback === "number") {
      const limits = ranges[key] || (key.endsWith("Radius") ? [0, 32] : [0, 8]);
      return Number.isFinite(value) ? Math.min(limits[1], Math.max(limits[0], key === "volume" ? value : Math.round(value))) : fallback;
    }
    if (key === "width") return ["half", "full"].includes(value) ? value : fallback;
    if (key.endsWith("Font")) return ["system", "serif", "mono", "rounded", "hachiMaruPop"].includes(value) ? value : fallback;
    if (key === "sound") return ["soft", "pop", "tick", "chime"].includes(value) ? value : fallback;
    return typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
  }
  const settings = attrs => Object.fromEntries(Object.keys(defaults).map(key => [key, setting(key, attrs?.[key])]));
  let parser = null;
  function evaluate(left, operation, right) {
    if (!validNumber(left) || !validNumber(right) || !operators.includes(operation)) throw "invalid";
    if (operation === "/" && Number(right) === 0) throw "division-zero";
    if (!global.FormulaParser) throw "unavailable";
    parser ||= new global.FormulaParser({});
    const result = parser.parse(`(${left})${operation}(${right})`, { row: 1, col: 1, sheet: "Calculator" });
    if (typeof result !== "number") throw "invalid";
    if (!Number.isFinite(result)) throw "overflow";
    return String(Number(result.toPrecision(15)));
  }
  function press(raw, key) {
    let next = state(raw);
    if (key === "clear") return initialState();
    if (!keys.flat().includes(key)) return next;
    try {
      const digit = /^\d$/.test(key);
      if (digit || key === ".") {
        if (next.error || next.evaluated) next = initialState();
        if (next.waiting) { next.entry = "0"; next.waiting = false; }
        if (key === ".") { if (!next.entry.includes(".") && !/e/i.test(next.entry)) next.entry += "."; }
        else if (next.entry.replace(/[-.]/g, "").length < 15) {
          next.entry = next.entry === "0" ? key : next.entry === "-0" ? "-" + key : next.entry + key;
        }
        next.result = next.entry;
        next.calculation = next.operation ? `${next.accumulator} ${labels[next.operation] || next.operation} ${next.entry}` : next.entry;
      } else if (key === "back") {
        if (next.error) return initialState();
        if (next.waiting) { next.operation = null; next.accumulator = null; next.waiting = false; }
        next.evaluated = false; next.repeatOperation = null; next.repeatOperand = null;
        const shorter = next.entry.slice(0, -1);
        next.entry = validNumber(shorter) ? shorter : "0"; next.result = next.entry;
        next.calculation = next.operation ? `${next.accumulator} ${labels[next.operation] || next.operation} ${next.entry}` : next.entry;
      } else if (key === "sign" || key === "%") {
        if (next.error) return next;
        const original = next.entry;
        if (key === "sign") next.entry = next.entry.startsWith("-") ? next.entry.slice(1) : "-" + next.entry;
        else {
          next.entry = evaluate(next.entry, "/", "100");
          if (["+", "-"].includes(next.operation) && next.accumulator !== null) next.entry = evaluate(next.accumulator, "*", next.entry);
        }
        next.waiting = false; next.evaluated = false; next.repeatOperation = null; next.repeatOperand = null;
        next.result = next.entry;
        next.calculation = key === "%" ? [next.operation ? `${next.accumulator} ${labels[next.operation] || next.operation}` : "", `${original}%`].filter(Boolean).join(" ")
          : next.operation ? `${next.accumulator} ${labels[next.operation] || next.operation} ${next.entry}` : next.entry;
      } else if (operators.includes(key)) {
        if (next.error) return next;
        if (next.operation && next.accumulator !== null && !next.waiting) next.entry = evaluate(next.accumulator, next.operation, next.entry);
        next.accumulator = next.entry; next.operation = key; next.waiting = true; next.evaluated = false;
        next.result = next.entry; next.calculation = `${next.entry} ${labels[key] || key}`;
      } else if (key === "=") {
        if (next.error) return next;
        const op = next.operation || (next.evaluated ? next.repeatOperation : null);
        const left = next.operation ? next.accumulator : next.entry;
        const right = next.operation ? next.entry : next.repeatOperand;
        if (op && left !== null && right !== null) {
          next.entry = evaluate(left, op, right); next.result = next.entry;
          next.calculation = `${left} ${labels[op] || op} ${right} =`;
          next.repeatOperation = op; next.repeatOperand = right;
        }
        next.operation = null; next.accumulator = null; next.waiting = false; next.evaluated = true;
      }
    } catch (error) { next.error = ["division-zero", "overflow", "unavailable"].includes(error) ? error : "invalid"; }
    return next;
  }
  const resultText = value => value.error ? ({ "division-zero": "Cannot divide by zero", overflow: "Number too large", unavailable: "Calculator unavailable", invalid: "Calculation error" })[value.error] : value.result;
  function parts(attrs, raw, fonts) {
    const value = state(raw), display = `font-family:${fonts[attrs.displayFont]};font-weight:${attrs.displayWeight};`;
    const copyIcon = `vellix-icon://asset/copy?tint=${encodeURIComponent(attrs.copyText)}&size=32`;
    return [["div", { class: "penned-calculator-display", style: `background:${attrs.displayBackground};border:${attrs.displayBorderWidth}px solid ${attrs.displayBorder};border-radius:${attrs.displayRadius}px;${display}` },
      ["div", { class: "penned-calculator-expression", style: `color:${attrs.calculationColor};--calc-expression-size:${attrs.calculationSize}px` }, value.calculation || "\u00a0"],
      ["div", { class: "penned-calculator-answer" }, ["span", { class: "penned-calculator-result", style: `color:${attrs.resultColor};--calc-result-size:${attrs.displaySize}px`, role: "status", "aria-live": "polite" }, resultText(value)],
        ["button", { type: "button", "data-calc-key": "copy", "aria-label": "Copy result", style: `background:${attrs.copyBackground};border:1px solid ${attrs.copyBorder};color:${attrs.copyText}` },
          ["img", { src: copyIcon, alt: "", draggable: "false" }]]]],
      ["div", { class: "penned-calculator-keys" }, ...keys.flat().map(key => {
        const group = role(key);
        return ["button", { type: "button", "data-calc-key": key, "aria-label": ({ clear: "Clear", sign: "Change sign", back: "Backspace", "%": "Percent", "=": "Equals", "*": "Multiply", "/": "Divide", "-": "Subtract", "+": "Add" })[key] || key,
          style: `background:${attrs[group + "Background"]};border:${attrs[group + "BorderWidth"]}px solid ${attrs[group + "Border"]};color:${attrs[group + "Text"]};border-radius:${attrs[group + "Radius"]}px;font-family:${fonts[attrs.buttonFont]};font-weight:${attrs.buttonWeight};font-size:${attrs.buttonSize}px`,
        }, ["span", { style: `--calc-button-size:${attrs.buttonSize}px` }, labels[key] || key]];
      })]];
  }
  function append(parent, spec) {
    if (typeof spec === "string") { parent.append(document.createTextNode(spec)); return; }
    const [tag, attrs, ...children] = spec, element = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, value);
    children.forEach(child => append(element, child)); parent.append(element);
  }
  function createExtension({ Node, mergeAttributes, post, closeHistory, fonts }) {
    const families = { ...fonts, hachiMaruPop: '"HachiMaruPop", cursive' };
    const style = document.createElement("style");
    style.textContent = `
      .penned-calculator { border-style:solid; }
      .penned-calculator-display { box-sizing:border-box; flex:none; height:40px; width:100%; min-width:0; padding:2px 4px; display:flex; flex-direction:column; justify-content:center; gap:1px; }
      .penned-calculator-expression { min-height:0; flex:1; line-height:1.1; text-align:right; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-size:min(11px,var(--calc-expression-size)) !important; }
      .penned-calculator-answer { display:flex; flex:1.5; min-height:0; align-items:center; gap:var(--widget-gap); }
      .penned-calculator-result { flex:1; min-width:0; line-height:1.1; text-align:right; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-size:min(18px,var(--calc-result-size)) !important; }
      .penned-calculator :is(button,img) { margin:0; box-shadow:none; }
      .penned-calculator [data-calc-key="copy"] { flex:none; display:grid; place-items:center; width:20px; height:100%; max-height:20px; padding:2px; border-radius:4px; }
      .penned-calculator [data-calc-key="copy"] img { display:block; width:100%; height:100%; object-fit:contain; border:0; pointer-events:none; }
      .penned-calculator-keys { display:grid; flex:1; min-height:0; grid-template-columns:repeat(4,minmax(0,1fr)); grid-template-rows:repeat(5,minmax(0,1fr)); gap:min(3px,1.5cqi); }
      .penned-calculator-keys button { display:grid; place-items:center; width:100%; min-width:0; min-height:0; height:100%; padding:1px; box-sizing:border-box; line-height:1; touch-action:pan-y; }
      .penned-calculator-keys button span { display:block; max-width:100%; white-space:nowrap; font-size:min(var(--calc-button-size),16px) !important; }
      .penned-calculator button:active { filter:brightness(0.85); }
      .penned-calculator button:focus-visible { outline:2px solid currentColor; outline-offset:-3px; }
    `;
    document.head.append(style);
    return Node.create({
      name: "calculator", group: "block", atom: true, selectable: true, draggable: true,
      addAttributes() {
        return { id: { default: null, parseHTML: element => element.getAttribute("data-vellix-block-id") },
          state: { default: initialState(), rendered: false, parseHTML: element => { try { return state(JSON.parse(element.dataset.calculatorState || "{}")); } catch { return initialState(); } } },
          ...Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [key, { default: fallback, rendered: false,
            parseHTML: element => { try { return setting(key, JSON.parse(element.dataset.calculatorSettings || "{}")[key]); } catch { return fallback; } },
          }])) };
      },
      parseHTML: () => [{ tag: "div[data-calculator]" }],
      renderHTML({ node, HTMLAttributes }) {
        const attrs = settings(node.attrs);
        return ["div", mergeAttributes(HTMLAttributes, { class: "penned-calculator penned-document-widget", "data-calculator": "", "data-vellix-block-id": node.attrs.id,
          "data-widget-size": attrs.width, "data-calculator-settings": JSON.stringify(attrs), "data-calculator-state": JSON.stringify(state(node.attrs.state)), contenteditable: "false",
          style: `background:${attrs.backgroundColor};border:${attrs.borderWidth}px solid ${attrs.borderColor};border-radius:${attrs.cornerRadius}px`,
        }), ...parts(attrs, node.attrs.state, families)];
      },
      addCommands() {
        return { calculatorUpdate: args => ({ tr, dispatch }) => {
          let found = null;
          tr.doc.descendants((node, pos) => { if (node.type.name === "calculator" && node.attrs.id === args.blockID) { found = { node, pos }; return false; } });
          if (!found || JSON.stringify(settings(found.node.attrs)) !== JSON.stringify(settings(args.original))) return false;
          const next = settings(args.settings);
          if (dispatch && JSON.stringify(settings(found.node.attrs)) !== JSON.stringify(next)) {
            closeHistory(tr); tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, ...next });
          }
          return true;
        } };
      },
      addNodeView() {
        return ({ node, getPos, editor }) => {
          let current = node, destroyed = false, touch = null, ignoreClickUntil = 0, appearanceSignature = "";
          const dom = document.createElement("div");
          dom.className = "penned-calculator penned-document-widget penned-widget-settings-surface";
          dom.contentEditable = "false"; dom.dataset.calculator = "";
          const listeners = new AbortController();
          const enabled = () => !destroyed && editor.isEditable && global.PennedDocumentWidgets.selectionMode() === "off" && !global.PennedBlockDragAndDrop?.busy;
          const live = () => { const pos = getPos(), target = Number.isInteger(pos) ? editor.state.doc.nodeAt(pos) : null;
            return target?.type.name === "calculator" && target.attrs.id === current.attrs.id ? { node: target, pos } : null; };
          const feedback = (attrs, action, value) => post("calculatorAction", { blockID: current.attrs.id, action, settings: attrs, ...(value !== undefined ? { value } : {}) });
          const activate = event => {
            const button = event.target.closest?.("button[data-calc-key]");
            if (!button || !dom.contains(button)) return false;
            if (!enabled() || (event.type === "click" && performance.now() < ignoreClickUntil) || global.PennedBlockSelection?.hasActiveGesture) return true;
            const target = live(); if (!target) return true;
            const attrs = settings(target.node.attrs), previous = state(target.node.attrs.state), key = button.dataset.calcKey;
            if (key === "copy") { if (!previous.error) feedback(attrs, "copy", previous.result); return true; }
            const next = press(previous, key);
            if (JSON.stringify(next) !== JSON.stringify(previous)) editor.view.dispatch(closeHistory(editor.state.tr).setNodeMarkup(target.pos, undefined, { ...target.node.attrs, state: next }));
            if (attrs.soundEnabled || attrs.hapticsEnabled) feedback(attrs, "press");
            return true;
          };
          const fit = () => {
            const attrs = settings(current.attrs);
            for (const span of dom.querySelectorAll(".penned-calculator-keys button span, .penned-calculator-result")) {
              const result = span.classList.contains("penned-calculator-result");
              const available = result ? span.clientWidth : span.parentElement.clientWidth - 6;
              const desired = result ? Math.min(18, attrs.displaySize, span.parentElement.clientHeight * 0.9) : Math.min(attrs.buttonSize, (span.parentElement.clientHeight - 2) * 0.7);
              if (available > 0) span.style.setProperty(result ? "--calc-result-size" : "--calc-button-size", `${Math.max(8, Math.min(desired, available / Math.max(1, span.textContent.length * 0.68)))}px`);
            }
            const expression = dom.querySelector(".penned-calculator-expression");
            if (expression?.clientHeight > 0) expression.style.setProperty("--calc-expression-size", `${Math.min(attrs.calculationSize, 11, expression.clientHeight / 1.1)}px`);
          };
          const render = () => {
            const attrs = settings(current.attrs);
            dom.dataset.vellixBlockId = current.attrs.id || ""; dom.dataset.widgetSize = attrs.width;
            dom.dataset.vellixIndent = String(Math.max(0, Math.min(6, current.attrs.indent || 0)));
            dom.style.backgroundColor = attrs.backgroundColor; dom.style.borderColor = attrs.borderColor;
            dom.style.borderWidth = `${attrs.borderWidth}px`; dom.style.borderRadius = `${attrs.cornerRadius}px`;
            const signature = JSON.stringify(attrs), value = state(current.attrs.state);
            if (signature !== appearanceSignature) {
              dom.replaceChildren(); parts(attrs, value, families).forEach(spec => append(dom, spec));
              appearanceSignature = signature;
            } else {
              dom.querySelector(".penned-calculator-expression").textContent = value.calculation || "\u00a0";
              dom.querySelector(".penned-calculator-result").textContent = resultText(value);
            }
            fit();
          };
          const release = global.PennedDocumentWidgets.bindSettings({ dom, surface: dom, editor, enabled, activate,
            open: () => { const target = live(); if (!target || !enabled()) return false;
              post("calculatorSettings", { blockId: target.node.attrs.id, settings: settings(target.node.attrs), state: state(target.node.attrs.state) }); return true; } });
          dom.addEventListener("touchstart", event => {
            const point = event.touches[0];
            touch = event.touches.length === 1 && enabled() ? { id: point.identifier, x: point.clientX, y: point.clientY, at: performance.now() } : null;
          }, { passive: true, signal: listeners.signal });
          dom.addEventListener("touchmove", event => {
            const point = [...event.touches].find(item => item.identifier === touch?.id);
            if (!point || event.touches.length !== 1 || Math.hypot(point.clientX - touch.x, point.clientY - touch.y) > 10) touch = null;
          }, { passive: true, signal: listeners.signal });
          dom.addEventListener("touchend", event => {
            const contact = touch; touch = null;
            if (!contact || event.defaultPrevented || !event.cancelable || !enabled() || performance.now() - contact.at >= 500 ||
                ![...event.changedTouches].some(item => item.identifier === contact.id)) return;
            if (activate(event)) { ignoreClickUntil = performance.now() + 650; event.preventDefault(); event.stopPropagation(); }
          }, { passive: false, signal: listeners.signal });
          dom.addEventListener("touchcancel", () => { touch = null; }, { passive: true, signal: listeners.signal });
          const resize = new ResizeObserver(fit); resize.observe(dom); render();
          return { dom, update(next) { if (next.type !== current.type || next.attrs.id !== current.attrs.id) return false; current = next; render(); return true; },
            stopEvent: event => global.PennedDocumentWidgets.selectionMode() === "off" && !/^(drag|drop)/.test(event.type), ignoreMutation: () => true,
            destroy() { destroyed = true; touch = null; release(); resize.disconnect(); listeners.abort(); } };
        };
      },
    });
  }
  global.PennedCalculator = { createExtension, settings, state, press, initialState, resultText };
})(globalThis);
