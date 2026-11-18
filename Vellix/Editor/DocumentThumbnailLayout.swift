import Foundation
import CoreGraphics

// Transient drawing instructions, derived only from the saved TipTap document.
nonisolated struct DocumentThumbnailLayout: Equatable {
    enum Shape: Equatable {
        case line, container, bullet, number(Int), checkbox(checked: Bool, crossed: Bool)
        case toggle(open: Bool), image, chip, washiTape
        case gridCardIcon(String)
        case headingLabel(String, level: Int, settings: HeadingLabelSettings)
        case listGridSurface(border: String?, radius: CGFloat, borderWidth: CGFloat)
        case listGridText(String, alignment: String?, fontSize: CGFloat, isGuidance: Bool)
    }

    struct Mark: Equatable {
        var shape: Shape
        var rect: CGRect
        var blockType: String
        var colorHex: String?
        var imagePath: String? = nil
        var imageTintHex: String? = nil
    }

    private(set) var marks: [Mark] = []
    private(set) var coverRect: CGRect?
    private(set) var isEmpty = true
    static let size = CGSize(width: 100, height: 130)

    init(json: String, title: String, monospaced: Bool = false, showsCover: Bool = false) {
        var builder = Builder(monospaced: monospaced)
        if showsCover {
            let rect = CGRect(x: 10, y: builder.y, width: 80, height: 80 / 1.78)
            coverRect = rect
            builder.y = rect.maxY + 8
        }
        builder.text(title, type: "title", x: 10, width: 80, thickness: 4, maxLines: 1)
        builder.y += 4
        let titleCount = builder.marks.count
        let document = TipTapContentAnalyzer.documentObject(from: json)
        builder.blocks(document["content"] as? [[String: Any]] ?? [], x: 10, width: 80)
        marks = builder.marks
        isEmpty = !showsCover && marks.count == titleCount
    }

    private struct Builder {
        var marks: [Mark] = []
        var y: CGFloat = 10
        var remainingNodes = 256
        var monospaced: Bool
        let bottom: CGFloat = 120

        mutating func add(_ shape: Shape, _ rect: CGRect, _ type: String, color: String? = nil,
                          imagePath: String? = nil, imageTint: String? = nil) {
            guard rect.minY < bottom, rect.width > 0 else { return }
            marks.append(Mark(shape: shape, rect: rect, blockType: type, colorHex: color,
                              imagePath: imagePath, imageTintHex: imageTint))
        }

        // Line lengths and wrapping follow actual text, not a decorative pattern.
        mutating func text(_ value: String, type: String, x: CGFloat, width: CGFloat,
                           thickness: CGFloat = 2.6, maxLines: Int = 16, alignment: String? = nil, color: String? = nil) {
            let advance: CGFloat = monospaced || type == "codeBlock" ? 1.9 : 1.65
            var length: CGFloat = 0
            var lines = 0
            func startX(_ length: CGFloat) -> CGFloat {
                switch alignment {
                case "center": return x + (width - length) / 2
                case "right": return x + width - length
                default: return x
                }
            }
            for character in value.prefix(2048) {
                guard y < bottom, lines < maxLines else { break }
                let step = character.isWhitespace ? advance * 0.6 : advance
                if character.isNewline || length + step > width {
                    if length > 0 {
                        add(.line, CGRect(x: startX(length), y: y, width: length, height: thickness), type, color: color)
                    }
                    y += 6.8
                    lines += 1
                    length = 0
                    if character.isNewline { continue }
                }
                guard y < bottom, lines < maxLines else { break }
                length += step
            }
            if length > 0, lines < maxLines, y < bottom {
                add(.line, CGRect(x: startX(length), y: y, width: length, height: thickness), type, color: color)
                y += 6.8
            } else if value.isEmpty {
                y += 6.8
            }
        }

        func inlineText(_ node: [String: Any], depth: Int = 0) -> String {
            guard depth < 16 else { return "" }
            if node["type"] as? String == "hardBreak" { return "\n" }
            if node["type"] as? String == "inlineTag", let name = (node["attrs"] as? [String: Any])?["name"] as? String { return "#" + name }
            if let text = node["text"] as? String { return String(text.prefix(2048)) }
            var result = ""
            for child in (node["content"] as? [[String: Any]] ?? []).prefix(256) {
                result += inlineText(child, depth: depth + 1)
                if result.count >= 2048 { return String(result.prefix(2048)) }
            }
            return result
        }

        mutating func listGrid(_ node: [String: Any], x: CGFloat, width: CGFloat) {
            let grid = ListGridPreviewData(node: node)
            let scale = width / 320
            let inset = ListGridPreviewData.inset * scale
            let gap = ListGridPreviewData.gap * scale
            let available = width - 2 * inset - gap
            let widths = [available * grid.leftFraction, available * (1 - grid.leftFraction)]
            let font = ListGridPreviewData.fontSize * scale
            let top = y
            let insertionIndex = marks.count
            y += inset
            for row in grid.rows {
                guard y < bottom, remainingNodes > 0 else { break }
                remainingNodes -= 1
                let cells = grid.cells(for: row)
                let values = cells.map { cell in
                    let guidance = cell.guidance
                    let string = guidance.isEmpty ? inlineText(cell.paragraph)
                        : guidance.prefix(256).map { inlineText($0) }.joined()
                    return (text: String(string.prefix(256)), isGuidance: !guidance.isEmpty)
                }
                let horizontalInsets = cells.map { (9 + ($0.border == nil ? 0 : 1)) * scale }
                let minHeight = ListGridPreviewData.cellMinHeight * scale
                let height = widths.indices.reduce(minHeight) { height, index in
                    let charactersPerLine = max(1, Int((widths[index] - 2 * horizontalInsets[index]) / (font * 0.55)))
                    let lines = values[index].text.split(separator: "\n", omittingEmptySubsequences: false)
                        .reduce(0) { $0 + max(1, ($1.count + charactersPerLine - 1) / charactersPerLine) }
                    return max(height, CGFloat(lines) * font * 1.35 + 18 * scale)
                }
                let visibleHeight = min(height, bottom - y)
                var left = x + inset
                for (index, cell) in cells.enumerated() {
                    let rect = CGRect(x: left, y: y, width: widths[index], height: visibleHeight)
                    add(.listGridSurface(border: cell.border, radius: ListGridPreviewData.cellRadius * scale, borderWidth: scale),
                        rect, "listGrid", color: cell.fill)
                    if !values[index].text.isEmpty {
                        let textRect = rect.insetBy(dx: horizontalInsets[index], dy: min(4 * scale, rect.height / 4))
                        add(.listGridText(values[index].text, alignment: cell.alignment, fontSize: font, isGuidance: values[index].isGuidance),
                            textRect, "listGrid", color: cell.ink)
                    }
                    left += rect.width + gap
                }
                y += height + gap
            }
            y = min(bottom, max(top + inset, y - gap) + inset)
            marks.insert(Mark(shape: .listGridSurface(border: grid.border, radius: ListGridPreviewData.cardRadius * scale, borderWidth: scale),
                              rect: CGRect(x: x, y: top, width: width, height: y - top),
                              blockType: "listGrid", colorHex: grid.fill), at: insertionIndex)
            y += 4
        }

        mutating func gridCard(_ node: [String: Any], x: CGFloat, width: CGFloat, scale: CGFloat) {
            let card = GridCardSettings(node["attrs"] as? [String: Any] ?? [:])
            let top = y, insertion = marks.count
            let inset = min(width / 4, 14 * scale)
            let iconSize = min(28 * scale, width - 2 * inset)
            let iconX = card.alignment == .center ? x + (width - iconSize) / 2
                : card.alignment == .right ? x + width - inset - iconSize : x + inset
            y += inset
            add(.gridCardIcon(card.icon), CGRect(x: iconX, y: y, width: iconSize, height: iconSize), "gridCard", color: card.iconColor)
            y += iconSize + 3
            if !card.title.isEmpty {
                text(card.title, type: "gridCardTitle", x: x + inset, width: width - 2 * inset,
                     thickness: 3.2, maxLines: 3, alignment: card.alignment.rawValue, color: card.inkColor)
            }
            for child in (node["content"] as? [[String: Any]] ?? []).prefix(16) {
                text(inlineText(child), type: "gridCardText", x: x + inset, width: width - 2 * inset,
                     thickness: 2.1, maxLines: 10, color: card.inkColor)
            }
            y = min(bottom, max(top + CGFloat(card.height) * scale, y + inset))
            marks.insert(Mark(shape: .container, rect: CGRect(x: x, y: top, width: width, height: y - top),
                              blockType: "gridCard", colorHex: card.backgroundColor), at: insertion)
            y += 4
        }

        mutating func blocks(_ nodes: [[String: Any]], x: CGFloat, width: CGFloat, depth: Int = 0,
                             listKind: String? = nil, start: Int = 1) {
            guard depth < 16, width > 5 else { return }
            var pairedIndex: Int?
            for (index, node) in nodes.enumerated() {
                if index == pairedIndex { continue }
                guard y < bottom, remainingNodes > 0 else { return }
                remainingNodes -= 1
                let type = node["type"] as? String ?? "paragraph"
                let attrs = node["attrs"] as? [String: Any] ?? [:]
                let children = node["content"] as? [[String: Any]] ?? []
                switch type {
                case "paragraph", "caption", "heading":
                    let level = attrs["level"] as? Int ?? 1
                    if type == "heading", let label = HeadingLabelSettings.configuration(attrs), label.enabled {
                        let value = inlineText(node)
                        let lines = min(2, max(1, Int(ceil(CGFloat(value.count) * 2.8 / width))))
                        let height = CGFloat(7 + lines * 6 + (label.shape == .ribbon ? 2 : 0))
                        add(.headingLabel(value, level: level, settings: label),
                            CGRect(x: x, y: y, width: width, height: height), type)
                        y += height + 3
                        continue
                    }
                    text(inlineText(node), type: type, x: x, width: width,
                         thickness: type == "heading" ? max(3.2, 5 - CGFloat(level) * 0.4) : (type == "caption" ? 2.2 : 2.6),
                         alignment: attrs["textAlign"] as? String)
                    y += listKind == nil ? 4 : 1.5
                case "bulletList", "orderedList", "taskList":
                    blocks(children, x: x, width: width, depth: depth + 1,
                           listKind: type, start: attrs["start"] as? Int ?? 1)
                case "listItem", "taskItem":
                    let marker: Shape
                    if type == "taskItem" {
                        marker = .checkbox(checked: attrs["checked"] as? Bool ?? false,
                                           crossed: attrs["crossed"] as? Bool ?? false)
                    } else if listKind == "orderedList" {
                        marker = .number(start + index)
                    } else {
                        marker = .bullet
                    }
                    add(marker, CGRect(x: x, y: y - 0.5, width: 4, height: 4), type)
                    blocks(children, x: x + 7, width: width - 7, depth: depth + 1, listKind: listKind)
                case "toggleItem":
                    let open = attrs["open"] as? Bool ?? true
                    add(.toggle(open: open), CGRect(x: x, y: y - 0.5, width: 4, height: 4), type)
                    blocks(Array(children.prefix(1)), x: x + 7, width: width - 7, depth: depth + 1)
                    if open {
                        blocks(Array(children.dropFirst()), x: x + 7, width: width - 7, depth: depth + 1)
                    }
                case "listGrid":
                    listGrid(node, x: x, width: width)
                case "richLink":
                    let link = RichLinkPreviewData(node)
                    let cell = link.layout == .card ? min(45, width) : width
                    let top = y
                    let insertion = marks.count
                    if link.layout == .card { y += cell / 2 }
                    text(link.title, type: "richLinkTitle", x: x + 3, width: cell - 6, maxLines: 1)
                    if link.layout != .small, !link.description.isEmpty {
                        text(link.description, type: "richLinkDescription", x: x + 3, width: cell - 6, thickness: 1.6, maxLines: 1)
                    }
                    marks.insert(Mark(shape: .container, rect: CGRect(x: x, y: top - 2, width: cell, height: y - top + 2),
                                      blockType: type, colorHex: nil), at: insertion)
                    y += 4
                case "gridCard", "callout":
                    let half = GridCardSettings.isHalf(node)
                    let gap: CGFloat = 3
                    let cell = half ? (width - gap) / 2 : width
                    let top = y
                    gridCard(node, x: x, width: cell, scale: width / 320)
                    if half, nodes.indices.contains(index + 1), GridCardSettings.isHalf(nodes[index + 1]) {
                        let firstBottom = y
                        y = top
                        gridCard(nodes[index + 1], x: x + cell + gap, width: cell, scale: width / 320)
                        y = max(y, firstBottom)
                        pairedIndex = index + 1
                    }
                case "plainCalloutRow":
                    let top = y
                    let gap: CGFloat = 3
                    let specified = children.reduce(0.0) { $0 + (((($1["attrs"] as? [String: Any])?["widthPercent"]) as? Double) ?? 0) }
                    let automatic = children.filter { ($0["attrs"] as? [String: Any])?["widthPercent"] == nil }.count
                    let share = automatic > 0 ? max(0, 100 - specified) / Double(automatic) : 0
                    let slots = children.count + (automatic == 0 && specified < 99 ? 1 : 0)
                    let gapShare = slots > 0 ? gap * CGFloat(slots - 1) / CGFloat(slots) : 0
                    var left = x, rowTop = top, rowBottom = top
                    for child in children {
                        let percent = ((child["attrs"] as? [String: Any])?["widthPercent"] as? Double) ?? (share > 0 ? share : 100)
                        let cellWidth = min(width, max(12, width * CGFloat(percent) / 100 - gapShare))
                        if left > x && left + cellWidth > x + width { left = x; rowTop = rowBottom + gap }
                        y = rowTop
                        blocks([child], x: left, width: cellWidth, depth: depth + 1)
                        rowBottom = max(rowBottom, y)
                        left += cellWidth + gap
                    }
                    y = rowBottom
                case "iconCallout", "plainCallout", "blockquote", "codeBlock":
                    if type == "plainCallout", let source = attrs["clipSource"] as? [String: Any] {
                        sourceCard(source, children: children, x: x, width: width, depth: depth)
                        continue
                    }
                    let top = y - 2
                    let insertionIndex = marks.count
                    let color = attrs["color"] as? String
                    y += 3
                    if type == "iconCallout" || type == "plainCallout" {
                        let card = IconCalloutSettings(attrs)
                        let background = type == "iconCallout" ? card.backgroundColor
                            : GridCardSettings.opaqueHex(attrs["color"], fallback: "#302d36")
                        let iconSize: CGFloat = 9
                        let xText = x + (type == "iconCallout" ? iconSize + 8 : 5)
                        let textWidth = width - (xText - x) - 4
                        if type == "iconCallout" {
                            add(.gridCardIcon(card.icon), CGRect(x: x + 4, y: y, width: iconSize, height: iconSize),
                                type, color: card.iconColor, imagePath: card.imagePath, imageTint: card.imageTint)
                        }
                        for child in children.prefix(16) {
                            text(inlineText(child), type: "calloutText", x: xText, width: textWidth,
                                 thickness: 2.1, maxLines: 10,
                                 color: type == "iconCallout" ? card.inkColor : GridCardSettings.readableInk(on: background))
                        }
                        y = min(bottom, max(y, top + 14) + 2)
                        marks.insert(Mark(shape: .container, rect: CGRect(x: x, y: top, width: width, height: y - top),
                                          blockType: type, colorHex: background), at: insertionIndex)
                        y += 6
                        continue
                    } else if type == "codeBlock" {
                        text(inlineText(node), type: type, x: x + 5, width: width - 10, thickness: 2)
                    } else {
                        let inset: CGFloat = 6
                        blocks(children, x: x + inset, width: width - inset - 4, depth: depth + 1)
                    }
                    let height = min(bottom, y + 2) - top
                    marks.insert(Mark(shape: .container,
                                      rect: CGRect(x: x, y: top, width: width, height: height),
                                      blockType: type, colorHex: color), at: insertionIndex)
                    y += 6
                case "divider", "horizontalRule":
                    let style = attrs["style"] as? String ?? "thinLine"
                    let color = attrs["color"] as? String
                    if style == "washiTape" {
                        let height = min(12, width / 5) * WashiTapeSize(attrs["tapeSize"]).heightScale
                        add(.washiTape, CGRect(x: x, y: y, width: width, height: height), type,
                            color: color, imagePath: attrs["imagePath"] as? String)
                        y += height + 5
                        continue
                    }
                    let fourDots = style == "fourCircles" || style == "fourDots"
                    if style == "dottedCircles" || fourDots {
                        let count = fourDots ? 4 : max(1, Int(width / 5))
                        let diameter: CGFloat = fourDots ? 0.6 : 2
                        let span = fourDots ? CGFloat(count - 1) * 5 + diameter : CGFloat(count) * 5
                        let left = x + (width - span) / 2
                        for dot in 0..<count {
                            add(.bullet, CGRect(x: left + CGFloat(dot) * 5, y: y + 2, width: diameter, height: diameter), type, color: color)
                        }
                    } else {
                        add(.line, CGRect(x: x, y: y + 2, width: width, height: style == "thickLine" ? 2.5 : 1), type, color: color)
                    }
                    y += 9
                case "pageBreak":
                    y += 5
                    add(.line, CGRect(x: x, y: y, width: width, height: 0.8), type)
                    y += 9
                case "image":
                    add(.image, CGRect(x: x, y: y, width: width, height: 22), type)
                    y += 27
                case "attachment":
                    let file = attrs["file"] as? [String: Any] ?? [:]
                    let kind = file["kind"] as? String ?? "file", mode = attrs["displayMode"] as? String ?? "auto"
                    let fraction = mode == "fullWidth" ? 1 : max(0.1, min(1, (attrs["widthPercent"] as? Double ?? 100) / 100))
                    let w = width * fraction
                    let left = attrs["textAlign"] as? String == "right" ? x + width - w : attrs["textAlign"] as? String == "center" ? x + (width - w) / 2 : x
                    if kind == "image" && mode != "card" {
                        let ratio = max(1, file["width"] as? Double ?? 100) / max(1, file["height"] as? Double ?? 30)
                        let height = max(3, min(32, w / ratio))
                        add(.image, CGRect(x: left, y: y, width: w, height: height), type); y += height + 5
                    } else {
                        let height: CGFloat = kind == "pdf" && mode != "card" ? 28 : 10
                        add(.container, CGRect(x: left, y: y, width: w, height: height), type); y += height + 5
                    }
                case "pageReference":
                    add(.container, CGRect(x: x, y: y, width: 12, height: 16), type)
                    y += 21
                case "inlineProperty":
                    property(attrs["property"], x: x, width: width)
                case "templateComponent":
                    if let definition = TemplateComponentDefinition.decode(attrs["definition"]) {
                        if !definition.label.isEmpty { text(definition.label, type: type, x: x, width: width, thickness: 3) }
                        if definition.kind == .slider {
                            add(.line, CGRect(x: x, y: y + 3, width: width, height: 1.5), type)
                            let value = (attrs["response"] as? NSNumber)?.doubleValue ?? definition.minimum
                            let progress = max(0, min(1, (value - definition.minimum) / (definition.maximum - definition.minimum)))
                            add(.chip, CGRect(x: x + (width - 4) * progress, y: y, width: 4, height: 6), type)
                            y += 12
                        } else {
                            let labels = definition.kind == .rating ? (Int(definition.minimum)...Int(definition.maximum)).map(String.init) : definition.choices.map(\.label)
                            var left = x
                            for label in labels {
                                let chipWidth = min(width, max(8, CGFloat(label.prefix(40).count) * 1.8 + 6))
                                if left + chipWidth > x + width { y += 9; left = x }
                                add(.chip, CGRect(x: left, y: y, width: chipWidth, height: 6), type)
                                left += chipWidth + 3
                            }
                            y += 13
                        }
                    }
                case "tabs":
                    let panels = children.filter { $0["type"] as? String == "tabPanel" }
                    let ids = panels.compactMap { ($0["attrs"] as? [String: Any])?["id"] as? String }
                    let active = (attrs["activeTab"] as? String).flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
                    let activeContent = (panels.first { ($0["attrs"] as? [String: Any])?["id"] as? String == active }?["content"]
                        as? [[String: Any]]) ?? []
                    blocks(activeContent, x: x, width: width, depth: depth + 1)
                default:
                    blocks(children, x: x, width: width, depth: depth + 1)
                }
            }
        }

        mutating func sourceCard(_ source: [String: Any], children: [[String: Any]], x: CGFloat, width: CGFloat, depth: Int) {
            let top = y - 2, insertionIndex = marks.count
            y += 2
            let linkTop = y, inset: CGFloat = 4
            add(.container, CGRect(x: x + inset, y: linkTop, width: width - inset * 2, height: 9), "clipSourceLink", color: "#202020")
            let path = (source["file"] as? [String: Any])?["relativePath"] as? String
            if let path {
                add(.image, CGRect(x: x + inset + 1, y: linkTop + 1, width: 12, height: 7), "clipSourceImage", imagePath: path)
            }
            let titleX = x + inset + (path == nil ? 2 : 16)
            y = linkTop + 3
            text(source["title"] as? String ?? source["url"] as? String ?? "", type: "clipSourceTitle", x: titleX,
                width: x + width - inset - titleX - 2, thickness: 2, maxLines: 1)
            y = linkTop + 13
            for child in children.prefix(96) {
                guard y < bottom, remainingNodes > 0 else { break }
                let attrs = child["attrs"] as? [String: Any] ?? [:]
                let inline = child["content"] as? [[String: Any]] ?? []
                if child["type"] as? String == "inlineProperty", let value = InlinePropertyDefinition.decode(attrs["property"]), value.kind == .date {
                    remainingNodes -= 1
                    add(.line, CGRect(x: x + inset, y: y + 1, width: 9, height: 1.8), "clipSourceTitle")
                    add(.chip, CGRect(x: x + inset + 11, y: y - 1, width: 15, height: 5), "clipSourceDate", color: "#B59AD9")
                    if value.includeTime { add(.line, CGRect(x: x + inset + 28, y: y + 1, width: 16, height: 1.8), "clipSourceTitle") }
                    y += 9
                } else if child["type"] as? String == "paragraph", inline.contains(where: { $0["type"] as? String == "inlineTag" }),
                          inline.allSatisfy({ $0["type"] as? String == "inlineTag" || ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    remainingNodes -= 1
                    var left = x + inset
                    for tag in inline where tag["type"] as? String == "inlineTag" {
                        let name = (tag["attrs"] as? [String: Any])?["name"] as? String ?? ""
                        let w = min(width - inset * 2, max(6, CGFloat(name.prefix(80).count) * 1.65 + 4))
                        if left + w > x + width - inset { y += 8; left = x + inset }
                        add(.chip, CGRect(x: left, y: y, width: w, height: 5), "clipSourceTag", color: "#B59AD9")
                        left += w + 2
                    }
                    y += 10
                } else {
                    blocks([child], x: x + inset, width: width - inset * 2, depth: depth + 1)
                }
            }
            marks.insert(Mark(shape: .container, rect: CGRect(x: x, y: top, width: width, height: max(0, min(bottom, y + 2) - top)),
                blockType: "clipSource", colorHex: "#292929"), at: insertionIndex)
            y += 6
        }

        mutating func property(_ object: Any?, x: CGFloat, width: CGFloat) {
            guard let property = InlinePropertyDefinition.decode(object) else { return }
            let top = y
            text(property.name, type: "inlineProperty", x: x, width: width * 0.4, thickness: 3, maxLines: 1)
            y = top
            let valueX = x + width * 0.47
            if property.kind == .checkbox {
                add(.checkbox(checked: property.checked, crossed: false),
                    CGRect(x: valueX, y: top - 1, width: 5, height: 5), "inlineProperty")
            } else if property.kind.isSelect {
                var chipX = valueX
                for option in property.options where property.selectedOptionIDs.contains(option.id) {
                    let chipWidth = min(width * 0.53, CGFloat(option.name.prefix(30).count) * 1.65 + 5)
                    if chipX + chipWidth > x + width { y += 8; chipX = valueX }
                    add(.chip, CGRect(x: chipX, y: y - 1, width: chipWidth, height: 5),
                        "inlineProperty", color: option.color)
                    chipX += chipWidth + 2
                }
            } else {
                let value = property.kind == .url && !property.urlLabel.isEmpty ? property.urlLabel : property.value
                text(value, type: "inlineProperty", x: valueX, width: width * 0.53, thickness: 2, maxLines: 2)
            }
            y = max(y, top + 7) + 4
        }
    }
}
