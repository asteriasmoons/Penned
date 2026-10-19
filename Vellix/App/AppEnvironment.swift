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
    case tags
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
        .templates,
        .tags
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
        case .tags: return "All Tags"
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
        case .tags: return "hashtagwavy"
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
    let dailyNotes: DailyNoteRepository
    let tags: DocumentTagRepository
    @Published var selectedTagIDs: Set<String> = []
    @Published var tagNavigationTarget: TagNavigationTarget?
    @Published private(set) var dailyNoteOnlyTemplateIDs: Set<String> = []
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
    @Published private(set) var selectedSpaceID: String?
    @Published private(set) var isSwitchingSpace = false {
        didSet {
            if !isSwitchingSpace {
                let waiters = workspaceWaiters; workspaceWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
    }
    private var workspaceWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var allSpaces: [SpaceRecord] = []
    @Published var spaceSheet: SpaceSheet?
    @Published var isSettingsPresented = false
    private let preferences: UserDefaults
    private let persistsSpaceSelection: Bool
    private var workspaceGeneration = 0
    @Published var selectedFolderID: String?
    @Published var isInspectorVisible = false
    @Published var errorMessage: String?
    @Published var isLibrarySearchRequested = false
    @Published var documentPendingDeletion: DocumentRecord?
    @Published var librarySheet: LibrarySheet?

    private let createsDefaultSpace: Bool

    init(database: AppDatabase, attachmentStore: AttachmentStore, preferences: UserDefaults? = nil, createsDefaultSpace: Bool = true) {
        self.createsDefaultSpace = createsDefaultSpace
        self.preferences = preferences ?? .standard
        self.persistsSpaceSelection = preferences != nil || !database.isInMemory
        let documents = DocumentRepository(database: database)
        let templates = TemplateRepository(database: database)
        let dailyNotes = DailyNoteRepository(database: database, templates: templates)
        let snapshots = SnapshotRepository(database: database)
        let search = DocumentSearchService(database: database)
        let collectionRepository = CollectionRepository(database: database, documents: documents)

        self.database = database
        self.tags = DocumentTagRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        let calendarNotes = CalendarEventNoteRepository(database: database, documents: documents)
        self.calendarEventNotes = calendarNotes
        self.calendar = CalendarModel(tasks: tasks, documents: documents, notes: calendarNotes, database: database, dailyNotes: dailyNotes)
        self.tasks = tasks
        self.taskNotifications = TaskNotificationsManager(repository: DocumentTaskRepository(database: database), database: database)
        self.attachmentStore = attachmentStore
        self.documents = documents
        self.collections = CollectionStore(repository: collectionRepository, database: database)
        self.spaces = SpaceRepository(database: database)
        self.folders = FolderRepository(database: database)
        self.templates = templates
        self.dailyNotes = dailyNotes
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
            guard let self else { return }
            self.documentPreviews.prewarm([document])
            if let templateID = document.templateID {
                if (try? self.templates.hasInteractiveComponents(id: templateID)) == true {
                    self.dailyNoteOnlyTemplateIDs.insert(templateID)
                } else { self.dailyNoteOnlyTemplateIDs.remove(templateID) }
            }
            if let templateID = document.templateID,
               self.overview.templateDocuments[templateID]?.id == document.id {
                self.overview.templateDocuments[templateID] = document
            }
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
            Task { @MainActor [weak self] in
                do { try await self?.openNotificationDocument(id) }
                catch { self?.report(error) }
            }
        }
        calendar.completeTask = { [weak self] id, occurrenceID, completed in
            guard let self else { throw DocumentTaskError.missingTask }
            try await self.setTaskCompleted(id: id, completed: completed, expectedOccurrenceID: occurrenceID)
        }
        let preferred = persistsSpaceSelection ? self.preferences.string(forKey: spaceSelectionKey) : nil
        do {
            if createsDefaultSpace { applySpace(try spaces.fallback(preferred: preferred)) }
            else { applySpace(try spaces.existingFallback(preferred: preferred), persist: false) }
        }
        catch {
            applySpace("$unavailable", persist: false)
            errorMessage = error.localizedDescription
        }
    }

    static func makeLive() throws -> AppEnvironment {
        let database = try AppDatabase.makeShared()
        let store = try AttachmentStore.liveStore()
        let environment = AppEnvironment(database: database, attachmentStore: store)
        try environment.bootstrap()
        try? environment.spaces.drainAttachmentCleanup(store: store)
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
        if let selectedSpaceID {
            guard let space = try spaces.space(id: selectedSpaceID), !space.isArchived else {
                throw VellixError.database(errorMessage ?? "An active Space could not be restored.")
            }
        } else if createsDefaultSpace || errorMessage != nil {
            throw VellixError.database(errorMessage ?? "An active Space could not be restored.")
        }
        if seedSampleData {
            let space = try spaces.create(title: "Writing Desk", description: "Drafts and long-form work")
            applySpace(space.id)
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
            dailyNoteOnlyTemplateIDs = try templates.dailyNoteOnlyTemplateIDs()
            allSpaces = try spaces.includingArchived()
            let nextOverview = LibraryOverview(
                recent: try documents.recent(),
                favorites: try documents.favorites(),
                all: try documents.allDocuments(),
                trashed: try documents.trashed(),
                spaces: try spaces.all(),
                folders: try folders.all(),
                templates: try templates.all(),
                templateDocuments: try templates.previewDocuments()
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
            calendar.refresh()
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
        guard !isSwitchingSpace else { return nil }
        do {
            try ensureSpaceForCreation()
            let sourceJSON = template?.tipTapJSON ?? TipTapContentAnalyzer.emptyDocumentJSON
            let folder = folderID.flatMap { id in overview.folders.first { $0.id == id } }
            let document: DocumentRecord
            if let template {
                for model in editorCache.preparedModels where model.document?.templateID == template.id {
                    try model.saveCurrentContent()
                }
                document = try templates.instantiate(id: template.id, title: title,
                    spaceID: folder == nil ? (spaceID ?? selectedSpaceID) : folder?.spaceID, folderID: folderID,
                    parentID: parentDocumentID, attachmentStore: attachmentStore)
            } else {
                document = try documents.create(
                DocumentDraft(
                    title: title,
                    spaceID: folder == nil ? (spaceID ?? selectedSpaceID) : folder?.spaceID,
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
            try ensureSpaceForCreation()
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
        spaceSheet = .edit(nil)
    }

    func createFolder() {
        requestFolderCreation(parentFolderID: selectedDestination == .allDocuments && selectedFolderID != "__unsorted" ? selectedFolderID : nil)
    }

    func requestFolderCreation(parentFolderID: String?) {
        let parent = overview.folders.first { $0.id == parentFolderID }
        librarySheet = .folder(FolderEditorRequest(folder: nil, parentFolderID: parentFolderID,
            spaceID: parent == nil ? selectedSpaceID : parent?.spaceID))
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
            try ensureSpaceForCreation()
            _ = try folders.create(title: title, spaceID: request.spaceID, parentFolderID: request.parentFolderID,
                icon: icon, iconColorHex: colorHex)
        }
        refresh()
    }

    func openFolder(_ id: String?) {
        selectedDocumentID = nil
        selectedFolderID = id
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

    func browseTags(named name: String? = nil) async {
        let generation = workspaceGeneration
        guard !isSwitchingSpace else { return }
        do {
            if let model = editorCache.model(for: selectedDocumentID) {
                await model.waitForPersistentOperations()
                if model.session.isReady, !model.session.isLoadingDocument { try await model.captureAndSave() }
                else { try model.saveCurrentContent() }
            }
            guard generation == workspaceGeneration, !isSwitchingSpace else { return }
            selectedTagIDs = try name.map { [try tags.resolve($0).id] } ?? []
            selectedDocumentID = nil
            selectedFolderID = nil
            isSettingsPresented = false
            selectedDestination = .tags
            tagNavigationTarget = nil
        } catch { report(error) }
    }

    func openTaggedBlock(_ block: TaggedBlock, selectedTags: Set<String>) async {
        let generation = workspaceGeneration
        guard !isSwitchingSpace else { return }
        do {
            let occurrence = selectedTags.sorted().compactMap { block.occurrenceIDs[$0] }.first
                ?? block.occurrenceIDs.sorted { $0.key < $1.key }.first?.value
            let target = TagNavigationTarget(documentID: block.documentID, blockID: block.blockID, occurrenceID: occurrence)
            for id in Set([selectedDocumentID, block.documentID].compactMap { $0 }) {
                if let model = editorCache.model(for: id) {
                    await model.waitForPersistentOperations()
                    if model.session.isReady, !model.session.isLoadingDocument { try await model.captureAndSave() }
                    else { try model.saveCurrentContent() }
                }
            }
            guard generation == workspaceGeneration, !isSwitchingSpace else { return }
            guard try tags.targetIsAvailable(target) else { throw VellixError.tagging("This tagged block is no longer available. Refresh the tag results.") }
            let doc = try documents.requireDocument(id: block.documentID)
            tagNavigationTarget = target
            select(doc)
        } catch { tagNavigationTarget = nil; report(error) }
    }

    func select(_ document: DocumentRecord) {
        print("VELLIX-OPEN select CALLED id=\(document.id) docSpace=\(document.spaceID ?? "nil") selectedSpace=\(selectedSpaceID ?? "nil") switching=\(isSwitchingSpace)")
        if tagNavigationTarget?.documentID != document.id { tagNavigationTarget = nil }
        guard !isSwitchingSpace, document.spaceID == selectedSpaceID else {
            print("VELLIX-OPEN select BAIL space/switching guard (docSpace=\(document.spaceID ?? "nil") selectedSpace=\(selectedSpaceID ?? "nil") switching=\(isSwitchingSpace))")
            return
        }
        cancelDocumentOpening()
        guard let current = try? documents.document(id: document.id), !current.isTrashed else {
            print("VELLIX-OPEN select BAIL document(id:) nil-or-trashed")
            return
        }
        let model = editorCache.prepare(current)
        print("VELLIX-OPEN select id=\(document.id) alreadyReady=\(model.session.isPresentationReady) preparedCount=\(editorCache.preparedModels.count)")
        if !model.session.isPresentationReady { model.session.bridgeErrorMessage = nil }
        pendingDocumentID = document.id
        finishDocumentOpening(model, document: current)
        guard pendingDocumentID == document.id else { return }
        let requestID = pendingDocumentRequestID
        pendingDocumentTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.pendingDocumentRequestID == requestID, self.pendingDocumentID == document.id else { return }
            print("VELLIX-OPEN TIMEOUT-12s id=\(document.id) stuck — never became presentationReady")
            self.cancelDocumentOpening()
            self.errorMessage = "This page could not be prepared. Please try opening it again."
        }
    }

    private func finishDocumentOpening(_ model: DocumentEditorModel, document: DocumentRecord) {
        print("VELLIX-OPEN finishDocumentOpening ENTER id=\(document.id) pending=\(pendingDocumentID ?? "nil") ready=\(model.session.isPresentationReady)")
        guard pendingDocumentID == document.id else { print("VELLIX-OPEN finishDocumentOpening BAIL pending-mismatch"); return }
        do {
            let current = try documents.requireDocument(id: document.id)
            guard !current.isTrashed else { cancelDocumentOpening(); return }
            let content = try collections.repository.previewContent(for: current, documents: documents)
            model.session.setCollections(content.payloads, preparingForDisplay: true)
        } catch {
            print("VELLIX-OPEN finishDocumentOpening THREW err=\(error)")
            cancelDocumentOpening()
            report(error)
            return
        }
        if model.session.isPresentationReady {
            print("VELLIX-OPEN finishDocumentOpening READY -> show id=\(document.id)")
            selectedDocumentID = document.id
            let documents = documents, documentID = document.id
            Task.detached(priority: .utility) { try? documents.markOpened(id: documentID) }
        } else {
            print("VELLIX-OPEN finishDocumentOpening WAIT for presentationReady id=\(document.id)")
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
        let generation = workspaceGeneration
        guard let task = try tasks.all(includeTemplates: true).first(where: { $0.id == id }) else {
            throw DocumentTaskError.missingTask
        }
        let model = editorCache.model(for: task.documentID)
        if let model {
            if model.session.isLoadingDocument { try model.saveCurrentContent() }
            else { try await model.captureAndSave() }
        }
        guard generation == workspaceGeneration, !isSwitchingSpace else { throw VellixError.impossibleMove("The active Space changed. Reopen the task.") }
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

    @discardableResult
    func openDailyNote(day: DailyNoteDay) async throws -> DocumentRecord {
        let owner = selectedSpaceID
        guard owner != nil, !isSwitchingSpace else { throw DailyNoteError.spaceChanged }
        try await commitWorkspaceEdits()
        guard owner == selectedSpaceID, !isSwitchingSpace else { throw DailyNoteError.spaceChanged }
        let document = try dailyNotes.createOrFind(day: day, attachmentStore: attachmentStore)
        refresh()
        openCalendarDocument(document)
        return document
    }

    var activeSpace: SpaceRecord? { allSpaces.first { $0.id == selectedSpaceID } }

    private func ensureSpaceForCreation() throws {
        guard selectedSpaceID == nil else { return }
        applySpace(try spaces.fallback(preferred: nil))
    }

    private func applySpace(_ id: String?, persist: Bool = true) {
        let scope = id ?? "$unavailable"
        documents.spaceID = scope; folders.spaceID = scope; templates.spaceID = scope
        dailyNotes.spaceID = scope
        tags.spaceID = scope
        selectedTagIDs = []
        tagNavigationTarget = nil
        snapshots.spaceID = scope; attachments.spaceID = scope; search.spaceID = scope; tasks.spaceID = scope
        selectedSpaceID = id
        if persistsSpaceSelection && persist, let id { preferences.set(id, forKey: spaceSelectionKey) }
    }

    private var spaceSelectionKey: String {
        database.libraryID == LibraryRecord.localID ? "penned.activeSpaceID" : "penned.activeSpaceID.\(database.libraryID)"
    }

    func prepareForWorkspaceNavigation() async throws {
        await waitForWorkspace()
        guard database.isAccessible else { throw LibraryError.staleWorkspace }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
    }

    func closeLibrary() async throws {
        await waitForWorkspace()
        guard database.isAccessible else { return }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        await taskNotifications.closeLibrary()
        calendar.deactivate()
        documentPreviews.resetForSpaceChange()
        cancelDocumentOpening()
        for model in editorCache.preparedModels { editorCache.remove(documentID: model.documentID) }
        collections.resetForSpaceChange()
        database.invalidate()
    }

    func importLibraryChanges(_ apply: () throws -> Set<String>) async throws {
        await waitForWorkspace()
        guard database.isAccessible else { throw LibraryError.staleWorkspace }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        let models = editorCache.preparedModels
        let editable = models.map { $0.session.editingEnabled }
        models.forEach { $0.session.setEditable(false) }
        defer { for (index, model) in models.enumerated() { model.session.setEditable(editable[index]) } }
        _ = try apply()
        for model in models {
            if let current = try documents.document(id: model.documentID), !current.isTrashed, !current.isArchived {
                try model.reloadAfterLibrarySync()
            } else {
                if selectedDocumentID == model.documentID { selectedDocumentID = nil }
                editorCache.remove(documentID: model.documentID)
            }
        }
        let selectedSpace = try selectedSpaceID.flatMap { try spaces.space(id: $0) }
        if selectedSpace?.isArchived != false {
            let preferred = preferences.string(forKey: spaceSelectionKey)
            if createsDefaultSpace { activateSpaceAfterSaving(try spaces.fallback(preferred: preferred)) }
            else { activateSpaceAfterSaving(try spaces.existingFallback(preferred: preferred)) }
        }
        documentPreviews.resetForSpaceChange()
        collections.resetForSpaceChange()
        if let selectedDocumentID { collections.watchDocument(selectedDocumentID) }
        refresh()
        calendar.spaceDidChange()
        taskNotifications.refresh()
    }

    private func waitForWorkspace() async {
        while isSwitchingSpace { await withCheckedContinuation { workspaceWaiters.append($0) } }
    }

    private func commitWorkspaceEdits() async throws {
        let models = editorCache.preparedModels
        let enabled = models.map { $0.session.editingEnabled }
        defer { for (index, model) in models.enumerated() { model.session.setEditable(enabled[index]) } }
        models.forEach { $0.session.setEditable(false) }
        for model in models {
            await model.waitForPersistentOperations()
            try model.prepareForSpaceChange?()
            if model.session.isReady && !model.session.isLoadingDocument { try await model.captureAndSave(suspendingEditing: true) }
            else { try model.saveCurrentContent() }
        }
    }

    func switchSpace(to id: String) async throws {
        guard id != selectedSpaceID else { return }
        guard !isSwitchingSpace else { throw VellixError.impossibleMove("A workspace change is already in progress.") }
        guard let target = try spaces.space(id: id), !target.isArchived else { throw VellixError.impossibleMove("Restore this Space before opening it.") }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        activateSpaceAfterSaving(id)
    }

    private func activateSpaceAfterSaving(_ id: String?) {
        cancelDocumentOpening()
        selectedDocumentID = nil
        // Successful commits precede cache removal, which intentionally cancels pending saves.
        for model in editorCache.preparedModels { editorCache.remove(documentID: model.documentID) }
        collections.resetForSpaceChange()
        librarySearch.updateQuery("")
        librarySheet = nil; spaceSheet = nil; documentPendingDeletion = nil
        selectedFolderID = nil; isInspectorVisible = false
        workspaceGeneration += 1
        applySpace(id)
        documentPreviews.resetForSpaceChange()
        selectedDestination = .home
        calendar.spaceDidChange()
        refresh()
    }

    func openNotificationDocument(_ id: String) async throws {
        guard let owner = try spaces.owningSpace(documentID: id) else { throw VellixError.impossibleMove("This reminder's Space or page is unavailable.") }
        try await switchSpace(to: owner)
        let document = try documents.requireDocument(id: id)
        select(document)
    }

    func saveSpace(_ proposed: SpaceRecord, isNew: Bool) async throws {
        if isNew {
            var space = try spaces.create(title: proposed.title, description: proposed.spaceDescription)
            space.icon = proposed.icon; space.iconImageData = proposed.iconImageData; space.sortOrder = proposed.sortOrder
            try spaces.save(space)
            refresh()
            try await switchSpace(to: space.id)
        } else { try spaces.save(proposed); refresh(); spaceSheet = nil }
    }

    func archiveSpace(_ id: String, archived: Bool) async throws {
        guard !isSwitchingSpace else { throw VellixError.impossibleMove("Wait for the current workspace change to finish.") }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        if archived && id == selectedSpaceID {
            try await commitWorkspaceEdits()
            let other = try spaces.all().first { $0.id != id }?.id
            let fallback = try other ?? spaces.create(title: "Personal").id
            activateSpaceAfterSaving(fallback)
            try spaces.archive(id: id)
        } else if archived { try spaces.archive(id: id) }
        else { try spaces.restore(id: id) }
        refresh(); taskNotifications.refresh(); calendar.spaceDidChange()
    }

    func deleteSpace(_ id: String) async throws {
        guard !isSwitchingSpace else { throw VellixError.impossibleMove("Wait for the current workspace change to finish.") }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        let removed = try spaces.delete(id: id, store: attachmentStore)
        for documentID in removed { editorCache.remove(documentID: documentID) }
        collections.resetForSpaceChange(); documentPreviews.remove(documentIDs: removed)
        if selectedSpaceID == id {
            cancelDocumentOpening(); selectedDocumentID = nil
            workspaceGeneration += 1
            applySpace(try spaces.fallback(preferred: nil))
            selectedFolderID = nil; selectedDestination = .home
            librarySearch.updateQuery(""); librarySheet = nil
        }
        spaceSheet = nil; documentPendingDeletion = nil
        if let selectedDocumentID {
            collections.watchDocument(selectedDocumentID)
            editorCache.model(for: selectedDocumentID)?.session.setCollections(collections.payloads(for: selectedDocumentID))
        }
        refresh(); calendar.spaceDidChange(); await taskNotifications.flush()
    }

    func transferSpaceContent(_ item: SpaceContent, to destination: String, copy: Bool) async throws {
        guard let source = selectedSpaceID, !isSwitchingSpace else { throw VellixError.impossibleMove("The current Space is unavailable.") }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        try spaces.transfer(item, from: source, to: destination, copy: copy, store: attachmentStore)
        selectedDocumentID = nil; cancelDocumentOpening()
        for model in editorCache.preparedModels { editorCache.remove(documentID: model.documentID) }
        collections.resetForSpaceChange(); documentPreviews.resetForSpaceChange()
        workspaceGeneration += 1
        spaceSheet = nil; selectedFolderID = nil
        refresh(); calendar.spaceDidChange(); await taskNotifications.flush()
    }
}
