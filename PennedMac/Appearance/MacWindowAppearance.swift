import AppKit
import Combine
import SwiftUI

// Project rule: no @AppStorage. This observable store is the Mac-side source of
// truth for the appearance preference. It reads/writes the same UserDefaults key the
// shared PennedAppearancePreference uses, so the shared appearance modifier stays in sync.
@MainActor final class PennedMacAppearanceStore: ObservableObject {
    static let shared = PennedMacAppearanceStore()
    @Published var preference: PennedAppearancePreference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: PennedAppearancePreference.storageKey) }
    }
    private init() { preference = PennedAppearancePreference.read() }
}

struct MacWindowAppearance: NSViewRepresentable {
    @ObservedObject private var store = PennedMacAppearanceStore.shared
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let preference = store.preference
        let name: NSAppearance.Name? = preference == .system ? nil : preference == .dark ? .darkAqua : .aqua
        DispatchQueue.main.async {
            guard let window = view.window, window.appearance?.name != name else { return }
            window.appearance = name.flatMap(NSAppearance.init(named:))
        }
    }
}

extension Menu {
    func macIconMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).tint(VellixSurface.ink)
    }
}

extension MacPopoverMenu {
    func macIconMenuStyle() -> some View { self }
}
