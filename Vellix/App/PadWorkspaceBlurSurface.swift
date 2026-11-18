import SwiftUI
#if os(iOS)
import UIKit

/// Native UIKit blur shared by iPhone and iPad workspace surfaces.
struct PadWorkspaceBlurSurface: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemUltraThinMaterial
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        if reduceTransparency {
            if view.effect != nil { view.effect = nil }
            view.backgroundColor = .secondarySystemBackground
        } else {
            view.backgroundColor = .clear
            if view.effect == nil {
                view.effect = UIBlurEffect(style: style)
            }
        }
    }
}

private struct PennedPhoneBlurEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PennedPadBlurEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pennedPhoneBlurEnabled: Bool {
        get { self[PennedPhoneBlurEnabledKey.self] }
        set { self[PennedPhoneBlurEnabledKey.self] = newValue }
    }

    /// Enabled by PadWorkspaceView only.
    var pennedPadBlurEnabled: Bool {
        get { self[PennedPadBlurEnabledKey.self] }
        set { self[PennedPadBlurEnabledKey.self] = newValue }
    }
}
/// Shared page surfaces use native blur in the iPad or iPhone workspace.
struct PadWorkspacePageBackground: View {
    @Environment(\.pennedPadBlurEnabled) private var isPadWorkspace
    @Environment(\.pennedPhoneBlurEnabled) private var isPhoneWorkspace
    let fallback: Color
    var style: UIBlurEffect.Style = .systemUltraThinMaterial

    var body: some View {
        Group {
            if isPhoneWorkspace {
                Color.black
            } else if isPadWorkspace {
                Color.black
            } else {
                fallback
            }
        }
    }
}

#endif
