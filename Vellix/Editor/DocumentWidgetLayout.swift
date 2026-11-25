import SwiftUI

nonisolated enum DocumentWidgetLayout {
    struct Specification: Decodable, Sendable {
        let version: Int
        let types: [String]
        let halfWidth: Double
        let fullWidth: Double
        let halfHeight: Double
        let fullHeight: Double
        let padding: Double
        let spacing: Double
        let pairGap: Double
    }

    static let specification: Specification = {
        if let bundle = Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle"),
           let data = try? Data(contentsOf: bundle.appendingPathComponent("document-widget-layout.json")),
           let value = try? JSONDecoder().decode(Specification.self, from: data), value.version == 1,
           value.halfWidth > 0, value.fullWidth > 0, value.halfHeight > 0, value.fullHeight > 0,
           value.padding >= 0, value.spacing >= 0, value.pairGap >= 0 { return value }
        return Specification(version: 1, types: ["moodBar", "countdown", "calculator"], halfWidth: 154, fullWidth: 320,
            halfHeight: 192, fullHeight: 192, padding: 6, spacing: 4, pairGap: 12)
    }()

    static func height(_ mode: String) -> CGFloat { CGFloat(mode == "half" ? specification.halfHeight : specification.fullHeight) }
    static func referenceWidth(_ mode: String) -> CGFloat { CGFloat(mode == "half" ? specification.halfWidth : specification.fullWidth) }
}

nonisolated struct DocumentWidgetMetrics {
    let size: CGSize
    let mode: String
    let borderWidth: CGFloat
    var inset: CGFloat { CGFloat(DocumentWidgetLayout.specification.padding) + borderWidth }
    var spacing: CGFloat { CGFloat(DocumentWidgetLayout.specification.spacing) }
    var width: CGFloat { max(1, size.width - inset * 2) }
    var height: CGFloat { max(1, size.height - inset * 2) }
    var compact: Bool { size.width < 230 }
    var keyGap: CGFloat { min(3, width * 0.015) }
    var displayHeight: CGFloat { 40 }
    var keyHeight: CGFloat { max(1, (height - displayHeight - spacing - keyGap * 4) / 5) }
}

private struct DocumentWidgetFrameLayout: Layout {
    let mode: String
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? DocumentWidgetLayout.referenceWidth(mode)
        return CGSize(width: max(1, width), height: DocumentWidgetLayout.height(mode))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

struct DocumentWidgetFrame<Content: View>: View {
    let mode: String
    let background: String
    let border: String
    let borderWidth: Int
    let radius: CGFloat
    let content: (DocumentWidgetMetrics) -> Content

    init(mode: String, background: String, border: String, borderWidth: Int, radius: CGFloat = 8,
         @ViewBuilder content: @escaping (DocumentWidgetMetrics) -> Content) {
        self.mode = mode
        self.background = background
        self.border = border
        self.borderWidth = borderWidth
        self.radius = radius
        self.content = content
    }

    var body: some View {
        DocumentWidgetFrameLayout(mode: mode) {
            GeometryReader { proxy in
                let metrics = DocumentWidgetMetrics(size: proxy.size, mode: mode, borderWidth: CGFloat(borderWidth))
                content(metrics).frame(width: metrics.width, height: metrics.height)
                    .padding(metrics.inset)
            }
        }
        .background(Color(vellixHex: background), in: RoundedRectangle(cornerRadius: radius))
        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color(vellixHex: border), lineWidth: CGFloat(borderWidth)) }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}
