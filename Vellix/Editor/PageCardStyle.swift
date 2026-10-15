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

struct CardRemotePhoto: Codable, Equatable, Hashable, Identifiable {
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
    var backdrop: PageCardBackdrop = .solid
    var startColor = "#3A4348"
    var endColor = "#26333C"
    var imagePath: String?
    var remotePhoto: CardRemotePhoto?

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

    static func decode(_ json: String?) -> PageCardStyle? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct PageCardEditorRequest: Identifiable {
    var blockID: String?
    var document: DocumentRecord
    var id: String { blockID ?? document.id }
}

extension DocumentRecord {
    var cardStyle: PageCardStyle? { PageCardStyle.decode(cardStyleJSON) }
}
