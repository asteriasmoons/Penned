#if os(iOS)
import SwiftUI

// The sheet belongs to the document, not the keyboard bar that disappears on blur.
struct InlineTextColorPresentation: ViewModifier {
    @Binding var request: InlineTextColorEditorRequest?
    @ObservedObject var session: TipTapEditorSession

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: { session.endTextColorEditing() }) { value in
            InlineTextColorSheet(request: value, session: session)
        }
        .onChange(of: session.isLoadingDocument) { _, loading in if loading { request = nil } }
        .onChange(of: session.isReady) { _, ready in if !ready { request = nil } }
        .onChange(of: session.selectionMode) { _, mode in if mode != "off" { request = nil } }
    }
}
#endif
