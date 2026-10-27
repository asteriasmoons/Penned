import AppKit
import SwiftUI

struct CardThreeModeColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Color
    var title: String
    var embedded = false
    @State private var mode = "Palette"
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var brightness = 1.0
    @State private var red = 255.0
    @State private var green = 255.0
    @State private var blue = 255.0
    @State private var hex = "#FFFFFF"
    private let palette = ["#FFFFFF", "#D5D5DA", "#85858F", "#343434", "#242424", "#000000",
        "#FFD6A8", "#FFC700", "#559EFA", "#2545B6", "#07BBA8", "#075442", "#007994", "#FF7300",
        "#C00016", "#FFC6C7", "#C6B0F7", "#A970FF", "#FF5CAA", "#2EC5F4", "#5B8CFF", "#FF9F43", "#FFD84D", "#52D273"]
    var body: some View {
        Group {
            if embedded { controls.padding(16) }
            else { controls.padding(22).frame(maxWidth: 400).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).pennedSheet(title: title, close: { dismiss() }) }
        }.fontDesign(.rounded).tint(VellixSurface.violet).onAppear(perform: readSelection)
            .onChange(of: selection) { _, _ in readSelection() }
    }
    private var controls: some View {
        VStack(spacing: 16) {
            if embedded { HStack { Text(title).font(.headline); Spacer() } }
            HStack(spacing: 3) {
                ForEach(["Palette", "Spectrum", "RGB"], id: \.self) { option in
                    Button { mode = option } label: {
                        Text(option).font(.system(size: 11, weight: .bold, design: .rounded)).frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(mode == option ? VellixSurface.violet : VellixSurface.secondaryInk)
                            .background(mode == option ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }.padding(3).background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            Group {
                switch mode {
                case "Palette":
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                        ForEach(palette, id: \.self) { value in
                            Button { selection = Color(vellixHex: value) } label: {
                                Circle().fill(Color(vellixHex: value)).frame(width: 29, height: 29)
                                    .overlay(Circle().stroke(VellixSurface.hairline))
                                    .overlay {
                                        if value == MacColorValue.hex(selection) {
                                            Circle().stroke(VellixSurface.violet, lineWidth: 2).padding(-3)
                                            LibraryIcon(name: "checkwavy", size: 13).foregroundStyle(value == "#FFFFFF" ? .black : .white)
                                        }
                                    }.frame(width: 36, height: 36)
                            }.buttonStyle(.plain).help(value).accessibilityLabel("Color " + value)
                                .accessibilityAddTraits(value == MacColorValue.hex(selection) ? .isSelected : [])
                        }
                    }
                case "Spectrum": spectrum
                default:
                    VStack(spacing: 16) {
                        channel("Red", value: $red, tint: .red)
                        channel("Green", value: $green, tint: .green)
                        channel("Blue", value: $blue, tint: .blue)
                    }
                }
            }.frame(height: 184, alignment: .top)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6).fill(selection).frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(VellixSurface.hairline))
                TextField("Hex", text: $hex).font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain)
                    .onSubmit { applyHex() }
                Button("Apply") { applyHex() }.disabled(MacColorValue.validatedHex(hex) == nil)
            }.padding(8).background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private var spectrum: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing))
                    .overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        Circle().stroke(.white, lineWidth: 2).background(Circle().stroke(.black, lineWidth: 1))
                            .frame(width: 12, height: 12).position(x: saturation * proxy.size.width, y: (1 - brightness) * proxy.size.height)
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        saturation = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        brightness = 1 - min(1, max(0, value.location.y / max(1, proxy.size.height)))
                        commitSpectrum()
                    })
                    .accessibilityLabel("Saturation and Brightness")
                    .accessibilityValue("\(Int(saturation * 100)) percent saturation, \(Int(brightness * 100)) percent brightness")
                    .accessibilityAdjustableAction { direction in
                        brightness = min(1, max(0, brightness + (direction == .increment ? 0.05 : -0.05))); commitSpectrum()
                    }
            }
            MacSlider(value: Binding(get: { hue }, set: { hue = $0; commitSpectrum() }), in: 0...1)
                .tint(Color(hue: hue, saturation: 1, brightness: 1)).accessibilityLabel("Hue")
        }
    }
    private func channel(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack {
            Text(title).font(.caption.weight(.bold)).frame(width: 38, alignment: .leading)
            MacSlider(value: Binding(get: { value.wrappedValue }, set: { next in
                value.wrappedValue = next; selection = MacColorValue.color(red: red, green: green, blue: blue)
            }), in: 0...255, step: 1).tint(tint).accessibilityLabel(title)
            Text(String(Int(value.wrappedValue))).font(.system(size: 11, design: .monospaced)).frame(width: 28, alignment: .trailing)
        }
    }
    private func applyHex() {
        if let value = MacColorValue.validatedHex(hex) { selection = Color(vellixHex: value) }
        else { hex = MacColorValue.hex(selection) }
    }
    private func commitSpectrum() { selection = Color(hue: hue, saturation: saturation, brightness: brightness) }
    private func readSelection() {
        let color = NSColor(selection).usingColorSpace(.deviceRGB) ?? .white
        red = color.redComponent * 255; green = color.greenComponent * 255; blue = color.blueComponent * 255
        if color.saturationComponent > 0.001 { hue = color.hueComponent }
        saturation = color.saturationComponent; brightness = color.brightnessComponent
        hex = MacColorValue.hex(selection)
    }
}
