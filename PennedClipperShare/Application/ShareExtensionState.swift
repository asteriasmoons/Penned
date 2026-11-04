import Foundation
import Observation

/// Observable state shared by the Share Extension's SwiftUI screens.
@MainActor
@Observable
final class ShareExtensionState {
    private let catalogueService = ClipperCatalogueService()

    private(set) var connection: ClipperConnection?
    var draft = ShareClipDraft()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var isSaved = false

    var spaces: [ClipperDestination] {
        guard let connection else { return [] }
        return catalogueService.spaces(in: connection)
    }

    var folders: [ClipperDestination] {
        guard let connection, !draft.spaceID.isEmpty else { return [] }
        return connection.folders.filter { $0.spaceID == draft.spaceID }
    }

    var tags: [ClipperDestination] {
        guard let connection, !draft.spaceID.isEmpty else { return [] }
        return catalogueService.tags(in: connection, spaceID: draft.spaceID)
    }

    var selectedSpace: ClipperDestination? {
        spaces.first { $0.id == draft.spaceID }
    }

    var selectedFolder: ClipperDestination? {
        folders.first { $0.id == draft.folderID }
    }

    var selectedTags: [ClipperDestination] {
        tags.filter { draft.tagIDs.contains($0.id) }
    }

    func loadCatalogue() {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try catalogueService.loadConnection()
            connection = loaded
            draft.sessionID = loaded.sessionID
            draft.spaceID = catalogueService.defaultSpaceID(in: loaded) ?? ""
            draft.folderID = nil
            draft.tagIDs = []
            errorMessage = nil
        } catch {
            connection = nil
            errorMessage = error.localizedDescription
        }
    }

    func selectSpace(_ spaceID: String) {
        guard spaces.contains(where: { $0.id == spaceID }) else { return }
        guard draft.spaceID != spaceID else { return }
        draft.spaceID = spaceID
        draft.folderID = nil
        draft.tagIDs = []
    }

    func selectFolder(_ folderID: String?) {
        guard let folderID else {
            draft.folderID = nil
            return
        }
        guard folders.contains(where: { $0.id == folderID }) else { return }
        draft.folderID = folderID
    }

    func toggleTag(_ tagID: String) {
        guard tags.contains(where: { $0.id == tagID }) else { return }
        if draft.tagIDs.contains(tagID) {
            draft.tagIDs.remove(tagID)
        } else {
            draft.tagIDs.insert(tagID)
        }
    }

    func folderBreadcrumbs() -> [ClipperDestination] {
        guard let connection, let folderID = draft.folderID else { return [] }
        return catalogueService.folderBreadcrumbs(for: folderID, in: connection)
    }

    func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
