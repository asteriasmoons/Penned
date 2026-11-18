import SwiftUI
import WebKit

nonisolated struct GridCardSettings: Equatable, Sendable {
    enum Width: String, CaseIterable, Sendable { case half, full }
    enum Alignment: String, CaseIterable, Sendable { case left, center, right }

    var icon: String
    var iconColor: String
    var backgroundColor: String
    var title: String
    var alignment: Alignment
    var width: Width
    var height: Int

    init(_ attrs: [String: Any]) {
        icon = attrs["icon"] as? String ?? "sparkle"
        iconColor = Self.opaqueHex(attrs["iconColor"] ?? attrs["color"], fallback: "#ffffff")
        let defaultBackground = attrs["color"] != nil && Self.readableInk(on: iconColor) == "#ffffff" ? "#e5e3e8" : "#302d36"
        backgroundColor = Self.opaqueHex(attrs["backgroundColor"], fallback: defaultBackground)
        title = attrs["title"] as? String ?? ""
        alignment = Alignment(rawValue: attrs["alignment"] as? String ?? "") ?? .left
        width = Width(rawValue: attrs["width"] as? String ?? "") ?? .full
        height = Self.clampHeight(attrs["height"] as? Int ?? 100)
    }

    static func clampHeight(_ height: Int) -> Int { min(1600, max(100, height)) }

    static func isHalf(_ node: [String: Any]) -> Bool {
        node["type"] as? String == "gridCard" && (node["attrs"] as? [String: Any])?["width"] as? String == "half"
    }

    var inkColor: String { Self.readableInk(on: backgroundColor) }

    static func readableInk(on background: String) -> String {
        let rgb = UInt32(background.dropFirst(), radix: 16) ?? 0
        let linear = [16, 8, 0].map { shift in
            let channel = Double((rgb >> shift) & 255) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 >= 0.179 ? "#000000" : "#ffffff"
    }

    static func opaqueHex(_ value: Any?, fallback: String) -> String {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.first == "#", UInt32(value.dropFirst(), radix: 16) != nil else { return fallback }
        switch value.count {
        case 4, 5: return "#" + value.dropFirst().prefix(3).map { String(repeating: String($0), count: 2) }.joined()
        case 7, 9: return String(value.prefix(7))
        default: return fallback
        }
    }

    var payload: [String: Any] {
        ["icon": icon, "iconColor": iconColor, "backgroundColor": backgroundColor, "title": title,
         "alignment": alignment.rawValue, "width": width.rawValue, "height": height]
    }
}

nonisolated struct GridCardSettingsRequest: Identifiable, Equatable, Sendable {
    let id: String
    let original: GridCardSettings
    let nodeData: Data
    let appearanceData: Data

    init?(payload: [String: Any]) {
        guard let id = payload["blockID"] as? String, !id.isEmpty,
              let node = payload["node"] as? [String: Any], node["type"] as? String == "gridCard",
              let attrs = node["attrs"] as? [String: Any], attrs["id"] as? String == id,
              let nodeData = try? JSONSerialization.data(withJSONObject: node),
              let appearanceData = try? JSONSerialization.data(withJSONObject: payload["appearance"] as? [String: Any] ?? [:]) else { return nil }
        self.id = id
        original = GridCardSettings(attrs)
        self.nodeData = nodeData
        self.appearanceData = appearanceData
    }

    @MainActor
    func commit(_ settings: GridCardSettings, in webView: WKWebView) async throws -> Any? {
        var args: [String: Any] = ["blockID": id, "original": original.payload, "settings": settings.payload]
        if let source = TipTapEditorIconRenderer.dataURL(for: settings.icon) {
            args["assets"] = [settings.icon: source]
        }
        return try await webView.callAsyncJavaScript("return await window.tiptapCommand('gridCardUpdate', args);",
            arguments: ["args": args], in: nil, contentWorld: .page)
    }
}

struct GridCardSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var draft: GridCardSettings
    @State private var iconPicker = false
    @State private var saving = false
    @State private var error: String?
    @State private var previewError = false
    @State private var renderedHeight: CGFloat = 0
    @State private var heightStart: CGFloat?
    @State private var widthStart: CGFloat?
    let request: GridCardSettingsRequest
    let onSave: (GridCardSettings) async throws -> Void

    init(request: GridCardSettingsRequest, onSave: @escaping (GridCardSettings) async throws -> Void) {
        self.request = request
        self.onSave = onSave
        _draft = State(initialValue: request.original)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    TextField("Title", text: $draft.title)
                        .focused($titleFocused)
                        .padding(12).pennedSheetField()
                    Button { iconPicker = true } label: {
                        HStack {
                            LibraryIcon(name: draft.icon, size: 20)
                                .foregroundStyle(Color(vellixHex: draft.iconColor))
                            Text("Icon")
                            Spacer()
                            LibraryIcon(name: "chevright", size: 14)
                        }.padding(12).contentShape(Rectangle())
                    }.buttonStyle(.plain).pennedSheetField()
                    ColorPicker("Icon Color", selection: color(\.iconColor), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    ColorPicker("Background", selection: color(\.backgroundColor), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    Picker("Icon and Title Alignment", selection: $draft.alignment) {
                        ForEach(GridCardSettings.Alignment.allCases, id: \.self) { alignment in
                            Image(systemName: "text.align\(alignment.rawValue)")
                                .accessibilityLabel(alignment.rawValue.capitalized).tag(alignment)
                        }
                    }.pickerStyle(.segmented)
                    Picker("Width", selection: $draft.width) {
                        Text("Half Width").tag(GridCardSettings.Width.half)
                        Text("Full Width").tag(GridCardSettings.Width.full)
                    }.pickerStyle(.segmented)
                }.padding(18)
            }
            .disabled(saving)
            .pennedSheet(title: "Grid Card Settings", closeDisabled: saving, close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton { titleFocused = false }.disabled(saving)
                #endif
                Button("Done", action: save).disabled(saving)
            }
        }
        .sheet(isPresented: $iconPicker) {
            VellixIconLibraryPicker(title: "Grid Card Icon", selectedIcon: draft.icon) { icon in
                draft.icon = icon.name
                iconPicker = false
            }
            #if os(macOS)
            .frame(width: 540, height: 600)
            #endif
        }
        .interactiveDismissDisabled(saving)
        .alert("Could Not Save Grid Card", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var preview: some View {
        let height = max(CGFloat(draft.height), renderedHeight)
        return GeometryReader { geometry in
            let available = max(0, geometry.size.width - 18)
            let width = draft.width == .full ? available : max(0, (available - 12) / 2)
            ZStack(alignment: .topLeading) {
                GridCardPreview(request: request, settings: draft, width: available,
                                renderedHeight: $renderedHeight, failed: $previewError)
                    .frame(width: available, height: height)
                    .allowsHitTesting(false)
                if previewError {
                    Text("Preview unavailable").foregroundStyle(.secondary).frame(width: width, height: height)
                }
                GridCardResizeHandle(axis: .horizontal, active: widthStart != nil)
                    .position(x: width, y: height / 2)
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { value in
                            if widthStart == nil { widthStart = width }
                            draft.width = (widthStart ?? width) + value.translation.width >= available * 0.73 ? .full : .half
                        }
                        .onEnded { _ in widthStart = nil })
                    .accessibilityHidden(true)
                GridCardResizeHandle(axis: .vertical, active: heightStart != nil)
                    .position(x: width / 2, y: height)
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { value in
                            if heightStart == nil { heightStart = height }
                            draft.height = GridCardSettings.clampHeight(Int((heightStart ?? height) + value.translation.height))
                        }
                        .onEnded { _ in heightStart = nil })
                    .accessibilityLabel("Card height")
                    .accessibilityValue("\(draft.height) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: draft.height = GridCardSettings.clampHeight(draft.height + 10)
                        case .decrement: draft.height = GridCardSettings.clampHeight(draft.height - 10)
                        @unknown default: break
                        }
                    }
            }.padding(.leading, 4)
        }.frame(height: height + 20)
    }

    private func color(_ key: WritableKeyPath<GridCardSettings, String>) -> Binding<Color> {
        Binding(get: { Color(vellixHex: draft[keyPath: key]) }, set: {
            draft[keyPath: key] = $0.vellixHexString(fallback: draft[keyPath: key])
        })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await onSave(draft); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

// A read-only instance of the existing editor page keeps the preview's block,
// paragraph typography, and icon mask on the same rendering path as the document.
struct GridCardResizeHandle: View {
    let axis: Axis
    let active: Bool

    var body: some View {
        Capsule().fill(active ? Color.accentColor : Color.secondary)
            .frame(width: axis == .horizontal ? 5 : 30, height: axis == .horizontal ? 30 : 5)
            .padding(3).background(.background, in: Capsule())
            .frame(width: 38, height: 38).contentShape(Rectangle())
    }
}

private struct GridCardPreview {
    let request: GridCardSettingsRequest
    let settings: GridCardSettings
    let width: CGFloat
    @Binding var renderedHeight: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(DocumentFontSchemeHandler(), forURLScheme: DocumentFontResources.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        #if os(iOS)
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        #elseif os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #endif
        view.navigationDelegate = coordinator
        if let bundle = Bundle.main.url(forResource: "VellixEditor", withExtension: "bundle") {
            view.loadFileURL(bundle.appendingPathComponent("tiptap.html"), allowingReadAccessTo: bundle)
        } else {
            Task { @MainActor in failed = true }
        }
        return view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var current: GridCardPreview?
        private var loaded = false
        private var working = false
        private var applied: GridCardSettings?
        private var appliedWidth: CGFloat?
        private var appliedRequestID: String?
        private var loadedCardID: String?
        private var registered = Set<String>()

        func update(_ preview: GridCardPreview, in view: WKWebView) {
            current = preview
            render(in: view)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            current?.failed = true
        }

        private func render(in view: WKWebView) {
            guard loaded, !working, let current, current.width > 0,
                  current.request.id != appliedRequestID || current.settings != applied || current.width != appliedWidth else { return }
            working = true
            applied = current.settings
            appliedWidth = current.width
            appliedRequestID = current.request.id
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                defer { working = false; render(in: view) }
                do {
                    var assets: [String: String] = [:]
                    for icon in Set([current.settings.icon, "sparkle"]).subtracting(registered) {
                        if let source = TipTapEditorIconRenderer.dataURL(for: icon) { assets[icon] = source }
                    }
                    var payload: [String: Any] = ["settings": current.settings.payload, "assets": assets,
                                                  "width": Double(current.width)]
                    if current.request.id != loadedCardID {
                        payload["node"] = try JSONSerialization.jsonObject(with: current.request.nodeData)
                        payload["appearance"] = try JSONSerialization.jsonObject(with: current.request.appearanceData)
                    }
                    let result = try await view.callAsyncJavaScript("return await window.pennedGridCardPreview(payload);",
                        arguments: ["payload": payload], in: nil, contentWorld: .page)
                    loadedCardID = current.request.id
                    registered.formUnion(assets.keys)
                    if let height = result as? NSNumber, let latest = self.current,
                       latest.request.id == current.request.id, latest.settings == current.settings, latest.width == current.width {
                        latest.failed = false
                        latest.renderedHeight = CGFloat(height.doubleValue)
                    }
                } catch {
                    self.current?.failed = true
                }
            }
        }
    }
}

#if os(iOS)
extension GridCardPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self, in: view) }
}
#elseif os(macOS)
extension GridCardPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self, in: view) }
}
#endif
