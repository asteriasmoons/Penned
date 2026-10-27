import AppKit
import WebKit

@MainActor
final class MacDocumentScrollBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?

    static func install(on webView: WKWebView) {
        let bridge = MacDocumentScrollBridge()
        bridge.webView = webView
        let controller = webView.configuration.userContentController
        controller.add(bridge, name: "pennedMacDocumentScroll")
        controller.addUserScript(WKUserScript(source: wheelScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView, webView.window != nil,
              let scroll = webView.enclosingScrollView, let document = scroll.documentView,
              let payload = message.body as? [String: Any], let delta = payload["deltaY"] as? Double,
              delta.isFinite, let mode = payload["deltaMode"] as? Int else { return }
        let clip = scroll.contentView
        let unit: CGFloat = mode == 1 ? 16 : mode == 2 ? clip.bounds.height : 1
        var bounds = clip.bounds
        bounds.origin.y += CGFloat(delta) * unit * (document.isFlipped ? 1 : -1)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // WebKit owns pointer input, but the native document ScrollView owns page scrolling.
    // Leave nested scrollable blocks and horizontal gestures with their existing handlers.
    static let wheelScript = """
    (() => {
        window.addEventListener('wheel', event => {
            if (event.defaultPrevented || event.ctrlKey || event.shiftKey || !event.cancelable ||
                !Number.isFinite(event.deltaY) || event.deltaY === 0 ||
                Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
            for (const element of event.composedPath()) {
                if (!(element instanceof Element) || element === document.body ||
                    element === document.documentElement) continue;
                const style = getComputedStyle(element);
                if (!/^(auto|scroll|overlay)$/.test(style.overflowY) ||
                    element.scrollHeight <= element.clientHeight + 1) continue;
                if ((event.deltaY < 0 && element.scrollTop > 0) ||
                    (event.deltaY > 0 && element.scrollTop + element.clientHeight < element.scrollHeight - 1)) return;
            }
            const handler = window.webkit?.messageHandlers?.pennedMacDocumentScroll;
            if (!handler) return;
            event.preventDefault();
            handler.postMessage({deltaY: event.deltaY, deltaMode: event.deltaMode});
        }, {passive: false});
    })();
    """
}
