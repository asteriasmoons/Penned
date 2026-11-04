import SafariServices
import ImageIO
import UniformTypeIdentifiers
import Darwin
import notify

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            context.cancelRequest(withError: ClipperError.message("Invalid Penned clipper request.")); return
        }
        Task {
            let reply: [String: Any]
            do { reply = try await ClipperNative.reply(message) }
            catch { reply = ["ok": false, "error": error.localizedDescription] }
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}

private enum ClipperNative {
    static func reply(_ message: [String: Any]) async throws -> [String: Any] {
        switch message["action"] as? String {
        case "catalogue":
            guard let connection = try ClipperShared.locked({ try ClipperShared.connection() }) else { return ["ok": true, "connected": false] }
            var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as! [String: Any]
            result.removeValue(forKey: "ownerID"); result.removeValue(forKey: "libraryID")
            return ["ok": true, "connected": true, "catalogue": result]
        case "save":
            guard let payload = message["clip"], JSONSerialization.isValidJSONObject(payload) else { throw ClipperError.message("The clip is empty.") }
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard data.count <= ClipperShared.maxPayload else { throw ClipperError.message("This article is too large to clip.") }
            return try await save(JSONDecoder().decode(ClipperSubmission.self, from: data))
        case "status":
            guard let id = message["id"] as? String, let sessionID = message["sessionID"] as? String else { throw ClipperError.message("Invalid clip status request.") }
            return try ClipperShared.locked {
                guard let connection = try ClipperShared.connection(), connection.sessionID == sessionID else { throw ClipperError.message("Your Penned account changed. Reopen the clipper.") }
                let directory = try ClipperShared.clipDirectory(id)
                let envelope = try ClipperShared.read(ClipperEnvelope.self, at: directory.appendingPathComponent("clip.json"))
                guard envelope.ownerID == connection.ownerID, envelope.libraryID == connection.libraryID else { throw ClipperError.message("This clip belongs to another account.") }
                let url = directory.appendingPathComponent("result.json")
                let result = FileManager.default.fileExists(atPath: url.path) ? try ClipperShared.read(ClipperResult.self, at: url) : ClipperResult(state: "queued")
                return ["ok": true, "state": result.state, "message": result.message ?? ""]
            }
        default: throw ClipperError.message("Unsupported Penned clipper request.")
        }
    }
    static func save(_ request: ClipperSubmission) async throws -> [String: Any] {
        let connection = try ClipperShared.locked { () throws -> ClipperConnection in
            guard let connection = try ClipperShared.connection() else { throw ClipperError.message("Open Penned and sign in under Account Settings first.") }
            try ClipperShared.validate(request, connection: connection)
            return connection
        }
        let destination = try ClipperShared.clipDirectory(request.id)
        let staging = try ClipperShared.directory().appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var sources: [String] = []
        func collect(_ nodes: [ClipperNode]) {
            for node in nodes {
                if node.type == "image", let src = node.attrs?.src, !sources.contains(src) { sources.append(src) }
                collect(node.content ?? [])
            }
        }
        collect(request.content)
        guard sources.count <= 150 else { throw ClipperError.message("This article has more than 150 images. Clip a smaller article.") }
        let requiredSources = Set(sources)
        if let thumbnail = request.thumbnailURL, !requiredSources.contains(thumbnail) { sources.append(thumbnail) }
        var assets: [ClipperAsset] = [], total = 0
        for source in sources {
            var downloaded: URL?
            do {
                let url: URL
                if ClipperShared.isImageDataURL(source), let comma = source.firstIndex(of: ","),
                   let bytes = Data(base64Encoded: String(source[source.index(after: comma)...])), bytes.count <= ClipperShared.maxAsset {
                    url = staging.appendingPathComponent(UUID().uuidString)
                    downloaded = url
                    try bytes.write(to: url)
                } else {
                    guard let remote = ClipperShared.webURL(source) else { throw ClipperError.message("An image URL is invalid.") }
                    do { url = try await ClipperImageDownload.fetch(remote, directory: staging) }
                    catch { throw ClipperError.message("Could not save an article image from \(remote.host ?? "the website"). Check your connection and retry. \(error.localizedDescription)") }
                }
                downloaded = url
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ClipperShared.maxAsset, total + size <= ClipperShared.maxAssetsBytes,
                      let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let identifier = CGImageSourceGetType(image) as String?, let type = UTType(identifier), type.conforms(to: .image),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, Double(width) * Double(height) <= 80_000_000 else {
                    throw ClipperError.message("An article image is unsupported or exceeds the safe image size. No clip was saved.")
                }
                let filename = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "img")
                try FileManager.default.moveItem(at: url, to: staging.appendingPathComponent(filename))
                total += size
                assets.append(ClipperAsset(source: source, filename: filename, mimeType: type.preferredMIMEType ?? "application/octet-stream"))
            } catch {
                if requiredSources.contains(source) { throw error }
                // A missing optional site thumbnail must not discard a complete article.
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            }
        }
        let envelope = ClipperEnvelope(ownerID: connection.ownerID, libraryID: connection.libraryID, createdAt: Date(), submission: request, assets: assets)
        try ClipperShared.write(envelope, to: staging.appendingPathComponent("clip.json"))
        try ClipperShared.locked {
            guard let current = try ClipperShared.connection(), current.ownerID == connection.ownerID, current.libraryID == connection.libraryID else {
                throw ClipperError.message("Your Penned account changed while clipping. Nothing was saved to the new account.")
            }
            try ClipperShared.validate(request, connection: current)
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try ClipperShared.read(ClipperEnvelope.self, at: destination.appendingPathComponent("clip.json"))
                guard existing.ownerID == envelope.ownerID, existing.libraryID == envelope.libraryID else { throw ClipperError.message("This clip identifier belongs to another account.") }
                let resultURL = destination.appendingPathComponent("result.json")
                if !FileManager.default.fileExists(atPath: resultURL.path) { return }
                if try ClipperShared.read(ClipperResult.self, at: resultURL).state != "error" { return }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        notify.notify_post(ClipperShared.notification)
        return ["ok": true, "state": "queued", "id": request.id]
    }
}

// Disk-backed, bounded downloads; no app credentials, Safari cookies or shared URL cache.
private final class ClipperImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var completion: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let directory: URL
    private var redirects = 0
    init(directory: URL) { self.directory = directory }
    static func fetch(_ url: URL, directory: URL) async throws -> URL {
        try await Task.detached {
            try validate(url)
            let loader = ClipperImageDownload(directory: directory)
            return try await loader.run(url)
        }.value
    }
    private func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { completion in
            self.completion = completion
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url); request.setValue("image/*", forHTTPHeaderField: "Accept")
            session.downloadTask(with: request).resume()
        }
    }
    private static func validate(_ url: URL) throws {
        guard ClipperShared.webURL(url.absoluteString) != nil, let host = url.host?.lowercased(),
              !host.hasSuffix(".local"), host != "localhost", !host.hasSuffix(".localhost"),
              url.port == nil || [80, 443].contains(url.port!) else { throw URLError(.unsupportedURL) }
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, nil, &addresses) == 0 else { throw URLError(.cannotFindHost) }
        defer { freeaddrinfo(addresses) }
        var entry = addresses
        while let current = entry {
            let address = current.pointee
            if address.ai_family == AF_INET, let socket = address.ai_addr {
                let value = UInt32(bigEndian: UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
                let a = value >> 24, b = (value >> 16) & 255
                guard a != 0, a != 10, a != 127, a < 224, !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                      !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)) else { throw URLError(.noPermissionsToReadFile) }
            } else if address.ai_family == AF_INET6, let socket = address.ai_addr {
                let bytes = withUnsafeBytes(of: UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr) { Array($0) }
                guard bytes.first.map({ $0 & 0xe0 == 0x20 }) == true else { throw URLError(.noPermissionsToReadFile) }
            }
            entry = address.ai_next
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        do { guard redirects <= 5, let url = request.url else { throw URLError(.httpTooManyRedirects) }; try Self.validate(url); completionHandler(request) }
        catch { completionHandler(nil); task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > Int64(ClipperShared.maxAsset) { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            let file = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: file)
            completion?.resume(returning: file); completion = nil
        } catch { completion?.resume(throwing: error); completion = nil }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion?.resume(throwing: error); completion = nil }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}
