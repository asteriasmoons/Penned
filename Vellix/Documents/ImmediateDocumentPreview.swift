import SwiftUI

// The saved document is available immediately, even before a first WebKit snapshot exists.
struct ImmediateDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    let document: DocumentRecord
    var showsPageSurfaces = true
    var showsDocumentTitle = true
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
        let nodes = TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []
        var result: [[[String: Any]]] = [[]]
        for node in nodes {
            if node["type"] as? String == "pageBreak" { result.append([]) }
            else { result[result.count - 1].append(node) }
        }
        return result
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            if showsPageSurfaces {
                LibrarySnapshotSurface(style: appearance.editorBackground,
                    photo: document.isThemed ? CardImageLoader.image(path: document.appearance.editorBackground.imagePath, store: environment.attachmentStore) : nil)
                if let theme = document.appearance.editorBackground.patternTheme(for: document.appearance.themeID) {
                    ThemePatternOverlay(theme: theme)
                        .opacity(document.appearance.editorBackground.effect == .faded ? 0.35 : 1)
                }
            }
            VStack(spacing: 14) {
                ForEach(Array(sheets.enumerated()), id: \.offset) { index, nodes in
                    VStack(alignment: .leading, spacing: 18) {
                        if index == 0 {
                            if showsDocumentTitle || appearance.displaysCover {
                                LibrarySnapshotHeader(document: document,
                                    cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore),
                                    appearance: appearance, titleLineLimit: nil, showsTitle: showsDocumentTitle)
                            }
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
                        if showsPageSurfaces {
                            if document.isThemed {
                                LibrarySnapshotSurface(style: appearance.innerPageBackground,
                                    photo: CardImageLoader.image(path: document.appearance.innerPageBackground.imagePath, store: environment.attachmentStore))
                            } else {
                                Color(vellixHex: appearance.editorBackground.colorHex)
                                    .overlay { if appearance.presentationColorScheme == .dark { Color.black.opacity(0.30) } }
                            }
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

@MainActor
enum ImmediateOpenPagePreview {
    static func snapshots(for document: DocumentRecord, environment: AppEnvironment, colorScheme: ColorScheme) -> OpenPageSnapshots? {
        let saved = environment.documentPreviews.content(for: document)
        let appearance = document.appearance.resolved(for: colorScheme)
        var sheets: [[[String: Any]]] = [[]]
        for node in TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? [] {
            if node["type"] as? String == "pageBreak" {
                if sheets.count == 2 { break }
                sheets.append([])
            } else { sheets[sheets.count - 1].append(node) }
        }
        let limit = OpenPageSnapshotRenderer.contentHeight
        #if os(iOS)
        let spacing: CGFloat = 10
        #else
        let spacing: CGFloat = 18
        #endif
        func bodyCapture(_ nodes: [[String: Any]], includesHeader: Bool) -> (image: CGImage, height: CGFloat)? {
            let measurement = OpenPageBodyMeasurement()
            let renderer = ImageRenderer(content: OpenPageBodyLayout(measurement: measurement, limit: limit * 2) {
                VStack(alignment: .leading, spacing: 18) {
                    if includesHeader {
                        if appearance.displaysCover {
                            LibrarySnapshotHeader(document: document,
                                cover: CardImageLoader.image(path: document.cover, store: environment.attachmentStore),
                                appearance: appearance, showsTitle: false)
                        }
                        if let (collection, entry) = saved.entryContext {
                            CollectionFieldsSnapshotPreview(snapshot: collection, entry: entry, appearance: appearance)
                        }
                    }
                    ImmediatePreviewBlocks(nodes: nodes, appearance: appearance, depth: 0,
                        collections: saved.collections, referencedDocuments: saved.children, spacing: spacing)
                }
                .frame(width: 320, alignment: .topLeading)
            }
            .foregroundStyle(Color(vellixHex: appearance.textColorHex))
            .environmentObject(environment).environment(\.colorScheme, appearance.presentationColorScheme).clipped())
            renderer.scale = 1
            renderer.isOpaque = false
            guard let image = renderer.cgImage else { return nil }
            return (image, measurement.height)
        }
        guard let first = bodyCapture(sheets[0], includesHeader: true),
              let empty = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        empty.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let emptyImage = empty.makeImage() else { return nil }
        let second: CGImage?
        let secondOffset: CGFloat
        if first.height > limit {
            second = first.image; secondOffset = limit
        } else {
            second = sheets.count > 1 ? bodyCapture(sheets[1], includesHeader: false)?.image : nil
            secondOffset = 0
        }
        func sheet(_ image: CGImage?, offset: CGFloat) -> CGImage? {
            let cropped = image.flatMap { image -> CGImage? in
                let height = min(limit, CGFloat(image.height) - offset)
                guard height > 0 else { return nil }
                return image.cropping(to: CGRect(x: 0, y: offset, width: CGFloat(image.width), height: height))
            }
            let renderer = ImageRenderer(content: LibrarySnapshotPage(document: document, appearance: appearance,
                headerImage: emptyImage, headerHeight: 0, bodyImage: cropped ?? emptyImage,
                bodyHeight: cropped.map { CGFloat($0.height) } ?? 0, pageBreaks: [],
                outerImage: CardImageLoader.image(path: appearance.editorBackground.imagePath, store: environment.attachmentStore),
                innerImage: CardImageLoader.image(path: appearance.innerPageBackground.imagePath, store: environment.attachmentStore))
                .frame(width: document.isThemed ? 376 : 360, height: limit + 40 + (document.isThemed ? 16 : 0))
                .environment(\.colorScheme, appearance.presentationColorScheme))
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage
        }
        guard let left = sheet(first.image, offset: 0), let right = sheet(second, offset: secondOffset) else { return nil }
        return OpenPageSnapshots(left: left, right: right)
    }
}

// Synchronous ImageRenderer layout measurement, not observable editor state. Clamp the
// bitmap to two pages even when a saved text block is much taller than the preview.
private nonisolated final class OpenPageBodyMeasurement { var height: CGFloat = 0 }

private struct OpenPageBodyLayout: Layout {
    let measurement: OpenPageBodyMeasurement
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.first?.sizeThatFits(ProposedViewSize(width: 320, height: nil)).height ?? 0
        measurement.height = height
        return CGSize(width: 320, height: max(1, min(limit, height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: 320, height: nil))
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
        let groups = PageCardPreviewGroup.groups(Array(nodes.prefix(96)), documents: referencedDocuments,
                                                includeRichLinkCards: true, includePlainCallouts: true)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                let node = group.nodes[0]
                let consecutiveProperties = index > 0 && node["type"] as? String == "inlineProperty"
                    && groups[index - 1].nodes.last?["type"] as? String == "inlineProperty"
                Group {
                    if group.smallCards || group.gridCards || group.richLinkCards || group.plainCallouts {
                        PageCardFlowLayout(smallCards: group.nodes.map { _ in true }) {
                            ForEach(Array(group.nodes.enumerated()), id: \.offset) { _, item in
                                ImmediatePreviewBlock(node: item, appearance: appearance, depth: depth,
                                    collections: collections, referencedDocuments: referencedDocuments)
                            }
                        }
                    } else {
                        ImmediatePreviewBlock(node: node, appearance: appearance, depth: depth,
                            collections: collections, referencedDocuments: referencedDocuments)
                    }
                }.padding(.top, index == 0 ? 0 : (consecutiveProperties ? 4 : spacing))
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

    var body: some View {
        if depth < 16 {
            content.padding(.leading, type == "richLink" ? 0 : CGFloat(max(0, min(6, attrs["indent"] as? Int ?? 0))) * 18)
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
        case "listGrid": ListGridPreview(node: node, appearance: appearance)
        case "richLink": ImmediateRichLinkPreview(link: RichLinkPreviewData(node), appearance: appearance)
        case "tabs":
            ImmediateTabsPreview(node: node, appearance: appearance, depth: depth,
                collections: collections, referencedDocuments: referencedDocuments)
        case "minimalFields":
            ImmediateMinimalFieldsPreview(node: node, appearance: appearance, depth: depth,
                collections: collections, referencedDocuments: referencedDocuments)
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
            let inlineAppearance = blockTextAppearance
            InlineTextPreview.text(inline, appearance: inlineAppearance, size: size, weight: type == "heading" ? .bold : .regular)
                .font(inlineAppearance.fontStyle.font(size: size, weight: type == "heading" ? .bold : .regular))
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
        case "gridCard", "callout":
            gridCard
        case "iconCallout", "plainCallout":
            let isPlain = type == "plainCallout"
            if isPlain, let source = attrs["clipSource"] as? [String: Any],
               let href = source["url"] as? String, InlinePropertyDefinition.safeURL(href) != nil {
                ClipSourceDocumentPreview(source: source, nodes: nodes, appearance: appearance,
                    depth: depth, collections: collections, referencedDocuments: referencedDocuments)
            } else {
                let settings = IconCalloutSettings(attrs, plain: isPlain)
                HStack(alignment: .top, spacing: 8) {
                    if !isPlain {
                        IconCalloutGlyph(settings: settings,
                            image: WashiTapePreview.documentImage(path: settings.imagePath, attachments: environment.attachments, store: environment.attachmentStore))
                    }
                    calloutBody(ink: settings.inkColor).padding(.vertical, 2)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: isPlain ? settings.minimumHeight.map { CGFloat($0) } : nil, alignment: .topLeading)
                .background(Color(vellixHex: settings.backgroundColor), in: RoundedRectangle(cornerRadius: 12))
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

    private var blockTextAppearance: DocumentAppearance {
        var styled = appearance
        if type == "codeBlock" {
            styled.fontStyle = .mono
        } else if let raw = attrs["blockFont"] as? String, let font = DocumentFontStyle(rawValue: raw), font != .hachiMaruPop {
            styled.fontStyle = font
        }
        return styled
    }

    private func calloutBody(ink: String) -> some View {
        var colors = appearance
        colors.textColorHex = ink
        return ImmediatePreviewBlocks(nodes: nodes, appearance: colors, depth: depth + 1,
            collections: collections, referencedDocuments: referencedDocuments, spacing: 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridCard: some View {
        let card = GridCardSettings(attrs)
        let horizontal: Alignment = card.alignment == .center ? .center : (card.alignment == .right ? .trailing : .leading)
        let text: TextAlignment = card.alignment == .center ? .center : (card.alignment == .right ? .trailing : .leading)
        var colors = appearance
        colors.textColorHex = card.effectiveTextColor
        return VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: horizontal.horizontal, spacing: 6) {
                LibraryIcon(name: card.icon, size: 28).foregroundStyle(Color(vellixHex: card.iconColor))
                if !card.title.isEmpty {
                    Text(card.title).font(appearance.fontStyle.font(size: 18, weight: .bold))
                        .foregroundStyle(Color(vellixHex: card.effectiveTitleColor)).multilineTextAlignment(text)
                }
            }.frame(maxWidth: .infinity, alignment: horizontal)
            ImmediatePreviewBlocks(nodes: nodes, appearance: colors, depth: depth + 1,
                collections: collections, referencedDocuments: referencedDocuments, spacing: 6)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: CGFloat(card.height), alignment: .topLeading)
        .background(Color(vellixHex: card.backgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func children(_ values: [[String: Any]]) -> some View {
        ImmediatePreviewBlocks(nodes: values, appearance: appearance, depth: depth + 1,
            collections: collections, referencedDocuments: referencedDocuments, spacing: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ImmediateRichLinkPreview: View {
    let link: RichLinkPreviewData
    let appearance: DocumentAppearance

    var body: some View {
        VStack(spacing: 0) {
            if link.layout == .card {
                if let url = link.image ?? link.favicon { image(url).aspectRatio(2, contentMode: .fit) }
                copy
            } else {
                HStack(spacing: 0) {
                    if let url = link.image ?? link.favicon {
                        image(url).frame(width: link.layout == .small ? 50 : 84, height: link.layout == .small ? 28 : 46)
                    }
                    copy
                }
            }
            if link.layout != .small {
                HStack(spacing: 5) {
                    if let favicon = link.favicon { image(favicon).frame(width: 14, height: 14) }
                    Text(link.site).font(appearance.fontStyle.font(size: 9)).lineLimit(1)
                }.opacity(0.65).padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.10)).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.16)) }
        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(link.title).font(appearance.fontStyle.font(size: 13, weight: .semibold)).lineLimit(1)
            if link.layout != .small, !link.description.isEmpty {
                Text(link.description).font(appearance.fontStyle.font(size: 11)).opacity(0.67)
                    .lineLimit(link.layout == .card ? 2 : 1)
            }
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: link.layout == .small ? 28 : 46, alignment: .leading)
    }

    private func image(_ url: URL) -> some View {
        Color.primary.opacity(0.06).overlay {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
            }
        }.clipped()
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

// Native preview of a tabs block: container, optional header, the tab bar with the
// active tab highlighted, and the active panel's content rendered recursively.
private struct ImmediateTabsPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]

    private var attrs: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }
    private var panels: [[String: Any]] {
        (node["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tabPanel" }
    }

    private func hex(_ value: Any?, _ fallback: String) -> String {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("#"), s.count == 7 || s.count == 9 else { return fallback }
        return s
    }
    private func number(_ value: Any?, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
        let n = (value as? NSNumber)?.intValue ?? (value as? Int) ?? (value as? String).flatMap { Int($0) } ?? fallback
        return max(lo, min(hi, n))
    }
    private func bool(_ value: Any?, _ fallback: Bool) -> Bool {
        (value as? Bool) ?? ((value as? String).map { $0 == "true" }) ?? fallback
    }
    private func panelName(_ panel: [String: Any], _ index: Int) -> String {
        let name = (panel["attrs"] as? [String: Any])?["name"] as? String ?? ""
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Tab \(index + 1)" : name
    }
    private var activeID: String {
        let ids = panels.compactMap { ($0["attrs"] as? [String: Any])?["id"] as? String }
        if let active = attrs["activeTab"] as? String, ids.contains(active) { return active }
        return ids.first ?? ""
    }

    var body: some View {
        let showContainer = bool(attrs["showContainer"], true)
        let activeContent = (panels.first { ($0["attrs"] as? [String: Any])?["id"] as? String == activeID }?["content"]
            as? [[String: Any]]) ?? []
        let inner = VStack(alignment: .leading, spacing: 12) {
            if bool(attrs["showHeader"], false) { header }
            tabBar
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(activeContent.prefix(40).enumerated()), id: \.offset) { _, child in
                    ImmediatePreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                        collections: collections, referencedDocuments: referencedDocuments)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if showContainer {
            let shape = RoundedRectangle(cornerRadius: CGFloat(number(attrs["cornerRadius"], 16, 0, 40)))
            inner
                .padding(CGFloat(number(attrs["padding"], 14, 0, 40)))
                .background(Color(vellixHex: hex(attrs["containerBg"], "#111113")), in: shape)
                .overlay(shape.strokeBorder(Color(vellixHex: hex(attrs["containerBorder"], "#2A2A2E")),
                    lineWidth: CGFloat(number(attrs["borderWidth"], 1, 0, 8))))
                .padding(.vertical, CGFloat(number(attrs["outerSpacing"], 8, 0, 40)))
        } else {
            inner.padding(.vertical, CGFloat(number(attrs["outerSpacing"], 8, 0, 40)))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            let icon = attrs["icon"] as? String ?? ""
            if !icon.isEmpty {
                LibraryIcon(name: icon, size: 22)
                    .foregroundStyle(Color(vellixHex: hex(attrs["indicatorColor"], "#7C5CFF")))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((attrs["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
                    .font(appearance.fontStyle.font(size: 18, weight: .bold))
                    .foregroundStyle(Color(vellixHex: hex(attrs["titleColor"], "#FFFFFF")))
                if let subtitle = attrs["subtitle"] as? String, !subtitle.isEmpty {
                    Text(subtitle).font(appearance.fontStyle.font(size: 12))
                        .foregroundStyle(Color(vellixHex: hex(attrs["subtitleColor"], "#9A9AA0")))
                }
            }
        }
    }

    private var tabBar: some View {
        let style = (attrs["tabBarStyle"] as? String).flatMap {
            ["filled", "underlined", "segmented", "minimal"].contains($0) ? $0 : nil } ?? "filled"
        let spacing = CGFloat(number(attrs["tabSpacing"], 8, 0, 32))
        return CollectionChipLayout(spacing: style == "segmented" ? 4 : spacing) {
            ForEach(Array(panels.enumerated()), id: \.offset) { index, panel in
                let id = (panel["attrs"] as? [String: Any])?["id"] as? String ?? ""
                tabChip(name: panelName(panel, index), active: id == activeID, style: style)
            }
        }
    }

    @ViewBuilder
    private func tabChip(name: String, active: Bool, style: String) -> some View {
        let activeText = Color(vellixHex: hex(attrs["activeTabText"], "#FFFFFF"))
        let inactiveText = Color(vellixHex: hex(attrs["inactiveTabText"], "#9A9AA0"))
        let indicator = Color(vellixHex: hex(attrs["indicatorColor"], "#7C5CFF"))
        let fg = active ? activeText : inactiveText
        let font = appearance.fontStyle.font(size: 15, weight: .semibold)
        switch style {
        case "underlined", "minimal":
            VStack(spacing: 3) {
                Text(name).font(font).foregroundStyle(fg)
                Rectangle().fill(active ? indicator : Color.clear).frame(height: 2)
            }
            .fixedSize()
        default:
            let activeBg = Color(vellixHex: hex(attrs["activeTabBg"], "#3A3A3C"))
            let inactiveBg = style == "segmented" ? Color.clear : Color(vellixHex: hex(attrs["inactiveTabBg"], "#1C1C1E"))
            Text(name).font(font).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(active ? activeBg : inactiveBg,
                    in: RoundedRectangle(cornerRadius: CGFloat(number(attrs["tabCornerRadius"], 10, 0, 24))))
                .fixedSize()
        }
    }
}

// Native preview of a Minimal Fields block: per-record accent rail, bold title,
// small coloured labels with their values beneath, and thin dividers.
private struct ImmediateMinimalFieldsPreview: View {
    let node: [String: Any]
    let appearance: DocumentAppearance
    let depth: Int
    let collections: [CollectionSnapshot]
    let referencedDocuments: [DocumentRecord]

    private var attrs: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }
    private var records: [[String: Any]] {
        (node["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "minimalRecord" }
    }
    private func hex(_ value: Any?, _ fallback: String) -> String {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("#"), s.count == 7 || s.count == 9 else { return fallback }
        return s
    }
    private func number(_ value: Any?, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
        let n = (value as? NSNumber)?.intValue ?? (value as? Int) ?? (value as? String).flatMap { Int($0) } ?? fallback
        return max(lo, min(hi, n))
    }
    private func bool(_ value: Any?, _ fallback: Bool) -> Bool {
        (value as? Bool) ?? ((value as? String).map { $0 == "true" }) ?? fallback
    }

    var body: some View {
        let dividerVisible = bool(attrs["dividerVisible"], true)
        let dividerColor = Color(vellixHex: hex(attrs["dividerColor"], "#2A2A2E"))
        let recordGap = CGFloat(number(attrs["recordSpacing"], 0, 48, 18))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                if index > 0 {
                    if dividerVisible {
                        Rectangle().fill(dividerColor).frame(height: 1)
                            .padding(.top, recordGap).padding(.bottom, recordGap)
                    } else {
                        Color.clear.frame(height: recordGap)
                    }
                }
                recordView(record)
            }
        }
        .padding(.vertical, CGFloat(number(attrs["outerSpacing"], 0, 40, 8)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordView(_ record: [String: Any]) -> some View {
        let accent = Color(vellixHex: hex(attrs["accentColor"], "#7C5CFF"))
        let accentW = CGFloat(number(attrs["accentWidth"], 1, 8, 3))
        let titleSize = CGFloat(number(attrs["titleSize"], 14, 32, 20))
        let children = record["content"] as? [[String: Any]] ?? []
        let titleContent = (children.first { $0["type"] as? String == "minimalRecordTitle" }?["content"] as? [[String: Any]]) ?? []
        let fields = children.filter { $0["type"] as? String == "minimalField" }
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: accentW / 2).fill(accent).frame(width: accentW)
            VStack(alignment: .leading, spacing: 0) {
                InlineTextPreview.text(titleContent, appearance: appearance, size: titleSize, weight: .bold)
                    .font(appearance.fontStyle.font(size: titleSize, weight: .bold))
                    .foregroundStyle(Color(vellixHex: hex(attrs["titleColor"], "#FFFFFF")))
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldView(_ field: [String: Any]) -> some View {
        let kids = field["content"] as? [[String: Any]] ?? []
        let labelContent = (kids.first { $0["type"] as? String == "minimalFieldLabel" }?["content"] as? [[String: Any]]) ?? []
        let valueContent = (kids.first { $0["type"] as? String == "minimalFieldValue" }?["content"] as? [[String: Any]]) ?? []
        let labelSize = CGFloat(number(attrs["labelSize"], 9, 18, 12))
        let uppercase = bool(attrs["labelUppercase"], true)
        return VStack(alignment: .leading, spacing: 2) {
            InlineTextPreview.text(labelContent, appearance: appearance, size: labelSize, weight: .bold)
                .font(appearance.fontStyle.font(size: labelSize, weight: .bold))
                .foregroundStyle(Color(vellixHex: hex(attrs["labelColor"], "#B98CFF")))
                .textCase(uppercase ? .uppercase : nil)
                .tracking(0.5)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(valueContent.prefix(20).enumerated()), id: \.offset) { _, child in
                    ImmediatePreviewBlock(node: child, appearance: appearance, depth: depth + 1,
                        collections: collections, referencedDocuments: referencedDocuments)
                }
            }
        }
        .padding(.top, CGFloat(number(attrs["fieldSpacing"], 0, 32, 12)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
