import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct ImmediateDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    private var appearance: DocumentAppearance { document.appearance.resolved(for: colorScheme) }
    private var savedContent: DocumentPreviewContent { environment.documentPreviews.content(for: document) }

    private var sheets: [[[String: Any]]] {
        var result: [[[String: Any]]] = [[]]
        for node in TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? [] {
            if node["type"] as? String == "pageBreak" { result.append([]) }
            else { result[result.count - 1].append(node) }
        }
        return result
    }

    var body: some View {
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
                                cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore), appearance: appearance)
                            if let (collection, entry) = savedContent.entryContext {
                                CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: appearance)
                            }
                        }
                        ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
                            collections: savedContent.collections, referencedDocuments: savedContent.children, spacing: 18)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
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
            let size: CGFloat = type == "heading" ? [34, 28, 23, 20, 18][max(0, min(4, level - 1))] : (type == "caption" ? 13.6 : 16)
            let alignment: TextAlignment = attrs["textAlign"] as? String == "center" ? .center : (attrs["textAlign"] as? String == "right" ? .trailing : .leading)
            richText(inline).font(.system(size: size, weight: type == "heading" ? .bold : .regular,
                design: type == "codeBlock" ? .monospaced : appearance.fontStyle.design))
                .opacity(guided ? 0.38 : (type == "caption" ? 0.75 : 1)).multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, minHeight: inline.isEmpty ? 20 : nil,
                    alignment: alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
        case "callout", "plainCallout":
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
                        if type == "orderedList" { Text("\((attrs["start"] as? Int ?? 1) + index).").font(.system(size: 16)) }
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
            Rectangle().fill(color.opacity(0.20)).frame(height: attrs["style"] as? String == "thickLine" ? 4 : 1).padding(.vertical, 8)
        case "pageReference":
            if let id = attrs["documentID"] as? String,
               let child = referencedDocuments.first(where: { $0.id == id }) ?? environment.editorCache.model(for: id)?.document {
                if let style = child.cardStyle {
                    PageCardView(document: child, style: style,
                        photo: CardImageLoader.image(path: style.imagePath, store: environment.attachmentStore), fillsDocumentWidth: style.size.fillsDocumentWidth,
                        attachmentStore: environment.attachmentStore)
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

    private func richText(_ values: [[String: Any]]) -> Text {
        InlineTextPreview.text(values, appearance: appearance)
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
        }.font(.system(size: 16, design: appearance.fontStyle.design)).foregroundStyle(ink)
    }
    private func chip(_ text: String, selected: Bool, rating: Bool = false) -> some View {
        Text(text).font(.system(size: 14, weight: rating ? (selected ? .semibold : .regular) : .bold, design: appearance.fontStyle.design))
            .foregroundStyle(selected && !rating ? inverse : ink).padding(.horizontal, rating ? 18 : 12).padding(.vertical, rating ? 10 : 4)
            .frame(minHeight: rating ? nil : 30)
            .background(selected ? ink.opacity(rating ? 0.16 : 1) : .clear, in: RoundedRectangle(cornerRadius: rating ? 10 : 18))
            .overlay(RoundedRectangle(cornerRadius: rating ? 10 : 18).stroke(ink.opacity(0.28)))
            .fixedSize(horizontal: false, vertical: true)
    }
}
