import Foundation
import CoreGraphics

enum PageCardSize: String, Codable, CaseIterable, Identifiable {
    case compact, landscape, portrait, wide, large
    var id: String { rawValue }
    var fillsDocumentWidth: Bool { self == .wide || self == .large }
    var size: CGSize {
        switch self {
        case .compact, .landscape: return CGSize(width: 154, height: 90)
        case .portrait: return CGSize(width: 154, height: 162)
        case .wide: return CGSize(width: 318, height: 90)
        case .large: return CGSize(width: 318, height: 154)
        }
    }
    var title: String {
        switch self {
        case .compact: return "Compact"
        case .landscape: return "Small Landscape"
        case .portrait: return "Small Portrait"
        case .wide: return "Wide"
        case .large: return "Large"
        }
    }
}

enum PageCardBackdrop: String, Codable, CaseIterable, Identifiable {
    case none, solid, gradient, photo
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PageCardPreviewStyle: String, Codable, CaseIterable, Identifiable {
    case pages, stickyNote, openPage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pages: return "Pages"
        case .stickyNote: return "Sticky Note"
        case .openPage: return "Open Page"
        }
    }
}

nonisolated struct CardRemotePhoto: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var thumbURL: String
    var imageURL: String
    var photographer: String
    var photographerURL: String
    var sourceURL: String

    var validImageURL: URL? {
        guard let url = URL(string: imageURL), url.scheme == "https", url.host == "images.unsplash.com" else { return nil }
        return url
    }
}

struct PageCardStyle: Codable, Equatable {
    var size: PageCardSize = .compact
    var showsPages = true
    var previewStyle: PageCardPreviewStyle = .pages
    var backdrop: PageCardBackdrop = .solid
    var startColor = "#3A4348"
    var endColor = "#26333C"
    var imagePath: String?
    var remotePhoto: CardRemotePhoto?

    private enum CodingKeys: String, CodingKey {
        case size, showsPages, previewStyle, backdrop, startColor, endColor, imagePath, remotePhoto
    }

    var textColor: String {
        guard backdrop != .photo else { return "#FFFFFF" }
        let colors = backdrop == .gradient ? [startColor, endColor] : [startColor]
        let brightness = colors.map { hex -> Double in
            let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            return (Double((value >> 16) & 255) * 0.299 + Double((value >> 8) & 255) * 0.587 + Double(value & 255) * 0.114) / 255
        }.reduce(0, +) / Double(colors.count)
        return brightness > 0.62 ? "#202024" : "#FFFFFF"
    }

    func encodedJSON() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static let decodeCache: NSCache<NSString, CardStyleBox> = {
        let cache = NSCache<NSString, CardStyleBox>(); cache.countLimit = 512; return cache
    }()
    static func decode(_ json: String?) -> PageCardStyle? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let key = json as NSString
        if let cached = decodeCache.object(forKey: key) { return cached.style }
        guard let style = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        decodeCache.setObject(CardStyleBox(style), forKey: key)
        return style
    }
}

extension PageCardStyle {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        size = try values.decodeIfPresent(PageCardSize.self, forKey: .size) ?? .compact
        showsPages = try values.decodeIfPresent(Bool.self, forKey: .showsPages) ?? true
        previewStyle = (try values.decodeIfPresent(String.self, forKey: .previewStyle))
            .flatMap { PageCardPreviewStyle(rawValue: $0) } ?? .pages
        backdrop = try values.decodeIfPresent(PageCardBackdrop.self, forKey: .backdrop) ?? .solid
        startColor = try values.decodeIfPresent(String.self, forKey: .startColor) ?? "#3A4348"
        endColor = try values.decodeIfPresent(String.self, forKey: .endColor) ?? "#26333C"
        imagePath = try values.decodeIfPresent(String.self, forKey: .imagePath)
        remotePhoto = try values.decodeIfPresent(CardRemotePhoto.self, forKey: .remotePhoto)
    }
}

private final class CardStyleBox { let style: PageCardStyle; init(_ style: PageCardStyle) { self.style = style } }

struct PageCardEditorRequest: Identifiable {
    var blockID: String?
    var document: DocumentRecord
    var id: String { blockID ?? document.id }
}

extension DocumentRecord {
    var cardStyle: PageCardStyle? { PageCardStyle.decode(cardStyleJSON) }
}
