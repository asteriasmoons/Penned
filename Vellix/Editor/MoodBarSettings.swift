import SwiftUI

nonisolated enum DocumentWidgetSize {
    static func isHalf(_ node: [String: Any]) -> Bool {
        DocumentWidgetLayout.specification.types.contains(node["type"] as? String ?? "") &&
            (node["attrs"] as? [String: Any])?["width"] as? String == "half"
    }
}

nonisolated struct MoodBarSettings: Equatable, Sendable {
    static let moods = ["miserable", "upset", "low", "neutral", "content", "happy", "ecstatic"]
    var value: Int
    var backgroundColor: String
    var barColor: String
    var borderColor: String
    var borderWidth: Int
    var width: String
    var buttonColor: String
    var buttonBorderColor: String

    init(_ attrs: [String: Any]) {
        value = min(6, max(0, (attrs["value"] as? NSNumber)?.intValue ?? 3))
        backgroundColor = GridCardSettings.opaqueHex(attrs["backgroundColor"], fallback: "#151518")
        barColor = GridCardSettings.opaqueHex(attrs["barColor"], fallback: "#af72e9")
        borderColor = GridCardSettings.opaqueHex(attrs["borderColor"], fallback: "#65606d")
        borderWidth = min(8, max(0, (attrs["borderWidth"] as? NSNumber)?.intValue ?? 2))
        width = attrs["width"] as? String == "half" ? "half" : "full"
        buttonColor = GridCardSettings.opaqueHex(attrs["buttonColor"], fallback: "#151518")
        buttonBorderColor = GridCardSettings.opaqueHex(attrs["buttonBorderColor"], fallback: "#ffffff")
    }
}

struct MoodBarSettingsRequest: Identifiable, Equatable {
    let id = UUID()
    let blockID: String
    let settings: MoodBarSettings
}

struct MoodBarSettingsSheet: View {
    let request: MoodBarSettingsRequest
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MoodBarSettings

    init(request: MoodBarSettingsRequest, session: TipTapEditorSession) {
        self.request = request
        self.session = session
        _draft = State(initialValue: request.settings)
    }

    private func color(_ path: WritableKeyPath<MoodBarSettings, String>, key: String) -> Binding<Color> {
        Binding(get: { Color(vellixHex: draft[keyPath: path]) }, set: { color in
            let hex = color.vellixHexString(fallback: draft[keyPath: path])
            draft[keyPath: path] = hex
            session.moodBarSetAttr(blockID: request.blockID, key: key, value: hex)
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        MoodBarPreview(settings: draft).frame(maxWidth: .infinity)
                        if draft.width == "half" { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                    }
                    Picker("Size", selection: Binding(get: { draft.width }, set: { value in
                        draft.width = value
                        session.moodBarSetAttr(blockID: request.blockID, key: "width", value: value)
                    })) {
                        Text("Half Size").tag("half")
                        Text("Full Size").tag("full")
                    }.pickerStyle(.segmented)
                    ColorPicker("Background", selection: color(\.backgroundColor, key: "backgroundColor"), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    ColorPicker("Bar Color", selection: color(\.barColor, key: "barColor"), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    ColorPicker("Button Color", selection: color(\.buttonColor, key: "buttonColor"), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    ColorPicker("Button Border Color", selection: color(\.buttonBorderColor, key: "buttonBorderColor"), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    ColorPicker("Border Color", selection: color(\.borderColor, key: "borderColor"), supportsOpacity: false)
                        .padding(12).pennedSheetField()
                    Stepper("Border Thickness: \(draft.borderWidth)", value: Binding(
                        get: { draft.borderWidth },
                        set: { value in
                            draft.borderWidth = value
                            session.moodBarSetAttr(blockID: request.blockID, key: "borderWidth", value: value)
                        }), in: 0...8)
                        .padding(12).pennedSheetField()
                }.padding(18)
            }
            .pennedSheet(title: "Mood Bar Settings", close: { dismiss() }) {
                #if os(iOS)
                PennedSheetKeyboardDismissButton {}
                #endif
                Button("Done") { dismiss() }
            }
        }
    }
}

struct MoodBarPreview: View {
    let settings: MoodBarSettings

    var body: some View {
        DocumentWidgetFrame(mode: settings.width, background: settings.backgroundColor, border: settings.borderColor, borderWidth: settings.borderWidth) { metrics in
          VStack(spacing: metrics.spacing) {
            Image(MoodBarSettings.moods[settings.value])
                .renderingMode(.original).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            GeometryReader { geometry in
                Capsule().fill(Color(vellixHex: settings.barColor))
                    .frame(height: min(26, max(22, metrics.width * 0.12))).frame(height: 44)
                Circle().fill(Color(vellixHex: settings.buttonColor))
                    .overlay { Circle().strokeBorder(Color(vellixHex: settings.buttonBorderColor), lineWidth: 3) }
                    .frame(width: 30, height: 30)
                    .offset(x: max(0, geometry.size.width - 30) * CGFloat(settings.value) / 6, y: 7)
            }.frame(height: 44)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mood")
        .accessibilityValue(MoodBarSettings.moods[settings.value])
        .allowsHitTesting(false)
    }
}
