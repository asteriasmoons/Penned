import Foundation
import WebKit

// Only native-resolved, Space-checked records are capabilities. Pasted URLs cannot read the store.
@MainActor
final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let session: TipTapEditorSession
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(session: TipTapEditorSession) { self.session = session }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              url.host == "file", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parts.queryItems?.first(where: { $0.name == "path" })?.value,
              let file = session.attachmentFiles.first(where: { $0.record.relativePath == path }),
              let store = session.attachmentStore else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let variant = parts.queryItems?.first(where: { $0.name == "preview" })?.value
        let thumbnail = variant == "thumbnail" ? file.record.thumbnailRelativePath : nil
        if variant == "thumbnail", thumbnail == nil { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let source: URL
        do { source = try store.validatedFileURL(relativePath: thumbnail ?? path) }
        catch { urlSchemeTask.didFailWithError(error); return }
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let headOnly = urlSchemeTask.request.httpMethod == "HEAD"
        let generation = session.attachmentGeneration
        tasks[key] = Task { [weak self] in
            defer { self?.tasks[key] = nil }
            do {
                let derived = variant == "pdf" && file.media.kind == .pdf || variant == "image" && file.media.kind == .image
                let data: Data?
                if derived {
                    data = try await Task.detached(priority: .userInitiated) { try store.previewPNG(relativePath: path, pdf: variant == "pdf") }.value
                } else { data = nil }
                let size: Int64
                if let data { size = Int64(data.count) }
                else { size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0 }
                let range: AttachmentByteRange?
                do { range = try AttachmentByteRange.parse(rangeHeader, size: size) }
                catch {
                    guard let self, self.tasks[key] != nil, !Task.isCancelled else { return }
                    urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Range": "bytes */\(size)", "Content-Length": "0"])!)
                    urlSchemeTask.didFinish(); self.tasks[key] = nil; return
                }
                var headers = ["Content-Type": derived || thumbnail != nil ? "image/png" : file.media.mimeType, "Accept-Ranges": "bytes",
                    "Content-Length": String(range?.count ?? size), "Access-Control-Allow-Origin": "*",
                    "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox"]
                if let range { headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(size)" }
                guard let self, self.tasks[key] != nil, !Task.isCancelled, self.session.attachmentGeneration == generation else { return }
                urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
                if !headOnly {
                    if let data {
                        let start = Int(range?.start ?? 0), end = start + Int(range?.count ?? size)
                        urlSchemeTask.didReceive(data.subdata(in: start..<end))
                    } else {
                        let handle = try FileHandle(forReadingFrom: source)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(range?.start ?? 0))
                        var remaining = range?.count ?? size
                        while remaining > 0 {
                            try Task.checkCancellation()
                            guard self.tasks[key] != nil, self.session.attachmentGeneration == generation else { return }
                            let count = Int(min(remaining, 64 * 1024))
                            let chunk = try await Task.detached(priority: .userInitiated) { try handle.read(upToCount: count) ?? Data() }.value
                            try Task.checkCancellation()
                            guard self.tasks[key] != nil, self.session.attachmentGeneration == generation else { return }
                            guard !chunk.isEmpty else { throw URLError(.cannotDecodeContentData) }
                            urlSchemeTask.didReceive(chunk); remaining -= Int64(chunk.count)
                        }
                    }
                }
                guard self.tasks[key] != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFinish(); self.tasks[key] = nil
            } catch {
                guard let self, self.tasks[key] != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error); self.tasks[key] = nil
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
