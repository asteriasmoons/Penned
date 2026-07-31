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
    case serif
    case rounded
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif:
            return "Serif"
        case .rounded:
            return "Rounded"
        case .mono:
            return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif:
            return .serif
        case .rounded:
            return .rounded
        case .mono:
            return .monospaced
        }
    }

    var cssFamily: String {
        switch self {
        case .serif:
            return "Georgia, 'Times New Roman', serif"
        case .rounded:
            return "'SF Pro Rounded', -apple-system, BlinkMacSystemFont, sans-serif"
        case .mono:
            return "'SF Mono', Menlo, Monaco, monospace"
        }
    }
}

enum DocumentBackgroundKind: String, Codable, CaseIterable, Identifiable {
    case solid
    case gradient
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradient:
            return "Gradient"
        case .image:
            return "Image"
        }
    }
}

enum VellixDividerStyle: String, CaseIterable, Identifiable {
    case fourDots
    case tinyDots
    case thinLine
    case thickLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourDots:
            return "4 Dots"
        case .tinyDots:
            return "Tiny Dots"
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
}

struct DocumentAppearance: Codable, Equatable, Hashable {
    var themeID: DocumentThemeID?
    var editorBackground: DocumentBackgroundStyle
    var innerPageBackground: DocumentBackgroundStyle
    var textColorHex: String
    var fontStyle: DocumentFontStyle

    static let plain = DocumentAppearance(
        themeID: nil,
        editorBackground: .solid("#202020"),
        innerPageBackground: .solid("#000000"),
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
            fontStyle: theme == .custom ? .rounded : .serif
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
