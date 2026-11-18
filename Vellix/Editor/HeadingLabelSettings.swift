import ImageIO
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#endif

nonisolated struct HeadingLabelSettings: Equatable, Sendable {
    enum Shape: String, CaseIterable, Sendable {
        case ribbon, pill, framed, rectangular, scalloped, plaque, banner

        fileprivate init?(legacyStyle: String) {
            switch legacyStyle {
            case "plaque": self = .plaque
            case "banner": self = .banner
            default: return nil
            }
        }
        var minimumWidthInEm: CGFloat {
            switch self {
            case .plaque: 6.8
            case .banner: 10
            default: 0
            }
        }
    }
    enum Surface: String, CaseIterable, Sendable { case filled, glass, textured, outline }
    enum Alignment: String, CaseIterable, Sendable { case left, center, right }

    var enabled: Bool
    var shape: Shape
    var surface: Surface
    var alignment: Alignment
    var font: String
    var textColor: String
    var backgroundColor: String
    var borderColor: String
    var borderThickness: Int
    var accentColor: String
    var iconEnabled: Bool
    var icon: String
    var iconColor: String

    init(_ attrs: [String: Any] = [:]) {
        func color(_ key: String, _ fallback: String) -> String {
            guard let value = attrs[key] as? String, value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return fallback }
            return value
        }
        enabled = attrs["presentation"] as? String == "label"
        let style = attrs["style"] as? String ?? ""
        shape = Shape(legacyStyle: style) ?? Shape(rawValue: attrs["shape"] as? String ?? "") ?? .rectangular
        surface = Surface(rawValue: style) ?? .filled
        alignment = Alignment(rawValue: attrs["alignment"] as? String ?? "") ?? .left
        let family = attrs["font"] as? String ?? "inherit"
        font = ["inherit", "system", "serif", "mono", "rounded", "hachiMaruPop"].contains(family) ? family : "inherit"
        textColor = color("textColor", "#281B36")
        backgroundColor = color("backgroundColor", "#D9C3F1")
        borderColor = color("borderColor", "#9E7EBC")
        let thickness = attrs["borderThickness"] as? Int ?? 1
        borderThickness = (0...6).contains(thickness) ? thickness : 1
        accentColor = color("accentColor", "#8966A8")
        iconColor = color("iconColor", "#60437D")
        iconEnabled = attrs["iconEnabled"] as? Bool == true
        let name = attrs["icon"] as? String ?? ""
        icon = name.range(of: "^(sf:)?[A-Za-z0-9_.+-]{1,120}$", options: .regularExpression) != nil ? name : "sparkle"
    }

    static func configuration(_ attrs: [String: Any]) -> Self? {
        guard (1...4).contains(attrs["level"] as? Int ?? 1), let label = attrs["label"] as? [String: Any] else { return nil }
        return Self(label)
    }

    var payload: [String: Any] {
        ["presentation": enabled ? "label" : "text", "shape": shape.rawValue, "style": surface.rawValue,
         "alignment": alignment.rawValue, "font": font, "textColor": textColor, "backgroundColor": backgroundColor,
         "borderColor": borderColor, "borderThickness": borderThickness, "accentColor": accentColor,
         "iconEnabled": iconEnabled, "icon": icon, "iconColor": iconColor]
    }
}

nonisolated struct HeadingLabelRequest: Identifiable, Equatable, Sendable {
    let id: String
    let level: Int
    let originalText: String
    let original: HeadingLabelSettings

    init?(payload: [String: Any]) {
        guard let id = payload["blockID"] as? String, !id.isEmpty,
              let level = payload["level"] as? Int, (1...4).contains(level),
              let text = payload["text"] as? String, let settings = payload["settings"] as? [String: Any] else { return nil }
        self.id = id
        self.level = level
        originalText = text
        original = HeadingLabelSettings(settings)
    }

    @MainActor
    func commit(_ settings: HeadingLabelSettings, text: String, in view: WKWebView) async throws -> Any? {
        var args: [String: Any] = ["blockID": id, "level": level, "originalText": originalText, "text": text,
                                    "original": original.payload, "settings": settings.payload]
        if settings.iconEnabled, let icon = TipTapEditorIconRenderer.dataURL(for: settings.icon) {
            args["assets"] = [settings.icon: icon]
        }
        return try await view.callAsyncJavaScript("return await window.tiptapCommand('headingLabelUpdate', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
    }
}

struct HeadingLabelSettingsSheet: View {
    private enum Dropdown: Hashable { case shape, surface, font }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HeadingLabelSettings
    @State private var text: String
    @State private var pickingIcon = false
    @State private var saving = false
    @State private var error: String?
    @State private var openDropdown: Dropdown?
    @FocusState private var headingTextFocused: Bool
    let request: HeadingLabelRequest
    let fallbackFont: DocumentFontStyle
    let onSave: (HeadingLabelSettings, String) async throws -> Void

    init(request: HeadingLabelRequest, fallbackFont: DocumentFontStyle, onSave: @escaping (HeadingLabelSettings, String) async throws -> Void) {
        self.request = request
        self.fallbackFont = fallbackFont
        self.onSave = onSave
        _draft = State(initialValue: request.original)
        _text = State(initialValue: request.originalText)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HeadingLabelTile(settings: draft, level: request.level, fallbackFont: fallbackFont, text: Text(text))
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { headingTextFocused = false; openDropdown = nil }
                    Picker("Presentation", selection: $draft.enabled) {
                        Text("Text").tag(false)
                        Text("Label").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Heading Text", text: $text, axis: .vertical)
                        .focused($headingTextFocused)
                        .submitLabel(.done)
                        .onSubmit { headingTextFocused = false }
                        .padding(12)
                        .pennedSheetField()
                    if draft.enabled {
                        dropdown(.shape, title: "Shape", selection: $draft.shape,
                                 choices: HeadingLabelSettings.Shape.allCases.map { ($0, $0.rawValue.capitalized) })
                        dropdown(.surface, title: "Style", selection: $draft.surface,
                                 choices: HeadingLabelSettings.Surface.allCases.map { ($0, $0.rawValue.capitalized) })
                        dropdown(.font, title: "Font", selection: $draft.font,
                                 choices: [("inherit", "Document Font")] + DocumentFontStyle.allCases.map { ($0.rawValue, $0.title) })
                        Picker("Alignment", selection: $draft.alignment) {
                            ForEach(HeadingLabelSettings.Alignment.allCases, id: \.self) {
                                Image(systemName: "text.align" + $0.rawValue).accessibilityLabel($0.rawValue.capitalized).tag($0)
                            }
                        }.pickerStyle(.segmented)
                        picker("Text", \.textColor)
                        picker("Background", \.backgroundColor)
                        picker("Border", \.borderColor)
                        Stepper("Border Thickness: \(draft.borderThickness)", value: $draft.borderThickness, in: 0...6)
                            .padding(10).pennedSheetField()
                        picker("Accent", \.accentColor)
                        Toggle("Show Icon", isOn: $draft.iconEnabled)
                        if draft.iconEnabled {
                            Button { pickingIcon = true } label: {
                                Label { Text("Choose Icon") } icon: {
                                    LibraryIcon(name: draft.icon, size: 20).foregroundStyle(Color(vellixHex: draft.iconColor))
                                }
                            }
                            picker("Icon Color", \.iconColor)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: headingTextFocused) { _, focused in if focused { openDropdown = nil } }
            .onChange(of: draft.enabled) { _, _ in openDropdown = nil }
            .disabled(saving)
            .pennedSheet(title: DocumentTextStyleNames.heading(request.level) + " Label", closeDisabled: saving, close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton { headingTextFocused = false }.disabled(saving)
                #endif
                Button("Done", action: save).disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
        .sheet(isPresented: $pickingIcon) {
            VellixIconLibraryPicker(title: "Label Icon", selectedIcon: draft.icon) { icon in
                draft.icon = icon.name
                pickingIcon = false
            }
            #if os(macOS)
            .frame(width: 540, height: 600)
            #endif
        }
        .alert("Could Not Save Label", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func dropdown<Value: Hashable>(_ key: Dropdown, title: String, selection: Binding<Value>,
                                           choices: [(Value, String)]) -> some View {
        HeadingLabelDropdown(title: title, selection: selection, choices: choices,
            expanded: openDropdown == key, toggle: {
                headingTextFocused = false
                openDropdown = openDropdown == key ? nil : key
            }, close: { openDropdown = nil })
    }

    private func picker(_ title: String, _ key: WritableKeyPath<HeadingLabelSettings, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(vellixHex: draft[keyPath: key]) },
            set: { draft[keyPath: key] = $0.vellixHexString(fallback: draft[keyPath: key]) }), supportsOpacity: false)
            .padding(10).pennedSheetField()
    }

    private func save() {
        headingTextFocused = false
        saving = true
        Task {
            defer { saving = false }
            do { try await onSave(draft, text); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct HeadingLabelDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    let expanded: Bool
    let toggle: () -> Void
    let close: () -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44

    var body: some View {
        let current = choices.first { $0.0 == selection }?.1 ?? ""
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(title).foregroundStyle(VellixSurface.secondaryInk)
                    Spacer(minLength: 4)
                    Text(current).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.75)
                    LibraryIcon(name: expanded ? "chevup" : "chevdown", size: 14)
                }
                .padding(.horizontal, 12).frame(height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue([current, expanded ? "Expanded" : "Collapsed"].joined(separator: ", "))
            if expanded {
                Rectangle().fill(VellixSurface.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(choices.indices, id: \.self) { index in
                                let (value, label) = choices[index]
                                Button {
                                    selection = value
                                    close()
                                } label: {
                                    HStack {
                                        Text(label).lineLimit(1).minimumScaleFactor(0.75)
                                        Spacer(minLength: 4)
                                        if value == selection { LibraryIcon(name: "checkwavy", size: 15) }
                                    }
                                    .padding(.horizontal, 12).frame(height: rowHeight)
                                    .background(value == selection ? VellixSurface.selection : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(value == selection ? .isSelected : [])
                                .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: rowHeight * CGFloat(min(choices.count, 3)))
                    .clipped()
                    .onAppear {
                        if let index = choices.firstIndex(where: { $0.0 == selection }), index >= 3 {
                            proxy.scrollTo(index, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .font(.system(.body, design: .rounded))
        .foregroundStyle(VellixSurface.controlInk)
        .background(PennedFrostedMaterial(tint: VellixSurface.input, cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(VellixSurface.hairline)
                .allowsHitTesting(false)
        }
    }
}

#if os(iOS)
struct PennedSheetKeyboardDismissButton: View {
    let clearFocus: () -> Void

    var body: some View {
        Button {
            clearFocus()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            LibraryIcon(name: "keyboardclose", size: 20)
        }
        .accessibilityLabel("Dismiss Keyboard")
    }
}
#endif

struct HeadingLabelTile: View {
    let settings: HeadingLabelSettings
    let level: Int
    let fallbackFont: DocumentFontStyle
    let text: Text

    private var alignment: Alignment {
        switch settings.alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
    private var shape: LabelSilhouette { LabelSilhouette(kind: settings.shape, fontSize: size) }
    private static func fontSize(for level: Int) -> CGFloat { [24, 21, 18, 16][min(4, max(1, level)) - 1] }
    private var size: CGFloat { Self.fontSize(for: level) }
    private var borderWidth: CGFloat { CGFloat(settings.borderThickness) }
    private var followsPerimeter: Bool {
        switch settings.shape {
        case .framed, .scalloped, .plaque, .banner: true
        case .ribbon, .pill, .rectangular: false
        }
    }
    private var hasRibbonTails: Bool { settings.shape == .ribbon }
    private var horizontalInset: CGFloat {
        switch settings.shape {
        case .plaque: size * 1.55
        case .banner: size * 1.35
        case .rectangular, .scalloped: size * 1.08
        case .pill, .framed: size * 1.05
        case .ribbon: size * 0.78
        }
    }
    private var verticalInset: CGFloat {
        switch settings.shape {
        case .scalloped: size * 0.58
        case .plaque, .banner: size * 0.48
        default: size * 0.38
        }
    }
    private var textAlignment: TextAlignment {
        if settings.shape == .plaque || settings.shape == .banner || settings.shape == .scalloped { return .center }
        switch settings.alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
    private var font: Font { (DocumentFontStyle(rawValue: settings.font) ?? fallbackFont).font(size: size, weight: .heavy) }

    init(settings: HeadingLabelSettings, level: Int, fallbackFont: DocumentFontStyle, text: Text) {
        self.settings = settings
        self.level = level
        self.fallbackFont = fallbackFont
        self.text = text
    }

    init(settings: HeadingLabelSettings, attrs: [String: Any], nodes: [[String: Any]], appearance: DocumentAppearance) {
        let level = attrs["level"] as? Int ?? 1
        var styled = appearance
        styled.fontStyle = DocumentFontStyle(rawValue: settings.font)
            ?? (attrs["blockFont"] as? String).flatMap(DocumentFontStyle.init(rawValue:)) ?? appearance.fontStyle
        self.init(settings: settings, level: level, fallbackFont: styled.fontStyle,
            text: InlineTextPreview.text(nodes, appearance: styled, size: Self.fontSize(for: level), weight: .heavy))
    }

    var body: some View {
        if settings.enabled {
            HeadingLabelWidthFloor(minimumWidth: size * settings.shape.minimumWidthInEm) {
                HStack(spacing: size * 0.45) {
                    if settings.iconEnabled {
                        LibraryIcon(name: settings.icon, size: size)
                            .foregroundStyle(Color(vellixHex: settings.iconColor)).accessibilityHidden(true)
                    }
                    text.fixedSize(horizontal: false, vertical: true)
                }
                .font(font)
                .foregroundStyle(Color(vellixHex: settings.textColor))
                .multilineTextAlignment(textAlignment)
                .frame(minWidth: settings.shape == .rectangular ? size * 4.2 : 0)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
            }
            .background { surface }
            .overlay {
                if borderWidth > 0 {
                    let color = Color(vellixHex: settings.borderColor)
                    if followsPerimeter {
                        shape.stroke(color, style: StrokeStyle(lineWidth: borderWidth, lineJoin: .round))
                            .allowsHitTesting(false)
                    } else {
                        shape.strokeBorder(color, lineWidth: borderWidth).allowsHitTesting(false)
                    }
                }
            }
            .padding(followsPerimeter ? borderWidth / 2 : 0)
            .padding(.horizontal, hasRibbonTails ? 15 : 0)
            .padding(.bottom, hasRibbonTails ? 4 : 0)
            .background {
                if hasRibbonTails {
                    Canvas { context, size in
                        let top = size.height * 0.24
                        var path = Path()
                        for mirrored in [false, true] {
                            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                                CGPoint(x: mirrored ? size.width - x : x, y: y)
                            }
                            path.move(to: point(0, top))
                            path.addLine(to: point(17, top))
                            path.addLine(to: point(17, size.height))
                            path.addLine(to: point(0, size.height))
                            path.addLine(to: point(5, (top + size.height) / 2))
                            path.closeSubpath()
                        }
                        context.fill(path, with: .color(Color(vellixHex: settings.accentColor)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            text.font(fallbackFont.font(size: size, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var surface: some View {
        let fill = Color(vellixHex: settings.backgroundColor)
        return ZStack {
            if settings.surface == .textured {
                LabelGrainSurface(palette: LabelGrainPalette(fillHex: settings.backgroundColor))
                    .clipShape(shape)
                    .allowsHitTesting(false)
            } else {
                shape.fill(fill.opacity(settings.surface == .outline ? 0.08 : 1))
            }
            if settings.surface == .glass {
                BubblyIconMaterial(tint: fill)
                    .mask { shape.fill(.white) }
                    .allowsHitTesting(false)
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.78), location: 0),
                    .init(color: .white.opacity(0.46), location: 0.08),
                    .init(color: .white.opacity(0.18), location: 0.22),
                    .init(color: .clear, location: 0.46),
                    .init(color: .clear, location: 0.65),
                    .init(color: Color(vellixHex: "#0D0C12").opacity(0.12), location: 0.86),
                    .init(color: Color(vellixHex: "#0D0C12").opacity(0.34), location: 1)
                ], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
            }
        }
    }
}

private struct HeadingLabelWidthFloor: Layout {
    let minimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        let floor = min(minimumWidth, proposal.width ?? minimumWidth)
        return CGSize(width: max(size.width, floor), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                             proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// Lunixia's BubblyIconMaterial, with its original palette colors resolved locally.
private struct BubblyIconMaterial: View {
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let materialTint = tint.opacity(0.75)
            let textPrimary = Color(vellixHex: "#F7F5FA")
            let background = Color(vellixHex: "#0D0C12")

            ZStack {
                materialTint

                if #available(iOS 26.0, macOS 26.0, *) {
                    Rectangle()
                        .fill(materialTint)
                        .glassEffect(.regular.tint(materialTint), in: Rectangle())
                }

                RadialGradient(
                    colors: [
                        textPrimary.opacity(0.408),
                        textPrimary.opacity(0.136),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.22, y: 0.18),
                    startRadius: 0,
                    endRadius: min(w, h) * 0.78
                )
                .blendMode(.screen)

                LinearGradient(
                    colors: [
                        textPrimary.opacity(0.289),
                        textPrimary.opacity(0.085),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)

                LinearGradient(
                    colors: [
                        Color.clear,
                        materialTint,
                        background.opacity(0.18)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
                .blendMode(.multiply)
            }
            .frame(width: w, height: h)
            .compositingGroup()
        }
    }
}

private struct LabelGrainPalette {
    let base: Color
    let flecks: Color

    // Match grainPalette in heading-label.js: derive both shades at the same hue and saturation.
    init(fillHex: String) {
        let rgb = UInt32(fillHex.dropFirst(), radix: 16) ?? 0
        let channels = [16, 8, 0].map { Double((rgb >> $0) & 255) / 255 }
        let lightness = ((channels.min() ?? 0) + (channels.max() ?? 0)) / 2
        let range = min(lightness, 1 - lightness)
        func shade(_ next: Double) -> Color {
            let scale = range > 0 ? min(next, 1 - next) / range : 0
            let shaded = channels.map { ((next + ($0 - lightness) * scale) * 255).rounded() / 255 }
            return Color(.sRGB, red: shaded[0], green: shaded[1], blue: shaded[2])
        }
        base = shade(lightness - min(0.026, lightness * 0.075))
        flecks = shade(lightness + min(0.065, (1 - lightness) * 0.13))
    }
}

private struct LabelGrainSurface: View {
    let palette: LabelGrainPalette
    private static let maskImage: CGImage? = {
        guard let url = Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle")?.appendingPathComponent("label-grain-light.png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    var body: some View {
        ZStack {
            palette.base
            if let image = Self.maskImage {
                // Use only the 384 px tile's alpha, just like the 192 CSS px web repeat.
                palette.flecks.mask {
                    Image(decorative: image, scale: 2)
                        .interpolation(.none)
                        .resizable(resizingMode: .tile)
                }
            }
        }
    }
}

private struct LabelSilhouette: InsettableShape {
    let kind: HeadingLabelSettings.Shape
    let fontSize: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        Self(kind: kind, fontSize: fontSize, insetAmount: insetAmount + amount)
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch kind {
        case .plaque, .banner:
            return decorativePath(in: bounds)
        case .pill:
            return Capsule().path(in: bounds)
        case .rectangular:
            return RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: bounds)
        case .ribbon:
            return RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: bounds)
        case .scalloped:
            return scallopedPath(in: bounds)
        case .framed:
            // Match the stepped perimeter in heading-label.js.
            let points: [(CGFloat, CGFloat)] = [(7, 0), (93, 0), (95, 12), (98, 12), (100, 26), (100, 74),
                (98, 88), (95, 88), (93, 100), (7, 100), (5, 88), (2, 88), (0, 74), (0, 26), (2, 12), (5, 12)]
            var path = Path()
            path.addLines(points.map { point in
                CGPoint(x: bounds.minX + bounds.width * point.0 / 100, y: bounds.minY + bounds.height * point.1 / 100)
            })
            path.closeSubpath()
            return path
        }
    }

    // Match decorativeLabelPath in scalloped-label.js. End caps scale with
    // type and height, while the flat middle takes up any additional width.
    private func decorativePath(in box: CGRect) -> Path {
        let w = box.width, h = box.height
        guard w > 0, h > 0 else { return Path() }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x, y: box.minY + y) }
        var path = Path()
        if kind == .banner {
            let notch = min(fontSize * 0.66, w * 0.20, h * 0.34)
            path.addLines([point(0, 0), point(w, 0), point(w - notch, h / 2), point(w, h), point(0, h), point(notch, h / 2)])
        } else {
            let cap = min(fontSize * 0.42, w * 0.19, h * 0.16)
            let shoulder = cap * 1.58
            let step = h * 0.12, join = h * 0.26
            let halfChord = h / 2 - join
            // Radius from the chord and its outward rise (sagitta).
            let radius = (halfChord * halfChord + cap * cap) / (2 * cap)
            let angle = Double(atan2(halfChord, radius - cap))
            path.addLines([point(shoulder, 0), point(w - shoulder, 0), point(w - shoulder, step),
                           point(w - cap, step), point(w - cap, join)])
            path.addRelativeArc(center: point(w - radius, h / 2), radius: radius,
                                startAngle: .radians(-angle), delta: .radians(2 * angle))
            // addLines starts a new subpath; append the shoulders to the same outline.
            for p in [point(w - cap, h - step), point(w - shoulder, h - step), point(w - shoulder, h),
                      point(shoulder, h), point(shoulder, h - step), point(cap, h - step), point(cap, h - join)] {
                path.addLine(to: p)
            }
            path.addRelativeArc(center: point(radius, h / 2), radius: radius,
                                startAngle: .radians(.pi - angle), delta: .radians(2 * angle))
            path.addLine(to: point(cap, step))
            path.addLine(to: point(shoulder, step))
        }
        path.closeSubpath()
        return path
    }

    private func scallopedPath(in bounds: CGRect) -> Path {
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        // Same circle intersections and clockwise arcs as scalloped-label.js.
        let radius = min(fontSize * 0.34, min(bounds.width, bounds.height) / 5)
        let left = bounds.minX + radius, right = bounds.maxX - radius
        let top = bounds.minY + radius, bottom = bounds.maxY - radius
        let corners = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                       CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
        let centers = corners.indices.flatMap { index -> [CGPoint] in
            let start = corners[index], end = corners[(index + 1) % corners.count]
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            let count = max(1, Int((length / (1.72 * radius)).rounded()), Int(ceil(length / (1.9 * radius))))
            return (0..<count).map { step in
                let fraction = CGFloat(step) / CGFloat(count)
                return CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            }
        }
        let joints = centers.indices.map { index in
            let start = centers[index], end = centers[(index + 1) % centers.count]
            let dx = end.x - start.x, dy = end.y - start.y
            let distance = hypot(dx, dy)
            let offset = sqrt(radius * radius - distance * distance / 4) / distance
            return CGPoint(x: (start.x + end.x) / 2 + dy * offset, y: (start.y + end.y) / 2 - dx * offset)
        }
        var path = Path()
        var start = joints[joints.count - 1]
        path.move(to: start)
        for (index, center) in centers.enumerated() {
            let end = joints[index]
            let startAngle = atan2(Double(start.y - center.y), Double(start.x - center.x))
            let endAngle = atan2(Double(end.y - center.y), Double(end.x - center.x))
            let fullTurn = 2 * Double.pi
            let sweep = (endAngle - startAngle + fullTurn).truncatingRemainder(dividingBy: fullTurn)
            path.addRelativeArc(center: center, radius: radius, startAngle: .radians(startAngle), delta: .radians(sweep))
            start = end
        }
        path.closeSubpath()
        return path
    }
}
