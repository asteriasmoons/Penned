import SwiftUI
import WebKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class DocumentExportRenderer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var ready: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var host: AnyObject?
    private let assets: DocumentExportAssets
    private let store: AttachmentStore
    private let snapshot: DocumentExportSnapshot
    private let scheme: ColorScheme

    init(snapshot: DocumentExportSnapshot, store: AttachmentStore, scheme: ColorScheme) {
        self.snapshot = snapshot; self.store = store; self.scheme = scheme
        assets = DocumentExportAssets(snapshot: snapshot, store: store)
    }

    func render(format: DocumentExportFormat, settings: DocumentExportSettings, directory: URL,
                progress: @escaping (String) -> Void) async throws -> DocumentExportOutput {
        let image = format == .image, size = image ? settings.imageSize : settings.paper.size
        defer { close() }
        try await start(size: size)
        let pdf = PDFDocument()
        var files: [URL] = [], warnings = snapshot.warnings, imageNumber = 0
        for (pageIndex, page) in snapshot.pages.enumerated() {
            try Task.checkCancellation()
            progress("Rendering \(page.title) (\(pageIndex + 1) of \(snapshot.pages.count))")
            // A fresh isolated DOM for each owned page preserves its individual
            // styling. This does not reload or touch the user's editor.
            if pageIndex > 0 { close(); try await start(size: size) }
            guard let view = self.webView else { throw DocumentExportError.failed("The export renderer closed unexpectedly.") }
            let appearance = settings.useStyle ? page.appearance.resolved(for: scheme) : DocumentAppearance.plain.resolved(for: .light)
            let references = snapshot.contents[page.id]?.children ?? []
            try await command("setAppearance", args: TipTapEditorCommand.setAppearance(appearance, interfaceScheme: scheme).args)
            try await command("setAttachments", args: ["files": snapshot.files.map(\.object)])
            try await command("setPageReferences", args: ["pages": references.map { referencePresentation($0, fontStyle: appearance.fontStyle) }])
            try await command("setCollections", args: ["collections": snapshot.collections(for: page)])
            try await command("setContent", args: ["document": TipTapContentAnalyzer.documentObject(from: page.tipTapJSON)])
            try await command("setEditable", args: ["editable": false])
            let resources = try await view.callAsyncJavaScript(DocumentExportScript.resources, arguments: [:], in: nil, contentWorld: .page) as? [String] ?? []
            var assetURLs: [String: String] = [:]
            for resource in resources {
                try Task.checkCancellation()
                if let url = URL(string: resource), let asset = try assets.asset(for: url) { assetURLs[resource] = asset.dataURL }
            }
            let cover: String
            if settings.showCover && appearance.displaysCover {
                if let path = page.cover, let url = snapshot.assets[path] { cover = try imageDataURL(url) }
                else { cover = png(ThemeCoverArt(theme: appearance.resolvedCoverTheme).frame(width: size.width - 72, height: (size.width - 72) / 1.78)) }
            } else { cover = "" }
            let backdrop = png(DocumentStyleSurface(style: appearance.editorBackground, store: store, theme: appearance.themeID).frame(width: size.width, height: size.height))
            let paperStyle = page.isThemed ? appearance.innerPageBackground : appearance.editorBackground
            let paper = png(DocumentStyleSurface(style: paperStyle, store: store).frame(width: size.width - 36, height: size.height - 36))
            var entryFields: [[String: Any]] = []
            if let context = snapshot.contents[page.id]?.entryContext {
                for field in context.0.fields {
                    let value = context.1.values[field.id] ?? CollectionValue()
                    let chips = field.configuration.options.filter { value.optionIDs.contains($0.id) }
                    entryFields.append(["name": field.name, "text": field.display(value),
                        "icon": TipTapEditorIconRenderer.dataURL(for: field.resolvedIcon, tintHex: appearance.textColorHex) ?? "",
                        "chips": chips.map { ["name": $0.name, "color": $0.color] }])
                }
            }
            let options: [String: Any] = ["width": size.width, "height": size.height, "title": page.title,
                "subtitle": page.subtitle ?? "", "showTitle": settings.showTitle, "showTags": settings.showTags,
                "cover": cover, "icon": page.icon.flatMap { TipTapEditorIconRenderer.dataURL(for: $0, tintHex: appearance.textColorHex) } ?? "",
                "fontFamily": appearance.fontStyle.cssFamily, "textColor": appearance.textColorHex,
                "fontScale": settings.fontSize.scale, "backdrop": backdrop, "paper": paper,
                "entryFields": entryFields, "collections": snapshot.collections(for: page), "assetURLs": assetURLs,
                "watermark": settings.showWatermark, "pageNumbers": settings.showPageNumbers, "image": image]
            let result = try await view.callAsyncJavaScript(DocumentExportScript.prepare, arguments: ["options": options], in: nil, contentWorld: .page)
            guard let layout = result as? [String: Any], let height = layout["height"] as? Double, height.isFinite, height >= 0 else {
                throw DocumentExportError.failed("The document's complete layout could not be measured.")
            }
            warnings += layout["warnings"] as? [String] ?? []
            let cuts = Self.pageCuts(height: height, available: Double(size.height - 80), layout: layout, image: image)
            for (index, cut) in cuts.enumerated() {
                try Task.checkCancellation()
                let captureHeight = size.height
                view.frame.size = CGSize(width: size.width, height: captureHeight)
                _ = try await view.callAsyncJavaScript(DocumentExportScript.showPage, arguments: ["start": cut.0, "end": cut.1,
                    "height": captureHeight, "index": index + 1, "total": cuts.count], in: nil, contentWorld: .page)
                let rect = CGRect(x: 0, y: 0, width: size.width, height: captureHeight)
                if image {
                    let config = WKSnapshotConfiguration(); config.rect = rect; config.afterScreenUpdates = true
                    let bitmap = try await view.takeSnapshot(configuration: config)
                    #if os(iOS)
                    let data = bitmap.pngData()
                    #else
                    let data = bitmap.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                    #endif
                    guard let data else { throw DocumentExportError.failed("An export image could not be encoded.") }
                    imageNumber += 1
                    let url = directory.appendingPathComponent(DocumentExportNames.filename(snapshot.root.title) + String(format: "-%03d.png", imageNumber))
                    try data.write(to: url, options: .atomic); files.append(url)
                } else {
                    let config = WKPDFConfiguration(); config.rect = rect
                    let data = try await view.pdf(configuration: config)
                    guard let slice = PDFDocument(data: data), slice.pageCount > 0 else { throw DocumentExportError.failed("A PDF page could not be generated.") }
                    for n in 0..<slice.pageCount { if let page = slice.page(at: n) { pdf.insert(page, at: pdf.pageCount) } }
                }
                progress("Rendered \(image ? files.count : pdf.pageCount) \(image ? "images" : "pages")")
            }
        }
        if !image {
            guard pdf.pageCount > 0 else { throw DocumentExportError.failed("The PDF contains no pages.") }
            let url = directory.appendingPathComponent(DocumentExportNames.filename(snapshot.root.title) + ".pdf")
            guard pdf.write(to: url) else { throw DocumentExportError.failed("The PDF could not be saved.") }
            files = [url]
        }
        return DocumentExportOutput(format: format, files: files, warnings: Array(Set(warnings)).sorted(), directory: directory)
    }

    private static func pageCuts(height: Double, available: Double, layout: [String: Any], image: Bool) -> [(Double, Double)] {
        let boxes = layout["boxes"] as? [[String: Double]] ?? [], breaks = (layout["breaks"] as? [Double] ?? []).sorted()
        var result: [(Double, Double)] = [], start = 0.0
        repeat {
            var end = min(height, start + available)
            if !image, let forced = breaks.first(where: { $0 > start + 1 && $0 < end }) { end = forced }
            else if end < height {
                // Prefer keeping blocks/rows together, except a block taller than
                // a page, whose text must continue instead of being truncated.
                let crossing = boxes.filter { ($0["top"] ?? 0) > start + 1 && ($0["top"] ?? 0) < end && ($0["bottom"] ?? 0) > end && ($0["bottom"] ?? 0) - ($0["top"] ?? 0) <= available }
                if let boundary = crossing.compactMap({ $0["top"] }).min(), boundary > start + available * 0.25 { end = boundary }
            }
            end = max(start + 1, end); result.append((start, end)); start = end
        } while start < height
        return result
    }
    private func referencePresentation(_ document: DocumentRecord, fontStyle: DocumentFontStyle) -> [String: Any] {
        // Visual exports keep the same reference preview as the editor, without
        // appending the referenced document as additional export pages.
        PageReferencePresentation.bridgeObject(document, attachmentStore: store, colorScheme: scheme, containingFontStyle: fontStyle)
    }
    private func start(size: CGSize) async throws {
        guard let document = TipTapEditorAssetCache.cachedDocument else { throw DocumentExportError.failed("Penned's bundled document renderer is missing.") }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DocumentFontSchemeHandler(), forURLScheme: DocumentFontResources.scheme)
        config.userContentController.add(self, name: "tiptap")
        for scheme in ["vellix-icon", "penned-file", "penned-cover"] { config.setURLSchemeHandler(assets, forURLScheme: scheme) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        webView = view; view.navigationDelegate = self
        #if os(iOS)
        view.isOpaque = false; view.scrollView.isScrollEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let parent = window?.rootViewController?.view else { close(); throw DocumentExportError.failed("Open a Penned window to export this document.") }
        let host = UIView(frame: view.frame); host.isUserInteractionEnabled = false; host.clipsToBounds = true
        host.addSubview(view); parent.insertSubview(host, at: 0); self.host = host
        #else
        guard let parent = NSApp.keyWindow?.contentView else { close(); throw DocumentExportError.failed("Open a Penned window to export this document.") }
        let host = NSView(frame: view.frame); host.addSubview(view); parent.addSubview(host, positioned: .below, relativeTo: parent.subviews.first); self.host = host
        #endif
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)); self?.finish(.failure(DocumentExportError.failed("The isolated export renderer did not become ready. No changes were made to your document."))) } catch {}
                }
                view.loadHTMLString(document.html, baseURL: document.baseURL)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func command(_ name: String, args: [String: Any]) async throws {
        guard let webView else { throw CancellationError() }
        _ = try await webView.callAsyncJavaScript("return await window.tiptapCommand(name,args);", arguments: ["name": name, "args": args], in: nil, contentWorld: .page)
    }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = ready; ready = nil; continuation?.resume(with: result)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "ready" else { return }
        finish(.success(()))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(DocumentExportError.failed("The export rendering process stopped. Please try again."))) }
    func close() {
        finish(.failure(CancellationError())); webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tiptap")
        webView?.navigationDelegate = nil
        #if os(iOS)
        (host as? UIView)?.removeFromSuperview()
        #else
        (host as? NSView)?.removeFromSuperview()
        #endif
        host = nil; webView = nil
    }
    private func png<V: View>(_ content: V) -> String {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme)); renderer.scale = 2
        #if os(iOS)
        let data = renderer.uiImage?.pngData()
        #else
        let data = renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #endif
        return data.map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
    }
    private func imageDataURL(_ url: URL) throws -> String {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            throw DocumentExportError.failed("The cover image could not be decoded: " + url.lastPathComponent)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw DocumentExportError.failed("The cover could not be encoded.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DocumentExportError.failed("The cover could not be encoded.") }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}

// Only snapshot-approved files can be requested. Assets are embedded in the
// static export DOM, so PDF capture never depends on a live editor scheme task.
@MainActor private final class DocumentExportAssets: NSObject, WKURLSchemeHandler {
    struct Asset {
        let data: Data
        let mime: String
        var dataURL: String { "data:" + mime + ";base64," + data.base64EncodedString() }
    }
    private let snapshot: DocumentExportSnapshot
    private let store: AttachmentStore
    private var cache: [String: Asset] = [:]
    init(snapshot: DocumentExportSnapshot, store: AttachmentStore) { self.snapshot = snapshot; self.store = store }

    func asset(for url: URL) throws -> Asset? {
        if let value = cache[url.absoluteString] { return value }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func query(_ key: String) -> String? { parts.queryItems?.first { $0.name == key }?.value }
        let result: Asset
        switch url.scheme {
        case "vellix-icon":
            guard url.host == "asset" else { return nil }
            let name = url.pathComponents.dropFirst().joined(separator: "/")
            guard let data = TipTapEditorIconRenderer.pngData(for: name, tintHex: query("tint") ?? "#ffffff") else { return nil }
            result = Asset(data: data, mime: "image/png")
        case "penned-file":
            guard url.host == "file", let path = query("path"),
                  let file = snapshot.files.first(where: { $0.record.relativePath == path }),
                  let source = snapshot.assets[path] else { return nil }
            if query("preview") == "thumbnail" {
                guard let path = file.record.thumbnailRelativePath, let thumbnail = snapshot.assets[path] else { return nil }
                result = Asset(data: try Data(contentsOf: thumbnail), mime: "image/png")
            } else if query("preview") == "pdf" && file.media.kind == .pdf {
                result = Asset(data: try store.previewPNG(relativePath: path, pdf: true), mime: "image/png")
            } else if query("preview") == "image" && file.media.kind == .image {
                result = Asset(data: try store.previewPNG(relativePath: path, pdf: false), mime: "image/png")
            } else {
                guard file.media.kind == .image else { return nil }
                result = Asset(data: try Data(contentsOf: source), mime: file.media.mimeType)
            }
        case "penned-cover":
            guard url.host == "image" else { return nil }
            let image: CGImage?
            if let path = query("path"), let source = snapshot.assets[path] {
                image = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            } else if let raw = query("theme"), let theme = DocumentThemeID(rawValue: raw) {
                image = NestedPageThemeCovers.image(for: theme)
            } else { return nil }
            guard let image else { return nil }
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            result = Asset(data: buffer as Data, mime: "image/png")
        default: return nil
        }
        cache[url.absoluteString] = result
        return result
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url, let value = try asset(for: url) else { throw URLError(.fileDoesNotExist) }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: value.mime, expectedContentLength: value.data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(value.data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
