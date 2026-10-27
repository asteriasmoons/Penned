import SwiftUI

struct MacActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(configuration.role == .destructive ? VellixSurface.coral : VellixSurface.ink)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(configuration.isPressed ? VellixSurface.selection : VellixSurface.input, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(VellixSurface.hairline))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct MacInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(VellixSurface.hairline))
    }
}

struct MacToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Capsule().fill(configuration.isOn ? VellixSurface.violet : VellixSurface.subtleFill)
                    .overlay(Capsule().stroke(VellixSurface.hairline))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? VellixSurface.inverseInk : VellixSurface.secondaryInk).padding(3).frame(width: 22, height: 22)
                    }.frame(width: 36, height: 22)
            }.foregroundStyle(VellixSurface.ink).contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct MacOptionPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    @State private var expanded = false
    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title; _selection = selection; self.options = options; self.label = label
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Text(label(selection)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                LibraryIcon(name: "chevdown", size: 10).foregroundStyle(VellixSurface.secondaryInk)
            }.font(.system(size: 12, weight: .semibold, design: .rounded)).padding(.horizontal, 10).frame(minHeight: 32)
                .foregroundStyle(VellixSurface.ink).background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(VellixSurface.hairline))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(label(selection))
            .popover(isPresented: $expanded) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(options, id: \.self) { option in
                            Button { selection = option; expanded = false } label: {
                                HStack(spacing: 12) {
                                    Text(label(option)).frame(maxWidth: .infinity, alignment: .leading)
                                    LibraryIcon(name: "checkwavy", size: 13).opacity(selection == option ? 1 : 0)
                                }.padding(.horizontal, 10).frame(minHeight: 32).contentShape(Rectangle())
                                    .foregroundStyle(selection == option ? VellixSurface.violet : VellixSurface.ink)
                                    .background(selection == option ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
                        }
                    }.padding(8)
                }.frame(width: 230).frame(maxHeight: min(360, CGFloat(options.count) * 35 + 16)).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
    }
}

struct MacSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> String)?
    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String, icon: ((Value) -> String)? = nil) {
        self.title = title; _selection = selection; self.options = options; self.label = label; self.icon = icon
    }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Group {
                        if let icon { LibraryIcon(name: icon(option), size: 16) }
                        else { Text(label(option)).lineLimit(1) }
                    }.font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == option ? VellixSurface.violet : VellixSurface.secondaryInk)
                        .frame(maxWidth: .infinity).frame(minHeight: 29)
                        .background(selection == option ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(label(option)).accessibilityLabel(label(option))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.padding(3).background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct MacPopoverMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: { label.contentShape(Rectangle()) }.buttonStyle(.plain)
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 3) { content }
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).padding(8).frame(minWidth: 220)
                    .buttonStyle(MacMenuActionStyle { expanded = false })
                    .foregroundStyle(VellixSurface.ink)
            }
    }
}

private struct MacMenuActionStyle: PrimitiveButtonStyle {
    var close: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.trigger(); close() } label: {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(configuration.role == .destructive ? VellixSurface.coral : VellixSurface.ink)
    }
}

struct MacForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }.formStyle(.grouped).scrollContentBackground(.hidden).background(VellixSurface.appBackground)
    }
}

extension View {
    func macApplicationControls() -> some View {
        buttonStyle(MacActionButtonStyle()).textFieldStyle(MacInputStyle()).toggleStyle(MacToggleStyle())
    }
}
