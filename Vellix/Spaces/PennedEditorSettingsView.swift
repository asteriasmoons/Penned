import SwiftUI

enum PennedEditorPreferences {
    static let scrollToTopButtonKey = "penned.editor.showsScrollToTopButton"
}

struct PennedEditorSettingsView: View {
    @AppStorage(PennedEditorPreferences.scrollToTopButtonKey) private var showsScrollToTopButton = false

    var body: some View {
        ScrollView {
            Toggle(isOn: $showsScrollToTopButton) {
                Label { Text("Scroll to Top Button") } icon: { LibraryIcon(name: "upwavy", size: 21) }
            }
            .font(.system(.body, design: .rounded).weight(.black))
            .padding(16).frame(minHeight: 52).pennedSheetField()
            .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background {
            #if os(iOS)
            PadWorkspacePageBackground(fallback: VellixSurface.appBackground)
            #else
            VellixSurface.appBackground
            #endif
        }
        .foregroundStyle(VellixSurface.ink)
        .tint(VellixSurface.violet)
    }
}
