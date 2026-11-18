import SwiftUI

// Match the editor's persisted colors, column sizing, and legacy header fallback.
nonisolated struct ListGridPreviewData {
    struct Cell {
        let paragraph: [String: Any]
        let fill: String
        let border: String?
        let ink: String

        var attrs: [String: Any] { paragraph["attrs"] as? [String: Any] ?? [:] }
        var alignment: String? { attrs["textAlign"] as? String }
        var content: [[String: Any]] { paragraph["content"] as? [[String: Any]] ?? [] }
        var guidance: [[String: Any]] {
            guard content.isEmpty, attrs["placeholderEnabled"] as? Bool == true else { return [] }
            return attrs["placeholderGuidance"] as? [[String: Any]] ?? []
        }
    }

    static let gap: CGFloat = 6
    static let inset: CGFloat = 7
    static let cellMinHeight: CGFloat = 42
    static let cellRadius: CGFloat = 4
    static let cardRadius: CGFloat = 8
    static let fontSize: CGFloat = 14

    let fill: String
    let border: String
    let leftFraction: CGFloat
    private let leftFill: String
    private let cellBorder: String
    private let leftInk: String
    let rows: [[String: Any]]

    init(node: [String: Any]) {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        fill = Self.color(attrs["cardBackground"], fallback: "#F2F2F2")
        border = Self.color(attrs["cardBorder"], fallback: "#D1D1D1")
        let left = Self.color(attrs["leftBackground"], fallback: "#E4E4E4")
        leftFill = left
        leftInk = Self.contrastInk(for: left)
        cellBorder = Self.color(attrs["rightBorder"], fallback: "#D1D1D1")
        let fraction = (attrs["leftFraction"] as? NSNumber)?.doubleValue
            ?? (attrs["leftFraction"] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        leftFraction = fraction.flatMap { $0.isFinite ? CGFloat(min(80, max(20, $0.rounded()))) / 100 : nil } ?? 0.34
        rows = node["content"] as? [[String: Any]] ?? []
    }

    func cells(for row: [String: Any]) -> [Cell] {
        let attrs = row["attrs"] as? [String: Any] ?? [:]
        let style: String
        switch attrs["rowStyle"] as? String {
        case "default": style = "default"
        case "filled": style = "filled"
        case "outlined": style = "outlined"
        default: style = attrs["isHeader"] as? Bool == true ? "filled" : "default"
        }
        let nodes = row["content"] as? [[String: Any]] ?? []
        return ["listGridLabel", "listGridValue"].enumerated().map { index, type in
            let node = nodes.first { $0["type"] as? String == type }
            let paragraph = (node?["content"] as? [[String: Any]])?.first ?? [:]
            let filled = index == 0 ? style != "outlined" : style == "filled"
            return Cell(paragraph: paragraph, fill: filled ? leftFill : "#FFFFFF",
                        border: filled ? nil : cellBorder,
                        ink: filled ? leftInk : "#171717")
        }
    }

    private static func color(_ value: Any?, fallback: String) -> String {
        guard let hex = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              hex.hasPrefix("#"), hex.count == 7 || hex.count == 9,
              hex.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return fallback }
        return hex
    }

    private static func contrastInk(for hex: String) -> String {
        let rgb = UInt32(hex.dropFirst().prefix(6), radix: 16) ?? 0
        func linear(_ shift: UInt32) -> Double {
            let channel = Double((rgb >> shift) & 255) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0) > 0.20 ? "#171717" : "#FFFFFF"
    }
}

struct ListGridPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance

    var body: some View {
        let grid = ListGridPreviewData(node: node)
        let shape = RoundedRectangle(cornerRadius: ListGridPreviewData.cardRadius)
        VStack(spacing: ListGridPreviewData.gap) {
            ForEach(Array(grid.rows.prefix(32).enumerated()), id: \.offset) { _, row in
                ListGridPreviewRow(leftFraction: grid.leftFraction) {
                    ForEach(Array(grid.cells(for: row).enumerated()), id: \.offset) { _, cell in
                        cellView(cell)
                    }
                }
            }
        }
        .padding(ListGridPreviewData.inset)
        .background(Color(vellixHex: grid.fill), in: shape)
        .overlay(shape.strokeBorder(Color(vellixHex: grid.border), lineWidth: 1))
    }

    private func cellView(_ cell: ListGridPreviewData.Cell) -> some View {
        let alignment: HorizontalAlignment = cell.alignment == "center" ? .center : cell.alignment == "right" ? .trailing : .leading
        let textAlignment: TextAlignment = cell.alignment == "center" ? .center : cell.alignment == "right" ? .trailing : .leading
        let guidance = cell.guidance
        let shape = RoundedRectangle(cornerRadius: ListGridPreviewData.cellRadius)
        let fontSize = ListGridPreviewData.fontSize
        let borderInset: CGFloat = cell.border == nil ? 0 : 1
        return InlineTextPreview.text(guidance.isEmpty ? cell.content : guidance, appearance: appearance, size: fontSize)
            .font(appearance.fontStyle.font(size: fontSize))
            .foregroundStyle(Color(vellixHex: cell.ink))
            .opacity(guidance.isEmpty ? 1 : 0.38)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9 + borderInset)
            .padding(.vertical, 8 + borderInset)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: ListGridPreviewData.cellMinHeight, maxHeight: .infinity,
                   alignment: Alignment(horizontal: alignment, vertical: .center))
            .background(Color(vellixHex: cell.fill), in: shape)
            .clipShape(shape)
            .overlay {
                if let border = cell.border { shape.strokeBorder(Color(vellixHex: border), lineWidth: 1) }
            }
    }
}

private struct ListGridPreviewRow: Layout {
    let leftFraction: CGFloat

    private func columns(for width: CGFloat) -> (left: CGFloat, right: CGFloat, gap: CGFloat) {
        let gap = min(width, ListGridPreviewData.gap)
        let left = (width - gap) * leftFraction
        return (left, width - gap - left, gap)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        let columns = columns(for: width)
        let left = subviews[0].sizeThatFits(ProposedViewSize(width: columns.left, height: nil))
        let right = subviews[1].sizeThatFits(ProposedViewSize(width: columns.right, height: nil))
        return CGSize(width: width, height: max(left.height, right.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let columns = columns(for: bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: columns.left, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + columns.left + columns.gap, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columns.right, height: bounds.height))
    }
}
