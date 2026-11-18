import AppKit
import Combine
import Foundation

@MainActor final class MacWindowRegistry {
    private final class Entry {
        let workspace: MacWorkspaceModel
        var editorObservation: AnyCancellable?
        init(_ workspace: MacWorkspaceModel) { self.workspace = workspace }
    }
    private var entries: [String: Entry] = [:]
    let editorChanges = PassthroughSubject<Void, Never>()
    weak var lastActive: MacWorkspaceModel?
    var workspaces: [MacWorkspaceModel] { entries.values.map(\.workspace).filter { $0.environment.database.isAccessible } }
    func existing(_ id: String, libraryID: String, ownerKey: String?) -> MacWorkspaceModel? {
        guard let workspace = entries[id]?.workspace, workspace.environment.database.libraryID == libraryID,
              workspace.ownerKey == ownerKey, workspace.environment.database.isAccessible else { return nil }
        return workspace
    }
    func register(_ workspace: MacWorkspaceModel) {
        let entry = Entry(workspace)
        entry.editorObservation = workspace.environment.$selectedDocumentID.removeDuplicates().dropFirst()
            .map { _ in () }
            .merge(with: workspace.$isBusy.dropFirst().filter { !$0 }.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.editorChanges.send() }
        entries[workspace.id] = entry; workspace.registry = self; lastActive = workspace
    }
    func unregister(_ id: String) { entries[id] = nil; editorChanges.send() }
    func flushAll() async throws { for workspace in workspaces { await workspace.waitForOperations(); try await workspace.flush() } }
    func closeLibraries() async throws {
        let windows = workspaces
        try await flushAll()
        for workspace in windows { try await workspace.environment.closeLibrary() }
    }
    func importChanges(_ apply: LibrarySyncEngine.ApplyIncoming, root: AppEnvironment) async throws -> Bool {
        let windows = workspaces.filter { $0.environment.database.libraryID == root.database.libraryID }
        guard root.database.isAccessible else { throw LibraryError.staleWorkspace }
        guard !root.isSwitchingSpace, windows.allSatisfy({ !$0.environment.isSwitchingSpace && !$0.isBusy }) else { return false }
        var protection = root.librarySyncProtection()
        for workspace in windows {
            protection.formUnion(workspace.environment.librarySyncProtection(alsoProtecting: workspace.activeTab.location.documentID))
        }
        if try apply(protection) {
            for environment in windows.map(\.environment) + [root] {
                try environment.reloadAfterLibraryImport(protectingEditorIDs: protection.documentIDs)
            }
            windows.forEach { $0.reconcile(preservingActiveEditor: true) }
        }
        return true
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
