import SwiftUI

struct ImmediateTablePreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    var maximumRows = 32
    var depth = 0
    var collections: [CollectionSnapshot] = []
    var referencedDocuments: [DocumentRecord] = []
    var maximumBlocks = 96

    private struct Cell: Identifiable {
        let id: String
        let row: Int
        let column: Int
        let rows: Int
        let columns: Int
        let value: [String: Any]
    }

    private var rows: [[String: Any]] { Array((node["content"] as? [[String: Any]] ?? []).prefix(maximumRows)) }
    private var cells: [Cell] {
        var result: [Cell] = []
        var occupied: Set<String> = []
        for (row, value) in rows.enumerated() {
            var column = 0
            for (index, cell) in (value["content"] as? [[String: Any]] ?? []).enumerated() {
                while occupied.contains("\(row):\(column)") { column += 1 }
                let attrs = cell["attrs"] as? [String: Any] ?? [:]
                let span = max(1, min(32, attrs["colspan"] as? Int ?? 1))
                let height = max(1, min(rows.count - row, attrs["rowspan"] as? Int ?? 1))
                result.append(Cell(id: "\(row):\(index)", row: row, column: column, rows: height, columns: span, value: cell))
                for r in row..<(row + height) { for c in column..<(column + span) { occupied.insert("\(r):\(c)") } }
                column += span
            }
        }
        return result
    }

    private var widths: [CGFloat] {
        let count = cells.map { $0.column + $0.columns }.max() ?? 1
        var result = Array(repeating: CGFloat(100), count: count)
        for cell in cells where cell.row == 0 {
            let attrs = cell.value["attrs"] as? [String: Any] ?? [:]
            let widths = attrs["colwidth"] as? [Double] ?? []
            for (index, width) in widths.enumerated() where cell.column + index < result.count {
                result[cell.column + index] = max(56, min(3000, width))
            }
        }
        return result
    }

    var body: some View {
        let widths = widths
        let tableAttrs = node["attrs"] as? [String: Any] ?? [:]
        let left = max(0, tableAttrs["leftOffset"] as? Double ?? 0)
        PreviewGrid(cells: cells, widths: widths, rowCount: rows.count, left: left) {
            ForEach(cells) { cell in
                let attrs = cell.value["attrs"] as? [String: Any] ?? [:]
                let isHeader = cell.value["type"] as? String == "tableHeader"
                let fill = attrs["fillColor"] as? String
                    ?? (isHeader ? appearance.presentationColors.tableHeader : (cell.row % 2 == 1 ? tableAttrs["stripeColor"] as? String : nil))
                let style = DocumentFontStyle(rawValue: attrs["font"] as? String ?? "") ?? appearance.fontStyle
                let width = widths[cell.column..<(cell.column + cell.columns)].reduce(0, +)
                let children = cell.value["content"] as? [[String: Any]] ?? []
                let structured = children.contains { !["paragraph", "caption", "heading", "text", "hardBreak", "inlineTag"].contains($0["type"] as? String ?? "") }
                Group {
                    if structured, attrs["calculated"] == nil {
                        ImmediatePreviewBlocks(nodes: children, appearance: appearance, depth: depth + 1,
                            collections: collections, referencedDocuments: referencedDocuments, spacing: 6, maximumBlocks: maximumBlocks)
                    } else {
                        styledCellText(cell.value, fontStyle: style, weight: (attrs["bold"] as? Bool ?? isHeader) ? .bold : .regular,
                                       italic: attrs["italic"] as? Bool == true)
                    }
                }
                    .font(style.font(size: 14, weight: (attrs["bold"] as? Bool ?? isHeader) ? .bold : .regular,
                                     code: attrs["code"] as? Bool == true, italic: attrs["italic"] as? Bool == true))
                    .strikethrough(attrs["strike"] as? Bool == true)
                    .foregroundStyle(Color(vellixHex: attrs["textColor"] as? String ?? appearance.textColorHex))
                    .multilineTextAlignment(attrs["align"] as? String == "center" ? .center : attrs["align"] as? String == "right" ? .trailing : .leading)
                    .padding(10).frame(width: width, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(fill.map { Color(vellixHex: $0) } ?? .clear)
                    .overlay(Rectangle().strokeBorder(Color(vellixHex: appearance.textColorHex).opacity(0.15), lineWidth: 0.5))
            }
        }
        .clipped().clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private struct PreviewGrid: Layout {
        let cells: [Cell]
        let widths: [CGFloat]
        let rowCount: Int
        let left: CGFloat

        private func frames(_ subviews: Subviews) -> [CGRect] {
            var heights = Array(repeating: CGFloat(44), count: rowCount)
            for (cell, subview) in zip(cells, subviews) {
                let width = widths[cell.column..<(cell.column + cell.columns)].reduce(0, +)
                let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                let required = measured.isFinite ? measured : 44
                let range = cell.row..<(cell.row + cell.rows)
                let extra = max(0, required - heights[range].reduce(0, +)) / CGFloat(cell.rows)
                for row in range { heights[row] += extra }
            }
            return cells.map { cell in
                CGRect(x: widths.prefix(cell.column).reduce(0, +) + left, y: heights.prefix(cell.row).reduce(0, +),
                    width: widths[cell.column..<(cell.column + cell.columns)].reduce(0, +),
                    height: heights[cell.row..<(cell.row + cell.rows)].reduce(0, +))
            }
        }
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? widths.reduce(0, +) + left
            return CGSize(width: max(1, width), height: frames(subviews).map(\.maxY).max() ?? 0)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for (subview, frame) in zip(subviews, frames(subviews)) {
                subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(frame.size))
            }
        }
    }

    private func cellText(_ node: [String: Any]) -> String {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        if node["type"] as? String == "inlineTag", let name = attrs["name"] as? String { return "#" + name }
        if let calculated = attrs["calculated"] as? String { return calculated }
        if let text = node["text"] as? String { return text }
        let children = node["content"] as? [[String: Any]] ?? []
        if children.isEmpty, attrs["placeholderEnabled"] as? Bool == true {
            return (attrs["placeholderGuidance"] as? [[String: Any]] ?? []).map(cellText).joined()
        }
        return children.map(cellText).joined(separator: node["type"] as? String == "paragraph" ? "" : "\n")
    }

    private func styledCellText(_ node: [String: Any], fontStyle: DocumentFontStyle, weight: Font.Weight, italic: Bool) -> Text {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        if let calculated = attrs["calculated"] as? String { return Text(calculated) }
        let children = node["content"] as? [[String: Any]] ?? []
        if node["type"] as? String == "paragraph" {
            var cellAppearance = appearance
            cellAppearance.fontStyle = fontStyle
            return InlineTextPreview.text(children, appearance: cellAppearance, size: 14, weight: weight, italic: italic)
        }
        if children.isEmpty { return Text(cellText(node)) }
        return children.enumerated().reduce(Text("")) { result, item in
            result + Text(item.offset == 0 ? "" : "\n") + styledCellText(item.element, fontStyle: fontStyle, weight: weight, italic: italic)
        }
    }
}
