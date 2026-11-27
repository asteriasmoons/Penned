import SwiftUI

// Read-only presentation of saved block attributes; no editor commands or writes.
private struct PreviewAttributes {
    let values: [String: Any]
    func color(_ key: String, _ fallback: String) -> Color {
        Color(vellixHex: GridCardSettings.opaqueHex(values[key], fallback: fallback))
    }
    func number(_ key: String, _ fallback: Int, _ bounds: ClosedRange<Int>) -> CGFloat {
        CGFloat(min(bounds.upperBound, max(bounds.lowerBound, (values[key] as? NSNumber)?.intValue ?? fallback)))
    }
    func flag(_ key: String, _ fallback: Bool = false) -> Bool {
        (values[key] as? Bool) ?? (values[key] as? String).map { $0 == "true" } ?? fallback
    }
}

struct CalendarBlockPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]
    var maximumBlocks = 96
    private var attrs: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }
    private var style: PreviewAttributes { PreviewAttributes(values: attrs) }
    private var selected: DailyNoteDay {
        if attrs["selectedDateBehavior"] as? String != "today", let key = attrs["selectedDate"] as? String,
           let day = DailyNoteDay(key: key) { return day }
        return DailyNoteDay(date: .now)
    }
    private var dates: [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = Int(style.number("firstDayOfWeek", 0, 0...6)) + 1
        let selectedDate = selected.date()
        let offset = (calendar.component(.weekday, from: selectedDate) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: selectedDate) ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        let collapsed = style.flag("collapsed")
        let spacing = style.number("spacing", 14, 0...32)
        let panels = node["content"] as? [[String: Any]] ?? []
        let children = (panels.first { ($0["attrs"] as? [String: Any])?["date"] as? String == selected.key }?["content"] as? [[String: Any]]) ?? []
        var ink = appearance
        ink.textColorHex = GridCardSettings.opaqueHex(attrs["contentTextColor"], fallback: "#f7f7fa")
        return VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 0) {
                arrow("chevleft").frame(width: 72, alignment: .leading)
                Text((attrs["title"] as? String)?.trimmedNonEmpty ?? "Calendar")
                    .font(appearance.fontStyle.font(size: 14, weight: .black)).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                arrow(collapsed ? "chevdown" : "chevup")
                arrow("chevright")
            }
            HStack(spacing: 4) {
                ForEach(dates, id: \.self) { date in
                    let active = DailyNoteDay(date: date) == selected
                    let size = style.number("fontSize", 14, 10...24)
                    let weight: Font.Weight = style.number("fontWeight", 700, 400...900) >= 800 ? .black
                        : style.number("fontWeight", 700, 400...900) >= 600 ? .bold : .regular
                    VStack(spacing: 5) {
                        Text(date.formatted(.dateTime.weekday(.narrow))).font(.system(size: min(16, size * 0.8), weight: weight, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(date.formatted(.dateTime.day())).font(.system(size: min(24, size * 1.2), weight: weight, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                    }.frame(maxWidth: .infinity).frame(height: 56)
                        .background {
                            RoundedRectangle(cornerRadius: 15).fill(style.color(active ? "activeTabColor" : "inactiveTabColor", active ? "#9276dc" : "#303137"))
                                .overlay { RoundedRectangle(cornerRadius: 15).fill(.black.opacity(active ? 0.20 : 0.08)) }
                        }
                        .foregroundStyle(.white)
                }
            }
            if !collapsed {
                Rectangle().fill(style.color("containerBorderColor", "#34343b")).frame(height: 1)
                ImmediatePreviewBlocks(nodes: children, appearance: ink, depth: depth + 1,
                    collections: collections, referencedDocuments: referencedDocuments, spacing: 10, maximumBlocks: maximumBlocks)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            }
        }
        .padding(style.number("padding", 14, 0...32))
        .foregroundStyle(Color(vellixHex: ink.textColorHex))
        .background(style.color("backgroundColor", "#121316"), in: RoundedRectangle(cornerRadius: style.number("cornerRadius", 18, 0...48)))
        .overlay { RoundedRectangle(cornerRadius: style.number("cornerRadius", 18, 0...48))
            .strokeBorder(style.color("containerBorderColor", "#34343b"), lineWidth: max(style.number("borderWidth", 1, 0...20), style.number("borderThickness", 1, 0...8))) }
    }
    private func arrow(_ name: String) -> some View {
        LibraryIcon(name: name, size: 18).foregroundStyle(style.color("navigationColor", "#7c8b80")).frame(width: 36, height: 36)
    }
}

struct LinkedCalendarEventPreview: View {
    let attrs: [String: Any]
    let appearance: DocumentAppearance
    private func date(_ key: String) -> Date? {
        guard let value = attrs[key] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func formatted(_ date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.timeZone = (attrs["timeZoneID"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
    var body: some View {
        let available = PreviewAttributes(values: attrs).flag("available", true)
        let start = date("start"), end = date("end")
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2).fill(Color(vellixHex: available ? "#9276dc" : "#777781")).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(available ? ((attrs["title"] as? String)?.trimmedNonEmpty ?? "Untitled Event") : "Event Unavailable")
                    .font(appearance.fontStyle.font(size: 14, weight: .semibold))
                if available {
                    if let title = (attrs["calendarTitle"] as? String)?.trimmedNonEmpty { Text(title) }
                    if let start {
                        Text(formatted(start, dateStyle: .full, timeStyle: .none))
                        if attrs["isAllDay"] as? Bool == true { Text("All Day") }
                        else {
                            Text(formatted(start, dateStyle: .none, timeStyle: .short) +
                                (end.map { " – " + formatted($0, dateStyle: .none, timeStyle: .short) } ?? ""))
                        }
                    } else { Text("Date unavailable") }
                } else { Text("The original calendar event is no longer accessible.") }
            }.font(appearance.fontStyle.font(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true).opacity(available ? 1 : 0.65).padding(.vertical, 3)
    }
}

struct InformationCardBlockPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]
    var maximumBlocks = 96
    private var attrs: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }
    private var style: PreviewAttributes { PreviewAttributes(values: attrs) }
    private func inline(_ type: String) -> [[String: Any]] {
        let children = node["content"] as? [[String: Any]] ?? []
        return children.first { $0["type"] as? String == type }?["content"] as? [[String: Any]] ?? []
    }
    var body: some View {
        let collapsed = style.flag("collapsible") && style.flag("collapsed")
        let hiddenHeader = style.flag("hideTitle") && style.flag("hideDescription")
        let body = inline("informationCardBody").filter { style.flag("showLabels", true) || $0["type"] as? String != "informationCardLabel" }
        var ink = appearance
        ink.textColorHex = GridCardSettings.opaqueHex(attrs["textColor"], fallback: "#E4E4EA")
        return VStack(alignment: .leading, spacing: 6) {
            if !hiddenHeader || style.flag("collapsible") {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if !style.flag("hideTitle") {
                        InlineTextPreview.text(inline("informationCardTitle"), appearance: ink, size: 19, weight: .heavy)
                            .foregroundStyle(style.color("titleColor", "#FFFFFF"))
                    }
                    if !style.flag("hideDescription") {
                        InlineTextPreview.text(inline("informationCardDescription"), appearance: ink, size: 14).opacity(0.72)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if style.flag("collapsible") { LibraryIcon(name: collapsed ? "chevdown" : "chevup", size: 18).foregroundStyle(style.color("titleColor", "#FFFFFF")) }
              }
            }
            if !collapsed {
                if !style.flag("hideDivider") { Rectangle().fill(style.color("dividerColor", "#393940")).frame(height: 1).padding(.top, hiddenHeader ? 0 : 8) }
                ImmediatePreviewBlocks(nodes: body, appearance: ink, depth: depth + 1,
                    collections: collections, referencedDocuments: referencedDocuments, spacing: 6, maximumBlocks: maximumBlocks)
                    .padding(.top, style.flag("hideDivider") && hiddenHeader ? 0 : 8)
            }
        }.padding(style.number("padding", 16, 8...36))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(style.color("backgroundColor", "#202024"), in: RoundedRectangle(cornerRadius: style.number("cornerRadius", 16, 0...32)))
            .overlay { RoundedRectangle(cornerRadius: style.number("cornerRadius", 16, 0...32))
                .strokeBorder(style.color("borderColor", "#393940"), lineWidth: style.flag("showBorder", true) ? style.number("borderThickness", 1, 1...12) : 0) }
            .foregroundStyle(Color(vellixHex: ink.textColorHex))
    }
}

struct CodeDocumentBlockPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    var maximumLines = 96
    var body: some View {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        let palette = CodeBlockCatalog.shared.palette(attrs["theme"] as? String ?? "auto", scheme: appearance.presentationColorScheme)
        let source = (node["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(maximumLines).enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)").foregroundStyle(Color(vellixHex: palette.hex("lineNumber"))).frame(width: 28, alignment: .trailing)
                    Text(line.isEmpty ? " " : line).foregroundStyle(Color(vellixHex: palette.hex("text")))
                        .fixedSize(horizontal: true, vertical: false).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                }.font(.system(size: 13, design: .monospaced)).padding(.vertical, 2)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(vellixHex: palette.hex("background")), in: RoundedRectangle(cornerRadius: 8))
    }
}
