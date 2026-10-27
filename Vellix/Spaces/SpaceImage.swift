import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct SpaceImage: View {
    let data: Data?
    let title: String
    var size: CGFloat

    init(space: SpaceRecord?, size: CGFloat) {
        data = space?.iconImageData
        title = space?.title ?? "Space"
        self.size = size
    }

    init(data: Data?, title: String, size: CGFloat) {
        self.data = data
        self.title = title
        self.size = size
    }

    var body: some View {
        Group {
            if let data, let image = CardImageLoader.image(data: data) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                ZStack {
                    VellixSurface.controlInk.opacity(0.10)
                    Text(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(VellixSurface.controlInk)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

nonisolated enum SpaceIconImage {
    static let maximumInputBytes = 20_000_000

    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else {
            throw VellixError.attachmentImport("Choose a valid image smaller than 20 MB.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VellixError.attachmentImport("The Space image could not be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VellixError.attachmentImport("The Space image could not be saved.")
        }
        return output as Data
    }
}
