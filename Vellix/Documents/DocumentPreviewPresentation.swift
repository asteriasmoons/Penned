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

enum DocumentPreviewImageFile {
    static func read(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
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
