import AppKit
import Foundation

@MainActor final class MacWindowRegistry {
    private final class Entry {
        let workspace: MacWorkspaceModel
        init(_ workspace: MacWorkspaceModel) { self.workspace = workspace }
    }
    private var entries: [String: Entry] = [:]
    weak var lastActive: MacWorkspaceModel?
    var workspaces: [MacWorkspaceModel] { entries.values.map(\.workspace).filter { $0.environment.database.isAccessible } }
    func existing(_ id: String, libraryID: String, ownerKey: String?) -> MacWorkspaceModel? {
        guard let workspace = entries[id]?.workspace, workspace.environment.database.libraryID == libraryID,
              workspace.ownerKey == ownerKey, workspace.environment.database.isAccessible else { return nil }
        return workspace
    }
    func register(_ workspace: MacWorkspaceModel) { entries[workspace.id] = Entry(workspace); workspace.registry = self; lastActive = workspace }
    func unregister(_ id: String) { entries[id] = nil }
    func flushAll() async throws { for workspace in workspaces { await workspace.waitForOperations(); try await workspace.flush() } }
    func closeLibraries() async throws {
        let windows = workspaces
        try await flushAll()
        for workspace in windows { try await workspace.environment.closeLibrary() }
    }
    func importChanges(_ apply: @escaping () throws -> Set<String>, root: AppEnvironment) async throws {
        let windows = workspaces.filter { $0.environment.database.libraryID == root.database.libraryID }
        let models = windows.flatMap { $0.environment.editorCache.preparedModels }
        let editable = models.map { $0.session.editingEnabled }
        models.forEach { $0.session.setEditable(false) }
        defer { for (index, model) in models.enumerated() { model.session.setEditable(editable[index]) } }
        for workspace in windows { await workspace.waitForOperations(); try await workspace.flush() }
        try await root.importLibraryChanges(apply)
        for workspace in windows {
            try await workspace.environment.importLibraryChanges { [] }
            workspace.reconcile()
        }
    }
    func focusDocument(_ id: String, except workspace: MacWorkspaceModel) -> Bool {
        guard let existing = workspaces.first(where: { $0 !== workspace && $0.ownerKey == workspace.ownerKey &&
            $0.environment.database.libraryID == workspace.environment.database.libraryID && $0.tabs.contains(where: { $0.location.documentID == id }) }),
              let tab = existing.tabs.first(where: { $0.location.documentID == id }) else { return false }
        existing.perform { try await existing.selectTab(tab.id); existing.window?.makeKeyAndOrderFront(nil) }
        return true
    }
    func refreshOthers(except source: AppEnvironment) {
        for workspace in workspaces where workspace.environment !== source { workspace.environment.refresh(); workspace.reconcile() }
    }
}
