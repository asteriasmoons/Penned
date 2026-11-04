import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

// Disk-backed, bounded downloads; no app credentials, Safari cookies or shared URL cache.
final class ShareClipImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var completion: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let directory: URL
    private var redirects = 0
    init(directory: URL) { self.directory = directory }
    static func fetch(_ url: URL, directory: URL) async throws -> URL {
        try await Task.detached {
            try validate(url)
            let loader = ShareClipImageDownload(directory: directory)
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
