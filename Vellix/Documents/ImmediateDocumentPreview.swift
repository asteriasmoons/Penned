import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct ImmediateDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    private var appearance: DocumentAppearance { document.appearance.resolved(for: colorScheme) }
    private var savedContent: DocumentPreviewContent { environment.documentPreviews.content(for: document) }
    private var blockSpacing: CGFloat {
        #if os(iOS)
        10
        #else
        18
        #endif
    }

    private var sheets: [[[String: Any]]] {
        var result: [[[String: Any]]] = [[]]
        for node in TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? [] {
            if node["type"] as? String == "pageBreak" { result.append([]) }
            else { result[result.count - 1].append(node) }
        }
        return result
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            LibrarySnapshotSurface(style: appearance.editorBackground,
                photo: document.isThemed ? CardImageLoader.image(path: document.appearance.editorBackground.imagePath, store: environment.attachmentStore) : nil)
            if let theme = document.appearance.editorBackground.patternTheme(for: document.appearance.themeID) {
                ThemePatternOverlay(theme: theme)
                    .opacity(document.appearance.editorBackground.effect == .faded ? 0.35 : 1)
            }
            VStack(spacing: 14) {
                ForEach(Array(sheets.enumerated()), id: \.offset) { index, nodes in
                    VStack(alignment: .leading, spacing: 18) {
                        if index == 0 {
                            LibrarySnapshotHeader(document: document,
                                cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore),
                                appearance: appearance, titleLineLimit: nil)
                            if let (collection, entry) = savedContent.entryContext {
                                CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: appearance)
                            }
                        }
                        ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
                            collections: savedContent.collections, referencedDocuments: savedContent.children, spacing: blockSpacing)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: sheets.count == 1
                        ? max(0, geometry.size.height - (document.isThemed ? 16 : 0)) : 0,
                        alignment: .topLeading)
                    .background {
                        if document.isThemed {
                            LibrarySnapshotSurface(style: appearance.innerPageBackground,
                                photo: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: environment.attachmentStore))
                        } else {
                            Color(vellixHex: appearance.editorBackground.colorHex)
                                .overlay { if appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(document.isThemed ? 8 : 0)
        }
        }
        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
        .environment(\.colorScheme, appearance.presentationColorScheme)
        .allowsHitTesting(false)
        .clipped()
    }
}

struct ImmediateDocumentBodyPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    var body: some View {
        let saved = environment.documentPreviews.content(for: document)
        let appearance = document.appearance.resolved(for: colorScheme)
        let nodes = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []
        ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
            collections: saved.collections, referencedDocuments: saved.children, spacing: 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .environment(\.colorScheme, appearance.presentationColorScheme)
            .allowsHitTesting(false)
    }
}

private struct ImmediatePreviewBlocks: View {
    let nodes: [[String: Any]]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]
    var spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.prefix(96).enumerated()), id: \.offset) { index, node in
                let consecutiveProperties = index > 0 && node["type"] as? String == "inlineProperty"
                    && nodes[index - 1]["type"] as? String == "inlineProperty"
                ImmediatePreviewBlock(node: node, appearance: appearance, depth: depth,
                    collections: collections, referencedDocuments: referencedDocuments)
                    .padding(.top, index == 0 ? 0 : (consecutiveProperties ? 4 : spacing))
            }
        }
    }
}

struct CalloutRowPreviewLayout: Layout {
    let widths: [Double?]

    init(nodes: [[String: Any]]) {
        widths = nodes.map { node in
            guard let value = (node["attrs"] as? [String: Any])?["widthPercent"] as? Double,
                  value.isFinite, value > 0 else { return nil }
            return min(100, max(1, value))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard width > 0, !subviews.isEmpty else { return [] }
        let specified = widths.compactMap { $0 }.reduce(0, +)
        let automatic = widths.filter { $0 == nil }.count
        let share = automatic > 0 ? max(0, 100 - specified) / Double(automatic) : 0
        let slots = subviews.count + (automatic == 0 && specified < 99 ? 1 : 0)
        let gapShare = CGFloat(slots > 0 ? 12 * Double(slots - 1) / Double(slots) : 0)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.enumerated().map { index, subview in
            let percent = widths[index] ?? (share > 0 ? share : 100 / Double(subviews.count))
            let cellWidth = min(width, max(min(120, width), width * CGFloat(percent) / 100 - gapShare))
            if x > 0 && x + cellWidth > width + 0.5 { x = 0; y += rowHeight + 12; rowHeight = 0 }
            let size = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            let rect = CGRect(x: x, y: y, width: cellWidth, height: size.height)
            x += cellWidth + 12; rowHeight = max(rowHeight, size.height)
            return rect
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct ImmediatePreviewBlock: View {
    @EnvironmentObject private var environment: AppEnvironment
    let node: [String: Any]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]

    private var type: String { node["type"] as? String ?? "paragraph" }
    private var attrs: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }
    private var nodes: [[String: Any]] { node["content"] as? [[String: Any]] ?? [] }
    private var color: Color { Color(vellixHex: attrs["color"] as? String ?? appearance.textColorHex) }
    private var populatedIconCallout: Bool {
        func hasText(_ node: [String: Any]) -> Bool {
            if node["type"] as? String == "text" { return !(node["text"] as? String ?? "").isEmpty }
            if node["type"] as? String == "inlineTag" { return true }
            return (node["content"] as? [[String: Any]] ?? []).contains(where: hasText)
        }
        return type == "callout" && nodes.contains(where: hasText)
    }

    var body: some View {
        if depth < 16 {
            content.padding(.leading, CGFloat(max(0, min(6, attrs["indent"] as? Int ?? 0))) * 18)
        }
    }

    @ViewBuilder private var content: some View {
        switch type {
        case "attachment":
            if let file = attrs["file"] as? [String: Any], let path = file["relativePath"] as? String,
               let resolved = try? environment.attachments.editorAttachment(relativePath: path) {
                AttachmentBlockPreview(file: resolved, attrs: attrs, store: environment.attachmentStore)
            }
        case "templateComponent":
            if let definition = TemplateComponentDefinition.decode(attrs["definition"]) {
                TemplateComponentPreview(definition: definition, response: attrs["response"], appearance: appearance)
            }
        case "collection":
            if let id = attrs["collectionID"] as? String, let snapshot = collections.first(where: { $0.record.id == id }) {
                CollectionSnapshotPreview(snapshot: snapshot, appearance: appearance, attachments: environment.attachmentStore)
                    .padding(.vertical, 16)
            }
        case "table": ImmediateTablePreview(node: node, appearance: appearance)
        case "paragraph", "caption", "heading", "codeBlock":
            let guided = nodes.isEmpty && attrs["placeholderEnabled"] as? Bool == true
            let inline = guided ? (attrs["placeholderGuidance"] as? [[String: Any]] ?? []) : nodes
            let level = attrs["level"] as? Int ?? 1
            let size: CGFloat = type == "heading" ? [24, 21, 18, 16, 16, 16][max(0, min(5, level - 1))] : (type == "caption" ? 12 : 14)
            let alignment: TextAlignment = attrs["textAlign"] as? String == "center" ? .center : (attrs["textAlign"] as? String == "right" ? .trailing : .leading)
            InlineTextPreview.text(inline, appearance: appearance, size: size, weight: type == "heading" ? .bold : .regular)
                .font(appearance.fontStyle.font(size: size, weight: type == "heading" ? .bold : .regular,
                code: type == "codeBlock"))
                .opacity(guided ? 0.38 : (type == "caption" ? 0.75 : 1)).multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, minHeight: inline.isEmpty ? 20 : nil,
                    alignment: alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
        case "plainCalloutRow":
            CalloutRowPreviewLayout(nodes: nodes) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                    ImmediatePreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                        collections: collections, referencedDocuments: referencedDocuments)
                }
            }
        case "callout", "plainCallout":
            if type == "plainCallout", let source = attrs["clipSource"] as? [String: Any],
               let href = source["url"] as? String, InlinePropertyDefinition.safeURL(href) != nil {
                ClipSourceDocumentPreview(source: source, nodes: nodes, appearance: appearance,
                    depth: depth, collections: collections, referencedDocuments: referencedDocuments)
            } else {
            HStack(alignment: populatedIconCallout ? .top : .firstTextBaseline, spacing: 11) {
                if type == "callout" {
                    LibraryIcon(name: attrs["icon"] as? String ?? "sparkle", size: 26).foregroundStyle(color)
                        .frame(width: 42, height: 42)
                        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                }
                children(nodes)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        // First-line center, even when the text spans many lines.
                        (dimensions[.firstTextBaseline] + dimensions.height - dimensions[.lastTextBaseline]) / 2
                    }
            }
            .frame(minHeight: 42)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.18)))
            }
        case "blockquote":
            children(nodes).padding(.leading, 14).padding(.vertical, 8)
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        case "toggleItem":
            HStack(alignment: .top, spacing: 8) {
                LibraryIcon(name: attrs["open"] as? Bool == false ? "chevright" : "chevdown", size: 14).padding(.top, 4)
                children(attrs["open"] as? Bool == false ? Array(nodes.prefix(1)) : nodes)
            }
        case "bulletList", "orderedList", "taskList":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(nodes.prefix(96).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        if type == "orderedList" {
                            let first = (item["content"] as? [[String: Any]])?.first
                            let heading = first?["type"] as? String == "heading"
                            let level = (first?["attrs"] as? [String: Any])?["level"] as? Int ?? 1
                            let size: CGFloat = heading ? [24, 21, 18, 16][max(0, min(3, level - 1))] : 14
                            Text("\((attrs["start"] as? Int ?? 1) + index).")
                                .font(appearance.fontStyle.font(size: size, weight: heading ? .bold : .regular))
                        }
                        else if type == "taskList" {
                            let itemAttrs = item["attrs"] as? [String: Any] ?? [:]
                            Group {
                                if itemAttrs["checked"] as? Bool == true { LibraryIcon(name: "checkwavy", size: 14) }
                                else { Circle().strokeBorder(.primary.opacity(0.55)).frame(width: 14, height: 14) }
                            }.padding(.top, 3)
                        } else { Circle().frame(width: 4, height: 4).padding(.top, 8) }
                        ImmediatePreviewBlock(node: item, appearance: appearance, depth: depth + 1,
                            collections: collections, referencedDocuments: referencedDocuments)
                    }
                }
            }
        case "divider", "horizontalRule":
            if ["fourCircles", "fourDots"].contains(attrs["style"] as? String ?? "") {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle().fill(Color(vellixHex: appearance.textColorHex)).frame(width: 4, height: 4)
                    }
                }.frame(maxWidth: .infinity, minHeight: 30)
            } else {
            #if os(iOS)
            if attrs["style"] == nil || ["thinLine", "thickLine"].contains(attrs["style"] as? String ?? "") {
                Rectangle().fill(color.opacity(attrs["style"] as? String == "thickLine" ? 1 : 0.5))
                    .frame(height: attrs["style"] as? String == "thickLine" ? 2 : 1)
                    .padding(.horizontal, 6).frame(height: 20)
            } else {
                Rectangle().fill(color.opacity(0.20)).frame(height: 1).padding(.vertical, 8)
            }
            #else
            Rectangle().fill(color.opacity(0.20)).frame(height: attrs["style"] as? String == "thickLine" ? 4 : 1).padding(.vertical, 8)
            #endif
            }
        case "pageReference":
            if let id = attrs["documentID"] as? String,
               let child = referencedDocuments.first(where: { $0.id == id }) ?? environment.editorCache.model(for: id)?.document {
                if let style = child.cardStyle {
                    PageCardView(document: child, style: style,
                        photo: CardImageLoader.image(path: style.imagePath, store: environment.attachmentStore), fillsDocumentWidth: style.size.fillsDocumentWidth,
                        attachmentStore: environment.attachmentStore, containingFontStyle: appearance.fontStyle)
                } else { NestedPageRow(document: child, appearance: appearance, open: {}) }
            }
        case "inlineProperty":
            if let property = InlinePropertyDefinition.decode(attrs["property"]) {
                InlinePropertyPreview(property: property, appearance: appearance)
            }
        default: children(nodes)
        }
    }

    private func children(_ values: [[String: Any]]) -> some View {
        ImmediatePreviewBlocks(nodes: values, appearance: appearance, depth: depth + 1,
            collections: collections, referencedDocuments: referencedDocuments, spacing: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ClipSourceDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    let source: [String: Any]
    let nodes: [[String: Any]]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]

    private var metadataAppearance: DocumentAppearance {
        var value = appearance
        value.textColorHex = "#D5D5D5"
        return value
    }
    private var thumbnail: CGImage? {
        guard let file = source["file"] as? [String: Any], let path = file["relativePath"] as? String,
              let resolved = try? environment.attachments.editorAttachment(relativePath: path), resolved.media.kind == .image else { return nil }
        return CardImageLoader.image(path: resolved.record.relativePath, store: environment.attachmentStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let image = thumbnail {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: 48, height: 30).clipped().clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(source["title"] as? String ?? source["url"] as? String ?? "")
                    .font(appearance.fontStyle.font(size: 14)).foregroundStyle(Color(vellixHex: "#D5D5D5"))
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(Color(vellixHex: "#202020"), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(nodes.prefix(96).enumerated()), id: \.offset) { _, node in
                    metadata(node)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(vellixHex: "#292929"), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func metadata(_ node: [String: Any]) -> some View {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        let inline = node["content"] as? [[String: Any]] ?? []
        if node["type"] as? String == "inlineProperty", let property = InlinePropertyDefinition.decode(attrs["property"]), property.kind == .date {
            ClipSavedDatePreview(property: property, appearance: appearance)
        } else if node["type"] as? String == "paragraph", inline.contains(where: { $0["type"] as? String == "inlineTag" }),
                  inline.allSatisfy({ $0["type"] as? String == "inlineTag" || ($0["type"] as? String == "text" && ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) {
            CollectionChipLayout(spacing: 4) {
                ForEach(Array(inline.filter { $0["type"] as? String == "inlineTag" }.enumerated()), id: \.offset) { _, tag in
                    Text("#" + ((tag["attrs"] as? [String: Any])?["name"] as? String ?? ""))
                        .font(appearance.fontStyle.font(size: 14, weight: .semibold))
                        .foregroundStyle(Color(vellixHex: "#B59AD9")).padding(.horizontal, 2)
                        .background(Color(vellixHex: "#B59AD9").opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        } else {
            ImmediatePreviewBlock(node: node, appearance: metadataAppearance, depth: depth + 1,
                collections: collections, referencedDocuments: referencedDocuments)
        }
    }
}

private struct ClipSavedDatePreview: View {
    let property: InlinePropertyDefinition
    let appearance: DocumentAppearance

    private func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        CollectionChipLayout(spacing: 4) {
            Text(property.name.isEmpty ? "Saved" : property.name)
            if let date = property.civilDate {
                HStack(spacing: 4) {
                    LibraryIcon(name: "numcal", size: 14)
                    Text(day(date))
                }
                .foregroundStyle(Color(vellixHex: "#B59AD9"))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color(vellixHex: "#B59AD9").opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                if property.includeTime { Text("at " + time(date)) }
            }
        }
        .font(appearance.fontStyle.font(size: 12)).foregroundStyle(Color(vellixHex: "#A7A7A7"))
    }
}

private struct TemplateComponentPreview: View {
    let definition: TemplateComponentDefinition
    let response: Any?
    let appearance: DocumentAppearance
    private var ink: Color { Color(vellixHex: appearance.textColorHex) }
    private var selectedIDs: Set<String> {
        if let value = response as? String { return [value] }
        return Set(response as? [String] ?? [])
    }
    private var inverse: Color {
        let number = UInt32(appearance.textColorHex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
        let brightness = Double((number >> 16) & 255) * 0.299 + Double((number >> 8) & 255) * 0.587 + Double(number & 255) * 0.114
        return brightness < 140 ? .white : .black
    }
    var body: some View {
        VStack(alignment: .leading, spacing: definition.kind == .rating ? 14 : 6) {
            if !definition.label.isEmpty { Text(definition.label).fontWeight(.semibold) }
            switch definition.kind {
            case .rating:
                CollectionChipLayout(spacing: 8) {
                    ForEach(Int(definition.minimum)...Int(definition.maximum), id: \.self) { value in
                        chip(String(value), selected: (response as? NSNumber)?.doubleValue == Double(value), rating: true)
                    }
                }
            case .singleSelect, .multiSelect:
                CollectionChipLayout(spacing: 6) {
                    ForEach(definition.choices) { choice in chip(choice.label, selected: selectedIDs.contains(choice.id)) }
                }
            case .slider:
                let value = (response as? NSNumber)?.doubleValue
                Slider(value: .constant(max(definition.minimum, min(definition.maximum, value ?? definition.minimum))), in: definition.minimum...definition.maximum, step: definition.step).tint(ink)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(definition.minimumLabel.isEmpty ? definition.minimum.formatted() : definition.minimumLabel)
                        .font(.caption).opacity(0.65).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if let value { Text(value.formatted()).fontWeight(.bold).fixedSize() }
                    Text(definition.maximumLabel.isEmpty ? definition.maximum.formatted() : definition.maximumLabel)
                        .font(.caption).opacity(0.65).multilineTextAlignment(.trailing)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                }.frame(maxWidth: .infinity)
            }
        }.font(appearance.fontStyle.font(size: 16)).foregroundStyle(ink)
    }
    private func chip(_ text: String, selected: Bool, rating: Bool = false) -> some View {
        Text(text).font(appearance.fontStyle.font(size: 14, weight: rating ? (selected ? .semibold : .regular) : .bold))
            .foregroundStyle(selected && !rating ? inverse : ink).padding(.horizontal, rating ? 18 : 12).padding(.vertical, rating ? 10 : 4)
            .frame(minHeight: rating ? nil : 30)
            .background(selected ? ink.opacity(rating ? 0.16 : 1) : .clear, in: RoundedRectangle(cornerRadius: rating ? 10 : 18))
            .overlay(RoundedRectangle(cornerRadius: rating ? 10 : 18).stroke(ink.opacity(0.28)))
            .fixedSize(horizontal: false, vertical: true)
    }
}
