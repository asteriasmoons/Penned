import SwiftUI
import ImageIO

struct PageCardPreviewGroup {
    var nodes: [[String: Any]]
    let smallCards: Bool
    var gridCards = false
    var richLinkCards = false
    var plainCallouts = false
    var documentWidgets = false

    static func groups(_ nodes: [[String: Any]], documents: [DocumentRecord], includeRichLinkCards: Bool = false,
                       includePlainCallouts: Bool = false, includeWidgets: Bool = false) -> [Self] {
        let records = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        var groups: [Self] = []
        for node in nodes {
            let id = (node["attrs"] as? [String: Any])?["documentID"] as? String ?? ""
            let small = node["type"] as? String == "pageReference" && records[id]?.cardStyle?.size.fillsDocumentWidth == false
            let grid = GridCardSettings.isHalf(node)
            let widget = includeWidgets && DocumentWidgetSize.isHalf(node)
            let attrs = node["attrs"] as? [String: Any]
            let halfCallout = includePlainCallouts && node["type"] as? String == "plainCallout"
                && !(attrs?["clipSource"] is [String: Any]) && attrs?["widthPercent"] as? Double == 50
            let linkCard = includeRichLinkCards && node["type"] as? String == "richLink"
                && (node["attrs"] as? [String: Any])?["layout"] as? String == RichLinkLayout.card.rawValue
            if (small && groups.last?.smallCards == true) || (grid && groups.last?.gridCards == true)
                || (linkCard && groups.last?.richLinkCards == true) || (halfCallout && groups.last?.plainCallouts == true)
                || (widget && groups.last?.documentWidgets == true) {
                groups[groups.count - 1].nodes.append(node)
            } else { groups.append(Self(nodes: [node], smallCards: small, gridCards: grid, richLinkCards: linkCard, plainCallouts: halfCallout, documentWidgets: widget)) }
        }
        return groups
    }
}

struct PageCardFlowLayout: Layout {
    let smallCards: [Bool]

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.enumerated().map { index, subview in
            let small = smallCards.indices.contains(index) && smallCards[index]
            let itemWidth = small ? max(0, (width - 12) / 2) : width
            let gap: CGFloat = 12
            if x > 0 && (!small || x + gap + itemWidth > width + 0.5) {
                x = 0; y += rowHeight + 12; rowHeight = 0
            }
            let left = x > 0 ? x + gap : 0
            let size = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            let rect = CGRect(x: left, y: y, width: itemWidth, height: size.height)
            x = rect.maxX
            rowHeight = max(rowHeight, size.height)
            return rect
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

struct PageCardView: View {
    var document: DocumentRecord
    var style: PageCardStyle
    var photo: CGImage?
    var spinePhoto: CGImage? = nil
    var includeBackdrop = true
    var isStylePreview = false
    var fillsDocumentWidth = false
    var fillsCardSlot = false
    var attachmentStore: AttachmentStore? = nil
    var containingFontStyle: DocumentFontStyle? = nil
    var previews: DocumentPreviewCache? = nil
    var bookDescriptionDisplayWidth: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var textFont: DocumentFontStyle {
        containingFontStyle == .hachiMaruPop ? .hachiMaruPop : document.appearance.fontStyle
    }

    @ViewBuilder
    var body: some View {
        if fillsCardSlot || (fillsDocumentWidth && style.size.fillsDocumentWidth) {
            GeometryReader { proxy in
                cardFace(bookDisplayWidth: proxy.size.width)
                    .scaleEffect(proxy.size.width / style.renderSize.width, anchor: .topLeading)
            }
            .aspectRatio(style.renderSize.width / style.renderSize.height, contentMode: .fit)
        } else {
            cardFace()
        }
    }

    @ViewBuilder private func cardFace(bookDisplayWidth: CGFloat? = nil) -> some View {
        if style.isBook {
            book(displayWidth: bookDisplayWidth ?? bookDescriptionDisplayWidth ?? style.renderSize.width)
        } else {
            ZStack(alignment: .topLeading) {
                if includeBackdrop { backdrop }
                if style.backdrop == .photo {
                    LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if style.showsPages {
                    switch style.previewStyle {
                    case .pages: pages
                    case .stickyNote: stickyNote
                    case .openPage: openPage
                    }
                }
                text
            }
            .frame(width: style.renderSize.width, height: style.renderSize.height, alignment: .topLeading)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(vellixHex: textColor).opacity(0.14), lineWidth: 0.75)
            }
        }
    }

    @ViewBuilder private var backdrop: some View {
        switch style.backdrop {
        case .none: Color(vellixHex: document.appearance.innerPageBackground.colorHex)
        case .solid: Color(vellixHex: style.startColor)
        case .gradient:
            LinearGradient(colors: [Color(vellixHex: style.startColor), Color(vellixHex: style.endColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .photo:
            if let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill()
                    .frame(width: style.size.size.width, height: style.size.size.height).clipped()
            } else if let url = style.remotePhoto?.validImageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color(vellixHex: style.startColor) }
                    .frame(width: style.size.size.width, height: style.size.size.height).clipped()
            } else { Color(vellixHex: style.startColor) }
        }
    }

    @ViewBuilder private var pages: some View {
        switch style.size {
        case .compact:
            ZStack {
                Circle().fill(Color(vellixHex: textColor).opacity(0.1))
                miniature(size: CGSize(width: 23, height: 30)).offset(y: 4)
            }
            .frame(width: 32, height: 32).clipShape(Circle())
            .overlay(Circle().stroke(Color(vellixHex: textColor).opacity(0.16), lineWidth: 0.75))
            .offset(x: 14, y: 10)
        case .landscape, .portrait:
            miniature(size: CGSize(width: 132, height: 172)).offset(x: 36, y: 50)
        case .wide:
            miniature(size: CGSize(width: 116, height: 151), second: true)
                .rotationEffect(.degrees(-1.5), anchor: .bottomLeading).offset(x: 184, y: 32)
            miniature(size: CGSize(width: 116, height: 151)).offset(x: 190, y: 26)
        case .large:
            miniature(size: CGSize(width: 84, height: 109), second: true)
                .rotationEffect(.degrees(-1.5)).offset(x: 208, y: 28)
            miniature(size: CGSize(width: 84, height: 109))
                .rotationEffect(.degrees(0.5)).offset(x: 214, y: 25)
        }
    }

    private var stickyNote: some View {
        let size: CGSize
        let position: CGPoint
        switch style.size {
        case .compact:
            size = CGSize(width: 29, height: 33); position = CGPoint(x: 15, y: 12)
        case .landscape, .portrait:
            size = CGSize(width: 96, height: 112); position = CGPoint(x: 42, y: 50)
        case .wide:
            size = CGSize(width: 100, height: 112); position = CGPoint(x: 258, y: 26)
        case .large:
            size = CGSize(width: 96, height: 110); position = CGPoint(x: 210, y: 22)
        }
        return StickyNotePagePreview(snapshot: isStylePreview ? nil : previews?.cardSnapshot(for: document, colorScheme: colorScheme, hidesPageSurfaces: true), size: size)
            .rotationEffect(.degrees(-4))
            .offset(x: position.x, y: position.y)
    }

    private var openPage: some View {
        let size: CGSize
        let position: CGPoint
        switch style.size {
        case .compact:
            size = CGSize(width: 40, height: 28); position = CGPoint(x: 14, y: 12)
        case .landscape, .portrait:
            size = CGSize(width: 188, height: 131); position = CGPoint(x: 31, y: 47)
        case .wide:
            size = CGSize(width: 120, height: 84); position = CGPoint(x: 238, y: 24)
        case .large:
            size = CGSize(width: 164, height: 114); position = CGPoint(x: 202, y: 27)
        }
        let appearance = document.appearance.resolved(for: colorScheme)
        return OpenPagePreview(snapshots: isStylePreview ? nil : previews?.openPageSnapshots(for: document, colorScheme: colorScheme),
            size: size, paperColor: appearance.presentationColorScheme == .dark ? "#242424" : "#FAFAF8")
            .offset(x: position.x, y: position.y)
    }

    // Leave room inside the exported PNG for the raised cover, page edges and shadow.
    private func book(displayWidth: CGFloat) -> some View {
        let size = style.renderSize
        // Keep phone-size typography, but do not enlarge the excerpt with an iPad card slot.
        let descriptionScale = max(1, displayWidth / 196)
        let cover = CGSize(width: size.width - 12, height: size.height - 12)
        let appearance = document.appearance.resolved(for: colorScheme)
        let spineW = cover.width * 0.16
        let holeCount = min(9, max(4, Int(cover.height / 28)))
        let paper = document.isThemed ? appearance.innerPageBackground : appearance.editorBackground
        let snapshot: CGImage? = isStylePreview ? nil : previews?.cardSnapshot(for: document, colorScheme: colorScheme)
        return ZStack(alignment: .topLeading) {
            BookPageEdges(coverSize: cover, spineWidth: spineW, paint: style.bookPaint(.pages, appearance: appearance),
                border: style.bookPaint(.edgesBorder, appearance: appearance))
                .frame(width: cover.width + 7, height: cover.height + 7)
                .offset(x: 2, y: 2)
            HStack(spacing: 0) {
                ZStack {
                    bookSurface(style.spineBackdrop, style.spineStartColor, style.spineEndColor,
                        imagePath: style.spineImagePath, remote: style.spineRemotePhoto, image: spinePhoto)
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.26), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .black.opacity(0.24), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    VStack(spacing: 0) {
                        ForEach(0..<holeCount, id: \.self) { _ in
                            BookBindingHole()
                                .frame(width: spineW * 0.34, height: spineW * 0.34)
                                .frame(maxHeight: .infinity)
                        }
                    }.padding(.vertical, 10)
                }
                .frame(width: spineW)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(BookPaint("#0D0B13", end: "#A6A2AF", opacity: 0.35).fill).frame(width: 1.6)
                }
                ZStack {
                    bookSurface(style.backdrop, style.startColor, style.endColor,
                        imagePath: style.imagePath, remote: style.remotePhoto, image: photo)
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.09), location: 0),
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.14), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 6) {
                        bookPreview(snapshot: snapshot, appearance: appearance, paper: paper)
                            .frame(height: cover.height * 0.28)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(style.bookPaint(.previewBorder, appearance: appearance).fill, lineWidth: 0.85)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 3.2, style: .continuous).strokeBorder(.black.opacity(0.3), lineWidth: 0.45).padding(1)
                            }
                            .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                        Text(isStylePreview ? "Book Title" : document.title)
                            .font(textFont.font(size: 15, weight: .black)).foregroundStyle(style.bookPaint(.title, appearance: appearance).fill).lineLimit(2)
                        Text(isStylePreview ? "Nested book" : PageReferencePresentation.previewText(document, previews: previews))
                            .font(textFont.font(size: 11 / descriptionScale)).foregroundStyle(style.bookPaint(.description, appearance: appearance).fill).lineLimit(2)
                        BookCoverRules(paint: style.bookPaint(.lines, appearance: appearance))
                            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: cover.width, height: cover.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style.bookPaint(.coverBorder, appearance: appearance).fill, lineWidth: 0.9)
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 1, y: 1.5)
            .offset(x: 2, y: 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: 2, x: 0.5, y: 1.5)
    }

    private func bookPreview(snapshot: CGImage?, appearance: DocumentAppearance, paper: DocumentBackgroundStyle) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(vellixHex: paper.colorHex)
                if let snapshot {
                    // Scale to the viewport's width, never center-crop the middle of a tall page.
                    Image(decorative: snapshot, scale: 1).resizable()
                        .frame(width: proxy.size.width, height: CGFloat(snapshot.height) * proxy.size.width / CGFloat(max(1, snapshot.width)))
                } else {
                    NestedPageThumbnail(json: isStylePreview ? TipTapContentAnalyzer.emptyDocumentJSON : document.tipTapJSON,
                        title: "", appearance: appearance,
                        size: CGSize(width: proxy.size.width, height: proxy.size.width * 1.3),
                        isStylePreview: isStylePreview, cover: document.cover, attachmentStore: attachmentStore, includesCover: false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private func bookSurface(_ backdrop: PageCardBackdrop, _ start: String, _ end: String,
                             imagePath: String?, remote: CardRemotePhoto?, image: CGImage? = nil) -> some View {
        GeometryReader { proxy in
            appearanceFill(backdrop, start, end, imagePath: imagePath, remote: remote, image: image)
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
    }

    @ViewBuilder
    private func appearanceFill(_ backdrop: PageCardBackdrop, _ start: String, _ end: String,
                                imagePath: String?, remote: CardRemotePhoto?, image: CGImage? = nil) -> some View {
        switch backdrop {
        case .none:
            let appearance = document.appearance.resolved(for: colorScheme)
            Color(vellixHex: (document.isThemed ? appearance.innerPageBackground : appearance.editorBackground).colorHex)
        case .solid:
            Color(vellixHex: start)
        case .gradient:
            LinearGradient(colors: [Color(vellixHex: start), Color(vellixHex: end)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .photo:
            if let image = image ?? CardImageLoader.image(path: imagePath, store: attachmentStore) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if let url = remote?.validImageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color(vellixHex: start) }
            } else {
                Color(vellixHex: start)
            }
        }
    }

    private var text: some View {
        let compact = style.size == .compact && style.showsPages
        let full = style.size == .large && style.showsPages
        let wide = style.size == .wide && style.showsPages
        let x: CGFloat = compact ? 14 : 18
        let y: CGFloat = compact ? 47 : (full ? 28 : (wide ? 26 : 18))
        let width: CGFloat = full ? 176 : (wide ? 156 : style.size.size.width - x - 14)
        let showsExcerpt = compact || wide || full || !style.showsPages
        return VStack(alignment: .leading, spacing: compact ? 4 : (wide ? 6 : 9)) {
            Text(isStylePreview ? "Card Title" : document.title)
                .font(textFont.font(size: full ? 20 : (wide ? 18 : 15), weight: .black))
                .lineLimit(full ? 2 : 1)
            if showsExcerpt {
                Text(isStylePreview ? "Preview of the page will be displayed here. Tap to add content." :
                    PageReferencePresentation.previewText(document, previews: previews))
                    .font(textFont.font(size: compact ? 11 : 13))
                    .foregroundStyle(Color(vellixHex: textColor).opacity(0.62))
                    .lineLimit(compact ? 1 : (full ? 4 : 2))
            }
        }
        .foregroundStyle(Color(vellixHex: textColor))
        .frame(width: width, alignment: .leading)
        .offset(x: style.showsPages ? x : 18, y: style.showsPages ? y : 18)
    }

    private var textColor: String { style.backdrop == .none ? document.appearance.textColorHex : style.textColor }

    private func miniature(size: CGSize, second: Bool = false) -> some View {
        Group {
            if isStylePreview {
                NestedPageThumbnail(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "", appearance: document.appearance,
                    size: size, isCardSheet: true, isStylePreview: true, includesCover: !second)
            } else if let image = previews?.cardSnapshot(for: document, colorScheme: colorScheme) {
                NestedPageThumbnail(json: TipTapContentAnalyzer.emptyDocumentJSON, title: "", appearance: document.appearance,
                    size: size, isCardSheet: true, snapshot: image)
            } else {
                Color(vellixHex: document.appearance.resolved(for: colorScheme).innerPageBackground.colorHex)
                    .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.30), radius: 0.8, x: 0, y: 1)
        .shadow(color: .black.opacity(0.32), radius: 5, x: 1, y: 4)
    }
}

private struct BookPageEdges: View {
    let coverSize: CGSize
    let spineWidth: CGFloat
    let paint: BookPaint
    let border: BookPaint

    var body: some View {
        Canvas { context, _ in
            // Keep the top inset, but let the bottom leaves continue under the spine.
            let paperBounds = CGRect(x: spineWidth + 1, y: 10,
                width: max(0, coverSize.width + 6 - spineWidth), height: max(0, coverSize.height - 3))
            var visiblePaper = Path(roundedRect: paperBounds, cornerRadius: 6)
            visiblePaper.addPath(Path(roundedRect: CGRect(x: 0, y: max(0, coverSize.height - 10),
                width: coverSize.width + 7, height: 17), cornerRadius: 6))
            context.clip(to: visiblePaper)
            for leaf in (1...6).reversed() {
                let offset = CGFloat(leaf) * 1.05
                let rect = CGRect(x: offset, y: offset, width: coverSize.width, height: coverSize.height)
                let path = Path(roundedRect: rect, cornerRadius: 10)
                context.fill(path, with: .linearGradient(paint.palette,
                    startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.fill(path, with: .color(.black.opacity(Double(leaf % 2) * 0.07)))
                context.stroke(path, with: .linearGradient(border.palette,
                    startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 0.55)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BookBindingHole: View {
    private let interior = BookPaint("#030305", end: "#141319")
    private let rim = BookPaint("#08070B", end: "#D8CFEB", opacity: 0.75)
    var body: some View {
        Circle()
            .fill(rim.fill)
            .overlay {
                Circle().fill(interior.fill)
                    .overlay { Circle().strokeBorder(.black.opacity(0.45), lineWidth: 0.6) }
                    .padding(1.1)
            }
            .shadow(color: .white.opacity(0.16), radius: 0.35, x: 0, y: 0.6)
            .accessibilityHidden(true)
    }
}

private struct BookCoverRules: View {
    let paint: BookPaint

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 7
            let height = max(0, min(8.5, (size.height - 8 - gap * 3) / 4))
            let width = max(0, size.width - 4)
            for (index, fraction) in [CGFloat(0.4), 0.6, 0.8, 1].enumerated() {
                let rect = CGRect(x: 2, y: 4 + CGFloat(index) * (height + gap), width: width * fraction, height: height)
                let bar = Path(roundedRect: rect, cornerRadius: height / 2)
                context.fill(bar, with: .linearGradient(paint.palette, startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)))
                let highlight = CGRect(x: rect.minX + 1.5, y: rect.minY + 1, width: max(0, rect.width - 3), height: height * 0.2)
                context.fill(Path(roundedRect: highlight, cornerRadius: highlight.height / 2),
                    with: .color(.white.opacity(paint.opacity * 0.3)))
            }
        }
        .accessibilityHidden(true)
    }
}

enum CardImageLoader {
    private static let cache: NSCache<NSString, CardDecodedImage> = {
        let cache = NSCache<NSString, CardDecodedImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 256_000_000
        return cache
    }()
    static func image(data: Data) -> CGImage? {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    static func image(path: String?, store: AttachmentStore?) -> CGImage? {
        guard let path, let store else { return nil }
        let url = store.fileURL(relativePath: path)
        // Imported assets have immutable UUID filenames, so a path is a stable cache key.
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = image(data: data) else { return nil }
        cache.setObject(CardDecodedImage(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

private final class CardDecodedImage {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
