#if os(iOS)
import QuartzCore
import UIKit
import WebKit

nonisolated struct MobileBlockSelectionDrag {
    let token: Int
    let revision: Int
    let active: Bool
    let point: CGPoint
    let screenY: CGFloat
    let direction: Int
    let distance: CGFloat

    init?(payload: [String: Any]) {
        guard let token = payload["token"] as? Int, token > 0,
              let active = payload["active"] as? Bool else { return nil }
        self.token = token
        self.active = active
        if active {
            guard let revision = payload["revision"] as? Int, revision >= 0,
                  let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                  let screenY = payload["screenY"] as? Double,
                  let direction = payload["direction"] as? Int, direction == 1 || direction == -1,
                  let distance = payload["distance"] as? Double, distance > 0,
                  [x, y, screenY, distance].allSatisfy(\.isFinite) else { return nil }
            self.revision = revision
            point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            self.screenY = CGFloat(screenY)
            self.direction = direction
            self.distance = CGFloat(distance)
        } else {
            revision = 0
            point = .zero
            screenY = 0
            direction = 0
            distance = 0
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
    private var lastScreenY: CGFloat?
    private var velocity: CGFloat = 0
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
        guard drag.revision > revision else { return }
        self.scrollView = scrollView
        self.webView = webView
        self.canScroll = canScroll
        revision = drag.revision
        if let lastScreenY {
            // A local touch point can arrive after the native scroll view has
            // moved again. Once anchored, track the finger in screen space.
            fingerInWindow.y += drag.screenY - lastScreenY
        } else {
            fingerInWindow = webView.convert(drag.point, to: window)
        }
        lastScreenY = drag.screenY
        let viewport = scrollView.convert(scrollView.bounds, to: window)
            .intersection(window.bounds.inset(by: window.safeAreaInsets))
        let edgeZone: CGFloat = 48
        let edgeDistance = drag.direction > 0 ? viewport.maxY - fingerInWindow.y : fingerInWindow.y - viewport.minY
        guard !viewport.isEmpty, edgeDistance < edgeZone else {
            // In the middle of the page the finger, not a timer, extends the range.
            velocity = 0
            displayLink?.isPaused = true
            previousTimestamp = 0
            return
        }
        let strength = min(1, max(0, (edgeZone - edgeDistance) / edgeZone))
        velocity = CGFloat(drag.direction) * (100 + 800 * strength)
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
        lastScreenY = nil
        velocity = 0
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
        guard velocity != 0 else { link.isPaused = true; return }
        let elapsed = previousTimestamp == 0 ? 1.0 / 60 : min(1.0 / 30, max(0, link.timestamp - previousTimestamp))
        previousTimestamp = link.timestamp
        let insets = scrollView.adjustedContentInset
        let minimum = -insets.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        guard maximum > minimum else { link.isPaused = true; return }
        let offset = scrollView.contentOffset
        let target = min(maximum, max(minimum, offset.y + velocity * CGFloat(elapsed)))
        let direction = velocity > 0 ? 1 : -1
        // Clamping an already overscrolled offset must not move the page
        // opposite to the requested direction.
        if (target - offset.y) * CGFloat(direction) > 0 {
            scrollView.setContentOffset(CGPoint(x: offset.x, y: target), animated: false)
        }
        let point = webView.convert(fingerInWindow, from: window)
        let boundary = direction > 0 && target >= maximum ? "end" : direction < 0 && target <= minimum ? "start" : ""
        // Keep scrolling each frame; coalesce range updates while one is in flight.
        guard !evaluating else { return }
        let generation = self.generation
        let revision = self.revision
        evaluating = true
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.generation == generation else { return }
            do {
                let active = try await webView.callAsyncJavaScript("""
                    return window.PennedBlockSelection?.continueDragScroll({token, revision, y, direction}) === true;
                    """, arguments: ["token": token, "revision": revision, "y": Double(point.y),
                                     "direction": direction], in: nil, contentWorld: .page)
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
