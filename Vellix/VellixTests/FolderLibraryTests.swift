import Foundation
import Testing
@testable import Vellix

@MainActor
struct FolderLibraryTests {
    @Test func nestedFoldersPersistTheirOwnLibraryIconsAndColors() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let space = try SpaceRepository(database: db).create(title: "Workspace")
        let parent = try folders.create(title: "Parent", spaceID: space.id, icon: "openedfolder", iconColorHex: "#FFCC00")
        let child = try folders.create(title: "Child", parentFolderID: parent.id, icon: "doclineslove", iconColorHex: "#2EC5F4")
        let reopened = try folders.all().first { $0.id == child.id }
        #expect(reopened?.parentFolderID == parent.id)
        #expect(reopened?.spaceID == space.id)
        #expect(reopened?.icon == "doclineslove")
        #expect(reopened?.iconColorHex == "#2EC5F4")
        let edited = try folders.update(id: child.id, title: "Renamed", icon: "starfolder", iconColorHex: "#A78BFA")
        #expect(edited.title == "Renamed" && edited.icon == "starfolder")
        #expect(edited.parentFolderID == parent.id && edited.iconColorHex == "#A78BFA")
    }

    @Test func homeShowsOnlyParentsAndCountsImmediateChildrenAndPages() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let documents = DocumentRepository(database: db)
        let parent = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", parentFolderID: parent.id)
        let grandchild = try folders.create(title: "Grandchild", parentFolderID: child.id)
        let page = try documents.create(DocumentDraft(title: "Page", folderID: parent.id))
        _ = try documents.create(DocumentDraft(title: "Nested Page", folderID: parent.id, parentDocumentID: page.id))
        _ = try documents.create(DocumentDraft(title: "Child Page", folderID: child.id))
        let hierarchy = FolderHierarchy(folders: try folders.all())
        #expect(hierarchy.children(of: nil).map(\.id) == [parent.id])
        #expect(hierarchy.children(of: parent.id).map(\.id) == [child.id])
        #expect(hierarchy.path(to: grandchild.id).map(\.id) == [parent.id, child.id, grandchild.id])
        #expect(hierarchy.itemCount(in: parent.id, documents: try documents.editorDocuments()) == 2)
        #expect(hierarchy.itemCount(in: child.id, documents: try documents.allDocuments()) == 2)
    }

    @Test func folderCreationCancelDoesNotWriteAndBackReturnsToParent() throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        let parent = try environment.folders.create(title: "Parent")
        environment.refresh()
        environment.openFolder(parent.id)
        environment.createFolder()
        guard case .folder(let request) = environment.librarySheet else { Issue.record("Folder editor was not presented"); return }
        #expect(request.parentFolderID == parent.id)
        environment.librarySheet = nil
        #expect(try environment.folders.all().count == 1)
        try environment.saveFolder(request, title: "Child", icon: "starfolder", colorHex: "#2EC5F4")
        let child = try #require(environment.folders.all().first { $0.parentFolderID == parent.id })
        environment.openFolder(child.id)
        environment.returnFromFolder(child.id)
        #expect(environment.selectedFolderID == parent.id && environment.selectedDestination == .allDocuments)
        environment.returnFromFolder(parent.id)
        #expect(environment.selectedFolderID == nil && environment.selectedDestination == .home)
    }

    @Test func documentMovesPreserveNestedOwnershipContentAndIndependentThemes() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let documents = DocumentRepository(database: db)
        let source = try folders.create(title: "Source")
        let destination = try folders.create(title: "Destination")
        let page = try documents.create(DocumentDraft(title: "Page", folderID: source.id,
            appearanceJSON: DocumentAppearance.defaultForTheme(.neonCode).encodedJSON()))
        let nested = try documents.create(DocumentDraft(title: "Nested", folderID: source.id, parentDocumentID: page.id))
        try folders.move(documentIDs: [page.id], folderIDs: [], to: destination.id)
        let moved = try documents.requireDocument(id: page.id)
        let movedNested = try documents.requireDocument(id: nested.id)
        #expect(moved.folderID == destination.id && movedNested.folderID == destination.id)
        #expect(movedNested.parentDocumentID == page.id)
        #expect(moved.tipTapJSON == page.tipTapJSON && movedNested.tipTapJSON == nested.tipTapJSON)
        #expect(movedNested.appearanceJSON == nil)
        #expect(try documents.documents(inFolder: destination.id).map(\.id) == [page.id])
        try folders.move(documentIDs: [page.id], folderIDs: [], to: nil)
        #expect(try documents.requireDocument(id: page.id).folderID == nil)
        #expect(try documents.requireDocument(id: nested.id).parentDocumentID == page.id)
    }

    @Test func cyclesAndInvalidMixedMovesAreRejectedAtomically() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let parent = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", parentFolderID: parent.id)
        let other = try folders.create(title: "Other")
        #expect(throws: VellixError.self) { try folders.move(documentIDs: [], folderIDs: [parent.id], to: child.id) }
        #expect(throws: VellixError.self) { try folders.move(documentIDs: ["missing-page"], folderIDs: [parent.id], to: other.id) }
        let saved = try #require(folders.all().first { $0.id == parent.id })
        #expect(saved.parentFolderID == nil)
        #expect(throws: VellixError.self) { try folders.create(title: "Invalid", parentFolderID: "missing-folder") }
    }

    @Test func movingParentAndChildTogetherKeepsHierarchyAndUpdatesWorkspace() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let documents = DocumentRepository(database: db)
        let space = try SpaceRepository(database: db).create(title: "Destination Workspace")
        let parent = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", parentFolderID: parent.id)
        let destination = try folders.create(title: "Destination", spaceID: space.id)
        let page = try documents.create(DocumentDraft(title: "Page", folderID: child.id))
        let nested = try documents.create(DocumentDraft(title: "Nested", parentDocumentID: page.id))
        try folders.move(documentIDs: [page.id], folderIDs: [parent.id, child.id], to: destination.id)
        let saved = try folders.all()
        #expect(saved.first { $0.id == parent.id }?.parentFolderID == destination.id)
        #expect(saved.first { $0.id == child.id }?.parentFolderID == parent.id)
        #expect(saved.first { $0.id == child.id }?.spaceID == space.id)
        #expect(try documents.requireDocument(id: page.id).folderID == child.id)
        #expect(try documents.requireDocument(id: page.id).spaceID == space.id)
        #expect(try documents.requireDocument(id: nested.id).folderID == child.id)
        #expect(try documents.requireDocument(id: nested.id).spaceID == space.id)
        #expect(try documents.requireDocument(id: nested.id).parentDocumentID == page.id)
    }

    @Test func aChildAlwaysInheritsItsParentsWorkspaceIncludingTheDefault() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let space = try SpaceRepository(database: db).create(title: "Other Workspace")
        let parent = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", spaceID: space.id, parentFolderID: parent.id)
        #expect(child.spaceID == parent.spaceID)
        let documents = DocumentRepository(database: db)
        let page = try documents.create(DocumentDraft(title: "Page", spaceID: space.id))
        try folders.move(documentIDs: [page.id], folderIDs: [], to: parent.id)
        #expect(try documents.requireDocument(id: page.id).spaceID == parent.spaceID)
    }

    @Test func starsPersistAndCanBeRemoved() throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        let document = try environment.documents.create(DocumentDraft(title: "Starred Page"))
        environment.starDocuments([document.id])
        #expect(try environment.documents.requireDocument(id: document.id).isFavorite)
        #expect(environment.overview.favorites.contains { $0.id == document.id })
        environment.starDocuments([document.id], isFavorite: false)
        #expect(try !environment.documents.requireDocument(id: document.id).isFavorite)
        #expect(!environment.overview.favorites.contains { $0.id == document.id })
    }

    @Test func searchLocationsFollowTheNestedFolderPathAfterMoves() throws {
        let db = try AppDatabase.makeInMemory()
        let folders = FolderRepository(database: db)
        let parent = try folders.create(title: "Parent")
        let child = try folders.create(title: "Child", parentFolderID: parent.id)
        let other = try folders.create(title: "Other")
        _ = try DocumentRepository(database: db).create(DocumentDraft(title: "Budget", folderID: child.id))
        let search = DocumentSearchService(database: db)
        #expect(try search.search("Budget").first?.locationPath.hasSuffix("Parent / Child") == true)
        try folders.move(documentIDs: [], folderIDs: [child.id], to: other.id)
        #expect(try search.search("Budget").first?.locationPath.hasSuffix("Other / Child") == true)
    }
}
