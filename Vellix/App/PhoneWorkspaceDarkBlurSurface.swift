import SwiftUI
#if os(iOS)
import UIKit

/// iPhone-only native dark blur; no custom color, gradient, or opaque overlay.
struct PhoneWorkspaceDarkBlurSurface: UIViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        if reduceTransparency {
            view.effect = nil
            view.backgroundColor = .secondarySystemBackground
        } else {
            view.backgroundColor = .clear
            if view.effect == nil {
                view.effect = UIBlurEffect(style: .dark)
            }
        }
    }
}
#endif

#if os(iOS)
/// Native dark blur for iPhone chrome, leaving iPad and macOS styling intact.
private struct PhoneDarkChromeModifier: ViewModifier {
    @Environment(\.pennedPhoneBlurEnabled) private var isPhone
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if isPhone {
                PhoneWorkspaceDarkBlurSurface()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }
}

extension View {
    func pennedPhoneDarkChrome(cornerRadius: CGFloat) -> some View {
        modifier(PhoneDarkChromeModifier(cornerRadius: cornerRadius))
    }
}
#endif
