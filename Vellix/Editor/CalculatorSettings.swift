import SwiftUI

nonisolated struct CalculatorButtonStyle: Equatable, Sendable {
    var background: String
    var border: String
    var text: String
    var borderWidth: Int
    var radius: Int

    init(_ attrs: [String: Any], prefix: String, background: String, border: String, text: String) {
        self.background = GridCardSettings.opaqueHex(attrs[prefix + "Background"], fallback: background)
        self.border = GridCardSettings.opaqueHex(attrs[prefix + "Border"], fallback: border)
        self.text = GridCardSettings.opaqueHex(attrs[prefix + "Text"], fallback: text)
        borderWidth = min(8, max(0, (attrs[prefix + "BorderWidth"] as? NSNumber)?.intValue ?? 1))
        radius = min(32, max(0, (attrs[prefix + "Radius"] as? NSNumber)?.intValue ?? 6))
    }

    func payload(prefix: String) -> [String: Any] {
        [prefix + "Background": background, prefix + "Border": border, prefix + "Text": text,
         prefix + "BorderWidth": borderWidth, prefix + "Radius": radius]
    }
}

nonisolated struct CalculatorSettings: Equatable, Sendable {
    var width: String
    var backgroundColor: String
    var borderColor: String
    var borderWidth: Int
    var cornerRadius: Int
    var displayBackground: String
    var displayBorder: String
    var displayBorderWidth: Int
    var displayRadius: Int
    var calculationColor: String
    var resultColor: String
    var displayFont: String
    var displayWeight: Int
    var displaySize: Int
    var calculationSize: Int
    var buttonFont: String
    var buttonWeight: Int
    var buttonSize: Int
    var numbers: CalculatorButtonStyle
    var operators: CalculatorButtonStyle
    var functions: CalculatorButtonStyle
    var equals: CalculatorButtonStyle
    var copyBackground: String
    var copyBorder: String
    var copyText: String
    var soundEnabled: Bool
    var sound: String
    var volume: Double
    var hapticsEnabled: Bool

    init(_ attrs: [String: Any]) {
        func color(_ key: String, _ fallback: String) -> String { GridCardSettings.opaqueHex(attrs[key], fallback: fallback) }
        func number(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, (attrs[key] as? NSNumber)?.intValue ?? fallback))
        }
        func font(_ key: String) -> String {
            let value = attrs[key] as? String ?? "rounded"
            return ["system", "serif", "mono", "rounded", "hachiMaruPop"].contains(value) ? value : "rounded"
        }
        width = attrs["width"] as? String == "half" ? "half" : "full"
        backgroundColor = color("backgroundColor", "#151518"); borderColor = color("borderColor", "#65606d")
        borderWidth = number("borderWidth", 2, 0...8); cornerRadius = number("cornerRadius", 8, 0...48)
        displayBackground = color("displayBackground", "#09090c"); displayBorder = color("displayBorder", "#45454e")
        displayBorderWidth = number("displayBorderWidth", 1, 0...8); displayRadius = number("displayRadius", 6, 0...32)
        calculationColor = color("calculationColor", "#bcbcc8"); resultColor = color("resultColor", "#ffffff")
        displayFont = font("displayFont"); displayWeight = number("displayWeight", 700, 100...900)
        displaySize = number("displaySize", 34, 12...72); calculationSize = number("calculationSize", 13, 8...30)
        buttonFont = font("buttonFont"); buttonWeight = number("buttonWeight", 600, 100...900); buttonSize = number("buttonSize", 21, 10...40)
        numbers = CalculatorButtonStyle(attrs, prefix: "number", background: "#303039", border: "#4a4a55", text: "#ffffff")
        operators = CalculatorButtonStyle(attrs, prefix: "operator", background: "#245769", border: "#468294", text: "#ffffff")
        functions = CalculatorButtonStyle(attrs, prefix: "function", background: "#41404b", border: "#62616f", text: "#ffffff")
        equals = CalculatorButtonStyle(attrs, prefix: "equals", background: "#b285e0", border: "#d4b2f7", text: "#130c1b")
        copyBackground = color("copyBackground", "#202027"); copyBorder = color("copyBorder", "#45454e"); copyText = color("copyText", "#d8c4ee")
        soundEnabled = attrs["soundEnabled"] as? Bool ?? false
        let sound = attrs["sound"] as? String ?? "soft"
        self.sound = ["soft", "pop", "tick", "chime"].contains(sound) ? sound : "soft"
        let volume = (attrs["volume"] as? NSNumber)?.doubleValue ?? 0.4
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0.4
        hapticsEnabled = attrs["hapticsEnabled"] as? Bool ?? false
    }

    var payload: [String: Any] {
        var values: [String: Any] = ["width": width, "backgroundColor": backgroundColor, "borderColor": borderColor,
            "borderWidth": borderWidth, "cornerRadius": cornerRadius, "displayBackground": displayBackground,
            "displayBorder": displayBorder, "displayBorderWidth": displayBorderWidth, "displayRadius": displayRadius,
            "calculationColor": calculationColor, "resultColor": resultColor, "displayFont": displayFont, "displayWeight": displayWeight,
            "displaySize": displaySize, "calculationSize": calculationSize, "buttonFont": buttonFont, "buttonWeight": buttonWeight,
            "buttonSize": buttonSize, "copyBackground": copyBackground, "copyBorder": copyBorder, "copyText": copyText,
            "soundEnabled": soundEnabled, "sound": sound, "volume": volume, "hapticsEnabled": hapticsEnabled]
        for (prefix, style) in [("number", numbers), ("operator", operators), ("function", functions), ("equals", equals)] {
            values.merge(style.payload(prefix: prefix)) { _, new in new }
        }
        return values
    }

    func style(for key: String) -> CalculatorButtonStyle {
        if key == "=" { return equals }
        if ["+", "-", "*", "/"].contains(key) { return operators }
        if ["clear", "sign", "%", "back"].contains(key) { return functions }
        return numbers
    }
}

nonisolated struct CalculatorState: Equatable, Sendable {
    var entry: String
    var accumulator: String?
    var operation: String?
    var waiting: Bool
    var evaluated: Bool
    var calculation: String
    var result: String
    var error: String
    var repeatOperation: String?
    var repeatOperand: String?

    static func isNumber(_ value: String) -> Bool {
        value.count <= 80 && value.range(of: "^-?[0-9]+(?:\\.[0-9]*)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil
            && Double(value)?.isFinite == true
    }

    init(_ attrs: [String: Any] = [:]) {
        func number(_ key: String) -> String? { (attrs[key] as? String).flatMap { Self.isNumber($0) ? $0 : nil } }
        func op(_ key: String) -> String? { (attrs[key] as? String).flatMap { ["+", "-", "*", "/"].contains($0) ? $0 : nil } }
        entry = number("entry") ?? "0"; result = number("result") ?? "0"
        accumulator = number("accumulator"); operation = op("operation")
        waiting = attrs["waiting"] as? Bool ?? false; evaluated = attrs["evaluated"] as? Bool ?? false
        calculation = String((attrs["calculation"] as? String ?? "").prefix(240))
        let error = attrs["error"] as? String ?? ""
        self.error = ["division-zero", "overflow", "unavailable", "invalid"].contains(error) ? error : ""
        repeatOperation = op("repeatOperation"); repeatOperand = number("repeatOperand")
    }

    var payload: [String: Any] {
        ["entry": entry, "accumulator": accumulator.map { $0 as Any } ?? NSNull(), "operation": operation.map { $0 as Any } ?? NSNull(),
         "waiting": waiting, "evaluated": evaluated, "calculation": calculation, "result": result, "error": error,
         "repeatOperation": repeatOperation.map { $0 as Any } ?? NSNull(), "repeatOperand": repeatOperand.map { $0 as Any } ?? NSNull()]
    }

    var resultText: String {
        switch error {
        case "division-zero": "Cannot divide by zero"
        case "overflow": "Number too large"
        case "unavailable": "Calculator unavailable"
        case "invalid": "Calculation error"
        default: result
        }
    }
}

struct CalculatorSettingsRequest: Identifiable, Equatable {
    let id = UUID()
    let blockID: String
    let settings: CalculatorSettings
    let state: CalculatorState
}

struct CalculatorSettingsSheet: View {
    let request: CalculatorSettingsRequest
    let session: TipTapEditorSession
    let onSave: (CalculatorSettings) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalculatorSettings
    @State private var preview: CalculatorState
    @State private var dropdown: String?
    @State private var saving = false
    @State private var previewWorking = false
    @State private var error: String?

    init(request: CalculatorSettingsRequest, session: TipTapEditorSession, onSave: @escaping (CalculatorSettings) async throws -> Void) {
        self.request = request; self.session = session; self.onSave = onSave
        _draft = State(initialValue: request.settings); _preview = State(initialValue: request.state)
    }

    private func color(_ title: String, _ path: WritableKeyPath<CalculatorSettings, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(vellixHex: draft[keyPath: path]) },
            set: { draft[keyPath: path] = $0.vellixHexString(fallback: draft[keyPath: path]) }), supportsOpacity: false)
            .padding(12).pennedSheetField()
    }

    private func size(_ title: String, _ path: WritableKeyPath<CalculatorSettings, Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper("\(title): \(draft[keyPath: path])", value: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }), in: range)
            .padding(12).pennedSheetField()
    }

    private func font(_ title: String, _ path: WritableKeyPath<CalculatorSettings, String>) -> some View {
        HeadingLabelDropdown(title: title, selection: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }),
            choices: DocumentFontStyle.allCases.map { ($0.rawValue, $0.title) }, expanded: dropdown == title,
            toggle: { dropdown = dropdown == title ? nil : title }, close: { dropdown = nil })
    }

    private func weight(_ title: String, _ path: WritableKeyPath<CalculatorSettings, Int>) -> some View {
        HeadingLabelDropdown(title: title, selection: Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }),
            choices: [(100, "Ultra Light"), (200, "Thin"), (300, "Light"), (400, "Regular"), (500, "Medium"),
                      (600, "Semibold"), (700, "Bold"), (800, "Heavy"), (900, "Black")], expanded: dropdown == title,
            toggle: { dropdown = dropdown == title ? nil : title }, close: { dropdown = nil })
    }

    private func keyStyle(_ title: String, _ path: WritableKeyPath<CalculatorSettings, CalculatorButtonStyle>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            color("Background", path.appending(path: \.background))
            color("Border Color", path.appending(path: \.border))
            color("Text Color", path.appending(path: \.text))
            size("Border Thickness", path.appending(path: \.borderWidth), 0...8)
            size("Corner Radius", path.appending(path: \.radius), 0...32)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        CalculatorWidgetPreview(settings: draft, state: preview, onKey: previewKey).disabled(previewWorking)
                        if draft.width == "half" { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                    }
                    Picker("Size", selection: $draft.width) { Text("Half Size").tag("half"); Text("Full Size").tag("full") }.pickerStyle(.segmented)
                    Text("Widget").font(.headline)
                    color("Background", \.backgroundColor); color("Border Color", \.borderColor)
                    size("Border Thickness", \.borderWidth, 0...8); size("Corner Radius", \.cornerRadius, 0...48)
                    Text("Display").font(.headline)
                    color("Background", \.displayBackground); color("Border Color", \.displayBorder)
                    color("Calculation Text", \.calculationColor); color("Result Text", \.resultColor)
                    size("Border Thickness", \.displayBorderWidth, 0...8); size("Corner Radius", \.displayRadius, 0...32)
                    font("Display Font", \.displayFont); weight("Display Font Weight", \.displayWeight)
                    size("Result Text Size", \.displaySize, 12...72); size("Calculation Text Size", \.calculationSize, 8...30)
                    Text("Button Typography").font(.headline)
                    font("Button Font", \.buttonFont); weight("Button Font Weight", \.buttonWeight)
                    size("Button Text Size", \.buttonSize, 10...40)
                    keyStyle("Number Buttons", \.numbers); keyStyle("Operator Buttons", \.operators)
                    keyStyle("Function Buttons", \.functions); keyStyle("Equals Button", \.equals)
                    Text("Copy Button").font(.headline)
                    color("Background", \.copyBackground); color("Border Color", \.copyBorder); color("Icon Color", \.copyText)
                    Text("Sound and Haptics").font(.headline)
                    Toggle("Button Sounds", isOn: $draft.soundEnabled).padding(12).pennedSheetField()
                    ForEach(CalculatorSound.allCases) { sound in
                        HStack(spacing: 10) {
                            Button { draft.sound = sound.rawValue; previewSound() } label: {
                                HStack { Text(sound.title); Spacer(); if draft.sound == sound.rawValue { LibraryIcon(name: "checkwavy", size: 18) } }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { previewSound(sound) } label: { LibraryIcon(name: "playwavy", size: 22).frame(width: 36, height: 36) }
                                .buttonStyle(.plain).accessibilityLabel("Preview \(sound.title)")
                        }.padding(12).pennedSheetField()
                    }
                    HStack { Text("Volume"); Slider(value: $draft.volume, in: 0...1); Text("\(Int(draft.volume * 100))%").monospacedDigit() }
                        .padding(12).pennedSheetField()
                    Toggle("Haptic Feedback", isOn: $draft.hapticsEnabled).padding(12).pennedSheetField()
                }.padding(18)
            }.disabled(saving)
                .pennedSheet(title: "Calculator Settings", closeDisabled: saving, close: { dismiss() }) {
                    #if os(iOS)
                    PennedSheetKeyboardDismissButton {}
                    #endif
                    Button("Done", action: save).disabled(saving || previewWorking)
                }
        }
        .interactiveDismissDisabled(saving)
        .alert("Calculator Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func previewSound(_ sound: CalculatorSound? = nil) {
        do { try CalculatorButtonFeedback.shared.play(sound ?? CalculatorSound(rawValue: draft.sound) ?? .soft, volume: draft.volume) }
        catch { self.error = error.localizedDescription }
    }

    private func previewKey(_ key: String) {
        guard !previewWorking else { return }
        if key == "copy" {
            guard preview.error.isEmpty else { return }
            CalculatorButtonFeedback.copy(preview)
            if draft.soundEnabled { previewSound() }
            CalculatorButtonFeedback.haptic(enabled: draft.hapticsEnabled)
            return
        }
        previewWorking = true
        Task { @MainActor in
            defer { previewWorking = false }
            do {
                preview = try await session.previewCalculator(state: preview, key: key)
                if draft.soundEnabled { previewSound() }
                CalculatorButtonFeedback.haptic(enabled: draft.hapticsEnabled)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !saving else { return }; saving = true
        Task { @MainActor in
            defer { saving = false }
            do { try await onSave(draft); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}

struct CalculatorWidgetPreview: View {
    let settings: CalculatorSettings
    let state: CalculatorState
    var onKey: ((String) -> Void)?
    static let keys = [["clear", "sign", "%", "/"], ["7", "8", "9", "*"], ["4", "5", "6", "-"], ["1", "2", "3", "+"], ["back", "0", ".", "="]]

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    static func label(_ key: String) -> String {
        ["clear": "AC", "sign": "\u{00b1}", "*": "\u{00d7}", "/": "\u{00f7}", "-": "\u{2212}" ][key] ?? key
    }

    static func accessibilityLabel(_ key: String) -> String {
        ["clear": "Clear", "sign": "Change sign", "%": "Percent", "back": "Backspace", "=": "Equals",
         "*": "Multiply", "/": "Divide", "-": "Subtract", "+": "Add"][key] ?? key
    }

    private func font(_ family: String, size: Int, weight: Int) -> Font {
        (DocumentFontStyle(rawValue: family) ?? .rounded).font(size: CGFloat(size), weight: Self.weight(weight))
    }

    var body: some View {
        DocumentWidgetFrame(mode: settings.width, background: settings.backgroundColor, border: settings.borderColor, borderWidth: settings.borderWidth, radius: CGFloat(settings.cornerRadius)) { metrics in
          let displayInset = CGFloat(settings.displayBorderWidth) + 2
          let displayContentHeight = max(1, metrics.displayHeight - displayInset * 2)
          let answerHeight = max(1, (displayContentHeight - 1) * 0.6)
          let expressionHeight = max(1, displayContentHeight - 1 - answerHeight)
          VStack(spacing: metrics.spacing) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(state.calculation.isEmpty ? " " : state.calculation)
                    .font(font(settings.displayFont, size: min(11, settings.calculationSize, max(6, Int(expressionHeight / 1.1))), weight: settings.displayWeight))
                    .foregroundStyle(Color(vellixHex: settings.calculationColor)).frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(height: expressionHeight)
                HStack(spacing: metrics.spacing) {
                    Text(state.resultText).font(font(settings.displayFont, size: min(18, settings.displaySize, max(8, Int(answerHeight / 1.1))), weight: settings.displayWeight))
                        .foregroundStyle(Color(vellixHex: settings.resultColor)).lineLimit(1).minimumScaleFactor(0.2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Button { onKey?("copy") } label: {
                        LibraryIcon(name: "copy", size: min(metrics.compact ? 12 : 14, answerHeight - 4)).foregroundStyle(Color(vellixHex: settings.copyText)).frame(width: 20, height: min(20, answerHeight))
                            .background(Color(vellixHex: settings.copyBackground), in: RoundedRectangle(cornerRadius: 4))
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(vellixHex: settings.copyBorder)) }
                    }.buttonStyle(.plain).accessibilityLabel("Copy result")
                }.frame(height: answerHeight)
            }.padding(.horizontal, displayInset + 2).padding(.vertical, displayInset).frame(height: metrics.displayHeight)
                .background(Color(vellixHex: settings.displayBackground), in: RoundedRectangle(cornerRadius: CGFloat(settings.displayRadius)))
                .overlay { RoundedRectangle(cornerRadius: CGFloat(settings.displayRadius)).strokeBorder(Color(vellixHex: settings.displayBorder), lineWidth: CGFloat(settings.displayBorderWidth)) }
            VStack(spacing: metrics.keyGap) {
                ForEach(Self.keys.indices, id: \.self) { row in
                    HStack(spacing: metrics.keyGap) {
                        ForEach(Self.keys[row], id: \.self) { key in
                            let style = settings.style(for: key)
                            Button { onKey?(key) } label: {
                                Group {
                                    if key == "back" { Image(systemName: "delete.left") }
                                    else { Text(Self.label(key)) }
                                }.font(font(settings.buttonFont, size: min(settings.buttonSize, 16, max(8, Int((metrics.keyHeight - CGFloat(style.borderWidth) * 2 - 2) * 0.7))), weight: settings.buttonWeight))
                                    .lineLimit(1).minimumScaleFactor(0.35)
                                    .foregroundStyle(Color(vellixHex: style.text)).frame(maxWidth: .infinity)
                                    .frame(height: metrics.keyHeight)
                                    .background(Color(vellixHex: style.background), in: RoundedRectangle(cornerRadius: CGFloat(style.radius)))
                                    .overlay { RoundedRectangle(cornerRadius: CGFloat(style.radius)).strokeBorder(Color(vellixHex: style.border), lineWidth: CGFloat(style.borderWidth)) }
                            }.buttonStyle(.plain).accessibilityLabel(Self.accessibilityLabel(key))
                        }
                    }
                }
            }
          }
        }.allowsHitTesting(onKey != nil)
    }
}
