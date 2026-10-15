//
//  AppEnvironment.swift
//  Vellix
//

import Foundation
import Combine
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case calendar
    case recents
    case favorites
    case allDocuments
    case folders
    case spaces
    case templates
    case trash

    var id: String { rawValue }

    static let primaryCases: [AppDestination] = [
        .home,
        .calendar,
        .recents,
        .favorites,
        .allDocuments,
        .folders,
        .spaces,
        .templates
    ]

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .calendar:
            return "Calendar"
        case .recents:
            return "Recents"
        case .favorites:
            return "Starred"
        case .allDocuments:
            return "All Docs"
        case .folders:
            return "Folders"
        case .spaces:
            return "Spaces"
        case .templates:
            return "Templates"
        case .trash:
            return "Trash"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .home:
            return "house"
        case .calendar:
            return "calendar"
        case .recents:
            return "clock"
        case .favorites:
            return "star"
        case .allDocuments:
            return "doc.text"
        case .folders:
            return "linesfolderfill"
        case .spaces:
            return "rectangle.stack"
        case .templates:
            return "square.on.square"
        case .trash:
            return "trash"
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
    let documentStyles: DocumentStyleRepository
    let snapshots: SnapshotRepository
    let search: DocumentSearchService
    let librarySearch: SearchModel
    let documentPreviews: DocumentPreviewCache
    let attachmentStore: AttachmentStore
    let attachments: AttachmentRepository
    let editorCache: DocumentEditorCache
    let tasks: DocumentTaskRepository
    let taskNotifications: TaskNotificationsManager
    let calendarEventNotes: CalendarEventNoteRepository
    let calendar: CalendarModel
    let collections: CollectionStore
    @Published private(set) var pendingDocumentID: String?
    private var pendingDocumentPresentation: AnyCancellable?
    private var pendingDocumentTimeout: Task<Void, Never>?
    private var pendingDocumentRequestID = UUID()

    @Published var overview = LibraryOverview()
    @Published var selectedDestination: AppDestination = .home {
        didSet { if oldValue != selectedDestination { cancelDocumentOpening() } }
    }
    @Published var selectedDocumentID: String? {
        didSet {
            pendingDocumentPresentation = nil
            pendingDocumentTimeout?.cancel()
            pendingDocumentTimeout = nil
            pendingDocumentID = nil
            pendingDocumentRequestID = UUID()
            if let id = selectedDocumentID {
                collections.watchDocument(id)
                editorCache.model(for: id)?.session.setCollections(collections.payloads(for: id))
            } else if let oldValue {
                documentPreviews.beginLibraryPresentation()
                collections.unwatchDocument(oldValue)
            }
        }
    }
    @Published var selectedSpaceID: String?
    @Published var selectedFolderID: String?
    @Published var isInspectorVisible = false
    @Published var errorMessage: String?
    @Published var isLibrarySearchRequested = false
    @Published var documentPendingDeletion: DocumentRecord?
    @Published var librarySheet: LibrarySheet?

    init(database: AppDatabase, attachmentStore: AttachmentStore) {
        let documents = DocumentRepository(database: database)
        let snapshots = SnapshotRepository(database: database)
        let search = DocumentSearchService(database: database)
        let collectionRepository = CollectionRepository(database: database, documents: documents)

        self.database = database
        let tasks = DocumentTaskRepository(database: database)
        let calendarNotes = CalendarEventNoteRepository(database: database, documents: documents)
        self.calendarEventNotes = calendarNotes
        self.calendar = CalendarModel(tasks: tasks, documents: documents, notes: calendarNotes, database: database)
        self.tasks = tasks
        self.taskNotifications = TaskNotificationsManager(repository: tasks, database: database)
        self.attachmentStore = attachmentStore
        self.documents = documents
        self.collections = CollectionStore(repository: collectionRepository, database: database)
        self.spaces = SpaceRepository(database: database)
        self.folders = FolderRepository(database: database)
        self.templates = TemplateRepository(database: database)
        self.documentStyles = DocumentStyleRepository(database: database, store: attachmentStore)
        self.snapshots = snapshots
        self.search = search
        self.librarySearch = SearchModel(service: search)
        self.documentPreviews = DocumentPreviewCache(documents: documents, attachments: attachmentStore, collections: collectionRepository)
        self.attachments = AttachmentRepository(database: database, store: attachmentStore)
        self.editorCache = DocumentEditorCache(
            documentRepository: documents,
            snapshotRepository: snapshots,
            attachmentStore: attachmentStore,
            collectionPayloads: { id in
                guard let document = try? documents.requireDocument(id: id),
                      let content = try? collectionRepository.previewContent(for: document, documents: documents) else { return [] }
                return content.payloads
            }
        )
        editorCache.onDocumentSaved = { [weak self] document in
            self?.documentPreviews.prewarm([document])
        }
        collections.onMetadataChanged = { [weak self] ids in
            guard let self else { return }
            for id in ids {
                guard let documentID = self.collections.snapshots[id]?.record.documentID else { continue }
                var current = try? self.documents.requireDocument(id: documentID)
                var visited = Set<String>()
                while let document = current, document.templateID != nil, visited.insert(document.id).inserted {
                    self.editorCache.model(for: document.id)?.noteTemplateChange()
                    current = document.parentDocumentID.flatMap { try? self.documents.requireDocument(id: $0) }
                }
            }
        }
        taskNotifications.openDocument = { [weak self] id in
            guard let self, let document = try? self.documents.requireDocument(id: id), !document.isTrashed else { return }
            self.editorCache.prepare(document)
            self.select(document)
        }
        calendar.completeTask = { [weak self] id, occurrenceID, completed in
            guard let self else { throw DocumentTaskError.missingTask }
            try await self.setTaskCompleted(id: id, completed: completed, expectedOccurrenceID: occurrenceID)
        }
    }

    static func makeLive() throws -> AppEnvironment {
        let database = try AppDatabase.makeShared()
        let store = try AttachmentStore.liveStore()
        let environment = AppEnvironment(database: database, attachmentStore: store)
        try environment.bootstrap()
        environment.taskNotifications.refresh()
        return environment
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
        if seedSampleData {
            let space = try spaces.create(title: "Writing Desk", description: "Drafts and long-form work")
            let folder = try folders.create(title: "Essays", spaceID: space.id)
            _ = try documents.create(
                DocumentDraft(
                    title: "A calm place to write",
                    subtitle: "Preview document",
                    spaceID: space.id,
                    folderID: folder.id,
                    tipTapJSON: TipTapContentAnalyzer.starterDocument(
                        title: "A calm place to write",
                        lines: ["This is a local-first Vellix document.", "Formatting is stored as TipTap JSON."]
                    )
                )
            )
        }
        refresh()
    }

    func refresh() {
        do {
            let nextOverview = LibraryOverview(
                recent: try documents.recent(),
                favorites: try documents.favorites(),
                all: try documents.allDocuments(),
                trashed: try documents.trashed(),
                spaces: try spaces.all(),
                folders: try folders.all(),
                templates: try templates.all()
            )
            let existingIDs = try documents.existingDocumentIDs()
            for model in editorCache.preparedModels where !existingIDs.contains(model.documentID) {
                editorCache.remove(documentID: model.documentID)
            }
            if let selectedDocumentID, !existingIDs.contains(selectedDocumentID) {
                self.selectedDocumentID = nil
            }
            if let pendingDocumentID, !existingIDs.contains(pendingDocumentID) { cancelDocumentOpening() }
            let prepared = try editorCache.preparedModels.compactMap { try documents.document(id: $0.documentID) }
            editorCache.prepare(prepared)
            if editorCache.preparedModels.isEmpty {
                let ids = DocumentEditorWarmupPolicy.documentIDs(recent: nextOverview.recent, selectedID: selectedDocumentID)
                for id in ids { editorCache.prepare(try documents.requireDocument(id: id)) }
            }
            overview = nextOverview
            let recentIDs = Set(nextOverview.recent.map(\.id))
            documentPreviews.prewarm(nextOverview.recent + nextOverview.favorites.prefix(5).filter { !recentIDs.contains($0.id) })
            librarySearch.refresh()
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
            let sourceJSON = template?.tipTapJSON ?? TipTapContentAnalyzer.emptyDocumentJSON
            let folder = folderID.flatMap { id in overview.folders.first { $0.id == id } }
            let document: DocumentRecord
            if let template {
                for model in editorCache.preparedModels where model.document?.templateID == template.id {
                    try model.saveCurrentContent()
                }
                document = try templates.instantiate(id: template.id, title: title,
                    spaceID: folder == nil ? spaceID : folder?.spaceID, folderID: folderID,
                    parentID: parentDocumentID, attachmentStore: attachmentStore)
            } else {
                document = try documents.create(
                DocumentDraft(
                    title: title,
                    spaceID: folder == nil ? spaceID : folder?.spaceID,
                    folderID: folderID,
                    parentDocumentID: parentDocumentID,
                    templateOriginID: template?.id,
                    tipTapJSON: sourceJSON
                )
            )
            }
            editorCache.prepare(document)
            refresh()
            select(document)
            return document
        } catch {
            report(error)
            return nil
        }
    }

    func createTemplate() {
        do {
            let document = try templates.create()
            editorCache.prepare(document)
            refresh()
            selectedDestination = .templates
            select(document)
        } catch { report(error) }
    }

    func editTemplate(_ template: TemplateRecord) {
        do {
            let document = try templates.editingDocument(id: template.id, attachmentStore: attachmentStore)
            editorCache.prepare(document)
            selectedDestination = .templates
            select(document)
        } catch { report(error) }
    }

    func saveAsTemplate(_ document: DocumentRecord) {
        do {
            if let model = editorCache.model(for: document.id) { try model.saveCurrentContent() }
            let current = try documents.requireDocument(id: document.id)
            let template = try templates.saveUserTemplate(from: current, title: current.title, attachmentStore: attachmentStore)
            refresh()
            editTemplate(template)
        } catch { report(error) }
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
        requestFolderCreation(parentFolderID: selectedDestination == .allDocuments && selectedFolderID != "__unsorted" ? selectedFolderID : nil)
    }

    func requestFolderCreation(parentFolderID: String?) {
        let parent = overview.folders.first { $0.id == parentFolderID }
        librarySheet = .folder(FolderEditorRequest(folder: nil, parentFolderID: parentFolderID,
            spaceID: parent == nil ? (selectedDestination == .spaces ? selectedSpaceID : nil) : parent?.spaceID))
    }

    func editFolder(_ folder: FolderRecord) {
        librarySheet = .folder(FolderEditorRequest(folder: folder, parentFolderID: folder.parentFolderID, spaceID: folder.spaceID))
    }

    func saveFolder(_ request: FolderEditorRequest, title: String, icon: String, colorHex: String) throws {
        guard title.trimmedNonEmpty != nil, VellixAssetIconLibrary.names.contains(icon) else {
            throw VellixError.impossibleMove("Choose a folder name and an icon from your library.")
        }
        if let folder = request.folder {
            _ = try folders.update(id: folder.id, title: title, icon: icon, iconColorHex: colorHex)
        } else {
            _ = try folders.create(title: title, spaceID: request.spaceID, parentFolderID: request.parentFolderID,
                icon: icon, iconColorHex: colorHex)
        }
        refresh()
    }

    func openFolder(_ id: String?) {
        selectedDocumentID = nil
        selectedFolderID = id
        if let folder = overview.folders.first(where: { $0.id == id }) { selectedSpaceID = folder.spaceID }
        selectedDestination = .allDocuments
    }

    func returnFromFolder(_ id: String?) {
        if let parentID = overview.folders.first(where: { $0.id == id })?.parentFolderID {
            openFolder(parentID)
        } else {
            selectedFolderID = nil
            selectedDestination = .home
        }
    }

    func requestMove(documentIDs: Set<String> = [], folderIDs: Set<String> = []) {
        guard !documentIDs.isEmpty || !folderIDs.isEmpty else { return }
        librarySheet = .move(LibraryMoveRequest(documentIDs: documentIDs, folderIDs: folderIDs))
    }

    func moveLibraryItems(_ request: LibraryMoveRequest, to folderID: String?) throws {
        try folders.move(documentIDs: request.documentIDs, folderIDs: request.folderIDs, to: folderID)
        refresh()
    }

    func select(_ document: DocumentRecord) {
        cancelDocumentOpening()
        guard let current = try? documents.document(id: document.id), !current.isTrashed else { return }
        let model = editorCache.prepare(current)
        if !model.session.isPresentationReady { model.session.bridgeErrorMessage = nil }
        pendingDocumentID = document.id
        finishDocumentOpening(model, document: current)
        guard pendingDocumentID == document.id else { return }
        let requestID = pendingDocumentRequestID
        pendingDocumentTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.pendingDocumentRequestID == requestID, self.pendingDocumentID == document.id else { return }
            self.cancelDocumentOpening()
            self.errorMessage = "This page could not be prepared. Please try opening it again."
        }
    }

    private func finishDocumentOpening(_ model: DocumentEditorModel, document: DocumentRecord) {
        guard pendingDocumentID == document.id else { return }
        do {
            let current = try documents.requireDocument(id: document.id)
            guard !current.isTrashed else { cancelDocumentOpening(); return }
            let content = try collections.repository.previewContent(for: current, documents: documents)
            model.session.setCollections(content.payloads, preparingForDisplay: true)
        } catch {
            cancelDocumentOpening()
            report(error)
            return
        }
        if model.session.isPresentationReady {
            selectedDocumentID = document.id
            let documents = documents, documentID = document.id
            Task.detached(priority: .utility) { try? documents.markOpened(id: documentID) }
        } else {
            let requestID = pendingDocumentRequestID
            pendingDocumentPresentation = Publishers.CombineLatest(model.session.$isPresentationReady, model.session.$bridgeErrorMessage)
                .filter { $0 || $1 != nil }.first().receive(on: DispatchQueue.main)
                .sink { [weak self] ready, error in
                    guard let self, self.pendingDocumentRequestID == requestID, self.pendingDocumentID == document.id else { return }
                    if ready { self.finishDocumentOpening(model, document: document) }
                    else {
                        self.cancelDocumentOpening()
                        self.errorMessage = error
                    }
                }
        }
    }

    private func cancelDocumentOpening() {
        pendingDocumentPresentation = nil
        pendingDocumentTimeout?.cancel()
        pendingDocumentTimeout = nil
        pendingDocumentID = nil
        pendingDocumentRequestID = UUID()
    }

    func setTaskCompleted(id: String, completed: Bool, expectedOccurrenceID: String? = nil) async throws {
        guard let task = try tasks.all(includeTemplates: true).first(where: { $0.id == id }) else {
            throw DocumentTaskError.missingTask
        }
        let model = editorCache.model(for: task.documentID)
        if let model {
            if model.session.isLoadingDocument { try model.saveCurrentContent() }
            else { try await model.captureAndSave() }
        }
        guard let current = try tasks.all(includeTemplates: true).first(where: { $0.id == id }) else {
            throw DocumentTaskError.missingTask
        }
        if let expectedOccurrenceID, expectedOccurrenceID != current.metadata.occurrenceID { throw DocumentTaskError.staleOccurrence }
        let saved = try tasks.setCompleted(taskID: id, occurrenceID: current.metadata.occurrenceID, completed: completed)
        editorCache.model(for: current.documentID)?.receiveExternalTaskChange(saved)
        refresh()
        await taskNotifications.flush()
    }

    func openCalendarDocument(_ document: DocumentRecord) {
        do {
            let current = try documents.requireDocument(id: document.id)
            guard !current.isTrashed else { throw VellixError.impossibleMove("Restore this event note from Trash before opening it.") }
            editorCache.prepare(current)
            select(current)
        } catch { report(error) }
    }

    func createEventNote(for event: CalendarEvent) throws -> DocumentRecord {
        let document = try calendarEventNotes.createOrFind(for: event)
        editorCache.prepare(document)
        refresh()
        calendar.refresh()
        return document
    }

    func returnFromDocument(_ document: DocumentRecord) {
        if let parentID = document.parentDocumentID,
           let parent = editorCache.model(for: parentID)?.document ?? (try? documents.document(id: parentID)),
           !parent.isTrashed {
            select(parent)
        } else {
            selectedDocumentID = nil
            if document.templateID != nil { selectedDestination = .templates }
            refresh()
        }
    }

    func focusLibrarySearch() {
        selectedDocumentID = nil
        selectedDestination = .home
        selectedFolderID = nil
        isLibrarySearchRequested = true
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

    func starDocuments(_ ids: Set<String>, isFavorite: Bool = true) {
        defer { refresh() }
        do {
            for id in ids { _ = try documents.setFavorite(id: id, isFavorite: isFavorite) }
        } catch { report(error) }
    }

    @discardableResult
    func trashDocuments(_ ids: Set<String>) -> Set<String> {
        var moved: Set<String> = []
        defer { refresh() }
        do {
            for id in ids {
                _ = try documents.trash(id: id)
                moved.insert(id)
            }
        } catch { report(error) }
        return moved
    }

    func duplicateSelected() {
        guard let selectedDocumentID else {
            return
        }

        do {
            if let document = editorCache.model(for: selectedDocumentID)?.document,
               let templateID = document.templateID, document.parentDocumentID == nil {
                try editorCache.model(for: selectedDocumentID)?.saveCurrentContent()
                let copy = try templates.duplicate(id: templateID, attachmentStore: attachmentStore)
                refresh()
                editTemplate(copy)
                return
            }
            let duplicate = try documents.duplicate(id: selectedDocumentID, attachmentStore: attachmentStore)
            editorCache.prepare(duplicate)
            self.select(duplicate)
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
            let document = try documents.requireDocument(id: selectedDocumentID)
            if document.templateID != nil && document.parentDocumentID == nil {
                documentPendingDeletion = document
                return
            }
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
            if let templateID = document.templateID, document.parentDocumentID == nil {
                try templates.delete(id: templateID, attachmentStore: attachmentStore)
            } else {
                try documents.permanentlyDelete(id: document.id, attachmentStore: attachmentStore)
            }
            editorCache.remove(documentID: document.id)
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
                editorCache.remove(documentID: document.id)
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
