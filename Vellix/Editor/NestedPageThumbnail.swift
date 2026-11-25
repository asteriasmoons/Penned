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
    var snapshot: CGImage? = nil
    @MainActor private var displayedAppearance: DocumentAppearance { appearance.resolved(for: colorScheme) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.json == rhs.json && lhs.title == rhs.title && lhs.appearance == rhs.appearance &&
        lhs.size == rhs.size && lhs.isCardSheet == rhs.isCardSheet && lhs.isStylePreview == rhs.isStylePreview &&
        lhs.cover == rhs.cover && lhs.attachmentStore === rhs.attachmentStore && lhs.includesCover == rhs.includesCover &&
        lhs.snapshot === rhs.snapshot
    }

    @MainActor var body: some View {
        let showsCover = snapshot == nil && includesCover && !isStylePreview && displayedAppearance.displaysCover
        let layout: DocumentThumbnailLayout? = isStylePreview || snapshot != nil ? nil : DocumentThumbnailLayout(json: json,
            title: title, monospaced: displayedAppearance.fontStyle == .mono, showsCover: showsCover)
        let image = showsCover ? (CardImageLoader.image(path: cover, store: attachmentStore)
            ?? NestedPageThemeCovers.image(for: displayedAppearance.resolvedCoverTheme)) : nil
        Canvas { context, size in
            context.scaleBy(x: size.width / DocumentThumbnailLayout.size.width,
                            y: size.height / DocumentThumbnailLayout.size.height)
            let face = isCardSheet ? drawCardSheet(in: &context) : drawPage(in: &context)
            context.clip(to: face)
            if let snapshot {
                let rect = CGRect(x: 2, y: 2, width: 96, height: 123.5)
                context.drawLayer { layer in
                    layer.clip(to: Path(roundedRect: rect, cornerRadius: 3))
                    let scale = max(rect.width / CGFloat(snapshot.width), rect.height / CGFloat(snapshot.height))
                    let width = CGFloat(snapshot.width) * scale, height = CGFloat(snapshot.height) * scale
                    layer.draw(Image(decorative: snapshot, scale: 1),
                        in: CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height))
                }
                if isCardSheet { drawCardLighting(face, in: &context) }
                return
            }
            if let coverRect = layout?.coverRect, let image {
                let rect = isCardSheet ? CGRect(x: 18, y: 17, width: 64, height: 64 / 1.78) : coverRect
                drawCover(image, rect: rect, in: &context)
            }
            if isCardSheet && (isStylePreview || layout?.isEmpty == true) {
                drawCardReferenceContent(in: &context)
            } else if let layout {
                for (index, mark) in layout.marks.enumerated() {
                    if isCardSheet { drawCardMark(mark, coverRect: layout.coverRect, index: index, in: &context) }
                    else { draw(mark, index: index, in: &context) }
                }
            }
        } symbols: {
            if let layout {
                ForEach(layout.marks.indices, id: \.self) { index in
                    let mark = layout.marks[index]
                    if case .headingLabel(let text, let level, let settings) = mark.shape {
                        HeadingLabelTile(settings: settings, level: level, fallbackFont: displayedAppearance.fontStyle, text: Text(text))
                            .lineLimit(2)
                            .frame(width: mark.rect.width * (isCardSheet ? 0.8 : 1) / Self.labelScale)
                            .fixedSize()
                            .tag(index)
                    }
                    if case .calculator(let settings, let state) = mark.shape {
                        CalculatorWidgetPreview(settings: settings, state: state)
                            .frame(width: mark.rect.width * 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(index)
                    }
                    if case .moodBar(let settings) = mark.shape {
                        MoodBarPreview(settings: settings)
                            .frame(width: mark.rect.width * 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(index)
                    }
                    if case .countdown(let settings) = mark.shape {
                        CountdownWidgetPreview(settings: settings,
                            iconImage: settings.imagePath.flatMap { CardImageLoader.image(path: $0, store: attachmentStore) })
                            .frame(width: mark.rect.width * 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(index)
                    }
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
        drawCardLighting(face, in: &context)
        return face
    }

    @MainActor private func drawCardLighting(_ face: Path, in context: inout GraphicsContext) {
        let dark = displayedAppearance.nestedPageTintHex == "#FFFFFF"
        let top = CGPoint(x: 0, y: 0)
        let bottom = CGPoint(x: 100, y: 130)
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

    private static let labelScale: CGFloat = 0.26

    @MainActor private func drawCardMark(_ mark: DocumentThumbnailLayout.Mark, coverRect: CGRect?, index: Int, in context: inout GraphicsContext) {
        var scaled = mark
        let sourceShift = coverRect.map { $0.height + 8 } ?? 0
        let coverShift: CGFloat = coverRect == nil ? 0 : 64 / 1.78 + 8
        if mark.blockType == "title" {
            scaled.rect = CGRect(x: 18, y: 24 + coverShift, width: min(64, mark.rect.width * 4), height: 8.5)
        } else {
            let height: CGFloat
            switch mark.shape {
            case .line: height = mark.rect.height * 2
            case .container, .image, .washiTape, .listGridSurface, .listGridText, .headingLabel: height = mark.rect.height * 1.7
            default: height = mark.rect.height * 0.8
            }
            scaled.rect = CGRect(x: 18 + (mark.rect.minX - 10) * 0.8,
                                 y: 44 + coverShift + (mark.rect.minY - sourceShift - 20.8) * 1.7,
                                 width: mark.rect.width * 0.8, height: height)
        }
        if case .line = mark.shape, mark.colorHex == nil, !["gridCardTitle", "gridCardText"].contains(mark.blockType) {
            drawCardLine(scaled.rect, heading: mark.blockType == "title" || mark.blockType == "heading", in: &context)
        } else {
            draw(scaled, index: index, in: &context)
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

    @MainActor private func draw(_ mark: DocumentThumbnailLayout.Mark, index: Int, in context: inout GraphicsContext) {
        let ink = Color(vellixHex: displayedAppearance.textColorHex)
        let tint = mark.colorHex.map { Color(vellixHex: $0) } ?? ink
        let rect = mark.rect
        let rounded = Path(roundedRect: rect, cornerRadius: 2)
        switch mark.shape {
        case .line:
            let customDivider = mark.blockType == "divider" && mark.colorHex != nil
            let lineInk = customDivider || ["gridCardTitle", "gridCardText", "calloutText"].contains(mark.blockType) ? tint : ink
            context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                         with: .color((mark.blockType == "clipSourceTitle" ? Color(vellixHex: "#D5D5D5") : lineInk)
                            .opacity(customDivider ? 1 : ["heading", "title", "gridCardTitle"].contains(mark.blockType) ? 0.7 : 0.46)))
        case .container:
            if ["clipSource", "clipSourceLink", "gridCard", "iconCallout", "plainCallout"].contains(mark.blockType) {
                context.fill(rounded, with: .color(tint))
                return
            }
            context.fill(rounded, with: .color(tint.opacity(0.12)))
            context.stroke(rounded, with: .color(tint.opacity(0.24)), lineWidth: 0.7)
            if mark.blockType == "blockquote" {
                context.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), cornerRadius: 1),
                             with: .color(tint.opacity(0.7)))
            }
        case .bullet:
            context.fill(Path(ellipseIn: rect.insetBy(dx: rect.width > 2 ? 0.6 : 0, dy: rect.height > 2 ? 0.6 : 0)),
                         with: .color(tint.opacity(mark.blockType == "divider" && mark.colorHex != nil ? 1 : 0.6)))
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
        case .calculator, .moodBar, .countdown:
            if let symbol = context.resolveSymbol(id: index), symbol.size.width > 0, symbol.size.height > 0 {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.translateBy(x: rect.minX, y: rect.minY)
                    layer.scaleBy(x: rect.width / symbol.size.width, y: rect.height / symbol.size.height)
                    layer.draw(symbol, at: .zero, anchor: .topLeading)
                }
            }
        case .gridCardIcon(let name):
            if let path = mark.imagePath, AttachmentStore.validRelativePath(path),
               let image = CardImageLoader.image(path: path, store: attachmentStore) {
                let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                let iconRect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
                let glyph = Image(decorative: image, scale: 1)
                if let imageTint = mark.imageTintHex {
                    var resolved = context.resolve(glyph.renderingMode(.template))
                    resolved.shading = .color(Color(vellixHex: imageTint))
                    context.draw(resolved, in: iconRect)
                } else {
                    context.draw(glyph, in: iconRect)
                }
                return
            }
            let icon = VellixAssetIcon(name: name)
            let image = icon.systemName.map { Image(systemName: $0) } ?? Image(name)
            var resolved = context.resolve(image.renderingMode(.template))
            resolved.shading = .color(tint)
            if resolved.size.width > 0, resolved.size.height > 0 {
                let scale = min(rect.width / resolved.size.width, rect.height / resolved.size.height)
                let width = resolved.size.width * scale, height = resolved.size.height * scale
                context.draw(resolved, in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
            }
        case .headingLabel:
            if let tile = context.resolveSymbol(id: index) {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.translateBy(x: rect.minX, y: rect.minY)
                    layer.scaleBy(x: Self.labelScale, y: Self.labelScale)
                    layer.draw(tile, at: .zero, anchor: .topLeading)
                }
            }
        case .listGridSurface(let border, let radius, let borderWidth):
            let shape = Path(roundedRect: rect, cornerRadius: radius)
            context.fill(shape, with: .color(tint))
            if let border {
                let inset = min(borderWidth, rect.width, rect.height) / 2
                let stroke = Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(0, radius - inset))
                context.stroke(stroke, with: .color(Color(vellixHex: border)), lineWidth: inset * 2)
            }
        case .listGridText(let value, let alignment, let fontSize, let isGuidance):
            let font = displayedAppearance.fontStyle.font(size: fontSize * (isCardSheet ? 0.8 : 1))
            let text = Text(value).font(font).foregroundStyle(tint.opacity(isGuidance ? 0.38 : 1))
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: rect.size)
            let x = alignment == "center" ? rect.midX - measured.width / 2
                : alignment == "right" ? rect.maxX - measured.width : rect.minX
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.draw(resolved, in: CGRect(x: x, y: rect.midY - measured.height / 2,
                                              width: measured.width, height: measured.height))
            }
        case .washiTape:
            let tape = WashiTapeShape().path(in: rect)
            context.fill(tape, with: .color(tint.opacity(mark.colorHex != nil ? 1 : 0.16)))
            if let path = mark.imagePath, AttachmentStore.validRelativePath(path),
               let image = CardImageLoader.image(path: path, store: attachmentStore) {
                context.drawLayer { layer in
                    layer.clip(to: tape)
                    drawCover(image, rect: rect, in: &layer)
                }
                if mark.colorHex != nil { context.fill(tape, with: .color(tint.opacity(0.38))) }
            }
        case .image:
            if let path = mark.imagePath, let image = CardImageLoader.image(path: path, store: attachmentStore) {
                drawCover(image, rect: rect, in: &context)
                return
            }
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
