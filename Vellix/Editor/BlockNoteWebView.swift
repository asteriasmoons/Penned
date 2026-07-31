//
//  BlockNoteWebView.swift
//  Vellix
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers
import os

struct BlockNoteWebView {
    @ObservedObject var session: EditorSession
    var documentID: String?
    var canonicalJSON: String

    init(
        session: EditorSession,
        documentID: String?,
        canonicalJSON: String
    ) {
        self.session = session
        self.documentID = documentID
        self.canonicalJSON = canonicalJSON
    }
}

#if os(iOS)

extension BlockNoteWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(
        context: Context
    ) -> WKWebView {
        makeWebView(
            coordinator: context.coordinator
        )
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        scheduleSessionLoad(webView)
    }

    static func dismantleUIView(
        _ webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.cleanUp(webView)
    }
}

#elseif os(macOS)

extension BlockNoteWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(
        context: Context
    ) -> WKWebView {
        makeWebView(
            coordinator: context.coordinator
        )
    }

    func updateNSView(
        _ webView: WKWebView,
        context: Context
    ) {
        scheduleSessionLoad(webView)
    }

    static func dismantleNSView(
        _ webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.cleanUp(webView)
    }
}

#endif

private extension BlockNoteWebView {
    func scheduleSessionLoad(_ webView: WKWebView) {
        let session = session
        let documentID = documentID
        let canonicalJSON = canonicalJSON

        Task { @MainActor in
            await Task.yield()
            session.attach(webView: webView)
            if let documentID {
                session.load(
                    documentID: documentID,
                    canonicalJSON: canonicalJSON
                )
            }
        }
    }

    func makeWebView(
        coordinator: Coordinator
    ) -> WKWebView {
        guard let editorBundleURL = Bundle.main.url(
            forResource: "VellixEditor",
            withExtension: "bundle"
        ) else {
            coordinator.logError("VellixEditor.bundle was not found.")

            return WKWebView()
        }

        let schemeHandler = VellixEditorSchemeHandler(
            editorBundleURL: editorBundleURL
        )

        coordinator.schemeHandler = schemeHandler

        let contentController =
            WKUserContentController()

        contentController.add(
            coordinator,
            name: "vellixEditor"
        )

        let configuration = WKWebViewConfiguration()

        configuration.userContentController =
            contentController

        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: "vellix-editor"
        )

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.navigationDelegate = coordinator
        let session = coordinator.session
        Task { @MainActor in
            await Task.yield()
            session.attach(webView: webView)
        }

        #if os(iOS)

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.inputAssistantItem.leadingBarButtonGroups = []
        webView.inputAssistantItem.trailingBarButtonGroups = []
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.bouncesZoom = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.delegate = coordinator

        #elseif os(macOS)

        webView.setValue(
            false,
            forKey: "drawsBackground"
        )

        #endif

        guard let editorURL = URL(
            string: "vellix-editor://app/index.html"
        ) else {
            print(
                "Vellix editor URL could not be created."
            )

            return webView
        }

        coordinator.logInfo("Loading Vellix editor from \(editorURL.absoluteString)")

        webView.load(
            URLRequest(url: editorURL)
        )

        return webView
    }
}

// MARK: - Native Bridge Coordinator

final class Coordinator:
    NSObject,
    WKScriptMessageHandler,
    WKNavigationDelegate
{
    let session: EditorSession
    var schemeHandler:
        VellixEditorSchemeHandler?
    private let logger = Logger(subsystem: "im.lystaria.Vellix", category: "BlockNoteWebView")

    init(session: EditorSession) {
        self.session = session
    }

    func userContentController(
        _ userContentController:
            WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "vellixEditor" else {
            return
        }

        guard message.body is [String: Any] else {
            logError("Vellix received an invalid editor message.")
            return
        }

        session.handleRawMessage(message.body)
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        logInfo("Vellix editor page finished loading")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        logError("Vellix editor navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation:
            WKNavigation!,
        withError error: Error
    ) {
        session.markNavigationStarted()
        logError("Vellix editor failed to begin loading: \(error.localizedDescription)")
    }

    func cleanUp(
        _ webView: WKWebView
    ) {
        webView.configuration
            .userContentController
            .removeScriptMessageHandler(
                forName: "vellixEditor"
            )

        webView.navigationDelegate = nil
        #if os(iOS)
        webView.scrollView.delegate = nil
        #endif
        schemeHandler = nil
    }

    func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

#if os(iOS)
extension Coordinator: UIScrollViewDelegate {
    func viewForZooming(
        in scrollView: UIScrollView
    ) -> UIView? {
        nil
    }
}
#endif

// MARK: - Bundled Editor File Server

final class VellixEditorSchemeHandler:
    NSObject,
    WKURLSchemeHandler
{
    private let editorBundleURL: URL

    init(
        editorBundleURL: URL
    ) {
        self.editorBundleURL =
            editorBundleURL
    }

    func webView(
        _ webView: WKWebView,
        start urlSchemeTask: WKURLSchemeTask
    ) {
        guard let requestURL =
                urlSchemeTask.request.url
        else {
            fail(
                task: urlSchemeTask,
                message:
                    "The editor request had no URL."
            )

            return
        }

        guard let relativePath =
                sanitizedRelativePath(
                    from: requestURL
                )
        else {
            fail(
                task: urlSchemeTask,
                message:
                    "The requested editor path was invalid."
            )

            return
        }

        let fileURL = editorBundleURL
            .appendingPathComponent(
                relativePath
            )

        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            fail(
                task: urlSchemeTask,
                message:
                    "Editor file was not found: \(relativePath)"
            )

            return
        }

        do {
            let data = try Data(
                contentsOf: fileURL,
                options: .mappedIfSafe
            )

            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(
                    for: fileURL
                ),
                expectedContentLength:
                    data.count,
                textEncodingName:
                    textEncodingName(
                        for: fileURL
                    )
            )

            urlSchemeTask.didReceive(
                response
            )

            urlSchemeTask.didReceive(
                data
            )

            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(
                error
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        stop urlSchemeTask: WKURLSchemeTask
    ) {
        // Nothing to cancel yet.
    }

    private func sanitizedRelativePath(
        from url: URL
    ) -> String? {
        var path = url.path

        if path.hasPrefix("/") {
            path.removeFirst()
        }

        if path.isEmpty {
            path = "index.html"
        }

        let decodedPath =
            path.removingPercentEncoding
            ?? path

        guard
            !decodedPath.contains(".."),
            !decodedPath.hasPrefix("/")
        else {
            return nil
        }

        return decodedPath
    }

    private func mimeType(
        for fileURL: URL
    ) -> String {
        if
            let type = UTType(
                filenameExtension:
                    fileURL.pathExtension
            ),
            let mimeType =
                type.preferredMIMEType
        {
            return mimeType
        }

        switch fileURL
            .pathExtension
            .lowercased()
        {
        case "html":
            return "text/html"

        case "css":
            return "text/css"

        case "js":
            return "text/javascript"

        case "json":
            return "application/json"

        case "woff":
            return "font/woff"

        case "woff2":
            return "font/woff2"

        case "svg":
            return "image/svg+xml"

        default:
            return "application/octet-stream"
        }
    }

    private func textEncodingName(
        for fileURL: URL
    ) -> String? {
        switch fileURL
            .pathExtension
            .lowercased()
        {
        case "html",
             "css",
             "js",
             "json",
             "svg":
            return "utf-8"

        default:
            return nil
        }
    }

    private func fail(
        task: WKURLSchemeTask,
        message: String
    ) {
        print(message)

        let error = NSError(
            domain: "VellixEditor",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    message
            ]
        )

        task.didFailWithError(error)
    }
}
