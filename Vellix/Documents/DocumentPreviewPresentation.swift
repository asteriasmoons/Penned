import Foundation
import CoreGraphics
import ImageIO

// A displayed preview stays on one rendering until its content or presentation changes.
struct DocumentPreviewPresentation {
    private(set) var key: String?
    private(set) var image: CGImage?

    mutating func prepare(key: String, image: () -> CGImage?) {
        guard self.key != key || self.image == nil else { return }
        self.key = key
        self.image = image()
    }
}

// Offscreen only: a fresh block ID proves WebKit loaded this request's body,
// even when the saved document ID is the same as an earlier capture.
struct DocumentPreviewCaptureIdentity {
    let id: String
    let json: String
    let hasSyntheticBlock: Bool

    init(json source: String) throws {
        let id = UUID().uuidString
        self.id = id
        var document = TipTapContentAnalyzer.documentObject(from: source)
        var blocks = document["content"] as? [[String: Any]] ?? []
        if let index = blocks.firstIndex(where: { block in
            ["paragraph", "heading", "caption"].contains(block["type"] as? String ?? "")
                && (block["content"] as? [[String: Any]])?.isEmpty == false
        }) {
            var attributes = blocks[index]["attrs"] as? [String: Any] ?? [:]
            attributes["id"] = id
            blocks[index]["attrs"] = attributes
            hasSyntheticBlock = false
        } else {
            blocks.append(["type": "paragraph", "attrs": ["id": id],
                           "content": [["type": "text", "text": id]]])
            hasSyntheticBlock = true
        }
        document["content"] = blocks
        json = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }
}

nonisolated enum DocumentPreviewImageFile {
    // The largest gallery/card preview display is the All Docs grid card (~185pt at
    // 3x ≈ 555px); the home strip is 138pt and starred 19pt. 768 is a ceiling above
    // every card's real pixel size, so downsampling to it changes nothing visible —
    // it only avoids a full decode of these ~720x1480 (~1MP) full-page preview PNGs.
    static let galleryMaxPixelSize = 768

    static func read(_ url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let maxPixelSize {
            // Decode downsampled straight to the display ceiling. ImageIO produces the
            // reduced bitmap without materializing the full-resolution image, which is
            // several times faster for these ~1MP preview PNGs. The on-disk file, its
            // cache key, persistence and pruning are unchanged — only the in-memory
            // decode size is capped.
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary) {
                return thumb
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func readVisiblePreview(_ url: URL, maxPixelSize: Int? = DocumentPreviewImageFile.galleryMaxPixelSize) -> CGImage? {
        guard let image = read(url, maxPixelSize: maxPixelSize), !isBlank(image) else { return nil }
        return image
    }

    static func isBlank(_ image: CGImage) -> Bool {
        // Premultiplied RGB makes a fully transparent frame read as black too.
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        return drawn && !pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 2 }
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: url, options: .atomic)
    }
}
