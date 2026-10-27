import SwiftUI

/// Shared frosted-glass recipe, ported from Voxiverse without content sizing.
struct PennedFrostedMaterial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let tint: Color
    var cornerRadius: CGFloat = 17

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if reduceTransparency { shape.fill(tint) } else {
            coloredField

            Color.clear
                .glassEffect(.regular.tint(tint.opacity(0.22)), in: shape)

            frostClouds
            }
        }
        .clipShape(shape)
    }

    private var coloredField: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                tint.opacity(0.5)

                Ellipse()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: w * 1.15, height: h * 1.05)
                    .offset(x: -w * 0.28, y: -h * 0.4)

                Ellipse()
                    .fill(tint)
                    .frame(width: w * 1.0, height: h * 0.95)
                    .offset(x: w * 0.04, y: h * 0.26)

                Ellipse()
                    .fill(VellixSurface.appBackground.opacity(0.4))
                    .frame(width: w * 0.9, height: h * 0.85)
                    .offset(x: w * 0.36, y: h * 0.4)
            }
            .blur(radius: 28)
            .frame(width: w, height: h)
            .scaleEffect(1.15)
        }
    }

    // Only the internal pigment and frost are blurred, never field content.
    private var frostClouds: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Ellipse()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: w * 0.95, height: h * 0.7)
                    .offset(x: -w * 0.16, y: -h * 0.08)
                    .blur(radius: 26)

                Ellipse()
                    .fill(Color.white.opacity(0.11))
                    .frame(width: w * 0.7, height: h * 0.6)
                    .offset(x: w * 0.3, y: h * 0.2)
                    .blur(radius: 24)

                Ellipse()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: w * 0.6, height: h * 0.5)
                    .offset(x: w * 0.12, y: -h * 0.32)
                    .blur(radius: 22)
            }
            .frame(width: w, height: h)
        }
    }
}

/// Optional content wrapper; fields use the material alone to retain their layout.
struct PennedFrostedCard<Content: View>: View {
    let tint: Color
    var cornerRadius: CGFloat = 17
    var contentPadding: CGFloat = 15
    var minHeight: CGFloat? = nil
    var alignment: Alignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(contentPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .background(PennedFrostedMaterial(tint: tint, cornerRadius: cornerRadius))
            .shadow(color: VellixSurface.appBackground.opacity(0.5), radius: 8, y: 5)
            .shadow(color: tint.opacity(0.32), radius: 6)
    }
}
