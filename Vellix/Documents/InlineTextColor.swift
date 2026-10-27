import Foundation
import SwiftUI

nonisolated struct InlineTextColor: Equatable {
    enum Kind: String, CaseIterable, Sendable { case solid, gradient }
    let kind: Kind
    let start: String
    let end: String
    let angle: Int

    init?(kind: Kind, start: String, end: String? = nil, angle: Int = 90) {
        guard let start = Self.normalizedHex(start),
              let end = Self.normalizedHex(end ?? start) else { return nil }
        self.kind = kind
        self.start = start
        self.end = kind == .solid ? start : end
        self.angle = kind == .solid ? 90 : ((angle % 360) + 360) % 360
    }

    static func normalizedHex(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        guard [3, 6].contains(digits.count), digits.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        return "#" + (digits.count == 3 ? digits.map { String(repeating: String($0), count: 2) }.joined() : digits)
    }

    static func decode(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any], let raw = object["kind"] as? String,
              let kind = Kind(rawValue: raw), let start = object["start"] as? String else { return nil }
        if kind == .solid { return Self(kind: kind, start: start) }
        guard let end = object["end"] as? String,
              let angle = (object["angle"] as? Double) ?? (object["angle"] as? Int).map(Double.init),
              angle.isFinite, abs(angle) < Double(Int.max) else { return nil }
        return Self(kind: kind, start: start, end: end, angle: Int(angle.rounded()))
    }

    static func markAttributes(_ attrs: [String: Any]) -> Self? {
        if var gradient = attrs["gradient"] as? [String: Any] {
            gradient["kind"] = "gradient"
            return decode(gradient)
        }
        guard let hex = attrs["color"] as? String else { return nil }
        return Self(kind: .solid, start: hex)
    }

    var bridgeValue: [String: Any] {
        if kind == .solid { return ["kind": kind.rawValue, "start": start] }
        return ["kind": kind.rawValue, "start": start, "end": end, "angle": angle]
    }

    @MainActor var gradient: LinearGradient {
        gradient(in: CGSize(width: 1, height: 1))
    }

    @MainActor func gradient(in size: CGSize) -> LinearGradient {
        let radians = Double(angle) * .pi / 180
        let width = max(Double(size.width), 1), height = max(Double(size.height), 1)
        let dx = sin(radians), dy = -cos(radians)
        let length = abs(dx) * width + abs(dy) * height
        let x = dx * length / (2 * width), y = dy * length / (2 * height)
        return LinearGradient(colors: [Color(vellixHex: start), Color(vellixHex: end)],
            startPoint: UnitPoint(x: 0.5 - x, y: 0.5 - y), endPoint: UnitPoint(x: 0.5 + x, y: 0.5 + y))
    }

    @MainActor func applying(to text: Text) -> Text {
        kind == .solid ? text.foregroundColor(Color(vellixHex: start)) : text.foregroundStyle(gradient)
    }
}

struct InlineTextColorSample: View {
    let text: Text
    let color: InlineTextColor?
    var maximumLines = 4

    var body: some View {
        let sample = text.lineLimit(maximumLines)
        Group {
            if let color, color.kind == .gradient {
                sample.foregroundStyle(Color.clear).overlay {
                    GeometryReader { proxy in
                        color.gradient(in: proxy.size)
                            .mask(sample.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading))
                    }.accessibilityHidden(true)
                }
            } else if let color {
                sample.foregroundStyle(Color(vellixHex: color.start))
            } else {
                sample
            }
        }
    }
}

nonisolated struct InlineTextColorEditorRequest: Identifiable {
    let id: String
    let documentID: String
    let selectedText: String
    let initialColor: InlineTextColor?
}

enum InlineTextPreview {
    static func text(_ values: [[String: Any]], appearance: DocumentAppearance) -> Text {
        values.reduce(Text("")) { result, item in
            let tag = item["type"] as? String == "inlineTag" ? (item["attrs"] as? [String: Any])?["name"] as? String : nil
            var attributed = AttributedString(tag.map { "#" + $0 } ?? (item["type"] as? String == "hardBreak" ? "\n" : (item["text"] as? String ?? "")))
            for mark in item["marks"] as? [[String: Any]] ?? [] {
                let attrs = mark["attrs"] as? [String: Any] ?? [:]
                if mark["type"] as? String == "highlight", let hex = attrs["color"] as? String {
                    attributed.backgroundColor = Color(vellixHex: hex)
                }
            }
            var text = Text(attributed)
            var explicitColor: InlineTextColor?
            if tag != nil { text = text.foregroundColor(Color(vellixHex: appearance.presentationColors.accent)).bold() }
            for mark in item["marks"] as? [[String: Any]] ?? [] {
                switch mark["type"] as? String {
                case "bold": text = text.bold()
                case "italic": text = text.italic()
                case "underline": text = text.underline()
                case "strike": text = text.strikethrough()
                case "code": text = text.monospaced()
                case "textStyle": explicitColor = InlineTextColor.markAttributes(mark["attrs"] as? [String: Any] ?? [:])
                case "link": text = text.foregroundColor(Color(vellixHex: appearance.presentationColors.link)).underline()
                default: break
                }
            }
            if let explicitColor { text = explicitColor.applying(to: text) }
            return result + text
        }
    }
}
