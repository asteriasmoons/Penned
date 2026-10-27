import AppKit
import SwiftUI

struct MacWorkspaceCommands: Commands {
    @FocusedObject private var workspace: MacWorkspaceModel?
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Document") { workspace?.createDocument() }.keyboardShortcut("n").disabled(workspace == nil)
            Button("New Tab") { workspace?.perform { try await workspace?.newTab() } }.keyboardShortcut("t").disabled(workspace == nil)
            Button("New Window") { openWindow(id: "workspace") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button((workspace?.tabs.count ?? 0) > 1 ? "Close Tab" : "Close Window") {
                if let workspace, workspace.tabs.count > 1 {
                    workspace.perform { try await workspace.closeTab(workspace.activeID) }
                } else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
            Button("Close Workspace Window") { workspace?.window?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(workspace == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.perform { try await workspace?.flush() } }.keyboardShortcut("s").disabled(workspace == nil)
            Button("Save as Template") { if let document = workspace?.activeEditor?.document { workspace?.environment.saveAsTemplate(document) } }
                .disabled(workspace?.activeEditor == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { edit("undo:") { $0.undo() } }.keyboardShortcut("z")
            Button("Redo") { edit("redo:") { $0.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Page") {
                if workspace?.activeEditor != nil { workspace?.findInDocument.toggle() }
                else { workspace?.activeTab.browser.query = ""; workspace?.environment.isLibrarySearchRequested = true }
            }.keyboardShortcut("f").disabled(workspace == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Navigation Sidebar") { workspace?.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control]).disabled(workspace == nil)
            Button("Toggle Document Inspector") { workspace?.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option]).disabled(workspace?.canShowInspector != true)
            Divider()
            Button("Next Tab") { selectAdjacentTab(1) }.keyboardShortcut(.tab, modifiers: .control).disabled((workspace?.tabs.count ?? 0) < 2)
            Button("Previous Tab") { selectAdjacentTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled((workspace?.tabs.count ?? 0) < 2)
        }
        CommandMenu("Document") {
            Button("Back") { workspace?.perform { try await workspace?.travel(-1) } }.keyboardShortcut("[").disabled(workspace?.canGoBack != true)
            Button("Forward") { workspace?.perform { try await workspace?.travel(1) } }.keyboardShortcut("]").disabled(workspace?.canGoForward != true)
            Divider()
            Button("Toggle Star") { workspace?.environment.toggleFavoriteSelected() }.disabled(workspace?.activeEditor == nil)
            Button("Version History") { workspace?.showHistory = true }.disabled(workspace?.activeEditor == nil)
            Button("Style Gallery") { workspace?.styleGalleryVisible = true }.disabled(workspace?.activeEditor == nil)
        }
    }
    private func edit(_ selector: String, command: (TipTapEditorSession) -> Void) {
        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(selector), to: nil, from: nil) }
        else if let session = workspace?.activeEditor?.session { command(session) }
    }
    private func selectAdjacentTab(_ direction: Int) {
        guard let workspace, let index = workspace.tabs.firstIndex(where: { $0.id == workspace.activeID }) else { return }
        let next = (index + direction + workspace.tabs.count) % workspace.tabs.count
        workspace.perform { try await workspace.selectTab(workspace.tabs[next].id) }
    }
}
