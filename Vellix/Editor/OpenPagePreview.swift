import SwiftUI

struct OpenPageSnapshots {
    let left: CGImage
    let right: CGImage

    var cost: Int { left.bytesPerRow * left.height + right.bytesPerRow * right.height }
}

struct OpenPagePreview: View {
    var snapshots: OpenPageSnapshots?
    var size: CGSize
    var paperColor = "#242424"

    var body: some View {
        HStack(spacing: 0) {
            page(snapshots?.left, isRight: false)
            page(snapshots?.right, isRight: true)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.25), location: 0.3),
                .init(color: .black.opacity(0.65), location: 0.5),
                .init(color: .black.opacity(0.25), location: 0.7),
                .init(color: .clear, location: 1)
            ],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: max(2, size.width * 0.045), height: size.height * 0.925)
                .offset(y: size.height * 0.035)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 0.8, x: 0, y: 1)
        .shadow(color: .black.opacity(0.38), radius: max(2, size.width * 0.03), x: 1, y: max(2, size.height * 0.035))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func page(_ snapshot: CGImage?, isRight: Bool) -> some View {
        let inset = max(0.6, size.width * 0.008)
        let depth = max(1, size.height * 0.022)
        let faceHeight = size.height - depth
        let shape = OpenPageLeaf(isRight: isRight)
        let rim = LinearGradient(stops: [
            .init(color: .white.opacity(0.30), location: 0),
            .init(color: .white.opacity(0.07), location: 0.45),
            .init(color: .black.opacity(0.40), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack(alignment: .topLeading) {
            ForEach([CGFloat(1), CGFloat(0.5)], id: \.self) { fraction in
                shape.fill(Color(vellixHex: paperColor))
                    .overlay { shape.fill(.black.opacity(0.16)) }
                    .overlay { shape.stroke(rim, lineWidth: 0.6) }
                    .frame(width: size.width / 2, height: faceHeight)
                    .offset(y: depth * fraction)
            }
            ZStack {
                Color(vellixHex: paperColor)
                if let snapshot {
                    Image(decorative: snapshot, scale: 1).resizable().scaledToFill()
                        .frame(width: size.width / 2 - inset * 2, height: faceHeight - inset * 2, alignment: .top)
                        .clipped()
                }
                // Light rolls over the raised leaf and falls into the binding, above the snapshot.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.48), location: 0),
                    .init(color: .black.opacity(0.12), location: 0.06),
                    .init(color: .white.opacity(0.09), location: 0.20),
                    .init(color: .clear, location: 0.55),
                    .init(color: .white.opacity(0.03), location: 0.80),
                    .init(color: .black.opacity(0.10), location: 1)
                ], startPoint: isRight ? .leading : .trailing, endPoint: isRight ? .trailing : .leading)
                LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.07)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: size.width / 2, height: faceHeight)
            .clipShape(shape)
            .overlay { shape.stroke(rim, lineWidth: 0.6) }
        }
        .frame(width: size.width / 2, height: size.height, alignment: .topLeading)
    }
}

private struct OpenPageLeaf: Shape {
    var isRight: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(4, rect.width * 0.06)
        let bend = rect.height * 0.035
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + bend),
            control1: CGPoint(x: rect.minX + rect.width * 0.5, y: rect.minY),
            control2: CGPoint(x: rect.minX + rect.width * 0.85, y: rect.minY + bend * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bend * 0.5))
        path.addCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control1: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.maxY - bend * 0.9),
            control2: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return isRight ? path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)) : path
    }
}
