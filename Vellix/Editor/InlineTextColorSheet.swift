#if os(iOS)
import SwiftUI

struct InlineTextColorSheet: View {
    let request: InlineTextColorEditorRequest
    let session: TipTapEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: InlineTextColor.Kind
    @State private var start: String
    @State private var end: String
    @State private var angle: Double
    @State private var endpoint = 0
    @State private var colorPickerTarget: InlineTextColorPickerTarget?
    @State private var applying = false
    @State private var errorMessage: String?

    private let palette = ["#FFFFFF", "#121212", "#9C9CA6", "#BC76FF", "#8956E8", "#FF78B5",
        "#F15A70", "#FF9B60", "#FFD75E", "#67D59A", "#42C4D5", "#599DFF"]
    private let presets = [["#BC76FF", "#FF78B5"], ["#599DFF", "#67D59A"],
        ["#FF9B60", "#F15A70"], ["#42C4D5", "#BC76FF"]]

    init(request: InlineTextColorEditorRequest, session: TipTapEditorSession) {
        self.request = request
        self.session = session
        _mode = State(initialValue: request.initialColor?.kind ?? .solid)
        _start = State(initialValue: request.initialColor?.start ?? "#BC76FF")
        _end = State(initialValue: request.initialColor.flatMap { $0.kind == .gradient ? $0.end : nil } ?? "#FF78B5")
        _angle = State(initialValue: Double(request.initialColor?.angle ?? 90))
    }

    private var color: InlineTextColor? { InlineTextColor(kind: mode, start: start, end: end, angle: Int(angle)) }
    private var activeHex: Binding<String> {
        Binding(get: { mode == .gradient && endpoint == 1 ? end : start }, set: {
            if mode == .gradient && endpoint == 1 { end = $0 } else { start = $0 }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modeControl
                preview
                if mode == .gradient { gradientControls }
                colorPickerButton
                swatches
                hexField
                channels
                if let errorMessage { Text(errorMessage).foregroundStyle(VellixSurface.coral) }
                Button("Default Text Color") { apply(nil) }
                    .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.plain)
                    .foregroundStyle(PennedSheetStyle.accent)
            }
            .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            .disabled(applying)
        }
        .font(.system(.body, design: .rounded).weight(.bold))
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: "Text Color", closeDisabled: applying, close: { dismiss() }) {
            Button("Apply") { if let color { apply(color) } }
                .disabled(color == nil || applying)
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .interactiveDismissDisabled(applying)
        .sheet(item: $colorPickerTarget) { target in
            CardThreeModeColorPicker(selection: pickerSelection(target), title: target.title)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    private var modeControl: some View {
        HStack(spacing: 4) {
            ForEach(InlineTextColor.Kind.allCases, id: \.self) { kind in
                Button { mode = kind } label: {
                    Text(kind == .solid ? "Solid" : "Gradient")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(mode == kind ? PennedSheetStyle.accent.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(mode == kind ? .isSelected : [])
            }
        }.padding(4).pennedSheetField()
    }

    private var preview: some View {
        let text = Text(request.selectedText).font(.system(size: 23, weight: .bold, design: .rounded))
        return InlineTextColorSample(text: text, color: color)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 130, alignment: .center)
        .padding(12).pennedSheetField()
        .accessibilityLabel("Selected text preview: " + request.selectedText)
    }

    private var gradientControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                endpointButton(0, hex: start)
                Button { let previous = start; start = end; end = previous } label: {
                    LibraryIcon(name: "repeatarrows", size: 20).frame(width: 44, height: 44)
                }
                    .buttonStyle(.plain).accessibilityLabel("Swap Gradient Colors")
                endpointButton(1, hex: end)
            }
            HStack(spacing: 12) {
                ForEach(presets, id: \.self) { pair in
                    Button { start = pair[0]; end = pair[1] } label: {
                        Rectangle().fill(LinearGradient(colors: pair.map { Color(vellixHex: $0) }, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Gradient " + pair.joined(separator: " to "))
                }
            }
            HStack {
                Text("Angle").frame(width: 62, alignment: .leading)
                Slider(value: $angle, in: 0...359, step: 1).tint(PennedSheetStyle.accent)
                    .accessibilityLabel("Gradient Angle")
                Text("\(Int(angle))\u{00B0}").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func endpointButton(_ index: Int, hex: String) -> some View {
        Button {
            endpoint = index
            colorPickerTarget = index == 0 ? .start : .end
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(vellixHex: InlineTextColor.normalizedHex(hex) ?? "#FFFFFF")).frame(width: 24, height: 24)
                    .overlay(Circle().stroke(VellixSurface.controlInk.opacity(0.35)))
                Text(index == 0 ? "Start" : "End")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(endpoint == index ? PennedSheetStyle.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(endpoint == index ? .isSelected : [])
            .accessibilityLabel(index == 0 ? "Choose Gradient Start Color" : "Choose Gradient End Color")
    }

    private var colorPickerButton: some View {
        let target: InlineTextColorPickerTarget = mode == .solid ? .solid : (endpoint == 1 ? .end : .start)
        let hex = target == .end ? end : start
        return Button { colorPickerTarget = target } label: {
            HStack(spacing: 12) {
                Circle().fill(Color(vellixHex: InlineTextColor.normalizedHex(hex) ?? "#BC76FF"))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(AngularGradient(colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink], center: .center), lineWidth: 3))
                    .overlay(LibraryIcon(name: "colorpicker", size: 16))
                Text("Color Picker")
                Spacer(minLength: 8)
                LibraryIcon(name: "chevright", size: 16)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle()).pennedSheetField()
        }.buttonStyle(.plain).accessibilityLabel("Choose " + target.title)
    }

    private func pickerSelection(_ target: InlineTextColorPickerTarget) -> Binding<Color> {
        let hex: Binding<String> = target == .end ? $end : $start
        return Binding(get: {
            Color(vellixHex: InlineTextColor.normalizedHex(hex.wrappedValue) ?? "#BC76FF")
        }, set: { color in
            hex.wrappedValue = color.vellixHexString(fallback: hex.wrappedValue)
        })
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 8) {
            ForEach(palette, id: \.self) { hex in
                Button { activeHex.wrappedValue = hex } label: {
                    Circle().fill(Color(vellixHex: hex)).frame(width: 32, height: 32)
                        .overlay(Circle().stroke(VellixSurface.controlInk.opacity(0.4)))
                        .padding(4).overlay(Circle().stroke(InlineTextColor.normalizedHex(activeHex.wrappedValue) == hex ? PennedSheetStyle.accent : .clear, lineWidth: 2))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Text Color " + hex)
            }
        }
    }

    private var hexField: some View {
        HStack {
            Text("Hex")
            TextField("#RRGGBB", text: activeHex).textInputAutocapitalization(.characters)
                .autocorrectionDisabled().font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing).accessibilityLabel("Hex Color")
        }.padding(12).pennedSheetField()
    }

    private var channels: some View {
        VStack(spacing: 12) {
            channel("Red", shift: 16)
            channel("Green", shift: 8)
            channel("Blue", shift: 0)
        }
    }

    private func channel(_ name: String, shift: Int) -> some View {
        let binding = Binding<Double>(get: {
            let number = Int(InlineTextColor.normalizedHex(activeHex.wrappedValue)?.dropFirst() ?? "0", radix: 16) ?? 0
            return Double((number >> shift) & 255)
        }, set: { value in
            let number = Int(InlineTextColor.normalizedHex(activeHex.wrappedValue)?.dropFirst() ?? "0", radix: 16) ?? 0
            let updated = (number & ~(255 << shift)) | (Int(value) << shift)
            activeHex.wrappedValue = String(format: "#%06X", updated)
        })
        return HStack {
            Text(name).frame(width: 62, alignment: .leading)
            Slider(value: binding, in: 0...255, step: 1).tint(PennedSheetStyle.accent).accessibilityLabel(name)
            Text("\(Int(binding.wrappedValue))").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }

    private func apply(_ value: InlineTextColor?) {
        applying = true
        errorMessage = nil
        Task {
            do { try await session.applyTextColor(value, request: request); dismiss() }
            catch { errorMessage = error.localizedDescription }
            applying = false
        }
    }
}

private enum InlineTextColorPickerTarget: String, Identifiable {
    case solid, start, end

    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "Solid Color"
        case .start: return "Gradient Start Color"
        case .end: return "Gradient End Color"
        }
    }
}
#endif
