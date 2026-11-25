import CoreGraphics
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

nonisolated struct IconCalloutSettings: Equatable, Sendable {
    var icon: String
    var iconColor: String
    var backgroundColor: String
    var imagePath: String?
    var textColor: String?
    var imageTint: String?
    var title: String
    var titleColor: String?
    var collapsible: Bool
    var collapsed: Bool
    var collapseColor: String?
    var widthPercent: Double?
    var minimumHeight: Int?

    init(_ attrs: [String: Any], plain: Bool = false) {
        let card = GridCardSettings(attrs)
        let name = card.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        icon = name.isEmpty ? "sparkle" : name
        iconColor = card.iconColor
        backgroundColor = plain ? GridCardSettings.opaqueHex(attrs["color"], fallback: "#ffffff") : card.backgroundColor
        imagePath = (attrs["imagePath"] as? String).flatMap { AttachmentStore.validRelativePath($0) ? $0 : nil }
        textColor = Self.optionalColor(attrs["textColor"])
        imageTint = Self.optionalColor(attrs["imageTint"])
        title = attrs["title"] as? String ?? ""
        titleColor = Self.optionalColor(attrs["titleColor"])
        collapsible = !plain && (attrs["collapsible"] as? Bool == true || attrs["collapsible"] as? String == "true")
        collapsed = collapsible && (attrs["collapsed"] as? Bool == true || attrs["collapsed"] as? String == "true")
        collapseColor = Self.optionalColor(attrs["collapseColor"])
        widthPercent = (attrs["widthPercent"] as? Double).flatMap { $0.isFinite && $0 > 0 ? min(100, max(1, $0)) : nil }
        minimumHeight = (attrs["minimumHeight"] as? Int).flatMap { $0 > 0 ? Self.clampMinimumHeight($0) : nil }
    }

    private static func optionalColor(_ value: Any?) -> String? {
        let hex = GridCardSettings.opaqueHex(value, fallback: "")
        return hex.isEmpty ? nil : hex
    }

    var inkColor: String { textColor ?? GridCardSettings.readableInk(on: backgroundColor) }
    var titleInk: String { titleColor ?? inkColor }
    var disclosureInk: String { collapseColor ?? iconColor }
    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func clampMinimumHeight(_ value: Int) -> Int { min(1600, max(44, value)) }

    var plainPayload: [String: Any] {
        var values: [String: Any] = ["color": backgroundColor]
        values["textColor"] = textColor
        values["widthPercent"] = widthPercent
        values["minimumHeight"] = minimumHeight
        return values
    }

    var payload: [String: Any] {
        var values: [String: Any] = ["icon": icon, "iconColor": iconColor, "backgroundColor": backgroundColor]
        values["imagePath"] = imagePath
        values["textColor"] = textColor
        values["imageTint"] = imageTint
        values["title"] = title
        values["titleColor"] = titleColor
        values["collapsible"] = collapsible
        values["collapsed"] = collapsible && collapsed
        values["collapseColor"] = collapseColor
        return values
    }
}

nonisolated struct IconCalloutSettingsRequest: Identifiable, Equatable, Sendable {
    let id: String
    let original: IconCalloutSettings
    let editableText: String?
    let previewText: String
    let isPlain: Bool

    init?(payload: [String: Any]) {
        guard let id = payload["blockID"] as? String, !id.isEmpty,
              let node = payload["node"] as? [String: Any], let type = node["type"] as? String,
              ["iconCallout", "plainCallout"].contains(type),
              let attrs = node["attrs"] as? [String: Any], attrs["id"] as? String == id else { return nil }
        self.id = id
        let plain = type == "plainCallout"
        isPlain = plain
        original = IconCalloutSettings(attrs, plain: plain)
        let children = node["content"] as? [[String: Any]] ?? []
        let lines = children.compactMap { paragraph -> String? in
            guard paragraph["type"] as? String == "paragraph" else { return nil }
            let runs = paragraph["content"] as? [[String: Any]] ?? []
            guard runs.allSatisfy({ $0["type"] as? String == "text" && ($0["marks"] as? [Any] ?? []).isEmpty }) else { return nil }
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        editableText = lines.count == children.count ? lines.joined(separator: "\n") : nil
        func text(in node: [String: Any]) -> String {
            if node["type"] as? String == "hardBreak" { return "\n" }
            if let value = node["text"] as? String { return value }
            let children = node["content"] as? [[String: Any]] ?? []
            return children.map(text(in:)).joined()
        }
        previewText = String(children.map(text(in:)).joined(separator: "\n").prefix(500))
    }

    @MainActor
    func commit(_ settings: IconCalloutSettings, text: String?, in webView: WKWebView) async throws -> Any? {
        let command = isPlain ? "plainCalloutUpdate" : "iconCalloutUpdate"
        var args: [String: Any] = ["blockID": id, "original": isPlain ? original.plainPayload : original.payload,
                                   "settings": isPlain ? settings.plainPayload : settings.payload]
        args["text"] = text
        args["originalText"] = editableText
        if !isPlain, settings.imagePath == nil, let source = TipTapEditorIconRenderer.dataURL(for: settings.icon) {
            args["assets"] = [settings.icon: source]
        }
        return try await webView.callAsyncJavaScript("return await window.tiptapCommand(command, args);",
            arguments: ["command": command, "args": args], in: nil, contentWorld: .page)
    }
}

// Imported art keeps its own color and alpha; it never goes through the library's tint/cache path.
nonisolated enum CustomCalloutIconImage {
    static func prepare(_ data: Data, removeHairlines: Bool = true) throws -> Data {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 288
              ] as CFDictionary) else {
            throw VellixError.attachmentImport("Choose a supported image up to 20 MB.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VellixError.attachmentImport("The icon could not be prepared.")
        }
        let prepared = removeHairlines ? removeOuterHairlines(image) ?? image : image
        CGImageDestinationAddImage(destination, prepared, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VellixError.attachmentImport("The icon could not be prepared.")
        }
        return output as Data
    }

    static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func tinted(_ image: CGImage, hex: String) -> CGImage? {
        guard let rgb = UInt32(hex.dropFirst(), radix: 16),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                             blue: CGFloat(rgb & 255) / 255, alpha: 1)
        context.fill(rect)
        context.setBlendMode(.destinationIn)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // A bounded, transient representation; the original attachment is never changed.
    static func tintedPNG(at url: URL, hex: String) throws -> Data {
        guard hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192,
              ] as CFDictionary), let rendered = tinted(image, hex: hex) else {
            throw VellixError.attachmentImport("The icon image could not be rendered.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VellixError.attachmentImport("The icon image could not be encoded.")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VellixError.attachmentImport("The icon image could not be encoded.")
        }
        return output as Data
    }

    static func readFile(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 20_000_000 else {
            throw VellixError.attachmentImport("Choose a supported image up to 20 MB.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func removeOuterHairlines(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let scale = min(w, h)
        guard scale >= 24,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let threshold: UInt8 = 10
        let thickness = max(3, scale / 40), minLength = max(8, scale / 18)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * w + x) * 4 + 3] }
        var minX = w, minY = h, maxX = -1, maxY = -1, opaqueCount = 0
        for y in 0..<h {
            for x in 0..<w where alpha(x, y) > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                opaqueCount += 1
            }
        }
        guard minX <= maxX, minY <= maxY, opaqueCount < w * h else { return nil }
        var removal = Set<Int>()
        // Like the library cleanup, use long alpha runs with low perpendicular thickness.
        // Restrict the scan to the silhouette's edges so strokes inside imported art survive.
        func markEdges(transposed: Bool, lines: ClosedRange<Int>, scan: ClosedRange<Int>, limit: Int) {
            func solid(_ along: Int, _ across: Int) -> Bool {
                (transposed ? alpha(across, along) : alpha(along, across)) > threshold
            }
            for line in lines where line - lines.lowerBound <= thickness || lines.upperBound - line <= thickness {
                var start = scan.lowerBound
                while start <= scan.upperBound {
                    guard solid(start, line) else { start += 1; continue }
                    var end = start
                    while end < scan.upperBound && solid(end + 1, line) { end += 1 }
                    if end - start + 1 >= minLength {
                        let thin = (start...end).compactMap { along -> (Int, ClosedRange<Int>)? in
                            var first = line, last = line
                            while first > 0 && line - first < thickness && solid(along, first - 1) { first -= 1 }
                            while last + 1 < limit && last - line < thickness && solid(along, last + 1) { last += 1 }
                            guard last - first + 1 <= thickness else { return nil }
                            return (along, first...last)
                        }
                        if thin.count >= minLength {
                            for (along, band) in thin {
                                for across in band { removal.insert(transposed ? along * w + across : across * w + along) }
                            }
                        }
                    }
                    start = end + 1
                }
            }
        }
        markEdges(transposed: false, lines: minY...maxY, scan: minX...maxX, limit: h)
        markEdges(transposed: true, lines: minX...maxX, scan: minY...maxY, limit: w)
        guard !removal.isEmpty, removal.count <= opaqueCount / 5 else { return nil }
        for pixel in removal {
            for channel in 0..<4 { bytes[pixel * 4 + channel] = 0 }
        }
        return context.makeImage()
    }
}

struct IconCalloutGlyph: View {
    let settings: IconCalloutSettings
    var image: CGImage?
    var size: CGFloat = 32
    var originalLibraryColors = false

    var body: some View {
        Group {
            if let image {
                if let tint = settings.imageTint {
                    Image(decorative: image, scale: 1).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(Color(vellixHex: tint))
                } else {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
            } else if originalLibraryColors {
                let icon = VellixAssetIcon(name: settings.icon)
                (icon.systemName.map { Image(systemName: $0) } ?? Image(settings.icon))
                    .renderingMode(.original).resizable().scaledToFit()
            } else {
                LibraryIcon(name: settings.icon, size: size * 26 / 32).foregroundStyle(Color(vellixHex: settings.iconColor))
            }
        }
        .shadow(color: outline, radius: 0, x: 0.6, y: 0)
        .shadow(color: outline, radius: 0, x: -0.6, y: 0)
        .shadow(color: outline, radius: 0, x: 0, y: 0.6)
        .shadow(color: outline, radius: 0, x: 0, y: -0.6)
        .frame(width: size, height: size).accessibilityHidden(true)
    }

    private var outline: Color {
        if image != nil { return settings.imageTint.map { Color(vellixHex: $0) } ?? .clear }
        return originalLibraryColors ? .clear : Color(vellixHex: settings.iconColor)
    }
}

struct IconCalloutSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @FocusState private var textFocused: Bool
    @FocusState private var titleFocused: Bool
    @ScaledMetric(relativeTo: .body) private var previewTitleSize: CGFloat = 19
    @State private var draft: IconCalloutSettings
    @State private var text: String
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false
    @State private var pickingIcon = false
    @State private var imageData: Data?
    @State private var image: CGImage?
    @State private var busy = false
    @State private var error: String?
    @State private var previewHeight: CGFloat = 44
    @GestureState private var widthAtDragStart: CGFloat? = nil
    @GestureState private var heightAtDragStart: CGFloat? = nil
    let request: IconCalloutSettingsRequest
    let onSave: (IconCalloutSettings, String?, Data?) async throws -> Void
    private var hasCustomImage: Bool { draft.imagePath != nil || imageData != nil }

    init(request: IconCalloutSettingsRequest, onSave: @escaping (IconCalloutSettings, String?, Data?) async throws -> Void) {
        self.request = request
        self.onSave = onSave
        _draft = State(initialValue: request.original)
        _text = State(initialValue: request.editableText ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if request.isPlain {
                        plainPreview
                        Picker("Width", selection: Binding(get: { draft.widthPercent ?? 100 }, set: { draft.widthPercent = $0 })) {
                            Text("Half Width").tag(50.0)
                            Text("Full Width").tag(100.0)
                            if let original = request.original.widthPercent, original != 50, original != 100 {
                                Text("Original").tag(original)
                            }
                        }.pickerStyle(.segmented)
                        if let height = draft.minimumHeight {
                            Button("Reset Height") { draft.minimumHeight = nil }
                                .accessibilityValue("\(height) points")
                        }
                    } else {
                        preview
                        TextField("Title (Optional)", text: $draft.title, axis: .vertical)
                            .textFieldStyle(.plain).focused($titleFocused)
                            .padding(12).pennedSheetField()
                        optionalPicker("Title Color", \.titleColor, fallback: draft.titleInk, resetTitle: "Automatic")
                        Toggle("Collapse Mode", isOn: $draft.collapsible)
                            .padding(12).pennedSheetField()
                            .onChange(of: draft.collapsible) { _, enabled in if !enabled { draft.collapsed = false } }
                        if draft.collapsible {
                            optionalPicker("Collapse Button Color", \.collapseColor,
                                fallback: draft.disclosureInk, resetTitle: "Automatic")
                        }
                        Button { pickingIcon = true } label: { source("Icon Library", icon: "sparkle") }.buttonStyle(.plain)
                        PhotosPicker(selection: $photo, matching: .images) { source("Photo Library", icon: "imagesign") }.buttonStyle(.plain)
                        Button { pickingFile = true } label: { source("Choose File", icon: "folderhand") }.buttonStyle(.plain)
                        if hasCustomImage {
                            Button("Remove Custom Image", role: .destructive) { clearImage() }
                            optionalPicker("Icon Color", \.imageTint, fallback: draft.iconColor, resetTitle: "Original Colors")
                        } else {
                            picker("Icon Color", \.iconColor)
                        }
                    }
                    optionalPicker("Text Color", \.textColor, fallback: draft.inkColor, resetTitle: "Automatic")
                    picker("Background", \.backgroundColor)
                }.padding(18)
            }
            .scrollDismissesKeyboard(.immediately)
            .disabled(busy)
            .pennedSheet(title: "Callout Settings", closeDisabled: busy, close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton { textFocused = false; titleFocused = false }.disabled(busy)
                #endif
                Button("Done", action: save).disabled(busy)
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $pickingIcon) {
            VellixIconLibraryPicker(title: "Callout Icon", selectedIcon: draft.icon) { icon in
                draft.icon = icon.name
                clearImage()
                pickingIcon = false
            }
            #if os(macOS)
            .frame(width: 540, height: 600)
            #endif
        }
        .task(id: photo) {
            guard let photo else { return }
            await load {
                guard let bytes = try await photo.loadTransferable(type: Data.self) else {
                    throw VellixError.attachmentImport("The photo could not be loaded.")
                }
                return bytes
            }
            self.photo = nil
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image]) { result in
            Task {
                await load {
                    let url = try result.get()
                    return try await Task.detached(priority: .userInitiated) { try CustomCalloutIconImage.readFile(url) }.value
                }
            }
        }
        .alert("Callout Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draft.hasTitle {
                HStack(alignment: .center, spacing: 8) {
                    IconCalloutGlyph(settings: draft, image: image ?? existingImage)
                    Text(draft.title)
                        .font(.system(size: previewTitleSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(vellixHex: draft.titleInk))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    previewDisclosure
                }
                if !draft.collapsed { previewBody.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    IconCalloutGlyph(settings: draft, image: image ?? existingImage)
                    if !draft.collapsed { previewBody.frame(maxWidth: .infinity, alignment: .leading) }
                    else { Spacer(minLength: 0) }
                    previewDisclosure
                }
            }
        }
        .foregroundStyle(Color(vellixHex: draft.inkColor))
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: request.isPlain ? draft.minimumHeight.map { CGFloat($0) } : nil,
               alignment: .topLeading)
        .background(Color(vellixHex: draft.backgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var previewDisclosure: some View {
        if draft.collapsible {
            Button { draft.collapsed.toggle() } label: {
                LibraryIcon(name: draft.collapsed ? "chevdown" : "chevup", size: 20)
                    .foregroundStyle(Color(vellixHex: draft.disclosureInk))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(draft.collapsed ? "Expand callout" : "Collapse callout")
        }
    }

    @ViewBuilder private var previewBody: some View {
        if request.editableText != nil {
            TextField("Callout Text", text: $text, axis: .vertical).textFieldStyle(.plain)
                .lineLimit(1...6).focused($textFocused)
        } else if !request.previewText.isEmpty {
            Text(request.previewText).lineLimit(6)
        }
    }

    private var plainPreview: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 18)
            let width = draft.widthPercent == 50 ? max(0, (available - 12) / 2)
                : available * CGFloat(draft.widthPercent ?? 100) / 100
            ZStack(alignment: .topLeading) {
                preview.frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { previewHeight = $0 }
                GridCardResizeHandle(axis: .horizontal, active: widthAtDragStart != nil)
                    .position(x: width, y: previewHeight / 2)
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($widthAtDragStart) { _, start, _ in if start == nil { start = width } }
                        .onChanged { value in draft.widthPercent = (widthAtDragStart ?? width) + value.translation.width >= available * 0.73 ? 100 : 50 })
                    .accessibilityHidden(true)
                GridCardResizeHandle(axis: .vertical, active: heightAtDragStart != nil)
                    .position(x: width / 2, y: previewHeight)
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($heightAtDragStart) { _, start, _ in if start == nil { start = previewHeight } }
                        .onChanged { value in draft.minimumHeight = IconCalloutSettings.clampMinimumHeight(Int((heightAtDragStart ?? previewHeight) + value.translation.height)) })
                    .accessibilityLabel("Callout minimum height")
                    .accessibilityValue(draft.minimumHeight.map { "\($0) points" } ?? "Automatic")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: draft.minimumHeight = IconCalloutSettings.clampMinimumHeight(Int(previewHeight) + 10)
                        case .decrement: draft.minimumHeight = IconCalloutSettings.clampMinimumHeight((draft.minimumHeight ?? Int(previewHeight)) - 10)
                        @unknown default: break
                        }
                    }
            }.padding(.leading, 4)
        }.frame(height: previewHeight + 20)
    }

    private var existingImage: CGImage? {
        WashiTapePreview.documentImage(path: draft.imagePath, attachments: environment.attachments, store: environment.attachmentStore)
    }

    private func source(_ title: String, icon: String) -> some View {
        Label { Text(title) } icon: { LibraryIcon(name: icon, size: 20) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).contentShape(Rectangle()).pennedSheetField()
    }

    private func picker(_ title: String, _ key: WritableKeyPath<IconCalloutSettings, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(vellixHex: draft[keyPath: key]) },
            set: { draft[keyPath: key] = $0.vellixHexString(fallback: draft[keyPath: key]) }), supportsOpacity: false)
            .padding(12).pennedSheetField()
    }

    private func optionalPicker(_ title: String, _ key: WritableKeyPath<IconCalloutSettings, String?>,
                                fallback: String, resetTitle: String) -> some View {
        HStack(spacing: 12) {
            ColorPicker(title, selection: Binding(get: { Color(vellixHex: draft[keyPath: key] ?? fallback) },
                set: { draft[keyPath: key] = $0.vellixHexString(fallback: fallback) }), supportsOpacity: false)
            if draft[keyPath: key] != nil {
                Button { draft[keyPath: key] = nil } label: {
                    LibraryIcon(name: "undo", size: 18).frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Reset \(title)")
                    .accessibilityHint(resetTitle)
            }
        }.padding(12).pennedSheetField()
    }

    private func clearImage() {
        draft.imagePath = nil
        imageData = nil
        image = nil
    }

    private func load(_ read: () async throws -> Data) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let input = try await read()
            let prepared = try await Task.detached(priority: .userInitiated) { try CustomCalloutIconImage.prepare(input) }.value
            try Task.checkCancellation()
            image = CustomCalloutIconImage.image(prepared)
            imageData = prepared
            draft.imagePath = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard !busy else { return }
        textFocused = false
        titleFocused = false
        busy = true
        Task {
            defer { busy = false }
            do { try await onSave(draft, request.editableText == nil ? nil : text, imageData); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
