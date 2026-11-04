#if os(iOS)
import Foundation
import UIKit

nonisolated struct ClipperThumbnailRequest: Sendable {
    let data: Data
    let size: CGFloat
}

nonisolated struct ClipperCatalogueImages: Sendable {
    var icons: [String: String] = [:]
    var thumbnails: [String: String] = [:]
}

// Image decoding, rasterization and PNG compression never run on the main actor.
actor WebClipperCatalogueImages {
    private struct Thumbnail {
        let request: ClipperThumbnailRequest
        let value: String?
    }
    private struct Icon { let value: String? }
    private var owner: String?
    private var scale: CGFloat = 0
    private var icons: [String: Icon] = [:]
    private var thumbnails: [String: Thumbnail] = [:]

    func render(ownerID: String, names: Set<String>, requests: [String: ClipperThumbnailRequest], displayScale: CGFloat) -> ClipperCatalogueImages? {
        guard !Task.isCancelled else { return nil }
        if owner != ownerID { thumbnails.removeAll(); owner = ownerID }
        if scale != displayScale { icons.removeAll(); thumbnails.removeAll(); scale = displayScale }
        icons = icons.filter { names.contains($0.key) }
        thumbnails = thumbnails.filter { requests[$0.key] != nil }
        var result = ClipperCatalogueImages()
        for name in names {
            guard !Task.isCancelled else { return nil }
            if icons[name] == nil {
                let value = autoreleasepool {
                    let image = name.hasPrefix("sf:") ? UIImage(systemName: String(name.dropFirst(3))) : UIImage(named: name)
                    return image.flatMap { thumbnail($0.withTintColor(.white, renderingMode: .alwaysOriginal), size: 24) }
                }
                icons[name] = Icon(value: value)
            }
            result.icons[name] = icons[name]?.value
        }
        for (id, request) in requests {
            guard !Task.isCancelled else { return nil }
            let cached = thumbnails[id]
            if cached?.request.size != request.size || cached?.request.data != request.data {
                let value = autoreleasepool { UIImage(data: request.data).flatMap { thumbnail($0, size: request.size) } }
                thumbnails[id] = Thumbnail(request: request, value: value)
            }
            result.thumbnails[id] = thumbnails[id]?.value
        }
        return result
    }

    func resetAccount() { owner = nil; thumbnails.removeAll() }

    private func thumbnail(_ image: UIImage, size: CGFloat) -> String? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let output = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            let ratio = min(size / image.size.width, size / image.size.height)
            image.draw(in: CGRect(x: (size - image.size.width * ratio) / 2, y: (size - image.size.height * ratio) / 2,
                                  width: image.size.width * ratio, height: image.size.height * ratio))
        }
        return output.pngData().map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}
#endif
