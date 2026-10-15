import SwiftUI

struct ImmediateTablePreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance

    private struct Cell: Identifiable {
        let id: String
        let row: Int
        let column: Int
        let rows: Int
        let columns: Int
        let value: [String: Any]
    }

    private var rows: [[String: Any]] { Array((node["content"] as? [[String: Any]] ?? []).prefix(32)) }
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

    private var heights: [CGFloat] {
        var result = Array(repeating: CGFloat(44), count: rows.count)
        for cell in cells {
            let width = widths[cell.column..<(cell.column + cell.columns)].reduce(0, +)
            let text = cellText(cell.value)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
                $0 + max(1, Int(ceil(Double($1.count) / max(1, Double(width - 32) / 8))))
            }
            result[cell.row] = max(result[cell.row], CGFloat(lines * 22 + 20) / CGFloat(cell.rows))
        }
        return result
    }

    var body: some View {
        let widths = widths, heights = heights
        let tableAttrs = node["attrs"] as? [String: Any] ?? [:]
        let left = max(0, tableAttrs["leftOffset"] as? Double ?? 0)
        ZStack(alignment: .topLeading) {
            ForEach(cells) { cell in
                let attrs = cell.value["attrs"] as? [String: Any] ?? [:]
                let isHeader = cell.value["type"] as? String == "tableHeader"
                let fill = attrs["fillColor"] as? String
                    ?? (isHeader ? "#066DB0" : (cell.row % 2 == 1 ? tableAttrs["stripeColor"] as? String : nil))
                let style = DocumentFontStyle(rawValue: attrs["font"] as? String ?? "") ?? appearance.fontStyle
                let width = widths[cell.column..<(cell.column + cell.columns)].reduce(0, +)
                let height = heights[cell.row..<(cell.row + cell.rows)].reduce(0, +)
                Text(cellText(cell.value))
                    .font(.system(size: 16, weight: (attrs["bold"] as? Bool ?? isHeader) ? .bold : .regular,
                                  design: attrs["code"] as? Bool == true ? .monospaced : style.design))
                    .italic(attrs["italic"] as? Bool == true)
                    .strikethrough(attrs["strike"] as? Bool == true)
                    .foregroundStyle(Color(vellixHex: attrs["textColor"] as? String ?? appearance.textColorHex))
                    .multilineTextAlignment(attrs["align"] as? String == "center" ? .center : attrs["align"] as? String == "right" ? .trailing : .leading)
                    .padding(10).frame(width: width, height: height, alignment: .topLeading)
                    .background(fill.map { Color(vellixHex: $0) } ?? .clear)
                    .overlay(Rectangle().strokeBorder(Color(vellixHex: appearance.textColorHex).opacity(0.15), lineWidth: 0.5))
                    .offset(x: widths.prefix(cell.column).reduce(0, +) + left, y: heights.prefix(cell.row).reduce(0, +))
            }
        }
        .frame(width: min(320, widths.reduce(0, +) + left), height: heights.reduce(0, +), alignment: .topLeading)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func cellText(_ node: [String: Any]) -> String {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        if let calculated = attrs["calculated"] as? String { return calculated }
        if let text = node["text"] as? String { return text }
        let children = node["content"] as? [[String: Any]] ?? []
        if children.isEmpty, attrs["placeholderEnabled"] as? Bool == true {
            return (attrs["placeholderGuidance"] as? [[String: Any]] ?? []).map(cellText).joined()
        }
        return children.map(cellText).joined(separator: node["type"] as? String == "paragraph" ? "" : "\n")
    }
}
