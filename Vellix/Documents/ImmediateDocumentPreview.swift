import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct ImmediateDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    let document: DocumentRecord
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
            LibrarySnapshotSurface(style: document.isThemed ? document.appearance.editorBackground : DocumentAppearance.plain.editorBackground,
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
                                cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore))
                            if let (collection, entry) = savedContent.entryContext {
                                CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: document.appearance)
                            }
                        }
                        ImmediatePreviewBlocks(nodes: nodes, appearance: document.appearance, depth: 0,
                            collections: savedContent.collections, referencedDocuments: savedContent.children, spacing: 18)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        if document.isThemed {
                            LibrarySnapshotSurface(style: document.appearance.innerPageBackground,
                                photo: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: environment.attachmentStore))
                        } else {
                            Color(vellixHex: DocumentAppearance.plain.editorBackground.colorHex).overlay(.black.opacity(0.30))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(document.isThemed ? 8 : 0)
        }
        .foregroundStyle(Color(vellixHex: document.appearance.textColorHex))
        .allowsHitTesting(false)
        .clipped()
    }
}

struct ImmediateDocumentBodyPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    let document: DocumentRecord
    var body: some View {
        let saved = environment.documentPreviews.content(for: document)
        let nodes = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []
        ImmediatePreviewBlocks(nodes: nodes, appearance: document.appearance, depth: 0,
            collections: saved.collections, referencedDocuments: saved.children, spacing: 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(vellixHex: document.appearance.textColorHex))
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

    var body: some View {
        if depth < 16 {
            content.padding(.leading, CGFloat(max(0, min(6, attrs["indent"] as? Int ?? 0))) * 18)
        }
    }

    @ViewBuilder private var content: some View {
        switch type {
        case "collection":
            if let id = attrs["collectionID"] as? String, let snapshot = collections.first(where: { $0.record.id == id }) {
                CollectionSnapshotPreview(snapshot: snapshot, appearance: appearance, attachments: environment.attachmentStore)
                    .padding(.vertical, 16)
            }
        case "table": ImmediateTablePreview(node: node, appearance: appearance)
        case "paragraph", "heading", "codeBlock":
            let guided = nodes.isEmpty && attrs["placeholderEnabled"] as? Bool == true
            let inline = guided ? (attrs["placeholderGuidance"] as? [[String: Any]] ?? []) : nodes
            let level = attrs["level"] as? Int ?? 1
            let size: CGFloat = type == "heading" ? [34, 28, 23, 20, 18][max(0, min(4, level - 1))] : 16
            let alignment: TextAlignment = attrs["textAlign"] as? String == "center" ? .center : (attrs["textAlign"] as? String == "right" ? .trailing : .leading)
            richText(inline).font(.system(size: size, weight: type == "heading" ? .bold : .regular,
                design: type == "codeBlock" ? .monospaced : appearance.fontStyle.design))
                .opacity(guided ? 0.38 : 1).multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, minHeight: inline.isEmpty ? 20 : nil,
                    alignment: alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
        case "callout":
            HStack(alignment: .top, spacing: 12) {
                LibraryIcon(name: attrs["icon"] as? String ?? "sparkle", size: 22).foregroundStyle(color.opacity(0.55))
                children(nodes)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
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
        values.reduce(Text("")) { result, item in
            var text = Text(item["type"] as? String == "hardBreak" ? "\n" : (item["text"] as? String ?? ""))
            for mark in item["marks"] as? [[String: Any]] ?? [] {
                switch mark["type"] as? String {
                case "bold": text = text.bold()
                case "italic": text = text.italic()
                case "underline": text = text.underline()
                case "strike": text = text.strikethrough()
                case "code": text = text.monospaced()
                default: break
                }
            }
            return result + text
        }
    }
}
