import AppKit
import SwiftUI

struct MacWindowBridge: NSViewRepresentable {
    @ObservedObject var workspace: MacWorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            workspace.window = window
            if window.delegate !== context.coordinator {
                context.coordinator.previous = window.delegate
                window.delegate = context.coordinator
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var previous: NSWindowDelegate?
        let workspace: MacWorkspaceModel
        private var closing = false
        private var allowed = false
        init(workspace: MacWorkspaceModel) { self.workspace = workspace }
        func windowDidBecomeKey(_ notification: Notification) {
            workspace.registry?.lastActive = workspace
            previous?.windowDidBecomeKey?(notification)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowed { return previous?.windowShouldClose?(sender) ?? true }
            guard !closing else { return false }
            closing = true
            Task {
                do {
                    await workspace.waitForOperations()
                    try await workspace.flush()
                    try await workspace.environment.closeLibrary()
                    workspace.registry?.unregister(workspace.id)
                    allowed = true; sender.performClose(nil)
                } catch { closing = false; workspace.errorMessage = error.localizedDescription }
            }
            return false
        }
    }
}
