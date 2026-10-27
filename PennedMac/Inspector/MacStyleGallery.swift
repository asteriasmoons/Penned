import AppKit
import SwiftUI

struct MacStyleGallery: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var model: DocumentEditorModel
    @EnvironmentObject private var environment: AppEnvironment
    @State private var query = ""
    @State private var styles: [SavedDocumentStyle] = []
    @State private var editing: SavedDocumentStyle?
    @State private var name = ""
    @State private var deleting: SavedDocumentStyle?
    @State private var selectedStyleID: String?
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Style Gallery").font(.system(size: 16, weight: .heavy, design: .rounded))
                Spacer()
                MacIconButton("Close Style Gallery", icon: "xmarkwavy") { workspace.styleGalleryVisible = false }
            }
            TextField("Search Styles", text: $query).textFieldStyle(MacInputStyle())
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                    ForEach(styles.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { style in
                        if let definition = try? style.definition() {
                            Button {
                                workspace.perform {
                                    guard workspace.isAuthorized else { throw LibraryError.wrongOwner }
                                    let value = try environment.documentStyles.apply(style, to: model.documentID)
                                    model.updateAppearance(cover: value.cover, appearance: value.appearance)
                                    workspace.styleGalleryVisible = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    DocumentStyleThumbnail(title: style.title, definition: definition, store: environment.attachmentStore)
                                        .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.id == selectedStyleID ? VellixSurface.violet : .clear, lineWidth: 2))
                                    Text(style.title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(2).frame(height: 30, alignment: .top)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu {
                                if !style.isBuiltIn {
                                    Button("Rename") { name = style.title; editing = style }
                                    Button("Delete Style", role: .destructive) { deleting = style }
                                }
                            }
                        }
                    }
                }
            }
        }.padding(20).background(.regularMaterial).onAppear(perform: load)
        .macAlert("Rename Style", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Style Name", text: $name)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Rename") { if let style = editing { workspace.perform { try environment.documentStyles.rename(style, title: name); load() } }; editing = nil }
        }
        .macConfirmationDialog("Delete this saved style?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Style", role: .destructive) { if let style = deleting { workspace.perform { try environment.documentStyles.delete(style); load() } }; deleting = nil }
        }
    }
    private func load() {
        do {
            styles = try environment.documentStyles.all()
            selectedStyleID = try environment.documentStyles.matchingStyle(.init(appearance: model.appearance, cover: model.document?.cover), in: styles)?.id
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}

struct MacStyleGalleryPresenter: NSViewRepresentable {
    @ObservedObject var workspace: MacWorkspaceModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if workspace.styleGalleryVisible, let model = workspace.activeEditor {
            context.coordinator.show(model: model, environment: environment, parent: workspace.window, scheme: colorScheme)
        } else { context.coordinator.close() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let workspace: MacWorkspaceModel
        var panel: NSPanel?
        init(workspace: MacWorkspaceModel) { self.workspace = workspace }
        func show(model: DocumentEditorModel, environment: AppEnvironment, parent: NSWindow?, scheme: ColorScheme) {
            if let panel { panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); return }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Style Gallery"; panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.minSize = NSSize(width: 520, height: 420); panel.level = .floating
            panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            panel.contentView = NSHostingView(rootView: MacStyleGallery(workspace: workspace, model: model).environmentObject(environment).macApplicationControls())
            self.panel = panel
            if let parent { parent.addChildWindow(panel, ordered: .above); panel.setFrameOrigin(NSPoint(x: parent.frame.midX - 320, y: parent.frame.midY - 325)) }
            else { panel.center() }
            panel.makeKeyAndOrderFront(nil)
        }
        func close() { panel?.parent?.removeChildWindow(panel!); panel?.orderOut(nil); panel?.close(); panel = nil }
        func windowWillClose(_ notification: Notification) { panel = nil; workspace.styleGalleryVisible = false }
    }
}
