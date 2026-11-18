#if os(iOS)
import QuartzCore
import UIKit
import WebKit
import os

/// Observes a cached editor's active host without changing its DOM or scroll position.
@MainActor
final class TipTapRenderRecovery {
    private struct Activation {
        let id = UUID()
        let started = ProcessInfo.processInfo.systemUptime
        let documentID: String
        let parentID: String?
        let previousID: String?
        let previousParentID: String?
        let retained: Bool
        var isParentReturn: Bool { previousParentID == documentID }
    }

    @MainActor
    private final class FrameTarget: NSObject {
        weak var owner: TipTapRenderRecovery?
        init(_ owner: TipTapRenderRecovery) { self.owner = owner; super.init() }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advanceFrame()
        }
    }

    #if DEBUG
    private static let diagnosticsEnabled = true
    #else
    private static let diagnosticsEnabled = false
    #endif
    private static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "EditorRendering")
    private weak var session: TipTapEditorSession?
    private weak var host: UIView?
    private weak var scrollView: UIScrollView?
    private var activation: Activation?
    private var displayLink: CADisplayLink?
    private var scrollObservation: NSKeyValueObservation?
    private var watchdog: Task<Void, Never>?
    private var pendingProbes: Set<UUID> = []
    private var didProbeVisibleHost = false
    private var hasPresentedEditor = false
    private var frameStarted: TimeInterval = 0
    private var lastGeometry = ""
    private var stableFrames = 0
    private var lastWaitReason = ""
    private var lastLayout = ""
    private var eventCount = 0
    private var scrollSamples = 0
    private var lastScrollSample: TimeInterval = 0
    private var probedUserScroll = false

    init(session: TipTapEditorSession) { self.session = session }

    func activate(documentID: String, parentID: String?, previousID: String?, previousParentID: String?,
                  scrollView: UIScrollView?) {
        guard Self.diagnosticsEnabled else { return }
        guard activation == nil else {
            if let scrollView { attachScrollView(scrollView) }
            startFramesIfNeeded()
            return
        }
        activation = Activation(documentID: documentID, parentID: parentID,
            previousID: previousID, previousParentID: previousParentID, retained: hasPresentedEditor)
        eventCount = 0
        didProbeVisibleHost = false
        lastGeometry = ""
        stableFrames = 0
        lastWaitReason = ""
        lastLayout = ""
        scrollSamples = 0
        lastScrollSample = 0
        probedUserScroll = false
        record("activation", ["os": UIDevice.current.systemVersion,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"])
        if let scrollView { attachScrollView(scrollView) }
        startFramesIfNeeded()
        guard Self.diagnosticsEnabled, let id = activation?.id else { return }
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.activation?.id == id else { return }
            self.record("activation-checkpoint", ["pendingProbes": self.pendingProbes.count,
                "pendingProbeIDs": self.pendingProbes.map(\.uuidString).sorted()])
            do { try await Task.sleep(for: .seconds(58)) } catch { return }
            guard self.activation?.id == id else { return }
            self.record("observation-window-ended", ["pendingProbes": self.pendingProbes.count])
            self.scrollObservation?.invalidate()
            self.scrollObservation = nil
        }
    }

    func deactivate(reason: String) {
        guard activation != nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        record("deactivation", ["reason": reason, "pendingProbes": pendingProbes.count])
        watchdog?.cancel()
        watchdog = nil
        scrollObservation?.invalidate()
        scrollObservation = nil
        pendingProbes.removeAll()
        activation = nil
    }

    func attachScrollView(_ view: UIScrollView) {
        guard Self.diagnosticsEnabled, session?.tagNavigationWebView?.isDescendant(of: view) == true else { return }
        let changed = scrollView !== view
        scrollView = view
        guard let activation, ProcessInfo.processInfo.systemUptime - activation.started < 60, Self.diagnosticsEnabled,
              changed || scrollObservation == nil else { return }
        let id = activation.id
        scrollObservation?.invalidate()
        record("outer-scroll-attached")
        scrollObservation = view.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
            let offset = view.contentOffset
            let user = view.isTracking || view.isDragging || view.isDecelerating
            let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.activation?.id == id, self.scrollView === view else { return }
                self.observedScroll(offset: offset, user: user, timestamp: timestamp)
            }
        }
    }

    func hostEvent(_ event: String, container: UIView, ownsHost: Bool) {
        if ownsHost && event == "host-claimed" {
            if host !== container { didProbeVisibleHost = false }
            host = container
            attachOuterScrollView(from: container)
            startFramesIfNeeded()
        }
        record(event, ["eventHost": ObjectIdentifier(container).debugDescription, "ownsHost": ownsHost])
    }

    func hostDidLayout(container: UIView, ownsHost: Bool) {
        guard ownsHost, host === container else { return }
        attachOuterScrollView(from: container)
        startFramesIfNeeded()
        guard Self.diagnosticsEnabled, let activation,
              ProcessInfo.processInfo.systemUptime - activation.started < 2,
              let webView = session?.tagNavigationWebView else { return }
        let signature = "\(webView.bounds):\(webView.window != nil):\(webView.superview === host):\(session?.isPresentationReady == true)"
        guard signature != lastLayout else { return }
        lastLayout = signature
        record("host-layout")
    }

    private func attachOuterScrollView(from container: UIView) {
        guard Self.diagnosticsEnabled else { return }
        var ancestor = container.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { attachScrollView(scroll); return }
            ancestor = view.superview
        }
    }

    private func startFramesIfNeeded() {
        guard Self.diagnosticsEnabled, let activation, !didProbeVisibleHost, displayLink == nil,
              ProcessInfo.processInfo.systemUptime - activation.started < 60,
              let host, host.window != nil, session?.tagNavigationWebView?.superview === host else { return }
        frameStarted = ProcessInfo.processInfo.systemUptime
        lastGeometry = ""
        stableFrames = 0
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func record(_ event: String, _ extra: @autoclosure () -> [String: Any] = [:]) {
        guard Self.diagnosticsEnabled, let session else { return }
        if eventCount >= 160 {
            if eventCount == 160 {
                eventCount += 1
                Self.logger.notice("[Penned Render] ts=\(Int64(Date().timeIntervalSince1970 * 1_000), privacy: .public) render=\(self.activation?.id.uuidString ?? "-", privacy: .public) event=diagnostic-budget-reached")
            }
            return
        }
        eventCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let documentID = activation?.documentID ?? session.renderingDocumentID ?? "-"
        var fields = extra()
        fields["native"] = nativeState()
        fields["readiness"] = session.openingReadinessState(for: documentID)
        fields["from"] = fields["from"] ?? activation?.previousID ?? "-"
        fields["targetParent"] = fields["targetParent"] ?? activation?.parentID ?? "-"
        fields["sourceParent"] = fields["sourceParent"] ?? activation?.previousParentID ?? "-"
        fields["parentReturn"] = activation?.isParentReturn ?? false
        fields["retained"] = activation?.retained ?? false
        let elapsed = Int((now - (activation?.started ?? now)) * 1_000)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) }
        catch {
            Self.logger.error("[Penned Render] ts=\(timestamp, privacy: .public) document=\(documentID, privacy: .public) event=log-encoding-failed originalEvent=\(event, privacy: .public) error=\(PennedDocumentOpenTrace.errorCode(error), privacy: .public)")
            return
        }
        let detail = String(decoding: data, as: UTF8.self)
        Self.logger.notice("[Penned Render] ts=\(timestamp, privacy: .public) uptimeMS=\(Int64(now * 1_000), privacy: .public) render=\(self.activation?.id.uuidString ?? "-", privacy: .public) request=\(session.openingTrace?.requestID?.uuidString ?? "-", privacy: .public) document=\(documentID, privacy: .public) event=\(event, privacy: .public) elapsedMS=\(elapsed, privacy: .public) \(detail, privacy: .public)")
    }

    private func advanceFrame() {
        guard activation != nil, let session, session.ownsEditorPresentation?() == true else {
            stopFrames()
            return
        }
        let reason = waitReason()
        if let reason {
            if reason != lastWaitReason { record("visible-probe-waiting", ["reason": reason]); lastWaitReason = reason }
            if ProcessInfo.processInfo.systemUptime - frameStarted > 1.5 {
                record("visible-probe-deferred", ["reason": reason])
                probeDOM(reason: "visible-probe-deferred")
                probeAnimationFrames()
                stopFrames()
            }
            return
        }
        guard let webView = session.tagNavigationWebView else { return }
        let geometry = "\(webView.bounds):\(webView.convert(webView.bounds, to: webView.window))"
        stableFrames = geometry == lastGeometry ? stableFrames + 1 : 0
        lastGeometry = geometry
        guard stableFrames >= 1 else {
            if ProcessInfo.processInfo.systemUptime - frameStarted > 1.5 {
                record("visible-probe-deferred", ["reason": "layout-kept-changing"])
                probeDOM(reason: "visible-probe-deferred")
                stopFrames()
            }
            return
        }
        didProbeVisibleHost = true
        hasPresentedEditor = true
        record("visible-layout-settled", ["hierarchy": hierarchy(webView), "layers": layers(webView)])
        probeDOM(reason: "visible-layout-settled")
        probeAnimationFrames()
        stopFrames()
    }

    private func stopFrames() { displayLink?.invalidate(); displayLink = nil }

    private func waitReason() -> String? {
        guard let session else { return "session-released" }
        guard session.isReady else { return "bridge-not-ready" }
        guard !session.isLoadingDocument else { return "document-loading" }
        guard session.isPresentationReady else { return "presentation-not-ready" }
        guard let activation, session.hasLoadedDocument(activation.documentID) else { return "target-document-not-loaded" }
        guard let webView = session.tagNavigationWebView, webView.superview != nil else { return "webview-detached" }
        guard webView.superview === host else { return "host-does-not-own-webview" }
        guard webView.window != nil else { return "webview-not-in-window" }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return "webview-bounds-zero" }
        guard !isHidden(webView) else { return "ancestor-hidden-or-transparent" }
        guard !visibleRect(webView).isEmpty else { return "webview-clipped-outside-window" }
        return nil
    }

    private func observedScroll(offset: CGPoint, user: Bool, timestamp: Int64) {
        guard let activation, ProcessInfo.processInfo.systemUptime - activation.started < 60, scrollSamples < 18 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard user && !probedUserScroll || now - lastScrollSample > 0.25 else { return }
        scrollSamples += 1
        lastScrollSample = now
        record("outer-scroll-event", ["observedAtMS": timestamp, "observedOffset": NSCoder.string(for: offset),
            "source": user ? "user" : "programmatic-or-restoration"])
        if user && !probedUserScroll {
            probedUserScroll = true
            if let webView = session?.tagNavigationWebView {
                record("first-user-scroll", ["hierarchy": hierarchy(webView), "layers": layers(webView)])
            }
            probeDOM(reason: "first-user-scroll")
            probeAnimationFrames()
        }
    }

    private func probeDOM(reason: String) {
        guard Self.diagnosticsEnabled, let activation, let webView = session?.tagNavigationWebView else { return }
        let probe = UUID()
        pendingProbes.insert(probe)
        record("dom-probe-start", ["probe": probe.uuidString, "reason": reason])
        let clip = webView.window.map { webView.convert(visibleRect(webView), from: $0) } ?? .zero
        let arguments: [String: Any] = ["nativeWidth": Double(webView.bounds.width),
            "nativeViewport": ["x": Double(clip.minX), "y": Double(clip.minY),
                "width": Double(clip.width), "height": Double(clip.height)]]
        webView.callAsyncJavaScript(TipTapBlockRenderDiagnostics.script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard self.activation?.id == activation.id else { self.record("probe-discarded", ["probe": probe.uuidString, "expectedRender": activation.id.uuidString, "reason": "activation-ended-or-replaced"]); return }
            self.pendingProbes.remove(probe)
            switch result {
            case .success(let value):
                var report = value as? [String: Any] ?? [:]
                let blocks = report.removeValue(forKey: "blockSamples") as? [[String: Any]] ?? []
                self.record("dom-probe-result", ["probe": probe.uuidString, "reason": reason, "dom": report])
                for block in blocks.prefix(24) {
                    self.record("block-render", ["probe": probe.uuidString, "reason": reason, "block": block])
                }
            case .failure(let error):
                self.record("dom-probe-failed", ["probe": probe.uuidString, "reason": reason,
                    "error": PennedDocumentOpenTrace.errorCode(error)])
            }
        }
    }

    private func probeAnimationFrames() {
        guard Self.diagnosticsEnabled, let activation, let webView = session?.tagNavigationWebView else { return }
        let probe = UUID()
        pendingProbes.insert(probe)
        record("animation-frame-probe-start", ["probe": probe.uuidString])
        webView.callAsyncJavaScript("const start = performance.now(); await new Promise(resolve => requestAnimationFrame(resolve)); const first = performance.now(); await new Promise(resolve => requestAnimationFrame(resolve)); return {firstFrameMS:first-start, secondFrameMS:performance.now()-start, visibility:document.visibilityState};",
            arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard self.activation?.id == activation.id else { self.record("probe-discarded", ["probe": probe.uuidString, "expectedRender": activation.id.uuidString, "reason": "activation-ended-or-replaced"]); return }
            self.pendingProbes.remove(probe)
            switch result {
            case .success(let value): self.record("animation-frame-probe-result", ["probe": probe.uuidString, "result": value])
            case .failure(let error): self.record("animation-frame-probe-failed", ["probe": probe.uuidString, "error": PennedDocumentOpenTrace.errorCode(error)])
            }
        }
    }

    private func nativeState() -> [String: Any] {
        guard let webView = session?.tagNavigationWebView else { return ["webView": "nil"] }
        var state: [String: Any] = ["webView": ObjectIdentifier(webView).debugDescription,
            "host": host.map { ObjectIdentifier($0).debugDescription } ?? "-", "hostAttached": host != nil && webView.superview === host,
            "window": webView.window != nil, "bounds": NSCoder.string(for: webView.bounds),
            "visibleWindowRect": NSCoder.string(for: visibleRect(webView)), "hiddenInHierarchy": isHidden(webView),
            "presentationHiddenInHierarchy": isHidden(webView, includingPresentation: true),
            "internalOffset": NSCoder.string(for: webView.scrollView.contentOffset),
            "internalContentSize": NSCoder.string(for: webView.scrollView.contentSize),
            "height": session?.editorContentHeight ?? 0, "visualBottom": session?.editorVisualContentBottom ?? 0,
            "bridgeError": session?.bridgeErrorMessage != nil, "editing": session?.isEditing ?? false,
            "selectionMode": session?.selectionMode ?? "-", "selectedBlocks": session?.selectedBlockCount ?? 0,
            "placeholderMode": session?.placeholderMode ?? false]
        state["contentSubviews"] = webView.scrollView.subviews.prefix(8).map {
            ["type": NSStringFromClass(type(of: $0)), "frame": NSCoder.string(for: $0.frame),
             "hidden": $0.isHidden, "alpha": $0.alpha] as [String: Any]
        }
        if let window = webView.window {
            state["windowID"] = ObjectIdentifier(window).debugDescription
            state["frameInWindow"] = NSCoder.string(for: webView.convert(webView.bounds, to: window))
        }
        if let scrollView {
            state["outerScroll"] = ["id": ObjectIdentifier(scrollView).debugDescription,
                "offset": NSCoder.string(for: scrollView.contentOffset), "bounds": NSCoder.string(for: scrollView.bounds),
                "contentSize": NSCoder.string(for: scrollView.contentSize), "insets": NSCoder.string(for: scrollView.adjustedContentInset),
                "tracking": scrollView.isTracking, "dragging": scrollView.isDragging, "decelerating": scrollView.isDecelerating,
                "webViewIsDescendant": webView.isDescendant(of: scrollView)]
        }
        return state
    }

    private func visibleRect(_ view: UIView) -> CGRect {
        guard let window = view.window else { return .zero }
        var rect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: window)) }
            ancestor = current.superview
        }
        return rect.isNull ? .zero : rect
    }

    private func isHidden(_ view: UIView, includingPresentation: Bool = false) -> Bool {
        var candidate: UIView? = view
        while let current = candidate {
            if current.isHidden || current.alpha <= 0.01 { return true }
            candidate = current.superview
        }
        var layer: CALayer? = view.layer
        while let current = layer {
            if current.isHidden || current.opacity <= 0.01 { return true }
            if includingPresentation && (current.presentation()?.opacity ?? current.opacity) <= 0.01 { return true }
            layer = current.superlayer
        }
        return false
    }

    private func hierarchy(_ view: UIView) -> [[String: Any]] {
        Array(sequence(first: view, next: { $0.superview }).prefix(12)).map {
            ["type": NSStringFromClass(type(of: $0)), "bounds": NSCoder.string(for: $0.bounds),
             "frame": NSCoder.string(for: $0.frame), "alpha": $0.alpha, "hidden": $0.isHidden, "clips": $0.clipsToBounds,
             "layerOpacity": $0.layer.opacity, "presentationOpacity": $0.layer.presentation()?.opacity ?? $0.layer.opacity]
        }
    }

    private func layers(_ view: UIView) -> [[String: Any]] {
        Array(sequence(first: view.layer, next: { $0.superlayer }).prefix(12)).map {
            ["type": NSStringFromClass(type(of: $0)), "bounds": NSCoder.string(for: $0.bounds),
             "frame": NSCoder.string(for: $0.frame), "opacity": $0.opacity, "hidden": $0.isHidden,
             "clips": $0.masksToBounds, "presentationOpacity": $0.presentation()?.opacity ?? $0.opacity]
        }
    }

}
#endif
