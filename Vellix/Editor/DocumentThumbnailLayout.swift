import Foundation
import CoreGraphics

// Transient drawing instructions, derived only from the saved TipTap document.
nonisolated struct DocumentThumbnailLayout: Equatable {
    enum Shape: Equatable {
        case line, container, bullet, number(Int), checkbox(checked: Bool, crossed: Bool)
        case toggle(open: Bool), image, chip
    }

    struct Mark: Equatable {
        var shape: Shape
        var rect: CGRect
        var blockType: String
        var colorHex: String?
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

        mutating func add(_ shape: Shape, _ rect: CGRect, _ type: String, color: String? = nil) {
            guard rect.minY < bottom, rect.width > 0 else { return }
            marks.append(Mark(shape: shape, rect: rect, blockType: type, colorHex: color))
        }

        // Line lengths and wrapping follow actual text, not a decorative pattern.
        mutating func text(_ value: String, type: String, x: CGFloat, width: CGFloat,
                           thickness: CGFloat = 2.6, maxLines: Int = 16, alignment: String? = nil) {
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
                        add(.line, CGRect(x: startX(length), y: y, width: length, height: thickness), type)
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
                add(.line, CGRect(x: startX(length), y: y, width: length, height: thickness), type)
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

        mutating func blocks(_ nodes: [[String: Any]], x: CGFloat, width: CGFloat, depth: Int = 0,
                             listKind: String? = nil, start: Int = 1) {
            guard depth < 16, width > 5 else { return }
            for (index, node) in nodes.enumerated() {
                guard y < bottom, remainingNodes > 0 else { return }
                remainingNodes -= 1
                let type = node["type"] as? String ?? "paragraph"
                let attrs = node["attrs"] as? [String: Any] ?? [:]
                let children = node["content"] as? [[String: Any]] ?? []
                switch type {
                case "paragraph", "heading":
                    let level = attrs["level"] as? Int ?? 1
                    text(inlineText(node), type: type, x: x, width: width,
                         thickness: type == "heading" ? max(3.2, 5 - CGFloat(level) * 0.4) : 2.6,
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
                case "callout", "plainCallout", "blockquote", "codeBlock":
                    let top = y - 2
                    let insertionIndex = marks.count
                    let color = attrs["color"] as? String
                    y += 3
                    if type == "codeBlock" {
                        text(inlineText(node), type: type, x: x + 5, width: width - 10, thickness: 2)
                    } else {
                        if type == "callout" {
                            add(.chip, CGRect(x: x + 4, y: y - 0.5, width: 5, height: 5), type, color: color)
                        }
                        let inset: CGFloat = type == "callout" ? 12 : 6
                        blocks(children, x: x + inset, width: width - inset - 4, depth: depth + 1)
                    }
                    let height = min(bottom, y + 2) - top
                    marks.insert(Mark(shape: .container,
                                      rect: CGRect(x: x, y: top, width: width, height: height),
                                      blockType: type, colorHex: color), at: insertionIndex)
                    y += 6
                case "divider", "horizontalRule":
                    let style = attrs["style"] as? String ?? "thinLine"
                    if style == "dottedCircles" || style == "fourCircles" {
                        let count = style == "fourCircles" ? 4 : max(1, Int(width / 5))
                        let left = x + (width - CGFloat(count) * 5) / 2
                        for dot in 0..<count {
                            add(.bullet, CGRect(x: left + CGFloat(dot) * 5, y: y + 2, width: 1.5, height: 1.5), type)
                        }
                    } else {
                        add(.line, CGRect(x: x, y: y + 2, width: width, height: style == "thickLine" ? 2.5 : 1), type)
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
                default:
                    blocks(children, x: x, width: width, depth: depth + 1)
                }
            }
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
