import SwiftUI

private struct MacPrompt<Actions: View, Message: View>: View {
    let title: String
    @Binding var presented: Bool
    @ViewBuilder var actions: Actions
    @ViewBuilder var message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 16, weight: .heavy, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                MacIconButton("Close", icon: "xmarkwavy") { presented = false }
            }
            message.font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) { actions }
                .buttonStyle(MacPromptActionStyle { presented = false })
        }.padding(24).frame(width: 440, alignment: .leading)
            .foregroundStyle(VellixSurface.ink).background(VellixSurface.paperLifted).macApplicationControls()
            .onExitCommand { presented = false }
    }
}

private struct MacPromptActionStyle: PrimitiveButtonStyle {
    let close: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) { configuration.trigger(); close() } label: { configuration.label.frame(maxWidth: .infinity) }
            .buttonStyle(MacActionButtonStyle())
    }
}

extension View {
    func macAlert<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder message: @escaping () -> Message) -> some View {
        sheet(isPresented: isPresented) { MacPrompt(title: title, presented: isPresented, actions: actions, message: message) }
    }
    func macAlert<Actions: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        macAlert(title, isPresented: isPresented, actions: actions) { EmptyView() }
    }
    func macConfirmationDialog<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder message: @escaping () -> Message) -> some View {
        macAlert(title, isPresented: isPresented, actions: actions, message: message)
    }
    func macConfirmationDialog<Actions: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        macAlert(title, isPresented: isPresented, actions: actions)
    }
}
