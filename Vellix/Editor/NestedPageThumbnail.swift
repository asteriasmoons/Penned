import SwiftUI

nonisolated struct NestedPageThumbnail: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    var json: String
    var title: String
    var appearance: DocumentAppearance
    var size = CGSize(width: 37, height: 48)
    var isCardSheet = false
    var isStylePreview = false
    var cover: String? = nil
    var attachmentStore: AttachmentStore? = nil
    var includesCover = true
    @MainActor private var displayedAppearance: DocumentAppearance { appearance.resolved(for: colorScheme) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.json == rhs.json && lhs.title == rhs.title && lhs.appearance == rhs.appearance &&
        lhs.size == rhs.size && lhs.isCardSheet == rhs.isCardSheet && lhs.isStylePreview == rhs.isStylePreview &&
        lhs.cover == rhs.cover && lhs.attachmentStore === rhs.attachmentStore && lhs.includesCover == rhs.includesCover
    }

    @MainActor var body: some View {
        let showsCover = includesCover && !isStylePreview && displayedAppearance.displaysCover
        let layout: DocumentThumbnailLayout? = isStylePreview ? nil : DocumentThumbnailLayout(json: json,
            title: title, monospaced: displayedAppearance.fontStyle == .mono, showsCover: showsCover)
        let image = showsCover ? (CardImageLoader.image(path: cover, store: attachmentStore)
            ?? NestedPageThemeCovers.image(for: displayedAppearance.resolvedCoverTheme)) : nil
        Canvas { context, size in
            context.scaleBy(x: size.width / DocumentThumbnailLayout.size.width,
                            y: size.height / DocumentThumbnailLayout.size.height)
            let face = isCardSheet ? drawCardSheet(in: &context) : drawPage(in: &context)
            context.clip(to: face)
            if let coverRect = layout?.coverRect, let image {
                let rect = isCardSheet ? CGRect(x: 18, y: 17, width: 64, height: 64 / 1.78) : coverRect
                drawCover(image, rect: rect, in: &context)
            }
            if isCardSheet && (isStylePreview || layout?.isEmpty == true) {
                drawCardReferenceContent(in: &context)
            } else if let layout {
                for mark in layout.marks {
                    if isCardSheet { drawCardMark(mark, coverRect: layout.coverRect, in: &context) }
                    else { draw(mark, in: &context) }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    @MainActor private func drawCover(_ image: CGImage, rect: CGRect, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect, cornerRadius: 2))
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            layer.draw(Image(decorative: image, scale: 1), in: CGRect(x: rect.midX - width / 2,
                y: rect.midY - height / 2, width: width, height: height))
        }
    }

    @MainActor private func drawCardReferenceContent(in context: inout GraphicsContext) {
        // Style-sheet artwork and empty-card fallback, never saved document content.
        drawCardLine(CGRect(x: 16, y: 20, width: 51, height: 7), heading: true, in: &context)
        let rows: [(CGFloat, CGFloat)] = [(36, 67), (46, 67), (60, 40), (70, 67), (79, 67), (88, 67), (97, 67)]
        for (y, width) in rows {
            drawCardLine(CGRect(x: 16, y: y, width: width, height: 5), heading: false, in: &context)
        }
    }

    @MainActor private func drawCardLine(_ rect: CGRect, heading: Bool, in context: inout GraphicsContext) {
        let ink = Color(vellixHex: displayedAppearance.textColorHex)
        let dark = displayedAppearance.nestedPageTintHex == "#FFFFFF"
        let opacity: Double = dark ? (heading ? 0.12 : 0.08) : (heading ? 0.30 : 0.20)
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .linearGradient(
            Gradient(colors: [ink.opacity(opacity), ink.opacity(opacity * 0.8)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    @MainActor private func drawCardSheet(in context: inout GraphicsContext) -> Path {
        let dark = displayedAppearance.nestedPageTintHex == "#FFFFFF"
        let top = CGPoint(x: 0, y: 0)
        let bottom = CGPoint(x: 100, y: 130)
        let base = Gradient(colors: [
            Color(vellixHex: displayedAppearance.innerPageBackground.colorHex),
            Color(vellixHex: displayedAppearance.innerPageBackground.secondaryColorHex)
        ])
        // Thin leaves beneath the face create paper thickness without a padded bevel.
        for offset in [CGFloat(2.4), CGFloat(1.2)] {
            let leaf = cardPaperPath(CGRect(x: 1, y: 1 + offset, width: 98, height: 125.5))
            context.fill(leaf, with: .linearGradient(base, startPoint: top, endPoint: bottom))
            context.fill(leaf, with: .color(.black.opacity(dark ? 0.24 : 0.10)))
            context.stroke(leaf, with: .color(.white.opacity(dark ? 0.10 : 0.35)), lineWidth: 0.45)
        }
        let face = cardPaperPath(CGRect(x: 1, y: 1, width: 98, height: 125.5))
        context.fill(face, with: .linearGradient(base, startPoint: top, endPoint: bottom))
        context.fill(face, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(dark ? 0.055 : 0.16), location: 0),
            .init(color: .clear, location: 0.45),
            .init(color: .black.opacity(0.055), location: 1)
        ]), startPoint: top, endPoint: bottom))
        context.stroke(face, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(dark ? 0.18 : 0.65), location: 0),
            .init(color: .white.opacity(dark ? 0.025 : 0.15), location: 0.4),
            .init(color: .black.opacity(dark ? 0.32 : 0.18), location: 1)
        ]), startPoint: top, endPoint: bottom), lineWidth: 0.65)
        return face
    }

    @MainActor private func cardPaperPath(_ rect: CGRect) -> Path {
        let radius: CGFloat = 5
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.minY + 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.maxY - 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    @MainActor private func drawCardMark(_ mark: DocumentThumbnailLayout.Mark, coverRect: CGRect?, in context: inout GraphicsContext) {
        var scaled = mark
        let sourceShift = coverRect.map { $0.height + 8 } ?? 0
        let coverShift: CGFloat = coverRect == nil ? 0 : 64 / 1.78 + 8
        if mark.blockType == "title" {
            scaled.rect = CGRect(x: 18, y: 24 + coverShift, width: min(64, mark.rect.width * 4), height: 8.5)
        } else {
            let height: CGFloat
            switch mark.shape {
            case .line: height = mark.rect.height * 2
            case .container, .image: height = mark.rect.height * 1.7
            default: height = mark.rect.height * 0.8
            }
            scaled.rect = CGRect(x: 18 + (mark.rect.minX - 10) * 0.8,
                                 y: 44 + coverShift + (mark.rect.minY - sourceShift - 20.8) * 1.7,
                                 width: mark.rect.width * 0.8, height: height)
        }
        if case .line = mark.shape {
            drawCardLine(scaled.rect, heading: mark.blockType == "title" || mark.blockType == "heading", in: &context)
        } else {
            draw(scaled, in: &context)
        }
    }

    @MainActor private func drawPage(in context: inout GraphicsContext) -> Path {
        let dark = displayedAppearance.nestedPageTintHex == "#FFFFFF"
        let base = Gradient(colors: [Color(vellixHex: displayedAppearance.innerPageBackground.colorHex),
                                     Color(vellixHex: displayedAppearance.innerPageBackground.secondaryColorHex)])
        let top = CGPoint(x: 0, y: 0)
        let bottom = CGPoint(x: 100, y: 130)
        let body = Path(roundedRect: CGRect(x: 1, y: 1, width: 98, height: 128), cornerRadius: 11)
        let face = Path(roundedRect: CGRect(x: 1, y: 1, width: 98, height: 122), cornerRadius: 11)

        // The lower edge is part of the miniature, not another surface behind the row.
        context.fill(body, with: .linearGradient(base, startPoint: top, endPoint: bottom))
        context.fill(body, with: .color(.black.opacity(dark ? 0.34 : 0.18)))
        context.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(dark ? 0.22 : 0.45), .black.opacity(0.40)]),
            startPoint: top, endPoint: bottom), lineWidth: 1.5)

        context.fill(face, with: .linearGradient(base, startPoint: top, endPoint: bottom))
        context.fill(face, with: .linearGradient(
            Gradient(colors: dark ? [.white.opacity(0.18), .white.opacity(0.07)]
                                  : [.white.opacity(0.24), .black.opacity(0.04)]),
            startPoint: top, endPoint: bottom))
        context.stroke(face, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(dark ? 0.40 : 0.75), location: 0),
                             .init(color: .white.opacity(dark ? 0.10 : 0.20), location: 0.45),
                             .init(color: .black.opacity(dark ? 0.50 : 0.25), location: 1)]),
            startPoint: top, endPoint: bottom), lineWidth: 2)

        let inset = Path(roundedRect: CGRect(x: 3, y: 3, width: 94, height: 118), cornerRadius: 9)
        context.stroke(inset, with: .linearGradient(
            Gradient(colors: [.white.opacity(dark ? 0.12 : 0.35), .clear, .black.opacity(0.12)]),
            startPoint: top, endPoint: bottom), lineWidth: 1)
        return face
    }

    @MainActor private func draw(_ mark: DocumentThumbnailLayout.Mark, in context: inout GraphicsContext) {
        let ink = Color(vellixHex: displayedAppearance.textColorHex)
        let tint = mark.colorHex.map { Color(vellixHex: $0) } ?? ink
        let rect = mark.rect
        let rounded = Path(roundedRect: rect, cornerRadius: 2)
        switch mark.shape {
        case .line:
            context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                         with: .color(ink.opacity(mark.blockType == "heading" || mark.blockType == "title" ? 0.7 : 0.46)))
        case .container:
            context.fill(rounded, with: .color(tint.opacity(0.12)))
            context.stroke(rounded, with: .color(tint.opacity(0.24)), lineWidth: 0.7)
            if mark.blockType == "blockquote" {
                context.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), cornerRadius: 1),
                             with: .color(tint.opacity(0.7)))
            }
        case .bullet:
            context.fill(Path(ellipseIn: rect.insetBy(dx: rect.width > 2 ? 0.6 : 0, dy: rect.height > 2 ? 0.6 : 0)),
                         with: .color(ink.opacity(0.6)))
        case .number(let number):
            context.draw(Text("\(number).").font(.system(size: 4.8, weight: .medium)).foregroundStyle(ink.opacity(0.65)),
                         at: CGPoint(x: rect.minX, y: rect.minY - 0.5), anchor: .topLeading)
        case .checkbox(let checked, let crossed):
            context.stroke(Path(ellipseIn: rect), with: .color(ink.opacity(0.6)), lineWidth: 0.8)
            if checked || crossed {
                var path = Path()
                path.move(to: CGPoint(x: rect.minX + 0.8, y: crossed ? rect.maxY - 0.8 : rect.midY))
                if !crossed {
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 0.9))
                }
                path.addLine(to: CGPoint(x: rect.maxX - 0.7, y: rect.minY + 0.8))
                if crossed {
                    path.move(to: CGPoint(x: rect.minX + 0.8, y: rect.minY + 0.8))
                    path.addLine(to: CGPoint(x: rect.maxX - 0.8, y: rect.maxY - 0.8))
                }
                context.stroke(path, with: .color(ink.opacity(0.8)), lineWidth: 0.8)
            }
        case .toggle(let open):
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: open ? rect.midX : rect.maxX, y: open ? rect.maxY : rect.midY))
            path.addLine(to: CGPoint(x: open ? rect.maxX : rect.minX, y: open ? rect.minY : rect.maxY))
            context.stroke(path, with: .color(ink.opacity(0.65)), lineWidth: 1)
        case .chip:
            context.fill(rounded, with: .color(tint.opacity(0.5)))
        case .image:
            context.fill(rounded, with: .color(ink.opacity(0.09)))
            context.stroke(rounded, with: .color(ink.opacity(0.3)), lineWidth: 0.8)
            var mountains = Path()
            mountains.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 3))
            mountains.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.midY))
            mountains.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 5))
            mountains.addLine(to: CGPoint(x: rect.minX + rect.width * 0.7, y: rect.minY + 5))
            mountains.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 3))
            context.stroke(mountains, with: .color(ink.opacity(0.4)), lineWidth: 1.3)
            context.fill(Path(ellipseIn: CGRect(x: rect.minX + 5, y: rect.minY + 4, width: 3, height: 3)),
                         with: .color(ink.opacity(0.5)))
        }
    }
}

@MainActor
enum NestedPageThemeCovers {
    private static var images: [DocumentThemeID: CGImage] = [:]

    static func image(for theme: DocumentThemeID) -> CGImage? {
        if let image = images[theme] { return image }
        let renderer = ImageRenderer(content: ThemeCoverArt(theme: theme).frame(width: 320, height: 320 / 1.78))
        renderer.scale = 2
        let image = renderer.cgImage
        images[theme] = image
        return image
    }
}
