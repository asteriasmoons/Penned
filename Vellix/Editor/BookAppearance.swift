import SwiftUI

enum CardSurfaceTarget: String, Identifiable {
    case face, spine
    var id: String { rawValue }
}

struct BookPaint: Codable, Equatable {
    var mode: PageCardBackdrop = .solid
    var startColor: String
    var endColor: String
    var opacity: Double = 1

    init(_ start: String, end: String? = nil, opacity: Double = 1) {
        mode = end == nil ? .solid : .gradient
        startColor = start
        endColor = end ?? start
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey { case mode, startColor, endColor, opacity }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(PageCardBackdrop.self, forKey: .mode) == .gradient ? .gradient : .solid
        startColor = GridCardSettings.opaqueHex(try values.decode(String.self, forKey: .startColor), fallback: "#FFFFFF")
        endColor = GridCardSettings.opaqueHex(try values.decodeIfPresent(String.self, forKey: .endColor) ?? startColor, fallback: startColor)
        let alpha = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        opacity = alpha.isFinite ? min(1, max(0, alpha)) : 1
    }

    @MainActor var palette: Gradient {
        Gradient(colors: [Color(vellixHex: startColor).opacity(opacity),
            Color(vellixHex: mode == .gradient ? endColor : startColor).opacity(opacity)])
    }
    @MainActor var fill: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(gradient: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

enum BookColorPart: String, CaseIterable, Identifiable {
    case title, description, previewBorder, coverBorder, lines, pages, edgesBorder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "Title"
        case .description: return "Description"
        case .previewBorder: return "Preview Border"
        case .coverBorder: return "Cover Border"
        case .lines: return "Cover Lines"
        case .pages: return "Page Edges"
        case .edgesBorder: return "Edges Border"
        }
    }
}

extension PageCardStyle {
    func bookPaint(_ part: BookColorPart, appearance: DocumentAppearance) -> BookPaint {
        if let saved = bookColors[part.rawValue] { return saved }
        let paper = appearance.themeID == nil ? appearance.editorBackground : appearance.innerPageBackground
        switch part {
        case .title:
            let dark = backdrop == .none ? appearance.presentationColorScheme == .dark : textColor == "#FFFFFF"
            return BookPaint(dark ? "#FFFFFF" : "#000000")
        case .description: return BookPaint("#D5D5DA", opacity: 0.8)
        case .previewBorder: return BookPaint("#F6F3ED", opacity: 0.7)
        case .coverBorder: return BookPaint("#E5E9EF", end: "#13161B", opacity: 0.55)
        case .lines: return BookPaint("#F6F3ED", opacity: 0.42)
        case .pages: return BookPaint(paper.colorHex, end: paper.secondaryColorHex)
        case .edgesBorder: return BookPaint("#FFFFFF", end: "#202024", opacity: 0.35)
        }
    }
}
