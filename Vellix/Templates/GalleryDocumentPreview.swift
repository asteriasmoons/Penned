import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct GalleryDocumentPreview: View {
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
                        GalleryPreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
                            collections: savedContent.collections, referencedDocuments: savedContent.children, spacing: blockSpacing)
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

struct GalleryDocumentBodyPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    var body: some View {
        let saved = environment.documentPreviews.content(for: document)
        let appearance = document.appearance.resolved(for: colorScheme)
        let nodes = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []
        GalleryPreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
            collections: saved.collections, referencedDocuments: saved.children, spacing: 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .environment(\.colorScheme, appearance.presentationColorScheme)
            .allowsHitTesting(false)
    }
}

private struct GalleryPreviewBlocks: View {
    let nodes: [[String: Any]]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]
    var spacing: CGFloat

    var body: some View {
        let groups = PageCardPreviewGroup.groups(nodes, documents: referencedDocuments, includePlainCallouts: true, includeWidgets: true)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                let node = group.nodes[0]
                let consecutiveProperties = index > 0 && node["type"] as? String == "inlineProperty"
                    && groups[index - 1].nodes.last?["type"] as? String == "inlineProperty"
                Group {
                    if group.smallCards || group.plainCallouts || group.documentWidgets {
                        PageCardFlowLayout(smallCards: group.nodes.map { _ in true }) {
                            ForEach(Array(group.nodes.enumerated()), id: \.offset) { _, item in
                                GalleryPreviewBlock(node: item, appearance: appearance, depth: depth,
                                    collections: collections, referencedDocuments: referencedDocuments)
                            }
                        }
                    } else {
                        GalleryPreviewBlock(node: node, appearance: appearance, depth: depth,
                            collections: collections, referencedDocuments: referencedDocuments)
                    }
                }.padding(.top, index == 0 ? 0 : (consecutiveProperties ? 4 : spacing))
            }
        }
    }
}

private struct GalleryPreviewBlock: View {
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
        case "moodBar": MoodBarPreview(settings: MoodBarSettings(attrs))
        case "countdown":
            CountdownWidgetPreview(settings: CountdownSettings(attrs),
                iconImage: WashiTapePreview.documentImage(path: attrs["imagePath"], attachments: environment.attachments, store: environment.attachmentStore))
        case "calculator":
            CalculatorWidgetPreview(settings: CalculatorSettings(attrs), state: CalculatorState(attrs["state"] as? [String: Any] ?? [:]))
        case "attachment":
            if let file = attrs["file"] as? [String: Any], let path = file["relativePath"] as? String,
               let resolved = try? environment.attachments.editorAttachment(relativePath: path) {
                AttachmentBlockPreview(file: resolved, attrs: attrs, store: environment.attachmentStore)
            }
        case "templateComponent":
            if let definition = TemplateComponentDefinition.decode(attrs["definition"]) {
                GalleryTemplateComponentPreview(definition: definition, response: attrs["response"], appearance: appearance)
            }
        case "collection":
            if let id = attrs["collectionID"] as? String, let snapshot = collections.first(where: { $0.record.id == id }) {
                CollectionSnapshotPreview(snapshot: snapshot, appearance: appearance, attachments: environment.attachmentStore)
                    .padding(.vertical, 16)
            }
        case "table": ImmediateTablePreview(node: node, appearance: appearance)
        case "listGrid": ListGridPreview(node: node, appearance: appearance)
        case "tabs":
            let panels = nodes.filter { $0["type"] as? String == "tabPanel" }
            let ids = panels.compactMap { ($0["attrs"] as? [String: Any])?["id"] as? String }
            let active = (attrs["activeTab"] as? String).flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            let activeContent = (panels.first { ($0["attrs"] as? [String: Any])?["id"] as? String == active }?["content"]
                as? [[String: Any]]) ?? []
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(activeContent.prefix(40).enumerated()), id: \.offset) { _, child in
                    GalleryPreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                        collections: collections, referencedDocuments: referencedDocuments)
                }
            }
        case "minimalFields":
            let records = nodes.filter { $0["type"] as? String == "minimalRecord" }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(records.prefix(12).enumerated()), id: \.offset) { _, record in
                    let children = record["content"] as? [[String: Any]] ?? []
                    let titleContent = (children.first { $0["type"] as? String == "minimalRecordTitle" }?["content"] as? [[String: Any]]) ?? []
                    let fields = children.filter { $0["type"] as? String == "minimalField" }
                    VStack(alignment: .leading, spacing: 4) {
                        InlineTextPreview.text(titleContent, appearance: appearance, size: 18, weight: .bold)
                        ForEach(Array(fields.prefix(8).enumerated()), id: \.offset) { _, field in
                            let kids = field["content"] as? [[String: Any]] ?? []
                            let labelContent = (kids.first { $0["type"] as? String == "minimalFieldLabel" }?["content"] as? [[String: Any]]) ?? []
                            let valueContent = (kids.first { $0["type"] as? String == "minimalFieldValue" }?["content"] as? [[String: Any]]) ?? []
                            VStack(alignment: .leading, spacing: 2) {
                                InlineTextPreview.text(labelContent, appearance: appearance, size: 12, weight: .bold)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(valueContent.prefix(6).enumerated()), id: \.offset) { _, child in
                                    GalleryPreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                                        collections: collections, referencedDocuments: referencedDocuments)
                                }
                            }
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        case "heading" where HeadingLabelSettings.configuration(attrs)?.enabled == true:
            if let label = HeadingLabelSettings.configuration(attrs) {
                HeadingLabelTile(settings: label, attrs: attrs, nodes: nodes, appearance: appearance)
            }
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
                    GalleryPreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                        collections: collections, referencedDocuments: referencedDocuments)
                }
            }
        case "iconCallout":
            let settings = IconCalloutSettings(attrs)
            HStack(alignment: .top, spacing: 8) {
                IconCalloutGlyph(settings: settings,
                    image: WashiTapePreview.documentImage(path: settings.imagePath, attachments: environment.attachments, store: environment.attachmentStore))
                calloutBody(ink: settings.inkColor).padding(.vertical, 2)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(Color(vellixHex: settings.backgroundColor), in: RoundedRectangle(cornerRadius: 12))
        case "callout", "plainCallout":
            if type == "plainCallout", let source = attrs["clipSource"] as? [String: Any],
               let href = source["url"] as? String, InlinePropertyDefinition.safeURL(href) != nil {
                GallerySourceDocumentPreview(source: source, nodes: nodes, appearance: appearance,
                    depth: depth, collections: collections, referencedDocuments: referencedDocuments)
            } else if type == "plainCallout" {
                let settings = IconCalloutSettings(attrs, plain: true)
                calloutBody(ink: settings.inkColor).padding(.vertical, 2)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: settings.minimumHeight.map { CGFloat($0) }, alignment: .topLeading)
                    .background(Color(vellixHex: settings.backgroundColor), in: RoundedRectangle(cornerRadius: 12))
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
                ForEach(Array(nodes.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        if type == "orderedList" { Text("\((attrs["start"] as? Int ?? 1) + index).").font(appearance.fontStyle == .hachiMaruPop ? appearance.fontStyle.font(size: 14) : .system(size: 14)) }
                        else if type == "taskList" {
                            let itemAttrs = item["attrs"] as? [String: Any] ?? [:]
                            Group {
                                if itemAttrs["checked"] as? Bool == true { LibraryIcon(name: "checkwavy", size: 14) }
                                else { Circle().strokeBorder(.primary.opacity(0.55)).frame(width: 14, height: 14) }
                            }.padding(.top, 3)
                        } else { Circle().frame(width: 4, height: 4).padding(.top, 8) }
                        GalleryPreviewBlock(node: item, appearance: appearance, depth: depth + 1,
                            collections: collections, referencedDocuments: referencedDocuments)
                    }
                }
            }
        case "divider", "horizontalRule":
            if attrs["style"] as? String == "washiTape" {
                WashiTapePreview(color: (attrs["color"] as? String).map { Color(vellixHex: $0) },
                    image: WashiTapePreview.documentImage(path: attrs["imagePath"], attachments: environment.attachments, store: environment.attachmentStore),
                    photo: WashiTapeRequest.photo(attrs["remotePhoto"]), tapeSize: WashiTapeSize(attrs["tapeSize"]))
            } else if ["fourCircles", "fourDots"].contains(attrs["style"] as? String ?? "") {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                }.frame(maxWidth: .infinity, minHeight: 30)
            } else if ["dottedCircles", "tinyDots"].contains(attrs["style"] as? String ?? "") {
                DividerDotsPreview(color: color, customColor: attrs["color"] is String)
            } else {
            #if os(iOS)
            if attrs["style"] == nil || ["thinLine", "thickLine"].contains(attrs["style"] as? String ?? "") {
                Rectangle().fill(color.opacity(attrs["color"] is String || attrs["style"] as? String == "thickLine" ? 1 : 0.5))
                    .frame(height: attrs["style"] as? String == "thickLine" ? 2 : 1)
                    .padding(.horizontal, 6).frame(height: 20)
            } else {
                Rectangle().fill(color.opacity(0.20)).frame(height: 1).padding(.vertical, 8)
            }
            #else
            Rectangle().fill(color.opacity(attrs["color"] is String ? 1 : 0.20)).frame(height: attrs["style"] as? String == "thickLine" ? 4 : 1).padding(.vertical, 8)
            #endif
            }
        case "pageReference":
            if let id = attrs["documentID"] as? String,
               let child = referencedDocuments.first(where: { $0.id == id }) ?? environment.editorCache.model(for: id)?.document {
                if let style = child.cardStyle {
                    PageCardView(document: child, style: style,
                        photo: CardImageLoader.image(path: style.imagePath, store: environment.attachmentStore), fillsDocumentWidth: style.size.fillsDocumentWidth,
                        fillsCardSlot: !style.size.fillsDocumentWidth,
                        attachmentStore: environment.attachmentStore, containingFontStyle: appearance.fontStyle, previews: environment.documentPreviews)
                } else { NestedPageRow(document: child, appearance: appearance, open: {}) }
            }
        case "inlineProperty":
            if let property = InlinePropertyDefinition.decode(attrs["property"]) {
                InlinePropertyPreview(property: property, appearance: appearance)
            }
        case "informationCard":
            children(nodes.filter {
                !((attrs["hideTitle"] as? Bool == true && $0["type"] as? String == "informationCardTitle") ||
                  (attrs["hideDescription"] as? Bool == true && $0["type"] as? String == "informationCardDescription"))
            })
        default: children(nodes)
        }
    }

    private func calloutBody(ink: String) -> some View {
        var colors = appearance
        colors.textColorHex = ink
        return GalleryPreviewBlocks(nodes: nodes, appearance: colors, depth: depth + 1,
            collections: collections, referencedDocuments: referencedDocuments, spacing: 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func children(_ values: [[String: Any]]) -> some View {
        GalleryPreviewBlocks(nodes: values, appearance: appearance, depth: depth + 1,
            collections: collections, referencedDocuments: referencedDocuments, spacing: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct GallerySourceDocumentPreview: View {
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
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
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
            GallerySavedDatePreview(property: property, appearance: appearance)
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
            GalleryPreviewBlock(node: node, appearance: metadataAppearance, depth: depth + 1,
                collections: collections, referencedDocuments: referencedDocuments)
        }
    }
}

private struct GallerySavedDatePreview: View {
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

private struct GalleryTemplateComponentPreview: View {
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
