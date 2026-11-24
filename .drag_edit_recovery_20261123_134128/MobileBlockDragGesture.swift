#if os(iOS)
import Combine
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

// UIKit recognizes the hold. JavaScript owns block identity and the shared
// contact decision; native tracking continues after WebKit receives touchcancel.
final class MobileBlockDragGesture: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    weak var webView: WKWebView?
    weak var session: TipTapEditorSession?
    weak var scrollView: UIScrollView?
    var editorIsActive = false {
        didSet { if !editorIsActive { cancelDrag(reason: "editor-inactive") } }
    }
    private final class Contact {
        let token = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        var contactID = "-"
        var armed = false
        var lifted = false
        var recognized = false
        var ended = false
        var cancelled = false
        var closing = false
        var reportedState: UIGestureRecognizer.State?
        var reason = "pending"
        var armTask: Task<Bool, Never>?
        var liftTask: Task<Bool, Never>?
        var competitions = Set<String>()
        let competitors = NSHashTable<UIGestureRecognizer>.weakObjects()
    }
    private var contact: Contact?
    var activeContactToken: String? { contact?.token }
    private var origin = CGPoint.zero
    private var finger = CGPoint.zero
    private var evaluating = false
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var lastPoint: CGPoint?
    private var offset: CGPoint?
    private let feedback = UISelectionFeedbackGenerator()
    private var destination: String?

    init(webView: WKWebView, session: TipTapEditorSession, scrollView: UIScrollView) {
        self.webView = webView; self.session = session; self.scrollView = scrollView
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(recognized(_:)))
        minimumPressDuration = MobileBlockDragAndDrop.holdDuration
        allowableMovement = 18
        numberOfTouchesRequired = 1
        delegate = self
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // Do not hold the document's native scroll pan hostage to a two-second
        // reorder candidate. Movement cancels this pending long press normally.
        scrollView.addGestureRecognizer(self)
    }

    private var enabledForDocument: Bool {
        editorIsActive && session?.acceptsEditorPresentationRequests == true && session?.editingEnabled == true
            && webView?.window?.windowScene?.activationState == .foregroundActive
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let webView, let target = touch.view,
              target === webView || target.isDescendant(of: webView) else { return false }
        let textMultitap = touch.tapCount >= 2 && (session?.selectedBlockCount ?? 0) == 0
        guard enabledForDocument, !textMultitap else {
            session?.recordBlockDrag("native-contact-rejected", token: "-",
                details: "reason=\(textMultitap ? "text-multitap" : "editor-inactive")")
            return false
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let contact else { return false }
        let pan = scrollView?.panGestureRecognizer
        let translation = pan?.translation(in: scrollView) ?? .zero
        let scrolling = (pan?.state == .began || pan?.state == .changed) && hypot(translation.x, translation.y) > allowableMovement
        let allowed = contact.armed && !contact.cancelled && enabledForDocument && !scrolling
        trace("native-hold-completed", contact, "accepted=\(allowed) scrolling=\(scrolling)")
        if !allowed { contact.reason = "hold-not-armed-or-editor-inactive" }
        return allowed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit's event-delivery recognizers are not competing block actions.
        // Let them transport pointer input while our hold is still possible.
        let target = otherGestureRecognizer.view
        let deliversWebInput = webView.map { web in target === web || target?.isDescendant(of: web) == true } == true
            && !(otherGestureRecognizer is UILongPressGestureRecognizer)
        competition("simultaneous-recognition", otherGestureRecognizer, allowed: deliversWebInput || (state == .possible && otherGestureRecognizer is UIPanGestureRecognizer))
        return deliversWebInput || (state == .possible && otherGestureRecognizer is UIPanGestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let target = otherGestureRecognizer.view, let webView else { return false }
        let required = otherGestureRecognizer is UILongPressGestureRecognizer &&
            (target === webView || target.isDescendant(of: webView))
        competition("failure-dependency", otherGestureRecognizer, allowed: required)
        return required
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Reserve native pan/hold actions, not WebKit's input-transport machinery.
        let action = preventedGestureRecognizer === scrollView?.panGestureRecognizer || preventedGestureRecognizer is UILongPressGestureRecognizer
        let allowed = action && super.canPrevent(preventedGestureRecognizer)
        competition("can-prevent", preventedGestureRecognizer, allowed: allowed)
        return allowed
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if state == .possible, preventingGestureRecognizer is UIPanGestureRecognizer {
            // Actual movement still fails the hold through touchesMoved.
            competition("can-be-prevented", preventingGestureRecognizer, allowed: false)
            return false
        }
        if editorIsActive, state == .possible || lifted,
           let webView, let target = preventingGestureRecognizer.view,
           target === webView || target.isDescendant(of: webView) {
            competition("can-be-prevented", preventingGestureRecognizer, allowed: false)
            return false
        }
        let allowed = super.canBePrevented(by: preventingGestureRecognizer)
        competition("can-be-prevented", preventingGestureRecognizer, allowed: allowed)
        return allowed
    }

    private var lifted: Bool { contact?.lifted == true }

    private func competition(_ event: String, _ other: UIGestureRecognizer, allowed: Bool) {
        guard let contact else { return }
        contact.competitors.add(other)
        let name = NSStringFromClass(type(of: other))
        guard contact.competitions.insert("\(event):\(name):\(allowed)").inserted else { return }
        trace("native-competition", contact, "decision=\(event) other=\(name) allowed=\(allowed) otherState=\(Self.stateName(other.state))")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, event.allTouches?.count == 1, enabledForDocument,
              let touch = touches.first, let window = webView?.window else {
            super.touchesBegan(touches, with: event)
            cancelDrag(reason: "invalid-contact")
            return
        }
        origin = touch.location(in: window); finger = origin
        let current = Contact()
        contact = current
        trace("native-contact-start", current, "tapCount=\(touch.tapCount)")
        super.touchesBegan(touches, with: event)
        guard let webView, let args = arguments(token: current.token) else { cancelDrag(reason: "webview-unavailable"); return }
        current.armTask = Task { [weak self, weak session] in
            guard !current.closing else { return false }
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.PennedBlockDragAndDrop?.native('arm', args) ?? {accepted:false, reason:'controller-missing'};",
                    arguments: ["args": args], in: nil, contentWorld: .page) as? [String: Any]
                current.contactID = result?["contactID"] as? String ?? "-"
                let accepted = result?["accepted"] as? Bool == true
                current.armed = accepted
                session?.recordBlockDrag("native-arm-response", token: current.token,
                    details: "contact=\(current.contactID) accepted=\(accepted) reason=\(result?["reason"] as? String ?? "-") owner=\(result?["owner"] as? String ?? "-")")
                if !accepted, let self, self.contact === current, self.state == .possible {
                    current.reason = "javascript-arm-rejected"
                    self.state = .failed
                }
                return accepted
            } catch {
                let failure = error as NSError
                session?.recordBlockDrag("arm-bridge-failed", token: current.token,
                    details: "domain=\(failure.domain) code=\(failure.code)")
                if let self, self.contact === current { self.cancelDrag(reason: "arm-bridge-failed") }
                return false
            }
        }
    }

    @objc private func recognized(_ recognizer: UILongPressGestureRecognizer) {
        guard let current = contact else { return }
        if current.reportedState != state { trace("native-state", current); current.reportedState = state }
        switch state {
        case .began:
            guard !current.recognized else { return }
            current.recognized = true
            current.reason = "reorder"
            session?.blockReorderDidLift.send(())
            feedback.prepare()
            guard let webView, let args = arguments(token: current.token) else { cancelDrag(reason: "lift-webview-unavailable"); return }
            trace("native-lift-request", current)
            // Ownership is already native .began, not conditional on an IPC reply.
            current.liftTask = Task { [weak self, weak session] in
                let accepted = await Self.send("lift", args: args, webView: webView, session: session)
                current.lifted = accepted
                session?.recordBlockDrag("native-lift-response", token: current.token,
                    details: "contact=\(current.contactID) accepted=\(accepted) ended=\(current.ended) cancelled=\(current.cancelled)")
                if !accepted {
                    if let self, self.contact === current { self.cancelDrag(reason: "javascript-lift-rejected") }
                } else if !current.ended, !current.cancelled, let self, self.contact === current {
                    self.webView?.endEditing(true)
                    let target = MobileBlockDragLinkTarget(gesture: self)
                    let link = CADisplayLink(target: target, selector: #selector(MobileBlockDragLinkTarget.step(_:)))
                    self.displayLink = link
                    link.add(to: .main, forMode: .common)
                }
                return accepted
            }
        case .ended: close(current, finish: true, reason: "finger-released")
        case .cancelled: close(current, finish: false, reason: current.reason == "reorder" ? "uikit-cancelled" : current.reason)
        default: break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard event.allTouches?.count == 1, let touch = touches.first, let window = webView?.window else {
            cancelDrag(reason: "additional-touch"); return
        }
        finger = touch.location(in: window)
        if state == .possible, hypot(finger.x - origin.x, finger.y - origin.y) > allowableMovement, let contact {
            contact.reason = "movement-before-hold"
            trace("native-hold-released-to-motion", contact,
                  "dx=\(Int(finger.x - origin.x)) dy=\(Int(finger.y - origin.y))")
            state = .failed
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let window = webView?.window { finger = touch.location(in: window) }
        if let contact, !contact.recognized { contact.reason = "released-before-hold" }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelDrag(reason: "native-touch-cancelled")
        super.touchesCancelled(touches, with: event)
    }

    private func cancelDrag(reason: String) {
        guard let contact else { return }
        contact.reason = reason
        close(contact, finish: false, reason: reason)
        trace("native-cancel", contact, "reason=\(reason)")
        if state == .possible { state = .failed }
        else if state == .began || state == .changed { state = .cancelled }
    }

    private func close(_ current: Contact, finish: Bool, reason: String) {
        guard !current.closing else { return }
        current.closing = true
        current.ended = finish
        current.cancelled = !finish
        displayLink?.invalidate(); displayLink = nil
        guard let webView else { return }
        let coordinates = arguments(token: current.token)
        var args = coordinates ?? ["token": current.token]
        args["reason"] = reason
        args["contactID"] = current.contactID
        let action = finish && coordinates != nil ? "finish" : current.recognized ? "cancelContact" : "releaseHold"
        Task { [weak session] in
            // Release a failed hold immediately, including an arm waiting for
            // DOM delivery. An actual lift must finish before finish/cancel IPC.
            let didLift: Bool
            if current.recognized { didLift = await current.liftTask?.value ?? false }
            else { didLift = false }
            let command = finish && !didLift ? "cancelContact" : action
            let accepted = await Self.send(command, args: args, webView: webView, session: session)
            session?.recordBlockDrag("native-contact-release", token: current.token,
                details: "contact=\(current.contactID) action=\(command) accepted=\(accepted) coordinates=\(coordinates != nil) reason=\(reason)")
        }
    }

    func cancelForLifecycle() { cancelDrag(reason: "application-inactive") }

    func relinquishToSelection(token: String) {
        guard let contact, contact.token == token, state == .possible else { return }
        contact.reason = "selection-committed"
        trace("native-yield-to-selection", contact)
        state = .failed
    }

    private func trace(_ event: String, _ contact: Contact, _ details: String = "") {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - contact.startedAt) * 1000)
        session?.recordBlockDrag(event, token: contact.token,
            details: "contact=\(contact.contactID) elapsedMS=\(elapsed) owner=\(contact.reason) armed=\(contact.armed) state=\(Self.stateName(state)) active=\(enabledForDocument) blocks=\(session?.selectedBlockCount ?? 0) \(details)")
    }

    private static func stateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "unknown-\(state.rawValue)"
        }
    }

    override func reset() {
        if let contact {
            if contact.reason == "pending" { contact.reason = "uikit-reset-without-recognition" }
            trace("native-reset", contact)
            for other in contact.competitors.allObjects where other.state != .possible {
                trace("native-competitor-outcome", contact,
                    "other=\(NSStringFromClass(type(of: other))) otherState=\(Self.stateName(other.state))")
            }
            if !contact.closing { close(contact, finish: false, reason: contact.reason) }
        }
        displayLink?.invalidate(); displayLink = nil
        contact = nil; evaluating = false
        previousTimestamp = 0; lastPoint = nil; destination = nil; offset = nil
        super.reset()
    }

    func reachedDestination(token: String, destination: String) {
        guard let contact, contact.token == token, contact.recognized, !contact.cancelled else { return }
        guard !destination.isEmpty else { self.destination = nil; return }
        guard self.destination != destination else { return }
        self.destination = destination
        feedback.selectionChanged()
        feedback.prepare()
    }

    private func arguments(token: String) -> [String: Any]? {
        guard let webView, let window = webView.window, webView.bounds.width > 0 else { return nil }
        let p = webView.convert(finger, from: window)
        return ["token": token, "x": Double(p.x), "y": Double(p.y), "width": Double(webView.bounds.width)]
    }

    private static func send(_ action: String, args: [String: Any], webView: WKWebView, session: TipTapEditorSession?) async -> Bool {
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.PennedBlockDragAndDrop?.native(action, args) ?? false;",
                arguments: ["action": action, "args": args], in: nil, contentWorld: .page)
            return result as? Bool == true
        } catch {
            let failure = error as NSError
            session?.recordBlockDrag("\(action)-bridge-failed", token: args["token"] as? String ?? "-",
                details: "domain=\(failure.domain) code=\(failure.code)")
            return false
        }
    }

    fileprivate func step(_ link: CADisplayLink) {
        guard let current = contact, current.lifted, enabledForDocument,
              let webView, let scrollView, let window = webView.window else { cancelDrag(reason: "drag-tracking-unavailable"); return }
        let dt = previousTimestamp == 0 ? 1.0 / 60 : min(1.0 / 30, max(0, link.timestamp - previousTimestamp))
        previousTimestamp = link.timestamp
        // Exclude the document's floating top and bottom controls from edge zones.
        var viewport = scrollView.convert(scrollView.bounds, to: window).intersection(window.bounds.inset(by: window.safeAreaInsets))
        viewport.origin.y += 64; viewport.size.height = max(0, viewport.height - 144)
        let zone: CGFloat = 64
        var speed: CGFloat = 0
        if finger.y < viewport.minY + zone { speed = -min(1, max(0, (viewport.minY + zone - finger.y) / zone)) }
        else if finger.y > viewport.maxY - zone { speed = min(1, max(0, (finger.y - viewport.maxY + zone) / zone)) }
        if speed != 0, !viewport.isEmpty {
            let minimum = -scrollView.adjustedContentInset.top
            let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let next = min(maximum, max(minimum, scrollView.contentOffset.y + speed * 850 * CGFloat(dt)))
            if (next - scrollView.contentOffset.y) * speed > 0 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
            }
        }
        let localPoint = webView.convert(finger, from: window)
        guard !evaluating, localPoint != lastPoint || offset != scrollView.contentOffset else { return }
        evaluating = true; lastPoint = localPoint; offset = scrollView.contentOffset
        guard let args = arguments(token: current.token) else { cancelDrag(reason: "move-coordinates-unavailable"); return }
        Task { [weak self] in
            let alive = await Self.send("move", args: args, webView: webView, session: self?.session)
            guard let self, self.contact === current else { return }
            self.evaluating = false
            if !alive { self.cancelDrag(reason: "javascript-drag-ended") }
        }
    }
}

private final class MobileBlockDragLinkTarget: NSObject {
    weak var gesture: MobileBlockDragGesture?
    init(gesture: MobileBlockDragGesture) { self.gesture = gesture }
    @objc func step(_ link: CADisplayLink) { gesture?.step(link) }
}
#endif
