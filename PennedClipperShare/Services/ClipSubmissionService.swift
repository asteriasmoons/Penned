import Foundation
import Darwin
import notify
import ImageIO
import UniformTypeIdentifiers

/// Queues a Share Extension clip for Penned's existing inbox importer.
struct ClipSubmissionService {
    /// A successful return means the clip is queued, not yet imported into Penned.
    func submit(_ draft: ShareClipDraft) async throws -> String {
        let request = draft.submission()
        let connection = try ClipperShared.locked { () throws -> ClipperConnection in
            guard let connection = try ClipperShared.connection() else {
                throw ShareClipError.pennedNotConnected
            }
            try ClipperShared.validate(request, connection: connection)
            return connection
        }

        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= ClipperShared.maxPayload else {
            throw ShareClipError.saveFailed("The article is too large to clip.")
        }

        let root = try ClipperShared.directory()
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        let destination = try ClipperShared.clipDirectory(request.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var sources: [String] = []
        func collect(_ nodes: [ClipperNode]) {
            for node in nodes {
                if node.type == "image", let src = node.attrs?.src, !sources.contains(src) {
                    sources.append(src)
                }
                collect(node.content ?? [])
            }
        }
        collect(request.content)
        guard sources.count <= 150 else {
            throw ShareClipError.saveFailed("This article contains too many images.")
        }
        let required = Set(sources)
        if let thumbnail = request.thumbnailURL, !required.contains(thumbnail) { sources.append(thumbnail) }

        var assets: [ClipperAsset] = []
        var totalBytes = 0
        for source in sources {
            var temporaryFile: URL?
            do {
                let file: URL
                if ClipperShared.isImageDataURL(source), let comma = source.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
                   data.count <= ClipperShared.maxAsset {
                    file = staging.appendingPathComponent(UUID().uuidString)
                    try data.write(to: file)
                } else {
                    guard let url = ClipperShared.webURL(source) else { throw URLError(.unsupportedURL) }
                    file = try await ShareClipImageDownload.fetch(url, directory: staging)
                }
                temporaryFile = file
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ClipperShared.maxAsset,
                      totalBytes + size <= ClipperShared.maxAssetsBytes,
                      let image = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let identifier = CGImageSourceGetType(image) as String?,
                      let type = UTType(identifier), type.conforms(to: .image),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, Double(width) * Double(height) <= 80_000_000 else {
                    throw ShareClipError.saveFailed("An article image is unsupported or too large.")
                }
                let filename = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "img")
                try FileManager.default.moveItem(at: file, to: staging.appendingPathComponent(filename))
                totalBytes += size
                assets.append(ClipperAsset(source: source, filename: filename,
                                           mimeType: type.preferredMIMEType ?? "application/octet-stream"))
            } catch {
                if required.contains(source) {
                    throw ShareClipError.saveFailed("Could not preserve an article image: " + error.localizedDescription)
                }
                if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            }
        }
        let envelope = ClipperEnvelope(ownerID: connection.ownerID, libraryID: connection.libraryID,
                                       createdAt: Date(), submission: request, assets: assets)
        try ClipperShared.write(envelope, to: staging.appendingPathComponent("clip.json"))

        try ClipperShared.locked {
            guard let current = try ClipperShared.connection(),
                  current.ownerID == connection.ownerID,
                  current.libraryID == connection.libraryID else {
                throw ShareClipError.saveFailed("Your Penned account changed while clipping.")
            }
            try ClipperShared.validate(request, connection: current)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ShareClipError.saveFailed("This clip has already been submitted.")
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        }

        notify_post(ClipperShared.notification)
        return request.id
    }
}
