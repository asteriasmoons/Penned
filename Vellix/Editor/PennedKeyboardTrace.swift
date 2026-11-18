#if DEBUG && os(iOS)
import Foundation
import UIKit
import WebKit
import os

@MainActor
enum PennedKeyboardTrace {
    nonisolated static let enabled = ProcessInfo.processInfo.arguments.contains("-PennedKeyboardTrace")

    nonisolated struct Stamp: Sendable {
        let wallUS = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let uptimeUS = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
    }

    private nonisolated static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "PennedKeyboard")
    private nonisolated static let outputQueue = DispatchQueue(label: "im.lystaria.Vellix.PennedKeyboardTrace", qos: .utility)
    private static var observers: [NSObjectProtocol] = []
    private static weak var activeSession: TipTapEditorSession?
    private static var sequence = 0
    private static var history = Array(repeating: "", count: 128)
    private static var liveUntilUS: Int64 = 0

    static func start() {
        guard enabled, observers.isEmpty else { return }
        let names: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "keyboardWillShow"),
            (UIResponder.keyboardDidShowNotification, "keyboardDidShow"),
            (UIResponder.keyboardWillHideNotification, "keyboardWillHide"),
            (UIResponder.keyboardDidHideNotification, "keyboardDidHide"),
            (UIResponder.keyboardWillChangeFrameNotification, "keyboardWillChangeFrame"),
            (UIResponder.keyboardDidChangeFrameNotification, "keyboardDidChangeFrame"),
            (UIApplication.willResignActiveNotification, "app.willResignActive"),
            (UIApplication.didBecomeActiveNotification, "app.didBecomeActive"),
            (UIWindow.didResignKeyNotification, "window.didResignKey"),
            (UIWindow.didBecomeKeyNotification, "window.didBecomeKey"),
        ]
        observers = names.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    observe(notification, label: label)
                }
            }
        }
        record("trace.start", "pid=\(ProcessInfo.processInfo.processIdentifier)", live: true)
    }

    static func setActiveSession(_ session: TipTapEditorSession) {
        guard enabled else { return }
        activeSession = session
    }

    static func documentToken(_ id: String?) -> String {
        id.map { String(UInt(bitPattern: $0.hashValue), radix: 16) } ?? "-"
    }

    nonisolated static func identity(_ object: AnyObject?) -> String {
        object.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "-"
    }

    @discardableResult
    static func record(_ event: String, session: TipTapEditorSession? = nil, webView: WKWebView? = nil,
                       _ details: @autoclosure () -> String = "", live: Bool = false, stamp: Stamp? = nil) -> Int? {
        guard enabled else { return nil }
        let stamp = stamp ?? Stamp()
        sequence += 1
        let view = webView ?? session?.tagNavigationWebView
        let line = "seq=\(sequence) wall_us=\(stamp.wallUS) uptime_us=\(stamp.uptimeUS) \(event)"
            + " session=\(identity(session)) wk=\(identity(view)) \(session?.keyboardTraceState ?? "") \(details())"
        history[(sequence - 1) % history.count] = line
        if live || stamp.uptimeUS <= liveUntilUS { emit([line]) }
        return sequence
    }

    private static func emit(_ lines: [String]) {
        // Capture the timeline on main, but do not emit a console dump from
        // inside UIKit's keyboard notification.
        outputQueue.async {
            for line in lines {
                logger.notice("📮 [PENNED-KEYBOARD] \(line, privacy: .public)")
            }
        }
    }

    private static func observe(_ note: Notification, label: String) {
        let stamp = Stamp()
        let session = activeSession
        let webView = session?.tagNavigationWebView
        let info = note.userInfo
        let start = (info?[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
        let end = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let window = (note.object as? UIWindow) ?? webView?.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        // Walk only on lifecycle notifications, never on input or bridge events.
        let responder = window.flatMap { firstResponder(in: $0) }
        let responderType = responder.map { NSStringFromClass(type(of: $0)) } ?? "-"
        let inEditor = webView.map { web in responder?.isDescendant(of: web) == true || responder === web } ?? false
        let details = "window=\(identity(window)) responder=\(responderType) responderInWK=\(inEditor)"
            + " begin=\(start.map { NSCoder.string(for: $0) } ?? "-") end=\(end.map { NSCoder.string(for: $0) } ?? "-")"
            + " duration=\(info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0)"
            + " curve=\(info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1)"
            + " local=\(info?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool ?? false)"
        guard let trigger = record(label, session: session, webView: webView, details, live: true, stamp: stamp),
              label == "keyboardWillHide" else { return }
        liveUntilUS = stamp.uptimeUS + 2_000_000
        var lines = ["history.begin trigger_seq=\(trigger) trigger_wall_us=\(stamp.wallUS) (oldest first; seq values are original)"]
        for offset in max(0, trigger - history.count)..<(trigger - 1) {
            lines.append("history trigger_seq=\(trigger) \(history[offset % history.count])")
        }
        lines.append("history.end trigger_seq=\(trigger) trigger_wall_us=\(stamp.wallUS)")
        emit(lines)
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let result = firstResponder(in: child) { return result }
        }
        return nil
    }

    private static let inboundKinds: Set<String> = [
        "ready", "focus", "update", "snapshot", "height", "caret", "formattingState", "textConversionState",
        "selection", "selectionMode", "blockSelectionDrag", "slashMenu", "error",
        "nativeCollections", "gridCardSettings", "codeBlockEdit", "propertyEditorRequest", "tableMenuRequest",
        "taskMenuRequest", "tagRequest", "templateRequest", "blockActionsRequest",
    ]

    static func receive(_ message: WKScriptMessage, body: Any, session: TipTapEditorSession) -> Bool {
        guard enabled, message.frameInfo.isMainFrame, let body = body as? [String: Any],
              let kind = body["kind"] as? String else { return false }
        if kind == "keyboardTrace" {
            if let rows = body["payload"] as? [[String: Any]], rows.count <= 16 {
                for row in rows { receiveRow(row, session: session, webView: message.webView) }
            }
            return true
        }
        if inboundKinds.contains(kind) {
            let payload = body["payload"] as? [String: Any]
            var state = ""
            if kind == "focus", let focused = payload?["focused"] as? Bool { state = " focused=\(focused)" }
            if kind == "selectionMode", let mode = payload?["mode"] as? String,
               ["off", "single", "multi"].contains(mode) { state = " mode=\(mode)" }
            if kind == "selection", let count = payload?["count"] as? Int { state = " count=\(count)" }
            if kind == "blockSelectionDrag", let active = payload?["active"] as? Bool { state = " active=\(active)" }
            record("bridge.in", session: session, webView: message.webView, "kind=\(kind)\(state)", live: kind == "focus")
        }
        return false
    }

    private static let webEvents: Set<String> = [
        "install", "editor.missing", "editor.destroy", "editor.focus", "editor.blur", "editor.selection",
        "editor.transaction", "dom.focusin", "dom.focusout", "dom.selection", "dom.beforeinput", "dom.input",
        "dom.compositionstart", "dom.compositionend", "page.visibility", "page.hide", "window.focus", "window.blur",
        "mobile.selection.blur", "mobile.selection.command", "mobile.divider.blur",
    ]
    private static let webTokens: [String: Set<String>] = [
        "active": ["none", "body", "editor", "editor-child", "field", "outside"],
        "related": ["none", "body", "editor", "editor-child", "field", "outside"],
        "selection": ["text", "node", "other", "none"],
        "source": ["root", "appended", "mobile-selection", "composition", "pointer", "input-window",
                   "touch-commit", "divider-conversion", "backspace-divider", "setContent", "setEditable"],
        "input": ["insertText", "insertReplacementText", "insertCompositionText", "deleteCompositionText",
                  "insertFromComposition", "insertLineBreak", "insertParagraph", "deleteContentBackward",
                  "deleteContentForward", "deleteWordBackward", "deleteWordForward", "insertFromPaste",
                  "insertFromDrop", "deleteByCut", "historyUndo", "historyRedo", "other"],
        "ui": ["paste", "cut", "drop", "input"],
        "visibility": ["visible", "hidden", "prerender"],
    ]
    private static let webNumbers = [
        "tipFocused", "editable", "composing", "from", "to", "steps", "docChanged", "selectionSet",
        "composition", "pointer", "mobile", "historyExcluded", "preventUpdate", "focusMeta", "blurMeta", "documentLoad",
        "inputAgeUS", "inEditor", "collapsed", "anchorOffset", "focusOffset", "preserving", "sourceLine", "sourceColumn",
    ]

    private static func receiveRow(_ row: [String: Any], session: TipTapEditorSession, webView: WKWebView?) {
        guard let event = row["event"] as? String, webEvents.contains(event),
              let page = row["page"] as? Int, let seq = row["seq"] as? Int,
              let wall = row["wallUS"] as? Int64, let elapsed = row["elapsedUS"] as? Int64 else { return }
        var parts = ["page=\(page)", "jseq=\(seq)", "js_wall_us=\(wall)", "js_elapsed_us=\(elapsed)"]
        for key in webNumbers {
            if let value = row[key] as? Int { parts.append("\(key)=\(value)") }
        }
        for (key, allowed) in webTokens {
            if let value = row[key] as? String, allowed.contains(value) { parts.append("\(key)=\(value)") }
        }
        let live = ["install", "editor.missing", "editor.destroy", "editor.blur", "dom.focusout",
                    "mobile.selection.blur", "mobile.divider.blur", "page.hide", "window.blur"].contains(event)
        record("js.\(event)", session: session, webView: webView, parts.joined(separator: " "), live: live)
    }

    static let script = #"""
    (() => {
      if (window.PennedKeyboardTrace) return;
      const handler = window.webkit?.messageHandlers?.tiptap;
      if (!handler) return;
      const page = Math.floor(Math.random() * 0x7fffffff);
      const root = document.querySelector(".tiptap-editor");
      // TipTap exposes its mounted Editor instance on view.dom.
      const editor = root?.editor;
      const listeners = new AbortController();
      let seq = 0, timer = 0, pending = [], lastInput = null, lastDOMSelection = "";
      const mode = node => !node ? "none" : node === document.body ? "body"
        : root && node === root ? "editor" : root?.contains(node) ? "editor-child"
        : node.matches?.("input, textarea, [contenteditable]") ? "field" : "outside";
      const selection = state => {
        const value = state?.selection;
        if (!value) return { selection: "none" };
        return { selection: value.node ? "node" : value.$cursor !== undefined ? "text" : "other",
          from: value.from, to: value.to };
      };
      const flush = () => {
        clearTimeout(timer);
        timer = 0;
        if (!pending.length) return;
        const payload = pending;
        pending = [];
        try { handler.postMessage({ kind: "keyboardTrace", payload }); } catch {}
      };
      const record = (event, details = {}, urgent = false) => {
        const time = performance.now();
        pending.push({ ...details, event, page, seq: ++seq, elapsedUS: Math.round(time * 1000),
          wallUS: Math.round((performance.timeOrigin + time) * 1000),
          active: mode(document.activeElement), tipFocused: Number(!!editor?.isFocused),
          editable: Number(!!editor?.isEditable), composing: Number(!!editor?.view?.composing) });
        if (urgent || pending.length >= 16) flush();
        else if (!timer) timer = setTimeout(flush, 90);
      };
      window.PennedKeyboardTrace = { record };
      record("install", {}, true);
      if (!editor) record("editor.missing", {}, true);

      const listen = (target, type, fn) => target.addEventListener(type, fn,
        { capture: true, passive: true, signal: listeners.signal });
      for (const type of ["focusin", "focusout"]) {
        listen(document, type, event => {
          // Only retain a numeric first-party source location, never the raw stack or URLs.
          const frame = type === "focusout" && new Error().stack?.match(/(?:tiptap\.bundle\.js|tiptap\.html|about:blank):(\d+):(\d+)/);
          record("dom." + type, { related: mode(event.relatedTarget),
            inEditor: Number(!!root?.contains(event.target)),
            ...(frame ? { sourceLine: Number(frame[1]), sourceColumn: Number(frame[2]) } : {}) }, true);
        });
      }
      listen(document, "selectionchange", () => {
        const range = document.getSelection();
        const inside = Number(!!range && !!root &&
          (root.contains(range.anchorNode) || root.contains(range.focusNode)));
        if (!inside && !lastDOMSelection) return;
        const details = { inEditor: inside, collapsed: Number(range?.isCollapsed ?? true),
          ...(inside ? { anchorOffset: range.anchorOffset, focusOffset: range.focusOffset } : {}) };
        const signature = inside ? [details.anchorOffset, details.focusOffset, details.collapsed].join(":") : "";
        if (signature === lastDOMSelection) return;
        lastDOMSelection = signature;
        record("dom.selection", details);
      });
      const inputTypes = new Set(["insertText", "insertReplacementText", "insertCompositionText", "deleteCompositionText",
        "insertFromComposition", "insertLineBreak", "insertParagraph", "deleteContentBackward", "deleteContentForward",
        "deleteWordBackward", "deleteWordForward", "insertFromPaste", "insertFromDrop", "deleteByCut",
        "historyUndo", "historyRedo"]);
      for (const type of ["beforeinput", "input", "compositionstart", "compositionend"]) {
        listen(document, type, event => {
          if (!root?.contains(event.target)) return;
          const input = inputTypes.has(event.inputType) ? event.inputType : "other";
          if (type === "beforeinput" || type === "input") lastInput = { input, at: performance.now() };
          record("dom." + type, { input, composition: Number(!!event.isComposing) });
        });
      }
      listen(document, "visibilitychange", () => record("page.visibility", { visibility: document.visibilityState }, true));
      listen(window, "pagehide", () => record("page.hide", {}, true));
      for (const type of ["focus", "blur"]) {
        listen(window, type, event => { if (event.target === window) record("window." + type, {}, true); });
      }
      if (!editor) return;

      const uiEvents = new Set(["paste", "cut", "drop", "input"]);
      const transaction = (tr, appended) => {
        const mobile = Object.keys(tr.meta).some(key => key.startsWith("pennedBlockSelection$"));
        const focus = !!tr.getMeta("focus"), blur = !!tr.getMeta("blur");
        if (!tr.docChanged && !tr.selectionSet && !mobile && !focus && !blur) return;
        const composition = tr.getMeta("composition"), pointer = !!tr.getMeta("pointer"), ui = tr.getMeta("uiEvent");
        const inputAgeUS = lastInput ? Math.round((performance.now() - lastInput.at) * 1000) : -1;
        const nearInput = inputAgeUS >= 0 && inputAgeUS <= 150000;
        // A recent input event is correlation only, not proof of a transaction's origin.
        const source = appended ? "appended" : mobile ? "mobile-selection" : composition ? "composition"
          : pointer ? "pointer" : nearInput ? "input-window" : "root";
        record("editor.transaction", { ...selection(tr), source, steps: tr.steps.length,
          docChanged: Number(tr.docChanged), selectionSet: Number(tr.selectionSet),
          composition: Number.isInteger(composition) ? composition : 0, pointer: Number(pointer),
          mobile: Number(mobile), historyExcluded: Number(tr.getMeta("addToHistory") === false),
          preventUpdate: Number(!!tr.getMeta("preventUpdate")), documentLoad: Number(!!tr.getMeta("pennedPlaceholderDocumentLoad")),
          focusMeta: Number(focus), blurMeta: Number(blur),
          ...(uiEvents.has(ui) ? { ui } : {}),
          ...(nearInput ? { inputAgeUS, input: lastInput.input } : {}) });
      };
      editor.on("transaction", ({ transaction: rootTransaction, appendedTransactions = [] }) => {
        transaction(rootTransaction, false);
        for (const tr of appendedTransactions) transaction(tr, true);
      });
      editor.on("selectionUpdate", () => record("editor.selection", selection(editor.state)));
      editor.on("focus", () => record("editor.focus", selection(editor.state), true));
      editor.on("blur", () => record("editor.blur", selection(editor.state), true));
      editor.on("destroy", () => {
        record("editor.destroy", {}, true);
        listeners.abort();
        delete window.PennedKeyboardTrace;
      });
    })();
    """#
}
#endif
