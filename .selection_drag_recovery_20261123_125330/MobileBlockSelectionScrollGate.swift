#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

// WebKit's touch-action rules do not govern the enclosing native ScrollView.
// Reserve its pan only for selection drags; never cancel delivery to the editor.
final class MobileBlockSelectionScrollGate: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var webView: WKWebView?
    weak var session: TipTapEditorSession?
    weak var scrollPan: UIPanGestureRecognizer?
    var editorIsActive = false
    private var origin = CGPoint.zero
    private var movement = CGPoint.zero
    private var startsSelected: Bool?
    private var contact = UUID()
    private var dragToken = "-"
    private var startedAt: TimeInterval = 0
    private var lookup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(webView: WKWebView, session: TipTapEditorSession, scrollView: UIScrollView) {
        self.webView = webView
        self.session = session
        self.scrollPan = scrollView.panGestureRecognizer
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        scrollView.addGestureRecognizer(self)
        scrollView.panGestureRecognizer.require(toFail: self)
    }

    private var canSelect: Bool {
        editorIsActive && session?.acceptsEditorPresentationRequests == true && session?.editingEnabled == true
            && session?.isLoadingDocument == false && webView?.window != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard canSelect, let webView, let target = touch.view else { return false }
        return target === webView || target.isDescendant(of: webView)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventedGestureRecognizer === scrollPan
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touches.count == 1, (event.allTouches?.count ?? 1) == 1, canSelect,
              let touch = touches.first, let webView, webView.bounds.width > 0 else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        origin = touch.location(in: webView)
        dragToken = session?.blockDragGesture?.activeContactToken ?? contact.uuidString
        startedAt = ProcessInfo.processInfo.systemUptime
        trace("contact")
        let token = contact
        let width = webView.bounds.width
        let point = origin
        lookup = Task { [weak self, weak webView] in
            guard let webView else { return }
            let result = try? await webView.callAsyncJavaScript("""
                return window.PennedBlockSelection?.classifyContactAtPoint({ x, y, width }) ?? { eligible: false };
                """, arguments: ["x": Double(point.x), "y": Double(point.y), "width": Double(width)],
                in: nil, contentWorld: .page)
            guard !Task.isCancelled, let self, self.contact == token, self.state == .possible else { return }
            self.deadline?.cancel()
            guard self.canSelect, let classification = result as? [String: Any], classification["eligible"] as? Bool == true else {
                self.trace("lookup-rejected"); self.state = .failed; return
            }
            self.startsSelected = classification["selected"] as? Bool == true
            self.trace("classified")
            self.resolveMovement()
        }
        // A stopped web process must not leave the native pan waiting indefinitely.
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.contact == token, self.state == .possible,
                  self.startsSelected == nil else { return }
            self.trace("lookup-timeout"); self.state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard (event.allTouches?.count ?? 1) == 1, let touch = touches.first, let webView else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        let point = touch.location(in: webView)
        movement = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if state == .possible { resolveMovement() }
        else if state == .began || state == .changed { state = .changed }
    }

    private func resolveMovement() {
        guard let startsSelected else { return }
        let dx = abs(movement.x), dy = abs(movement.y)
        if max(dx, dy) >= 8, ProcessInfo.processInfo.systemUptime - startedAt > 0.32 {
            trace("late-motion-yields-to-scroll"); state = .failed; return
        }
        if startsSelected {
            // A stationary selected block is still eligible for the two-second
            // lift. Reserve range scrolling only after actual range movement.
            if dy >= 8 && dy > dx * 1.1 { trace("range-motion"); state = .began }
            else if movement.x <= -6 && dx > dy * 1.8 { trace("left-swipe-motion"); state = .began }
            return
        }
        // Match the existing JS pending-gesture direction thresholds. This only
        // arbitrates native scrolling; selection and range tracking remain in JS.
        if dy >= 10 || (dy >= 8 && dy >= dx / 1.8) { trace("yield-to-scroll"); state = .failed }
        else if movement.x <= -6 && dx > dy * 1.8 { trace("left-swipe-motion"); state = .began }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if state == .possible { state = .failed }
        else if state == .began || state == .changed { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .possible { state = .failed }
        else if state == .began || state == .changed { state = .cancelled }
    }

    override func reset() {
        if startedAt > 0 { trace("reset") }
        lookup?.cancel(); deadline?.cancel()
        lookup = nil; deadline = nil
        contact = UUID(); startsSelected = nil; movement = .zero
        dragToken = "-"; startedAt = 0
        super.reset()
    }

    private func trace(_ event: String) {
        session?.recordBlockDrag("scroll-gate-\(event)", token: dragToken,
            details: "gate=\(contact.uuidString) state=\(state.rawValue) selected=\(startsSelected.map { String($0) } ?? "unknown") elapsedMS=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
    }
}
#endif
