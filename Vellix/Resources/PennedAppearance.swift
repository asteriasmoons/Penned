import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PennedAppearancePreference: String, CaseIterable, Codable, Identifiable {
    case light, dark, system

    static let storageKey = "penned.applicationAppearance"
    static let defaultValue: Self = .dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    func effectiveScheme(system: ColorScheme) -> ColorScheme { colorScheme ?? system }

    static func read(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

extension Color {
    static func penned(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        let light = UIColor(light), dark = UIColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #elseif canImport(AppKit)
        let light = NSColor(light), dark = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #else
        return dark
        #endif
    }
}

private struct PennedApplicationAppearance: ViewModifier {
    @AppStorage(PennedAppearancePreference.storageKey) private var preference = PennedAppearancePreference.defaultValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(preference.colorScheme)
    }
}

extension View {
    func pennedApplicationAppearance() -> some View { modifier(PennedApplicationAppearance()) }
}

