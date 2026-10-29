#if os(iOS)
import QuartzCore
import UIKit
import WebKit

nonisolated struct MobileBlockSelectionDrag {
    let token: Int
    let revision: Int
    let active: Bool
    let point: CGPoint
    let deltaY: CGFloat

    init?(payload: [String: Any]) {
        guard let token = payload["token"] as? Int, token > 0,
              let active = payload["active"] as? Bool else { return nil }
        self.token = token
        self.active = active
        if active {
            guard let revision = payload["revision"] as? Int, revision >= 0,
                  let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                  let delta = payload["deltaY"] as? Double,
                  [x, y, delta].allSatisfy(\.isFinite) else { return nil }
            self.revision = revision
            point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            deltaY = CGFloat(delta)
        } else {
            revision = 0
            point = .zero
            deltaY = 0
        }
    }
}

@MainActor
final class MobileBlockSelectionScrollDriver {
    private weak var scrollView: UIScrollView?
    private weak var webView: WKWebView?
    private var canScroll: (() -> Bool)?
    private var displayLink: CADisplayLink?
    private var token: Int?
    private var revision = 0
    private var generation = 0
    private var fingerInWindow = CGPoint.zero
    private var velocity: CGFloat = 0
    private var dragDistance: CGFloat = 0
    private var previousTimestamp: CFTimeInterval = 0
    private var evaluating = false

    func receive(_ drag: MobileBlockSelectionDrag, scrollView: UIScrollView, webView: WKWebView,
                 canScroll: @escaping () -> Bool) {
        guard drag.active else {
            if token == drag.token { stop() }
            return
        }
        guard let window = webView.window, webView.isDescendant(of: scrollView), canScroll() else {
            stop()
            return
        }
        if token != drag.token || self.webView !== webView || self.scrollView !== scrollView {
            stop()
            token = drag.token
        }
        self.scrollView = scrollView
        self.webView = webView
        self.canScroll = canScroll
        revision = drag.revision
        fingerInWindow = webView.convert(drag.point, to: window)
        if abs(drag.deltaY) > 0.25 {
            let direction: CGFloat = drag.deltaY > 0 ? 1 : -1
            if velocity * direction < 0 { dragDistance = 0 }
            dragDistance += abs(drag.deltaY)
            velocity = direction * min(1440, max(360, dragDistance * 12))
        }
        guard velocity != 0 else { return }
        if let displayLink {
            if displayLink.isPaused { previousTimestamp = 0 }
            displayLink.isPaused = false
        } else {
            let target = MobileSelectionScrollLinkTarget(driver: self)
            let link = CADisplayLink(target: target, selector: #selector(MobileSelectionScrollLinkTarget.step(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    func finish(token: Int) {
        if self.token == token { stop() }
    }

    func stop() {
        generation += 1
        displayLink?.invalidate()
        displayLink = nil
        token = nil
        revision = 0
        velocity = 0
        dragDistance = 0
        previousTimestamp = 0
        evaluating = false
        canScroll = nil
        scrollView = nil
        webView = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        guard let token, let scrollView, let webView, let window = webView.window,
              window.windowScene?.activationState == .foregroundActive,
              webView.isDescendant(of: scrollView), canScroll?() == true else {
            stop()
            return
        }
        let elapsed = previousTimestamp == 0 ? 1.0 / 60 : min(1.0 / 30, max(0, link.timestamp - previousTimestamp))
        previousTimestamp = link.timestamp
        let insets = scrollView.adjustedContentInset
        let minimum = -insets.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        guard maximum > minimum else { link.isPaused = true; return }
        let target = min(maximum, max(minimum, scrollView.contentOffset.y + velocity * CGFloat(elapsed)))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
        let point = webView.convert(fingerInWindow, from: window)
        let boundary = velocity > 0 && target >= maximum ? "end" : velocity < 0 && target <= minimum ? "start" : ""
        // Keep scrolling each frame; coalesce range updates while one is in flight.
        guard !evaluating else { return }
        let generation = self.generation
        let revision = self.revision
        evaluating = true
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.generation == generation else { return }
            do {
                let active = try await webView.callAsyncJavaScript("""
                    return window.PennedBlockSelection?.continueDragScroll({token, revision, y, boundary}) === true;
                    """, arguments: ["token": token, "revision": revision, "y": Double(point.y), "boundary": boundary], in: nil, contentWorld: .page)
                guard self.generation == generation else { return }
                self.evaluating = false
                if active as? Bool != true { self.stop() }
                else if !boundary.isEmpty, self.revision == revision { self.displayLink?.isPaused = true }
            } catch {
                if self.generation == generation { self.stop() }
            }
        }
    }
}

@MainActor
private final class MobileSelectionScrollLinkTarget: NSObject {
    weak var driver: MobileBlockSelectionScrollDriver?
    init(driver: MobileBlockSelectionScrollDriver) { self.driver = driver }
    @objc func step(_ link: CADisplayLink) {
        guard let driver else { link.invalidate(); return }
        driver.step(link)
    }
}
#endif
