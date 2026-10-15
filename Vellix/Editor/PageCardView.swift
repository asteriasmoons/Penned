import SwiftUI
import ImageIO

struct PageCardView: View {
    var document: DocumentRecord
    var style: PageCardStyle
    var photo: CGImage?
    var includeBackdrop = true
    var isStylePreview = false
    var fillsDocumentWidth = false
    var attachmentStore: AttachmentStore? = nil

    @ViewBuilder
    var body: some View {
        if fillsDocumentWidth && style.size.fillsDocumentWidth {
            GeometryReader { proxy in
                cardFace.scaleEffect(proxy.size.width / style.size.size.width, anchor: .topLeading)
            }
            .aspectRatio(style.size.size.width / style.size.size.height, contentMode: .fit)
        } else {
            cardFace
        }
    }

    private var cardFace: some View {
        ZStack(alignment: .topLeading) {
            if includeBackdrop { backdrop }
            if style.backdrop == .photo {
                LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if style.showsPages { pages }
            text
        }
        .frame(width: style.size.size.width, height: style.size.size.height, alignment: .topLeading)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(vellixHex: textColor).opacity(0.14), lineWidth: 0.75)
        }
    }

    @ViewBuilder private var backdrop: some View {
        switch style.backdrop {
        case .none: Color(vellixHex: document.appearance.innerPageBackground.colorHex)
        case .solid: Color(vellixHex: style.startColor)
        case .gradient:
            LinearGradient(colors: [Color(vellixHex: style.startColor), Color(vellixHex: style.endColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .photo:
            if let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill()
                    .frame(width: style.size.size.width, height: style.size.size.height).clipped()
            } else if let url = style.remotePhoto?.validImageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color(vellixHex: style.startColor) }
                    .frame(width: style.size.size.width, height: style.size.size.height).clipped()
            } else { Color(vellixHex: style.startColor) }
        }
    }

    @ViewBuilder private var pages: some View {
        switch style.size {
        case .compact:
            ZStack {
                Circle().fill(Color(vellixHex: textColor).opacity(0.1))
                miniature(size: CGSize(width: 23, height: 30)).offset(y: 4)
            }
            .frame(width: 32, height: 32).clipShape(Circle())
            .overlay(Circle().stroke(Color(vellixHex: textColor).opacity(0.16), lineWidth: 0.75))
            .offset(x: 14, y: 10)
        case .landscape, .portrait:
            miniature(size: CGSize(width: 132, height: 172)).offset(x: 36, y: 50)
        case .wide:
            miniature(size: CGSize(width: 116, height: 151), second: true)
                .rotationEffect(.degrees(-1.5), anchor: .bottomLeading).offset(x: 184, y: 32)
            miniature(size: CGSize(width: 116, height: 151)).offset(x: 190, y: 26)
        case .large:
            miniature(size: CGSize(width: 84, height: 109), second: true)
                .rotationEffect(.degrees(-1.5)).offset(x: 208, y: 28)
            miniature(size: CGSize(width: 84, height: 109))
                .rotationEffect(.degrees(0.5)).offset(x: 214, y: 25)
        }
    }

    private var text: some View {
        let compact = style.size == .compact && style.showsPages
        let full = style.size == .large && style.showsPages
        let wide = style.size == .wide && style.showsPages
        let x: CGFloat = compact ? 14 : 18
        let y: CGFloat = compact ? 47 : (full ? 28 : (wide ? 26 : 18))
        let width: CGFloat = full ? 176 : (wide ? 156 : style.size.size.width - x - 14)
        let showsExcerpt = compact || wide || full || !style.showsPages
        return VStack(alignment: .leading, spacing: compact ? 4 : (wide ? 6 : 9)) {
            Text(isStylePreview ? "Card Title" : document.title)
                .font(.system(size: full ? 20 : (wide ? 18 : 15), weight: .black, design: document.appearance.fontStyle.design))
                .lineLimit(full ? 2 : 1)
            if showsExcerpt {
                Text(isStylePreview ? "Preview of the page will be displayed here. Tap to add content." :
                    (document.previewText == "No content yet" ? "Empty page" : document.previewText))
                    .font(.system(size: compact ? 11 : 13, design: document.appearance.fontStyle.design))
                    .foregroundStyle(Color(vellixHex: textColor).opacity(0.62))
                    .lineLimit(compact ? 1 : (full ? 4 : 2))
            }
        }
        .foregroundStyle(Color(vellixHex: textColor))
        .frame(width: width, alignment: .leading)
        .offset(x: style.showsPages ? x : 18, y: style.showsPages ? y : 18)
    }

    private var textColor: String { style.backdrop == .none ? document.appearance.textColorHex : style.textColor }

    private func miniature(size: CGSize, second: Bool = false) -> some View {
        NestedPageThumbnail(json: isStylePreview ? TipTapContentAnalyzer.emptyDocumentJSON : (second ? continuationJSON : document.tipTapJSON),
            title: second ? "" : document.title, appearance: document.appearance, size: size, isCardSheet: true, isStylePreview: isStylePreview,
            cover: document.cover, attachmentStore: attachmentStore, includesCover: !second)
            .compositingGroup()
            .shadow(color: .black.opacity(0.30), radius: 0.8, x: 0, y: 1)
            .shadow(color: .black.opacity(0.32), radius: 5, x: 1, y: 4)
    }

    private var continuationJSON: String {
        var object = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)
        let blocks = object["content"] as? [[String: Any]] ?? []
        if let boundary = blocks.firstIndex(where: { $0["type"] as? String == "pageBreak" }) {
            object["content"] = Array(blocks.dropFirst(boundary + 1))
        } else {
            object["content"] = []
        }
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? TipTapContentAnalyzer.emptyDocumentJSON
    }
}

enum CardImageLoader {
    private static let cache: NSCache<NSString, CardDecodedImage> = {
        let cache = NSCache<NSString, CardDecodedImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 48_000_000
        return cache
    }()
    static func image(data: Data) -> CGImage? {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    static func image(path: String?, store: AttachmentStore?) -> CGImage? {
        guard let path, let store else { return nil }
        let url = store.fileURL(relativePath: path)
        // Imported assets have immutable UUID filenames, so a path is a stable cache key.
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = image(data: data) else { return nil }
        cache.setObject(CardDecodedImage(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

private final class CardDecodedImage {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
