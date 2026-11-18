import SwiftUI

struct StickyNotePagePreview: View {
    var snapshot: CGImage?
    var size: CGSize

    var body: some View {
        let paper = StickyNotePaperShape()
        ZStack(alignment: .topLeading) {
            paper.fill(LinearGradient(colors: [Color(vellixHex: "#FFF9D8"), Color(vellixHex: "#FFF2AE"), Color(vellixHex: "#FFEB91")],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            if let snapshot {
                let inset = size.width * 0.065
                Image(decorative: snapshot, scale: 1).resizable().scaledToFill()
                    .frame(width: size.width - inset * 2, height: size.height - inset * 2, alignment: .top)
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 2))
                    .offset(x: inset, y: inset)
            }
            paper.fill(LinearGradient(colors: [.white.opacity(0.10), .clear, Color(vellixHex: "#9D7928").opacity(0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            StickyNoteCurlShape().fill(LinearGradient(colors: [.white.opacity(0.65), Color(vellixHex: "#D9B953").opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.20), radius: max(0.5, size.width * 0.012), x: -0.5, y: -0.5)
            paper.stroke(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.12), .black.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(paper)
        .background {
            paper.fill(Color(vellixHex: "#D6BB67"))
                .offset(x: 0.6, y: max(0.8, size.height * 0.012))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.20), radius: 0.7, x: 0, y: 0.8)
        .shadow(color: .black.opacity(0.32), radius: max(2, size.width * 0.035), x: 1, y: max(2, size.height * 0.035))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [Color(vellixHex: "#8C793F").opacity(0.44), Color(vellixHex: "#B09B52").opacity(0.40)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: size.width * 0.48, height: size.height * 0.13)
                .overlay { Rectangle().stroke(.white.opacity(0.18), lineWidth: 0.4) }
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.6)
                .rotationEffect(.degrees(-2))
                .offset(y: -size.height * 0.065)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StickyNotePaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * 0.045
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.15))
        path.addCurve(to: CGPoint(x: rect.maxX - rect.width * 0.23, y: rect.maxY - r * 0.5),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - r), control2: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY - r * 0.6))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

}

private struct StickyNoteCurlShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.27, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.19),
            control1: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.maxY - rect.height * 0.035),
            control2: CGPoint(x: rect.maxX - rect.width * 0.025, y: rect.maxY - rect.height * 0.10))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
