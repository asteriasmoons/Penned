import Foundation
import CoreFoundation

nonisolated enum DocumentLinkURL {
    static func normalize(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return openable(value) ?? InlinePropertyDefinition.safeURL(value).flatMap { openable($0.absoluteString) }
    }

    static func openable(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\\"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto", "tel": return value.dropFirst(scheme.count + 1).isEmpty ? nil : url
        default: return nil
        }
    }

    static func web(_ value: String) -> URL? {
        guard let url = openable(value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

nonisolated enum RichLinkLayout: String, CaseIterable, Identifiable, Sendable {
    case small, regular, card
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated enum LinkInsertionKind: String, CaseIterable, Identifiable, Sendable {
    case text, label, rich
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "URL Text"
        case .label: "Link Text"
        case .rich: "Rich Link"
        }
    }
}

nonisolated struct RichLinkPreviewData {
    let layout: RichLinkLayout
    let url: URL?
    let title: String
    let description: String
    let site: String
    let image: URL?
    let favicon: URL?

    init(_ node: [String: Any]) {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        let metadata = attrs["metadata"] as? [String: Any] ?? [:]
        let href = attrs["href"] as? String ?? ""
        let body = (node["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        let resolved = DocumentLinkURL.web(href)
        let website = metadata["site"] as? String ?? ""
        let host = (resolved?.host ?? "") + (resolved?.path == "/" ? "" : (resolved?.path ?? ""))
        let pageTitle = metadata["title"] as? String ?? ""
        url = resolved
        layout = RichLinkLayout(rawValue: attrs["layout"] as? String ?? "") ?? .regular
        title = !pageTitle.isEmpty ? pageTitle : (!body.isEmpty ? body : (!host.isEmpty ? host : "Link"))
        description = metadata["description"] as? String ?? ""
        site = !website.isEmpty && website != host ? "\(website) · \(host)" : host
        image = (metadata["image"] as? String).flatMap(DocumentLinkURL.web)
        favicon = (metadata["favicon"] as? String).flatMap(DocumentLinkURL.web)
    }
}

nonisolated struct SelectedDocumentLink: Equatable, Identifiable, Sendable {
    let id: String
    let href: String
    let isRich: Bool
    let layout: RichLinkLayout
    let thumbnail: URL?
    let hasMetadata: Bool
    let canConvertToRich: Bool

    init?(_ value: Any?) {
        guard let values = value as? [String: Any], let id = values["blockID"] as? String, !id.isEmpty,
              let kind = values["kind"] as? String, ["text", "rich"].contains(kind),
              let href = values["href"] as? String, DocumentLinkURL.openable(href) != nil else { return nil }
        self.id = id
        self.href = href
        isRich = kind == "rich"
        layout = RichLinkLayout(rawValue: values["layout"] as? String ?? "") ?? .regular
        let metadata = values["metadata"] as? [String: Any]
        thumbnail = (metadata?["image"] as? String).flatMap(DocumentLinkURL.web)
            ?? (metadata?["favicon"] as? String).flatMap(DocumentLinkURL.web)
        hasMetadata = metadata != nil
        canConvertToRich = values["canConvertToRich"] as? Bool == true
    }
}

nonisolated struct DocumentLinkRequest: Identifiable, Equatable, Sendable {
    enum Mode: String, Sendable { case text, insert, block }
    let id: String
    let documentID: String
    let generation: Int
    let mode: Mode
    let href: String
    let existing: Bool
    let isRich: Bool
}

nonisolated enum DocumentLinkMetadataSource {
    struct Page: Sendable {
        let html: String
        let href: String
    }

    static func fetch(_ url: URL) async throws -> Page? {
        guard DocumentLinkURL.web(url.absoluteString) != nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let resolved = response.url, DocumentLinkURL.web(resolved.absoluteString) != nil,
              ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { return nil }
        var data = Data()
        let limit = 512 * 1024
        for try await byte in bytes {
            data.append(byte)
            if data.count == limit { break }
        }
        let encoding: String.Encoding = response.textEncodingName.flatMap { name in
            let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard value != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        } ?? .utf8
        let html = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        return Page(html: html, href: resolved.absoluteString)
    }
}
