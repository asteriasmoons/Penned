import AppKit
import SwiftUI

@MainActor enum MacColorValue {
    static func hex(_ color: Color) -> String {
        let color = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return String(format: "#%02X%02X%02X", byte(color.redComponent * 255), byte(color.greenComponent * 255), byte(color.blueComponent * 255))
    }
    static func validatedHex(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^#?[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return "#" + value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    }
    static func color(red: Double, green: Double, blue: Double) -> Color { Color(red: Double(byte(red)) / 255, green: Double(byte(green)) / 255, blue: Double(byte(blue)) / 255) }
    private static func byte(_ value: Double) -> Int { value.isFinite ? Int(min(255, max(0, value)).rounded()) : 0 }
}

struct MacColorRow: View {
    let title: String
    @Binding var selection: Color
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                RoundedRectangle(cornerRadius: 6).fill(selection).frame(width: 34, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(VellixSurface.hairline))
            }.foregroundStyle(VellixSurface.ink).padding(.horizontal, 10).frame(minHeight: 36)
                .background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(MacColorValue.hex(selection))
            .popover(isPresented: $expanded) { CardThreeModeColorPicker(selection: $selection, title: title, embedded: true).frame(width: 308) }
    }
}

struct MacFontOptions: View {
    @Binding var selection: DocumentFontStyle
    var body: some View {
        HStack(spacing: 6) {
            ForEach(DocumentFontStyle.allCases) { font in
                Button { selection = font } label: {
                    Text(font.sample).font(.system(size: 19, weight: .medium, design: font.design))
                        .foregroundStyle(selection == font ? VellixSurface.violet : VellixSurface.ink)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(selection == font ? VellixSurface.selection : VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help(font.title).accessibilityLabel(font.title).accessibilityAddTraits(selection == font ? .isSelected : [])
            }
        }
    }
}

struct MacGradientDirectionControl: View {
    @Binding var selection: DocumentGradientDirection
    var start: Color
    var end: Color
    var body: some View {
        HStack(spacing: 8) {
            ForEach(DocumentGradientDirection.allCases) { direction in
                Button { selection = direction } label: {
                    RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [start, end], startPoint: direction.startPoint, endPoint: direction.endPoint))
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selection == direction ? VellixSurface.violet : VellixSurface.hairline, lineWidth: selection == direction ? 2 : 1))
                }.buttonStyle(.plain).help(direction.title).accessibilityLabel(direction.title).accessibilityAddTraits(selection == direction ? .isSelected : [])
            }
        }
    }
}
