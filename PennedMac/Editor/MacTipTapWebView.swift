// Mac-target platform adapter. Based on Vellix/Editor/TipTapWebView.swift.
// iPhone/iPad implementations remain in their original target.
//
//  TipTapWebView.swift
//  Vellix
//

import SwiftUI
import WebKit
import os

#if os(iOS)
import UIKit

private final class TipTapWKWebView: WKWebView {
    override var inputAccessoryView: UIView? { nil }

    #if DEBUG
    weak var diagnosticCoordinator: Coordinator?

    override func removeFromSuperview() {
        TipTapHostLifecycleTrace.record("removeFromSuperview.before", webView: self, includeStack: superview != nil)
        super.removeFromSuperview()
        TipTapHostLifecycleTrace.record("removeFromSuperview.after", webView: self)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        TipTapHostLifecycleTrace.record("didMoveToSuperview", webView: self, includeStack: superview == nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        TipTapHostLifecycleTrace.record("didMoveToWindow", webView: self, includeStack: window == nil)
    }
    #endif
}

#if DEBUG
@MainActor
private enum TipTapHostLifecycleTrace {
    private static var sequence = 0
    private static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "TipTapHostTrace")

    static func record(_ event: String, webView: WKWebView?, container: UIView? = nil,
                       coordinator: Coordinator? = nil, documentID: String? = nil, includeStack: Bool = false) {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let coordinator = coordinator ?? (webView as? TipTapWKWebView)?.diagnosticCoordinator,
              coordinator.session.preparesInteractivePresentation, sequence < 2_000 else { return }
        sequence += 1
        let parent = webView?.superview
        let document = coordinator.session.documentForRecovery?()
        let report: [String: Any] = [
            "sequence": sequence, "uptime": ProcessInfo.processInfo.systemUptime,
            "pid": ProcessInfo.processInfo.processIdentifier, "event": event,
            "documentID": documentID ?? document?.id ?? "nil",
            "webView": identity(webView), "container": identity(container), "parent": identity(parent),
            "parentType": parent.map { NSStringFromClass(type(of: $0)) } ?? "nil",
            "coordinator": identity(coordinator), "session": identity(coordinator.session),
            "containerOwnsWebView": container != nil && parent === container,
            "containerHasWindow": container?.window != nil, "webViewHasWindow": webView?.window != nil,
            "ready": coordinator.session.isReady, "loading": coordinator.session.isLoadingDocument,
            "presentationReady": coordinator.session.isPresentationReady,
            "stack": includeStack ? Array(Thread.callStackSymbols.prefix(32)) : []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) else { return }
        logger.info("PENNED-HOST \(String(decoding: data, as: UTF8.self), privacy: .public)")
        // Ordered native lifecycle events only; never read or write document content.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PennedEditorHostLifecycle.jsonl")
        var line = data
        line.append(0x0A)
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            if let size = try? file.seekToEnd(), size < 2_000_000 { try? file.write(contentsOf: line) }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private static func identity(_ object: AnyObject?) -> String {
        object.map { ObjectIdentifier($0).debugDescription } ?? "nil"
    }
}
#endif
#elseif os(macOS)
import AppKit
#endif

private enum TipTapEditorStartupTiming {
    static let processStart = CFAbsoluteTimeGetCurrent()

    static func elapsedMS() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - processStart) * 1000)
    }
}

enum TipTapEditorAssetCache {
    static let cachedDocument: (html: String, baseURL: URL)? = {
        guard let bundleURL = Bundle.main.url(
            forResource: "VellixEditor",
            withExtension: "bundle"
        ) else {
            return nil
        }

        return try? document(in: bundleURL)
    }()

    static func document(in bundleURL: URL) throws -> (html: String, baseURL: URL) {
        var html = try String(contentsOf: bundleURL.appendingPathComponent("tiptap.html"), encoding: .utf8)
        let placeholdersURL = bundleURL.appendingPathComponent("structured-placeholders.js")
        if let script = try? String(contentsOf: placeholdersURL, encoding: .utf8) {
            html = html.replacingOccurrences(of: "</head>",
                with: "<script>\(script.replacingOccurrences(of: "</script>", with: "<\\/script>"))</script></head>")
        }
        // loadHTMLString cannot reliably read sibling file scripts on its first
        // navigation. Keep every required dependency inline, in its original order.
        for path in ["vendor/formula-parser.min.js", "table-formulas.js", "vellix-tables.js", "vendor/table-library.js", "tiptap.bundle.js"] {
            let bundleJS = try String(contentsOf: bundleURL.appendingPathComponent(path), encoding: .utf8)
            let safeJS = bundleJS.replacingOccurrences(of: "</script>", with: "<\\/script>")
            html = html.replacingOccurrences(
                of: "<script src=\"./\(path)\"></script>",
                with: "<script>\n\(safeJS)\n</script>"
            )
        }
        let tableCSS = try String(contentsOf: bundleURL.appendingPathComponent("vellix-tables.css"), encoding: .utf8)
        html = html.replacingOccurrences(of: #"<link rel="stylesheet" href="./vellix-tables.css" />"#,
            with: "<style>\(tableCSS)</style>")

        return (html, bundleURL)
    }
}

struct TipTapWebView {
    @ObservedObject var session: TipTapEditorSession
    let store: TipTapEditorWebViewStore
    var documentID: String?
    var canonicalJSON: String

    init(
        session: TipTapEditorSession,
        store: TipTapEditorWebViewStore,
        documentID: String?,
        canonicalJSON: String
    ) {
        self.session = session
        self.store = store
        self.documentID = documentID
        self.canonicalJSON = canonicalJSON
    }
}

@MainActor
final class TipTapEditorWebViewStore {
    let coordinator: Coordinator
    let webView: WKWebView
    private weak var activeHost: TipTapWebViewContainer?

    init(session: TipTapEditorSession, loadEditor: ((WKWebView, Coordinator) -> Void)? = nil) {
        let coordinator = loadEditor.map { Coordinator(session: session, loadEditor: $0) } ?? Coordinator(session: session)
        self.coordinator = coordinator
        self.webView = TipTapWebView.makeWebView(coordinator: coordinator)
    }

    func claimHost(_ container: TipTapWebViewContainer) {
        // SwiftUI may update an outgoing representable after making its replacement.
        activeHost = container
        container.owningStore = self
        container.host(webView)
    }

    func ownsHost(_ container: TipTapWebViewContainer) -> Bool {
        activeHost === container && container.owningStore === self
    }

    fileprivate func releaseHost(_ container: TipTapWebViewContainer) -> Bool {
        guard ownsHost(container) else { return false }
        activeHost = nil
        return true
    }
}

#if os(iOS)

final class TipTapWebViewContainer: UIView {
    private weak var hostedWebView: WKWebView?
    fileprivate weak var owningStore: TipTapEditorWebViewStore?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    func host(_ webView: WKWebView) {
        #if DEBUG
        TipTapHostLifecycleTrace.record("host.request", webView: webView, container: self)
        #endif
        guard let owningStore, owningStore.ownsHost(self), owningStore.webView === webView else {
            #if DEBUG
            TipTapHostLifecycleTrace.record("host.ignoredStaleHost", webView: webView, container: self)
            #endif
            return
        }
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        guard owningStore.ownsHost(self) else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hostedWebView = webView
        #if DEBUG
        TipTapHostLifecycleTrace.record("host.attached", webView: webView, container: self)
        #endif
    }

    func unhost() {
        #if DEBUG
        TipTapHostLifecycleTrace.record("unhost.request", webView: hostedWebView, container: self)
        #endif
        guard owningStore?.releaseHost(self) == true else {
            #if DEBUG
            TipTapHostLifecycleTrace.record("unhost.ignoredStaleHost", webView: hostedWebView, container: self)
            #endif
            return
        }
        guard let hostedWebView, hostedWebView.superview === self else { return }
        hostedWebView.removeFromSuperview()
    }
}

extension TipTapWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        #if DEBUG
        TipTapHostLifecycleTrace.record("makeCoordinator", webView: store.webView, coordinator: store.coordinator, documentID: documentID)
        #endif
        return store.coordinator
    }

    func makeUIView(context: Context) -> TipTapWebViewContainer {
        let container = TipTapWebViewContainer()
        #if DEBUG
        TipTapHostLifecycleTrace.record("makeUIView.begin", webView: store.webView, container: container,
                                       coordinator: context.coordinator, documentID: documentID)
        #endif
        container.onLayout = { [weak session, weak coordinator = context.coordinator] in
            session?.editorDidLayout()
            #if DEBUG
            coordinator?.scheduleRenderingDiagnostic(reason: "layout")
            #endif
        }
        store.claimHost(container)
        scheduleSessionLoad(store.webView, coordinator: context.coordinator, container: container)
        #if DEBUG
        TipTapHostLifecycleTrace.record("makeUIView.end", webView: store.webView, container: container,
                                       coordinator: context.coordinator, documentID: documentID)
        #endif
        return container
    }

    func updateUIView(_ container: TipTapWebViewContainer, context: Context) {
        #if DEBUG
        TipTapHostLifecycleTrace.record("updateUIView.begin", webView: store.webView, container: container,
                                       coordinator: context.coordinator, documentID: documentID)
        #endif
        guard store.ownsHost(container) else {
            #if DEBUG
            TipTapHostLifecycleTrace.record("updateUIView.ignoredStaleHost", webView: store.webView, container: container,
                                           coordinator: context.coordinator, documentID: documentID)
            #endif
            return
        }
        container.host(store.webView)
        context.coordinator.pinInternalScrollPosition(store.webView.scrollView)
        scheduleSessionLoad(store.webView, coordinator: context.coordinator, container: container)
        #if DEBUG
        context.coordinator.scheduleRenderingDiagnostic(reason: "update")
        TipTapHostLifecycleTrace.record("updateUIView.end", webView: store.webView, container: container,
                                       coordinator: context.coordinator, documentID: documentID)
        #endif
    }

    static func dismantleUIView(_ container: TipTapWebViewContainer, coordinator: Coordinator) {
        #if DEBUG
        TipTapHostLifecycleTrace.record("dismantleUIView.begin", webView: coordinator.session.tagNavigationWebView,
                                       container: container, coordinator: coordinator)
        #endif
        container.unhost()
        #if DEBUG
        TipTapHostLifecycleTrace.record("dismantleUIView.end", webView: coordinator.session.tagNavigationWebView,
                                       container: container, coordinator: coordinator)
        #endif
    }
}

#elseif os(macOS)

final class TipTapWebViewContainer: NSView {
    private weak var hostedWebView: WKWebView?
    fileprivate weak var owningStore: TipTapEditorWebViewStore?
    var onLayout: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The full-height editor must not intercept the fixed header outside its scroll viewport.
        guard visibleRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    func host(_ webView: WKWebView) {
        guard let owningStore, owningStore.ownsHost(self), owningStore.webView === webView else { return }
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        guard owningStore.ownsHost(self) else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hostedWebView = webView
    }

    func unhost() {
        guard owningStore?.releaseHost(self) == true else { return }
        guard let hostedWebView, hostedWebView.superview === self else { return }
        hostedWebView.removeFromSuperview()
    }
}

extension TipTapWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        store.coordinator
    }

    func makeNSView(context: Context) -> TipTapWebViewContainer {
        let container = TipTapWebViewContainer()
        container.onLayout = { [weak session] in session?.editorDidLayout() }
        store.claimHost(container)
        scheduleSessionLoad(store.webView, coordinator: context.coordinator, container: container)
        return container
    }

    func updateNSView(_ container: TipTapWebViewContainer, context: Context) {
        guard store.ownsHost(container) else { return }
        container.host(store.webView)
        scheduleSessionLoad(store.webView, coordinator: context.coordinator, container: container)
    }

    static func dismantleNSView(_ container: TipTapWebViewContainer, coordinator: Coordinator) {
        container.unhost()
    }
}

#endif

fileprivate extension TipTapWebView {
    func scheduleSessionLoad(_ webView: WKWebView, coordinator: Coordinator, container: TipTapWebViewContainer) {
        let session = session
        let store = store
        let documentID = documentID
        let canonicalJSON = canonicalJSON

        Task { @MainActor [weak webView, weak coordinator, weak store, weak container] in
            await Task.yield()
            guard
                let webView,
                let coordinator,
                let store, let container, store.ownsHost(container),
                coordinator.isActive
            else {
                return
            }

            session.attach(webView: webView)
            if let documentID {
                session.load(documentID: documentID, canonicalJSON: canonicalJSON)
            }
        }
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: "tiptap")
        contentController.addUserScript(WKUserScript(source: TextBlockConversion.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.setURLSchemeHandler(DocumentFontSchemeHandler(), forURLScheme: DocumentFontResources.scheme)
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(VellixTipTapIconSchemeHandler(), forURLScheme: "vellix-icon")
        configuration.setURLSchemeHandler(CollectionCoverSchemeHandler(store: { [weak session = coordinator.session] in
            session?.attachmentStore
        }), forURLScheme: "penned-cover")
        configuration.setURLSchemeHandler(AttachmentSchemeHandler(session: coordinator.session), forURLScheme: "penned-file")

        #if os(iOS)
        let webView = TipTapWKWebView(frame: .zero, configuration: configuration)
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.navigationDelegate = coordinator
        #if DEBUG && os(iOS)
        webView.diagnosticCoordinator = coordinator
        if UIDevice.current.userInterfaceIdiom == .pad, coordinator.session.preparesInteractivePresentation,
           #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        coordinator.logInfo("⏱️ STARTUP +\(TipTapEditorStartupTiming.elapsedMS())ms makeWebView created \(ObjectIdentifier(webView).debugDescription)")

        #if os(iOS)
        webView.isOpaque = false
        webView.clipsToBounds = false
        webView.layer.masksToBounds = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.clipsToBounds = false
        webView.scrollView.layer.masksToBounds = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.bouncesZoom = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.delegate = coordinator
        if #available(iOS 17.0, *) {
            webView.scrollView.allowsKeyboardScrolling = false
        }
        coordinator.pinInternalScrollPosition(webView.scrollView)
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        MacDocumentScrollBridge.install(on: webView)
        #endif

        Task { @MainActor in
            await Task.yield()
            coordinator.session.attach(webView: webView)
        }

        coordinator.loadEditor(webView, coordinator)
        return webView
    }

    static func loadEditor(into webView: WKWebView, coordinator: Coordinator) {
        if let cachedDocument = TipTapEditorAssetCache.cachedDocument {
            coordinator.logInfo("🌐 Loading inline TipTap editor HTML from VellixEditor.bundle")
            webView.loadHTMLString(cachedDocument.html, baseURL: cachedDocument.baseURL)
            return
        }

        guard let bundleURL = Bundle.main.url(
            forResource: "VellixEditor",
            withExtension: "bundle"
        ) else {
            coordinator.logError("VellixEditor.bundle was not found.")
            return
        }

        let htmlURL = bundleURL.appendingPathComponent("tiptap.html")
        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            coordinator.logError("tiptap.html was not found in VellixEditor.bundle.")
            return
        }

        coordinator.logInfo("🌐 Loading TipTap editor file \(htmlURL.absoluteString)")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: bundleURL)
    }
}

final class Coordinator:
    NSObject,
    WKScriptMessageHandler,
    WKNavigationDelegate
{
    let session: TipTapEditorSession
    private(set) var isActive = true
    private let logger = Logger(subsystem: "im.lystaria.Vellix", category: "TipTapWebView")
    let loadEditor: (WKWebView, Coordinator) -> Void
    #if DEBUG && os(iOS)
    private var renderingDiagnosticTask: Task<Void, Never>?
    private var renderingDiagnosticSignature = ""
    private var renderingDiagnosticCount = 0
    #endif

    init(session: TipTapEditorSession,
         loadEditor: @escaping (WKWebView, Coordinator) -> Void = { TipTapWebView.loadEditor(into: $0, coordinator: $1) }) {
        self.session = session
        self.loadEditor = loadEditor
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "tiptap" else {
            return
        }

        if let dictionary = message.body as? [String: Any] {
            let kind = dictionary["kind"] as? String ?? "unknown"
            logInfo("📨 TRACE WKScriptMessage kind=\(kind)")
        }

        session.handleRawMessage(message.body)
        #if DEBUG && os(iOS)
        if let kind = (message.body as? [String: Any])?["kind"] as? String,
           ["editorReady", "contentHeightChanged", "collectionRegionsChanged"].contains(kind) {
            scheduleRenderingDiagnostic(reason: kind)
        }
        #endif
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        session.markNavigationStarted()
        logInfo("⏱️ STARTUP +\(TipTapEditorStartupTiming.elapsedMS())ms webView didStartProvisionalNavigation url=\(webView.url?.absoluteString ?? "nil")")
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        logInfo("⏱️ STARTUP +\(TipTapEditorStartupTiming.elapsedMS())ms webView didFinish url=\(webView.url?.absoluteString ?? "nil")")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        session.bridgeErrorMessage = error.localizedDescription
        logError("TipTap editor navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        session.markNavigationStarted()
        session.bridgeErrorMessage = error.localizedDescription
        logError("🌐🚨 TipTap editor failed to begin loading: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard isActive else { return }
        logError("💥 WEBVIEW PROCESS TERMINATED url=\(webView.url?.absoluteString ?? "nil")")
        session.markNavigationStarted()
        loadEditor(webView, self)
    }

    func cleanUp(_ webView: WKWebView) {
        logInfo("🧹 TRACE webView cleanUp \(ObjectIdentifier(webView).debugDescription)")
        isActive = false
        session.detach(webView: webView)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tiptap")
        webView.navigationDelegate = nil
        #if os(iOS)
        webView.scrollView.delegate = nil
        #endif
    }

    func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    #if DEBUG && os(iOS)
    func scheduleRenderingDiagnostic(reason: String) {
        guard UIDevice.current.userInterfaceIdiom == .pad, session.preparesInteractivePresentation,
              isActive, renderingDiagnosticTask == nil, renderingDiagnosticCount < 32 else { return }
        renderingDiagnosticTask = Task { @MainActor [weak self] in
            // Observe the committed SwiftUI layout without changing readiness or editor state.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.renderingDiagnosticTask = nil
            guard self.isActive, let webView = self.session.tagNavigationWebView else { return }
            let document = self.session.documentForRecovery?()
            let views = sequence(first: webView as UIView, next: { $0.superview }).map { view in
                ["type": NSStringFromClass(type(of: view)), "frame": NSCoder.string(for: view.frame),
                 "bounds": NSCoder.string(for: view.bounds), "alpha": view.alpha, "hidden": view.isHidden,
                 "clips": view.clipsToBounds, "siblingIndex": view.superview?.subviews.firstIndex(of: view) ?? -1] as [String: Any]
            }
            let layers = sequence(first: webView.layer, next: { $0.superlayer }).map { layer in
                ["type": NSStringFromClass(type(of: layer)), "frame": NSCoder.string(for: layer.frame),
                 "opacity": layer.opacity, "presentationOpacity": layer.presentation()?.opacity ?? layer.opacity,
                 "hidden": layer.isHidden, "clips": layer.masksToBounds] as [String: Any]
            }
            let native: [String: Any] = [
                "documentID": document?.id ?? "nil", "savedJSONBytes": document?.json.utf8.count ?? 0,
                "renderedDocumentID": self.session.renderedDocumentID ?? "nil",
                "ready": self.session.isReady, "loading": self.session.isLoadingDocument,
                "presentationReady": self.session.isPresentationReady,
                "presentation": self.session.presentationDiagnostics,
                "contentHeight": self.session.editorContentHeight, "visualBottom": self.session.editorVisualContentBottom,
                "hasWindow": webView.window != nil,
                "windowFrame": NSCoder.string(for: webView.convert(webView.bounds, to: webView.window)),
                "windowBounds": NSCoder.string(for: webView.window?.bounds ?? .zero),
                "internalContentSize": NSCoder.string(for: webView.scrollView.contentSize),
                "internalContentOffset": NSCoder.string(for: webView.scrollView.contentOffset),
                "views": views, "layers": layers
            ]
            guard let signature = try? JSONSerialization.data(withJSONObject: native, options: .sortedKeys),
                  String(decoding: signature, as: UTF8.self) != self.renderingDiagnosticSignature else { return }
            self.renderingDiagnosticSignature = String(decoding: signature, as: UTF8.self)
            self.renderingDiagnosticCount += 1
            let script = #"""
            (() => {
              const describe = element => {
                if (!element) return null;
                const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
                return {tag:element.tagName, classes:element.className, textCharacters:element.textContent.length,
                  rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
                  display:style.display, visibility:style.visibility, opacity:style.opacity,
                  color:style.color, background:style.backgroundColor, fontSize:style.fontSize,
                  overflow:style.overflow, contentVisibility:style.contentVisibility, transform:style.transform};
              };
              const editor = document.querySelector('.tiptap-editor');
              const ancestors = [];
              for (let node = editor; node; node = node.parentElement) ancestors.push(describe(node));
              return {readyState:document.readyState, visibility:document.visibilityState,
                viewport:{width:innerWidth,height:innerHeight,scale:devicePixelRatio},
                commandAvailable:typeof window.tiptapCommand === 'function', editor:describe(editor),
                blocks:editor?.children.length ?? 0, ancestors,
                firstBlocks:editor ? [...editor.children].slice(0,6).map(describe) : [],
                images:[...document.images].map(image => ({complete:image.complete,
                  naturalWidth:image.naturalWidth,naturalHeight:image.naturalHeight})),
                bodyScrollHeight:document.body?.scrollHeight ?? 0};
            })()
            """#
            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }
                let report: [String: Any] = [
                    "time": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier,
                    "reason": reason, "webView": ObjectIdentifier(webView).debugDescription,
                    "native": native, "dom": result ?? NSNull(), "error": error?.localizedDescription ?? "none"
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) else { return }
                self.logInfo("PENNED-RENDER \(String(decoding: data, as: UTF8.self))")
                // Temporary diagnostics only; no editor text, account secrets, or library writes.
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("PennedEditorDiagnostics.jsonl")
                var line = data
                line.append(0x0A)
                if let file = try? FileHandle(forWritingTo: url) {
                    defer { try? file.close() }
                    if let size = try? file.seekToEnd(), size < 512_000 { try? file.write(contentsOf: line) }
                } else {
                    try? line.write(to: url, options: .atomic)
                }
            }
        }
    }
    #endif
}

#if os(iOS)
extension Coordinator: UIScrollViewDelegate {
    func pinInternalScrollPosition(_ scrollView: UIScrollView) {
        guard scrollView.contentOffset != .zero else { return }
        scrollView.setContentOffset(.zero, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pinInternalScrollPosition(scrollView)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        nil
    }
}
#endif

enum TipTapEditorIconRenderer {
    static func dataURL(for icon: String, tintHex: String = "#ffffff", pointSize: CGFloat = 96) -> String? {
        let usesPersistentPrecompute = tintHex.lowercased() == "#ffffff" && pointSize == 96

        if usesPersistentPrecompute,
           let precomputed = PrecomputedTipTapIconData.base64(for: icon) {
            return "data:image/png;base64,\(precomputed)"
        }

        guard let data = pngData(for: icon, tintHex: tintHex, pointSize: pointSize) else {
            return nil
        }

        let base64 = data.base64EncodedString()
        if usesPersistentPrecompute {
            PrecomputedTipTapIconData.persist(base64: base64, for: icon)
        }

        return "data:image/png;base64,\(base64)"
    }

    static func pngData(for icon: String, tintHex: String = "#ffffff", pointSize: CGFloat = 96) -> Data? {
        #if os(iOS)
        let symbol = VellixAssetIcon(name: icon).systemName
        guard let image = (symbol.flatMap { UIImage(systemName: $0) } ?? UIImage(named: icon))?.withRenderingMode(.alwaysOriginal) else {
            return nil
        }

        let source = croppedTransparentPadding(from: image) ?? image
        return squareTintedPNGData(
            from: source,
            tintColor: UIColor(Color(vellixHex: tintHex)),
            pointSize: pointSize,
            cleanHairlines: symbol == nil
        )
        #elseif os(macOS)
        guard
            let image = VellixAssetIcon(name: icon).systemName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? NSImage(named: NSImage.Name(icon)),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func squareTintedPNGData(from image: UIImage, tintColor: UIColor, pointSize: CGFloat, cleanHairlines: Bool = true) -> Data? {
        let targetSize = CGSize(width: pointSize, height: pointSize)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.opaque = false
        rendererFormat.scale = UIScreen.main.scale

        let rendered = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat).image { _ in
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return
            }

            let scale = min(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = CGRect(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )

            tintColor.setFill()
            UIRectFill(rect)
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }

        return (cleanHairlines ? removingHairlineArtifacts(from: rendered) ?? rendered : rendered).pngData()
    }

    private static func croppedTransparentPadding(from image: UIImage) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let renderScale = max(image.scale, UIScreen.main.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false

        let rendered = UIGraphicsImageRenderer(size: sourceSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: sourceSize))
        }

        guard let cgImage = rendered.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * bytesPerRow) + (x * bytesPerPixel) + 3]
                guard alpha > 4 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: renderScale, orientation: .up)
    }

    private static func removingHairlineArtifacts(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let alphaThreshold: UInt8 = 10
        let maxThickness = max(3, min(width, height) / 40)
        let minLength = max(8, min(width, height) / 18)
        var removeMask = [Bool](repeating: false, count: width * height)

        func pixelIndex(x: Int, y: Int) -> Int {
            y * width + x
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[(pixelIndex(x: x, y: y) * bytesPerPixel) + 3]
        }

        func verticalThickness(atX x: Int, y: Int) -> Int {
            var thickness = 1
            var up = y - 1
            while up >= 0, alpha(x: x, y: up) > alphaThreshold {
                thickness += 1
                up -= 1
            }

            var down = y + 1
            while down < height, alpha(x: x, y: down) > alphaThreshold {
                thickness += 1
                down += 1
            }

            return thickness
        }

        func horizontalThickness(atX x: Int, y: Int) -> Int {
            var thickness = 1
            var left = x - 1
            while left >= 0, alpha(x: left, y: y) > alphaThreshold {
                thickness += 1
                left -= 1
            }

            var right = x + 1
            while right < width, alpha(x: right, y: y) > alphaThreshold {
                thickness += 1
                right += 1
            }

            return thickness
        }

        func markVerticalBand(x: Int, y: Int) {
            var up = y
            var steps = 0
            while up >= 0, alpha(x: x, y: up) > alphaThreshold, steps < maxThickness {
                removeMask[pixelIndex(x: x, y: up)] = true
                up -= 1
                steps += 1
            }

            var down = y + 1
            steps = 0
            while down < height, alpha(x: x, y: down) > alphaThreshold, steps < maxThickness {
                removeMask[pixelIndex(x: x, y: down)] = true
                down += 1
                steps += 1
            }
        }

        func markHorizontalBand(x: Int, y: Int) {
            var left = x
            var steps = 0
            while left >= 0, alpha(x: left, y: y) > alphaThreshold, steps < maxThickness {
                removeMask[pixelIndex(x: left, y: y)] = true
                left -= 1
                steps += 1
            }

            var right = x + 1
            steps = 0
            while right < width, alpha(x: right, y: y) > alphaThreshold, steps < maxThickness {
                removeMask[pixelIndex(x: right, y: y)] = true
                right += 1
                steps += 1
            }
        }

        for y in 0..<height {
            var x = 0
            while x < width {
                while x < width, alpha(x: x, y: y) <= alphaThreshold { x += 1 }
                let startX = x
                while x < width, alpha(x: x, y: y) > alphaThreshold { x += 1 }
                let endX = x - 1
                guard endX >= startX else { continue }

                let runLength = endX - startX + 1
                let thinXs = (startX...endX).filter { verticalThickness(atX: $0, y: y) <= maxThickness }
                guard runLength >= minLength, thinXs.count >= minLength else { continue }

                for thinX in thinXs {
                    markVerticalBand(x: thinX, y: y)
                }
            }
        }

        for x in 0..<width {
            var y = 0
            while y < height {
                while y < height, alpha(x: x, y: y) <= alphaThreshold { y += 1 }
                let startY = y
                while y < height, alpha(x: x, y: y) > alphaThreshold { y += 1 }
                let endY = y - 1
                guard endY >= startY else { continue }

                let runLength = endY - startY + 1
                let thinYs = (startY...endY).filter { horizontalThickness(atX: x, y: $0) <= maxThickness }
                guard runLength >= minLength, thinYs.count >= minLength else { continue }

                for thinY in thinYs {
                    markHorizontalBand(x: x, y: thinY)
                }
            }
        }

        for index in removeMask.indices where removeMask[index] {
            let offset = index * bytesPerPixel
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }

        guard let cleaned = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cleaned, scale: image.scale, orientation: .up)
    }
    #endif
}

private final class VellixTipTapIconSchemeHandler: NSObject, WKURLSchemeHandler {
    private let logger = Logger(subsystem: "im.lystaria.Vellix", category: "TipTapIconScheme")

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let iconName = iconName(from: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let tintHex = tintHex(from: url)
        let pointSize = pointSize(from: url)
        logger.info("✨ TRACE ICON scheme start icon=\(iconName, privacy: .public) tint=\(tintHex, privacy: .public) size=\(pointSize) url=\(url.absoluteString, privacy: .public)")

        let data: Data
        if let iconData = TipTapEditorIconRenderer.pngData(for: iconName, tintHex: tintHex, pointSize: pointSize) {
            data = iconData
            logger.info("✨ TRACE ICON scheme asset-hit icon=\(iconName, privacy: .public) bytes=\(iconData.count)")
        } else if let fallbackData = TipTapEditorIconRenderer.pngData(for: "sparkle", tintHex: tintHex, pointSize: pointSize) {
            data = fallbackData
            logger.info("✨ TRACE ICON scheme asset-miss fallback=sparkle requested=\(iconName, privacy: .public) bytes=\(fallbackData.count)")
        } else if let transparentData = transparentPNGData() {
            data = transparentData
            logger.info("✨ TRACE ICON scheme transparent-fallback requested=\(iconName, privacy: .public) bytes=\(transparentData.count)")
        } else {
            logger.error("✨ TRACE ICON scheme fail requested=\(iconName, privacy: .public)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        logger.info("✨ TRACE ICON scheme response-summary icon=\(iconName, privacy: .public) \(self.pngDataSummary(data), privacy: .public)")

        let response = URLResponse(
            url: url,
            mimeType: "image/png",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func iconName(from url: URL) -> String? {
        let rawName: String
        if url.host == "asset" {
            rawName = url.pathComponents.dropFirst().joined(separator: "/")
        } else {
            rawName = url.host ?? ""
        }

        let cleanName = rawName
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return cleanName.isEmpty ? nil : cleanName
    }

    private func tintHex(from url: URL) -> String {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let tint = components.queryItems?.first(where: { $0.name == "tint" })?.value,
            !tint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "#ffffff"
        }

        return tint
    }

    private func pointSize(from url: URL) -> CGFloat {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let size = components.queryItems?.first(where: { $0.name == "size" })?.value,
            let value = Double(size)
        else {
            return 22
        }

        return CGFloat(max(96, min(value, 160)))
    }

    private func pngDataForAssetIcon(named name: String, tintHex: String, pointSize: CGFloat) -> Data? {
        #if os(iOS)
        guard let image = UIImage(named: name) else {
            return nil
        }

        let source = croppedTransparentPadding(from: image) ?? image
        return squareTintedPNGData(
            from: source,
            tintColor: UIColor(Color(vellixHex: tintHex)),
            pointSize: pointSize
        )
        #elseif os(macOS)
        guard
            let image = NSImage(named: NSImage.Name(name)),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    private func pngDataSummary(_ data: Data) -> String {
        #if os(iOS)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            return "bytes=\(data.count) decode=failed"
        }

        return alphaSummary(cgImage: cgImage, bytes: data.count)
        #elseif os(macOS)
        guard
            let image = NSImage(data: data),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let cgImage = bitmap.cgImage
        else {
            return "bytes=\(data.count) decode=failed"
        }

        return alphaSummary(cgImage: cgImage, bytes: data.count)
        #else
        return "bytes=\(data.count) decode=unavailable"
        #endif
    }

    private func alphaSummary(cgImage: CGImage, bytes: Int) -> String {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return "bytes=\(bytes) pixels=\(width)x\(height) alpha=empty"
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "bytes=\(bytes) pixels=\(width)x\(height) alpha=unreadable"
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var nonZeroAlpha = 0
        var strongAlpha = 0
        var minAlpha = UInt8.max
        var maxAlpha = UInt8.min
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * bytesPerRow) + (x * bytesPerPixel) + 3]
                minAlpha = min(minAlpha, alpha)
                maxAlpha = max(maxAlpha, alpha)
                guard alpha > 0 else {
                    continue
                }

                nonZeroAlpha += 1
                if alpha > 8 {
                    strongAlpha += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        let bounds: String
        if maxX >= minX, maxY >= minY {
            bounds = "\(minX),\(minY),\(maxX - minX + 1),\(maxY - minY + 1)"
        } else {
            bounds = "none"
        }

        return "bytes=\(bytes) pixels=\(width)x\(height) nonZeroAlpha=\(nonZeroAlpha) strongAlpha=\(strongAlpha) minAlpha=\(minAlpha) maxAlpha=\(maxAlpha) alphaBounds=\(bounds)"
    }

    #if os(iOS)
    private func squareTintedPNGData(from image: UIImage, tintColor: UIColor, pointSize: CGFloat) -> Data? {
        let targetSize = CGSize(width: pointSize, height: pointSize)
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.opaque = false
        rendererFormat.scale = UIScreen.main.scale

        let rendered = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat).image { _ in
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return
            }

            let scale = min(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = CGRect(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )

            tintColor.setFill()
            UIBezierPath(rect: rect).fill()
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }

        return rendered.pngData()
    }

    private func croppedTransparentPadding(from image: UIImage) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let renderScale = max(image.scale, UIScreen.main.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false

        let rendered = UIGraphicsImageRenderer(size: sourceSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: sourceSize))
        }

        guard let cgImage = rendered.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * bytesPerRow) + (x * bytesPerPixel) + 3]
                guard alpha > 4 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: renderScale, orientation: .up)
    }
    #endif

    private func transparentPNGData() -> Data? {
        Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )
    }
}
