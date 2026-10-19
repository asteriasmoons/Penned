import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import QuickLookThumbnailing

nonisolated enum AttachmentKind: String, Codable, Sendable {
    case image, pdf, video, audio, file
}

struct AttachmentEditorRequest: Identifiable, Equatable {
    var id: String { blockID }
    let blockID: String
    let relativePath: String
    let mode: String
    let width: Double?
    let alignment: String
}

struct AttachmentActionRequest: Equatable {
    let documentID: String
    let attachment: AttachmentEditorRequest
}

nonisolated struct AttachmentImportData: Equatable, Sendable {
    let name: String
    let mimeType: String?
    let data: Data
}

// Derived metadata never replaces the original attachment or its bytes.
nonisolated struct AttachmentMedia: Sendable {
    var kind: AttachmentKind
    var mimeType: String
    var uti: String?
    var width: Int?
    var height: Int?

    func typeLabel(fileName: String) -> String {
        let known = ["application/pdf": "PDF", "image/svg+xml": "SVG", "video/quicktime": "MOV",
            "audio/mpeg": "MP3", "audio/mp4": "M4A", "text/plain": "TXT", "application/zip": "ZIP"]
        if let label = known[mimeType] { return label }
        if kind == .image || kind == .video || kind == .audio {
            return String((mimeType.split(separator: "/").last.map(String.init) ?? kind.rawValue).uppercased().prefix(8))
        }
        let suffix = (fileName as NSString).pathExtension
        return suffix.isEmpty ? "FILE" : String(suffix.uppercased().prefix(8))
    }

    static func inspect(url: URL, mimeType: String? = nil) -> Self {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let typeID = CGImageSourceGetType(source) as String?, let type = UTType(typeID),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let rotated = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            let width = properties[kCGImagePropertyPixelWidth] as? Int
            let height = properties[kCGImagePropertyPixelHeight] as? Int
            return Self(kind: .image, mimeType: type.preferredMIMEType ?? "image/png", uti: typeID,
                width: rotated ? height : width, height: rotated ? width : height)
        }
        let handle = try? FileHandle(forReadingFrom: url)
        defer { try? handle?.close() }
        let bytes = (try? handle?.read(upToCount: 4096)) ?? Data()
        if bytes.starts(with: Data("%PDF-".utf8)) {
            return Self(kind: .pdf, mimeType: "application/pdf", uti: UTType.pdf.identifier)
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension)
        let prefix = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if (type?.conforms(to: .svg) == true || prefix.hasPrefix("<svg") || prefix.hasPrefix("<?xml")),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 16 * 1024 * 1024,
           let svg = svgMedia(data) {
            return svg
        }
        // Never trust an image suffix when the image decoder could not recognize the bytes.
        let signature = Array(bytes)
        if signature.count >= 12, String(bytes: signature[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: signature[8..<12], encoding: .ascii) ?? ""
            if ["M4A ", "M4B ", "M4P "].contains(brand) { return Self(kind: .audio, mimeType: "audio/mp4", uti: UTType.mpeg4Audio.identifier) }
            if !["heic", "heix", "hevc", "mif1", "avif"].contains(brand) { return Self(kind: .video, mimeType: brand == "qt  " ? "video/quicktime" : "video/mp4", uti: type?.identifier) }
        }
        if bytes.starts(with: Data("ID3".utf8)) || signature.count > 1 && signature[0] == 0xff && signature[1] & 0xe0 == 0xe0 {
            return Self(kind: .audio, mimeType: "audio/mpeg", uti: UTType.mp3.identifier)
        }
        if bytes.starts(with: Data("fLaC".utf8)) { return Self(kind: .audio, mimeType: "audio/flac", uti: type?.identifier) }
        if signature.count >= 12, String(bytes: signature[0..<4], encoding: .ascii) == "RIFF", String(bytes: signature[8..<12], encoding: .ascii) == "WAVE" {
            return Self(kind: .audio, mimeType: "audio/wav", uti: UTType.wav.identifier)
        }
        if bytes.starts(with: Data([0x1a, 0x45, 0xdf, 0xa3])) { return Self(kind: .video, mimeType: "video/webm", uti: type?.identifier) }
        if bytes.starts(with: Data("OggS".utf8)) { return Self(kind: type?.conforms(to: .movie) == true ? .video : .audio, mimeType: type?.conforms(to: .movie) == true ? "video/ogg" : "audio/ogg", uti: type?.identifier) }
        let kind: AttachmentKind = type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .audio) == true ? .audio : .file
        let mime = type?.conforms(to: .image) == true || type == .pdf ? "application/octet-stream" : type?.preferredMIMEType ?? mimeType ?? "application/octet-stream"
        return Self(kind: kind, mimeType: mime, uti: type?.identifier)
    }

    private static func svgMedia(_ data: Data) -> Self? {
        guard let text = String(data: data, encoding: .utf8)?.lowercased(),
              !text.contains("<!doctype"), !text.contains("<!entity"),
              !text.contains("<script"), !text.contains("<foreignobject"),
              !text.contains("@import"), !text.contains("javascript:"),
              text.range(of: #"\bon[a-z]+\s*="#, options: .regularExpression) == nil,
              text.range(of: #"(?:href\s*=\s*["']\s*(?!#)|url\s*\(\s*["']?(?!#))"#, options: .regularExpression) == nil else { return nil }
        let delegate = SVGRootValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isSVG else { return nil }
        return Self(kind: .image, mimeType: "image/svg+xml", uti: UTType.svg.identifier, width: delegate.width, height: delegate.height)
    }

    private final class SVGRootValidator: NSObject, XMLParserDelegate {
        var isSVG = false
        var width: Int?
        var height: Int?
        private var sawRoot = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let localName = elementName.lowercased().split(separator: ":").last.map(String.init) ?? ""
            if ["script", "foreignobject"].contains(localName) { parser.abortParsing(); return }
            if !sawRoot {
                isSVG = localName == "svg"; sawRoot = true
                let viewBox = (attributes["viewBox"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
                func dimension(_ text: String?, fallback: Double?) -> Int? {
                    let value = text.flatMap { Double($0.replacingOccurrences(of: "px", with: "")) } ?? fallback
                    guard let value, value.isFinite, value > 0, value <= 100_000 else { return nil }
                    return max(1, Int(value))
                }
                width = dimension(attributes["width"], fallback: viewBox.count == 4 ? viewBox[2] : nil)
                height = dimension(attributes["height"], fallback: viewBox.count == 4 ? viewBox[3] : nil)
            }
        }
    }
}

nonisolated struct EditorAttachment: Identifiable, Sendable {
    let record: AttachmentRecord
    let media: AttachmentMedia
    var id: String { record.id }

    var object: [String: Any] {
        var result: [String: Any] = ["attachmentID": id, "relativePath": record.relativePath,
            "name": record.originalFileName, "mimeType": media.mimeType, "kind": media.kind.rawValue, "size": record.fileSize,
            "typeLabel": media.typeLabel(fileName: record.originalFileName)]
        if let width = media.width { result["width"] = width }
        if let height = media.height { result["height"] = height }
        if let path = record.thumbnailRelativePath { result["previewPath"] = path }
        return result
    }

    static func paths(in json: String) -> Set<String> {
        func walk(_ node: [String: Any]) -> Set<String> {
            var paths = Set<String>()
            if node["type"] as? String == "attachment",
               let attrs = node["attrs"] as? [String: Any], let file = attrs["file"] as? [String: Any],
               let path = file["relativePath"] as? String { paths.insert(path) }
            for child in node["content"] as? [[String: Any]] ?? [] { paths.formUnion(walk(child)) }
            return paths
        }
        return walk(TipTapContentAnalyzer.documentObject(from: json))
    }
}

nonisolated struct AttachmentByteRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    var count: Int64 { end - start + 1 }

    static func parse(_ header: String?, size: Int64) throws -> Self? {
        guard let header else { return nil }
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw URLError(.badServerResponse) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw URLError(.badServerResponse) }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw URLError(.badServerResponse) }
            return Self(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw URLError(.badServerResponse) }
        let end = parts[1].isEmpty ? size - 1 : Int64(parts[1]) ?? -1
        guard end >= start else { throw URLError(.badServerResponse) }
        return Self(start: start, end: min(end, size - 1))
    }
}

extension AttachmentRecord {
    nonisolated var storedPaths: [String] { [relativePath, thumbnailRelativePath].compactMap { $0 } }
}

extension AttachmentStore {
    // NSCache synchronizes its own access; values are immutable once published.
    nonisolated(unsafe) private static let mediaPreviewCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 24
        return cache
    }()

    // Quick Look is only a derived preview for formats ImageIO cannot draw, never a replacement file.
    func makeEditorThumbnail(for record: AttachmentRecord) async -> String? {
        guard let url = try? validatedFileURL(relativePath: record.relativePath) else { return nil }
        let media = AttachmentMedia.inspect(url: url, mimeType: record.mimeType)
        guard media.mimeType == "image/svg+xml" || media.kind == .video else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1000, height: 1000), scale: 1, representationTypes: .thumbnail)
        request.iconMode = false
        if let type = media.uti.flatMap({ UTType($0) }) { request.contentType = type }
        let image = await AttachmentThumbnailRequest(request: request).image()
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return try? importData(data as Data, originalFileName: "Preview.png", mimeType: "image/png", documentID: record.documentID).relativePath
    }

    nonisolated func copy(_ record: AttachmentRecord, documentID: String) throws -> AttachmentRecord {
        var copy = try importFile(at: validatedFileURL(relativePath: record.relativePath), documentID: documentID)
        copy.originalFileName = record.originalFileName
        if let path = record.thumbnailRelativePath {
            copy.thumbnailRelativePath = try? importFile(at: validatedFileURL(relativePath: path), documentID: documentID).relativePath
        }
        return copy
    }
    nonisolated static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/") && !path.contains("\\") && !path.contains("\0")
    }

    nonisolated func validatedFileURL(relativePath: String) throws -> URL {
        guard Self.validRelativePath(relativePath) else { throw VellixError.attachmentImport("The attachment path is invalid.") }
        let url = fileURL(relativePath: relativePath)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == url.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw VellixError.attachmentImport("The attachment path is outside its store.")
        }
        return url
    }

    nonisolated func previewPNG(relativePath: String, pdf: Bool = false) throws -> Data {
        let url = try validatedFileURL(relativePath: relativePath)
        let key = (url.path + (pdf ? "-pdf" : "-image")) as NSString
        if let cached = Self.mediaPreviewCache.object(forKey: key) { return cached as Data }
        let image: CGImage
        if pdf {
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { throw URLError(.cannotDecodeContentData) }
            let bounds = page.getBoxRect(.cropBox)
            guard bounds.width > 0, bounds.height > 0 else { throw URLError(.cannotDecodeContentData) }
            let scale = min(800 / bounds.width, 600 / bounds.height)
            let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw URLError(.cannotDecodeContentData) }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let result = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
            image = result
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let result = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
            image = result
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw URLError(.cannotCreateFile) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotCreateFile) }
        Self.mediaPreviewCache.setObject(data, forKey: key, cost: data.length)
        return data as Data
    }
}

@MainActor
private final class AttachmentThumbnailRequest {
    let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var timeout: Task<Void, Never>?
    init(request: QLThumbnailGenerator.Request) { self.request = request }

    func image() async -> CGImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                QLThumbnailGenerator.shared.cancel(request)
                finish(nil)
            }
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
                Task { @MainActor in self?.finish(result?.cgImage) }
            }
        }
    }

    private func finish(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: image)
    }
}
