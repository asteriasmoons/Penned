//
//  DocumentAppearance.swift
//  Vellix
//

import Foundation
import SwiftUI

enum DocumentThemeID: String, Codable, CaseIterable, Identifiable {
    case custom
    case lunarClouds
    case neonCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom:
            return "Custom"
        case .lunarClouds:
            return "Lunar Clouds"
        case .neonCode:
            return "Neon Code"
        }
    }

    var accentHex: String {
        switch self {
        case .custom:
            return "#F7F7F7"
        case .lunarClouds:
            return "#8FE9FF"
        case .neonCode:
            return "#45F7DF"
        }
    }

    var defaultEditorBackground: DocumentBackgroundStyle {
        switch self {
        case .custom:
            return .gradient(primary: "#0A0B0B", secondary: "#191B1F")
        case .lunarClouds:
            return .gradient(primary: "#07080A", secondary: "#2A1D44")
        case .neonCode:
            return .gradient(primary: "#041314", secondary: "#140923")
        }
    }

    var defaultInnerPageBackground: DocumentBackgroundStyle {
        .solid("#000000")
    }
}

enum DocumentFontStyle: String, Codable, CaseIterable, Identifiable {
    case system, serif, mono, rounded

    var id: String { rawValue }

    var sample: String {
        switch self {
        case .system: return "Aa"
        case .serif: return "Ss"
        case .mono: return "00"
        case .rounded: return "Rr"
        }
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded:
            return "Rounded"
        case .mono:
            return "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded:
            return .rounded
        case .mono:
            return .monospaced
        }
    }

    var cssFamily: String {
        switch self {
        case .system: return "system-ui, sans-serif"
        case .serif: return "ui-serif, Georgia, serif"
        case .rounded:
            return "ui-rounded, system-ui, sans-serif"
        case .mono:
            return "ui-monospace, monospace"
        }
    }
}

enum DocumentBackgroundKind: String, Codable, CaseIterable, Identifiable {
    case none
    case solid
    case gradient
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .solid:
            return "Solid"
        case .gradient:
            return "Gradient"
        case .image:
            return "Image"
        }
    }
}

enum DocumentGradientDirection: String, Codable, CaseIterable, Identifiable {
    case topToBottom, leftToRight, diagonal, bottomToTop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topToBottom: return "Top to Bottom"
        case .leftToRight: return "Left to Right"
        case .diagonal: return "Diagonal"
        case .bottomToTop: return "Bottom to Top"
        }
    }
    var startPoint: UnitPoint {
        switch self {
        case .topToBottom: return .top
        case .leftToRight: return .leading
        case .diagonal: return .topLeading
        case .bottomToTop: return .bottom
        }
    }
    var endPoint: UnitPoint {
        switch self {
        case .topToBottom: return .bottom
        case .leftToRight: return .trailing
        case .diagonal: return .bottomTrailing
        case .bottomToTop: return .top
        }
    }
}

enum DocumentBackdropEffect: String, Codable, CaseIterable, Identifiable {
    case immersive, faded
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum VellixDividerStyle: String, CaseIterable, Identifiable {
    case dottedCircles
    case fourCircles
    case thinLine
    case thickLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dottedCircles:
            return "Dotted Circles"
        case .fourCircles:
            return "Four Circles"
        case .thinLine:
            return "Thin Line"
        case .thickLine:
            return "Thick Line"
        }
    }
}

struct DocumentBackgroundStyle: Codable, Equatable, Hashable {
    var kind: DocumentBackgroundKind
    var colorHex: String
    var secondaryColorHex: String
    var imagePath: String?
    // Optional fields preserve the decoding and rendering of existing appearance JSON.
    var gradientDirection: DocumentGradientDirection?
    var blurImage: Bool?
    var effect: DocumentBackdropEffect?
    var remotePhoto: CardRemotePhoto?

    static var none: Self { Self(kind: .none, colorHex: "#000000", secondaryColorHex: "#000000") }

    static func solid(_ hex: String) -> DocumentBackgroundStyle {
        DocumentBackgroundStyle(
            kind: .solid,
            colorHex: hex,
            secondaryColorHex: hex,
            imagePath: nil
        )
    }

    static func gradient(primary: String, secondary: String) -> DocumentBackgroundStyle {
        DocumentBackgroundStyle(
            kind: .gradient,
            colorHex: primary,
            secondaryColorHex: secondary,
            imagePath: nil
        )
    }

    static func image(path: String, fallback: String = "#000000") -> DocumentBackgroundStyle {
        DocumentBackgroundStyle(
            kind: .image,
            colorHex: fallback,
            secondaryColorHex: fallback,
            imagePath: path
        )
    }

    func patternTheme(for theme: DocumentThemeID?) -> DocumentThemeID? {
        guard let theme, theme != .custom else { return nil }
        let original = theme.defaultEditorBackground
        guard kind == original.kind,
              colorHex.caseInsensitiveCompare(original.colorHex) == .orderedSame,
              secondaryColorHex.caseInsensitiveCompare(original.secondaryColorHex) == .orderedSame,
              (gradientDirection ?? .diagonal) == (original.gradientDirection ?? .diagonal) else { return nil }
        return theme
    }
}

struct DocumentAppearance: Codable, Equatable, Hashable {
    var themeID: DocumentThemeID?
    var editorBackground: DocumentBackgroundStyle
    var innerPageBackground: DocumentBackgroundStyle
    var textColorHex: String
    var fontStyle: DocumentFontStyle
    var showsCover: Bool?
    var coverPhoto: CardRemotePhoto?
    var coverThemeID: DocumentThemeID?

    var displaysCover: Bool { showsCover ?? (themeID != nil) }
    var resolvedCoverTheme: DocumentThemeID { coverThemeID ?? themeID ?? .custom }

    mutating func enableCustomLayout() {
        if themeID == nil {
            themeID = .custom
            showsCover = false
        }
    }

    mutating func customizeBackdrop() {
        if displaysCover && coverThemeID == nil { coverThemeID = resolvedCoverTheme }
        enableCustomLayout()
        themeID = .custom
    }

    var nestedPageTintHex: String {
        func brightness(_ hex: String) -> Double {
            let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var value: UInt64 = 0
            guard (sanitized.count == 6 || sanitized.count == 8), Scanner(string: sanitized).scanHexInt64(&value) else { return 0 }
            if sanitized.count == 8 { value >>= 8 }
            let red = Double((value >> 16) & 0xFF) / 255
            let green = Double((value >> 8) & 0xFF) / 255
            let blue = Double(value & 0xFF) / 255
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        let average = (brightness(innerPageBackground.colorHex) + brightness(innerPageBackground.secondaryColorHex)) / 2
        return average < 0.5 ? "#FFFFFF" : "#000000"
    }

    static let plain = DocumentAppearance(
        themeID: nil,
        editorBackground: .solid("#343434"),
        innerPageBackground: .solid("#242424"),
        textColorHex: "#F7F7F7",
        fontStyle: .rounded
    )

    static func defaultForTheme(_ theme: DocumentThemeID?) -> DocumentAppearance {
        guard let theme else {
            return .plain
        }

        return DocumentAppearance(
            themeID: theme,
            editorBackground: theme.defaultEditorBackground,
            innerPageBackground: theme.defaultInnerPageBackground,
            textColorHex: theme == .lunarClouds ? "#8FE9FF" : "#FFFFFF",
            fontStyle: .rounded
        )
    }

    static func decode(_ json: String?) -> DocumentAppearance {
        guard
            let json,
            let data = json.data(using: .utf8),
            let appearance = try? JSONDecoder().decode(DocumentAppearance.self, from: data)
        else {
            return .plain
        }

        return appearance
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

extension DocumentRecord {
    var appearance: DocumentAppearance {
        DocumentAppearance.decode(appearanceJSON)
    }

    var isThemed: Bool {
        appearance.themeID != nil
    }
}

extension Color {
    init(vellixHex hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch sanitized.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        default:
            red = 1
            green = 1
            blue = 1
            alpha = 1
        }

        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}
