//
//  AppEnvironment.swift
//  Vellix
//

import Foundation
import Combine
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case today
    case recents
    case favorites
    case allDocuments
    case spaces
    case templates
    case trash
    case search

    var id: String { rawValue }

    static let primaryCases: [AppDestination] = [
        .home,
        .today,
        .recents,
        .favorites,
        .allDocuments,
        .spaces,
        .templates
    ]

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .today:
            return "Today"
        case .recents:
            return "Recents"
        case .favorites:
            return "Starred"
        case .allDocuments:
            return "All Pages"
        case .spaces:
            return "Spaces"
        case .templates:
            return "Templates"
        case .trash:
            return "Trash"
        case .search:
            return "Search"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .home:
            return "house"
        case .today:
            return "calendar"
        case .recents:
            return "clock"
        case .favorites:
            return "star"
        case .allDocuments:
            return "doc.text"
        case .spaces:
            return "rectangle.stack"
        case .templates:
            return "square.on.square"
        case .trash:
            return "trash"
        case .search:
            return "magnifyingglass"
        }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let database: AppDatabase
    let documents: DocumentRepository
    let spaces: SpaceRepository
    let folders: FolderRepository
    let templates: TemplateRepository
    let snapshots: SnapshotRepository
    let search: DocumentSearchService
    let attachmentStore: AttachmentStore
    let attachments: AttachmentRepository

    @Published var overview = LibraryOverview()
    @Published var selectedDestination: AppDestination = .home
    @Published var selectedDocumentID: String?
    @Published var selectedSpaceID: String?
    @Published var selectedFolderID: String?
    @Published var isInspectorVisible = false
    @Published var errorMessage: String?

    init(database: AppDatabase, attachmentStore: AttachmentStore) {
        self.database = database
        self.attachmentStore = attachmentStore
        self.documents = DocumentRepository(database: database)
        self.spaces = SpaceRepository(database: database)
        self.folders = FolderRepository(database: database)
        self.templates = TemplateRepository(database: database)
        self.snapshots = SnapshotRepository(database: database)
        self.search = DocumentSearchService(database: database)
        self.attachments = AttachmentRepository(database: database, store: attachmentStore)
    }

    static func makeLive() -> AppEnvironment {
        do {
            let database = try AppDatabase.makeShared()
            let store = try AttachmentStore.liveStore()
            let environment = AppEnvironment(database: database, attachmentStore: store)
            try environment.bootstrap()
            return environment
        } catch {
            let fallbackDatabase = try! AppDatabase.makeInMemory()
            let environment = AppEnvironment(
                database: fallbackDatabase,
                attachmentStore: .previewStore()
            )
            environment.errorMessage = "Vellix started with an in-memory library because the local database could not open: \(error.localizedDescription)"
            try? environment.bootstrap()
            return environment
        }
    }

    static func makePreview() -> AppEnvironment {
        let database = try! AppDatabase.makeInMemory()
        let environment = AppEnvironment(
            database: database,
            attachmentStore: .previewStore()
        )
        try? environment.bootstrap(seedSampleData: true)
        return environment
    }

    func bootstrap(seedSampleData: Bool = false) throws {
        try templates.seedBuiltIns()
        if seedSampleData {
            let space = try spaces.create(title: "Writing Desk", description: "Drafts and long-form work")
            let folder = try folders.create(title: "Essays", spaceID: space.id)
            _ = try documents.create(
                DocumentDraft(
                    title: "A calm place to write",
                    subtitle: "Preview document",
                    spaceID: space.id,
                    folderID: folder.id,
                    blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(
                        title: "A calm place to write",
                        lines: ["This is a local-first Vellix document.", "Formatting is stored as BlockNote JSON."]
                    )
                )
            )
        }
        refresh()
    }

    func refresh() {
        do {
            overview = LibraryOverview(
                recent: try documents.recent(),
                favorites: try documents.favorites(),
                all: try documents.allDocuments(),
                trashed: try documents.trashed(),
                spaces: try spaces.all(),
                folders: try folders.all(),
                templates: try templates.all()
            )
        } catch {
            report(error)
        }
    }

    @discardableResult
    func createDocument(
        title: String = "Untitled",
        from template: TemplateRecord? = nil,
        spaceID: String? = nil,
        folderID: String? = nil,
        parentDocumentID: String? = nil
    ) -> DocumentRecord? {
        do {
            let sourceJSON = template?.blockNoteJSON ?? BlockNoteContentAnalyzer.emptyDocumentJSON
            let document = try documents.create(
                DocumentDraft(
                    title: title,
                    spaceID: spaceID,
                    folderID: folderID,
                    parentDocumentID: parentDocumentID,
                    templateOriginID: template?.id,
                    blockNoteJSON: sourceJSON
                )
            )
            selectedDocumentID = document.id
            refresh()
            return document
        } catch {
            report(error)
            return nil
        }
    }

    func createSpace() {
        do {
            let space = try spaces.create(title: "New Space")
            selectedDestination = .spaces
            selectedSpaceID = space.id
            refresh()
        } catch {
            report(error)
        }
    }

    func createFolder() {
        do {
            let folder = try folders.create(
                title: "New Folder",
                spaceID: selectedSpaceID
            )
            selectedFolderID = folder.id
            refresh()
        } catch {
            report(error)
        }
    }

    func select(_ document: DocumentRecord) {
        selectedDocumentID = document.id
        try? documents.markOpened(id: document.id)
        refresh()
    }

    func toggleFavoriteSelected() {
        guard let selectedDocumentID else {
            return
        }

        do {
            let document = try documents.requireDocument(id: selectedDocumentID)
            _ = try documents.setFavorite(id: document.id, isFavorite: !document.isFavorite)
            refresh()
        } catch {
            report(error)
        }
    }

    func duplicateSelected() {
        guard let selectedDocumentID else {
            return
        }

        do {
            let duplicate = try documents.duplicate(id: selectedDocumentID)
            self.selectedDocumentID = duplicate.id
            refresh()
        } catch {
            report(error)
        }
    }

    func trashSelected() {
        guard let selectedDocumentID else {
            return
        }

        do {
            _ = try documents.trash(id: selectedDocumentID)
            self.selectedDocumentID = nil
            refresh()
        } catch {
            report(error)
        }
    }

    func restore(_ document: DocumentRecord) {
        do {
            _ = try documents.restore(id: document.id)
            refresh()
        } catch {
            report(error)
        }
    }

    func permanentlyDelete(_ document: DocumentRecord) {
        do {
            try documents.permanentlyDelete(id: document.id, attachmentStore: attachmentStore)
            if selectedDocumentID == document.id {
                selectedDocumentID = nil
            }
            refresh()
        } catch {
            report(error)
        }
    }

    func emptyTrash() {
        do {
            for document in try documents.trashed() {
                try documents.permanentlyDelete(id: document.id, attachmentStore: attachmentStore)
            }
            refresh()
        } catch {
            report(error)
        }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
