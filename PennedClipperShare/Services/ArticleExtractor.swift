import Foundation
import CoreFoundation
import WebKit

/// HTML and metadata retrieved for a shared public webpage.
struct ExtractedArticle {
    let url: URL
    let title: String
    let author: String
    let siteName: String
    let html: String
    let thumbnailURL: String?
}

/// Fetches webpage HTML and extracts article metadata for the converter.
struct ArticleExtractor {
    func extract(from url: URL) async throws -> ExtractedArticle {
        guard ClipperShared.webURL(url.absoluteString) != nil else {
            throw ShareClipError.invalidWebpageURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let resolvedURL = response.url,
              ClipperShared.webURL(resolvedURL.absoluteString) != nil else {
            throw ShareClipError.articleExtractionFailed("The webpage could not be loaded.")
        }
        guard data.count <= 8_000_000 else {
            throw ShareClipError.articleExtractionFailed("The webpage is too large to clip.")
        }
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard mimeType == "text/html" || mimeType == "application/xhtml+xml" else {
            throw ShareClipError.articleExtractionFailed("The link does not contain an HTML webpage.")
        }

        let encoding = response.textEncodingName.flatMap { charset -> String.Encoding? in
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        } ?? .utf8
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
            throw ShareClipError.articleExtractionFailed("The webpage text could not be decoded.")
        }

        let metadata = await HTMLMetadataReader.read(html: html, baseURL: resolvedURL)
        return ExtractedArticle(
            url: resolvedURL,
            title: metadata.title.isEmpty ? (resolvedURL.host ?? "Untitled Article") : metadata.title,
            author: metadata.author,
            siteName: metadata.siteName.isEmpty ? (resolvedURL.host ?? "") : metadata.siteName,
            html: html,
            thumbnailURL: metadata.thumbnailURL
        )
    }
}

/// Uses an isolated HTML document to read metadata without executing webpage scripts.
@MainActor
private enum HTMLMetadataReader {
    struct Metadata {
        var title: String = ""
        var author: String = ""
        var siteName: String = ""
        var thumbnailURL: String?
    }

    static func read(html: String, baseURL: URL) async -> Metadata {
        // The article converter will handle the full document structure.
        // Metadata is parsed here without loading third-party webpage resources.
        let pattern = #"<meta\s+[^>]*>|<title\b[^>]*>[\s\S]*?</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return Metadata()
        }
        var values: [String: String] = [:]
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let swiftRange = Range(match.range, in: html) else { continue }
            let element = String(html[swiftRange])
            if element.lowercased().hasPrefix("<title") {
                if let start = element.firstIndex(of: ">"),
                   let end = element.range(of: "</title", options: .caseInsensitive)?.lowerBound {
                    values["title"] = decodeEntities(String(element[element.index(after: start)..<end]))
                }
                continue
            }
            let attributes = parseAttributes(element)
            let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
            if !key.isEmpty, let content = attributes["content"], values[key] == nil {
                values[key] = decodeEntities(content)
            }
        }
        let rawImage = values["og:image"] ?? values["twitter:image"]
        let imageURL = rawImage.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return Metadata(
            title: values["og:title"] ?? values["twitter:title"] ?? values["title"] ?? "",
            author: values["author"] ?? values["article:author"] ?? "",
            siteName: values["og:site_name"] ?? "",
            thumbnailURL: imageURL.flatMap { ClipperShared.webURL($0.absoluteString) == nil ? nil : $0.absoluteString }
        )
    }

    private static func parseAttributes(_ element: String) -> [String: String] {
        let pattern = #"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(element.startIndex..<element.endIndex, in: element)
        var result: [String: String] = [:]
        for match in regex.matches(in: element, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: element) else { continue }
            let name = String(element[nameRange]).lowercased()
            for index in 2...4 {
                if let valueRange = Range(match.range(at: index), in: element) {
                    result[name] = String(element[valueRange])
                    break
                }
            }
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
