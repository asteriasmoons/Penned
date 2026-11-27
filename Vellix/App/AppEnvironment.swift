//
//  AppEnvironment.swift
//  Vellix
//

import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case calendar
    case dailyNotes
    case connect
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
        .dailyNotes,
        .connect,
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
        case .dailyNotes:
            return "Daily Notes"
        case .connect:
            return "Connect"
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
        case .dailyNotes:
            return "calendar"
        case .connect:
            return "cloudie"
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
    let templateGallery: TemplateGalleryRepository
    private(set) lazy var templateGalleryCloud = TemplateGalleryCloudStore()
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
    lazy var publishing = PublishingQueue(database: database, store: attachmentStore)
    @Published private(set) var pendingDocumentID: String? {
        didSet {
            pendingOpeningTrace?.event("pending-document-assigned", "previous=\(oldValue ?? "-") current=\(pendingDocumentID ?? "-")")
        }
    }
    private var pendingDocumentPresentation: AnyCancellable?
    private var pendingDocumentTimeout: Task<Void, Never>?
    #if os(iOS)
    private var pendingDocumentLookup: Task<Void, Never>?
    #endif
    private var pendingOpeningTrace: PennedDocumentOpenTrace?
    private var pendingDocumentRequestID = UUID() {
        didSet {
            pendingOpeningTrace?.event("request-uuid-changed", "previous=\(oldValue) current=\(pendingDocumentRequestID)")
        }
    }

    @Published var overview = LibraryOverview()
    // Bumped on every refresh so paginated surfaces can reload after any mutation
    // (create, edit, trash, move, duplicate, star, sync import) without observing
    // the full document list.
    @Published var libraryGeneration = 0
    @Published var calendarDocumentReturnID: String?
    @Published var selectedDestination: AppDestination = .home {
        didSet {
            if oldValue != selectedDestination { cancelDocumentOpening() }
            if selectedDestination != .calendar { calendarDocumentReturnID = nil }
        }
    }
    @Published var selectedDocumentID: String? {
        didSet {
            if oldValue != selectedDocumentID {
                editorCache.model(for: oldValue)?.clearEditorPresentationRequests()
            }
            pendingOpeningTrace?.event("request-cancelled", "reason=selected-document-assigned previousSelected=\(oldValue ?? "-") \(documentOpeningTraceState)")
            #if os(iOS)
            pendingDocumentLookup?.cancel()
            pendingDocumentLookup = nil
            #endif
            pendingDocumentPresentation = nil
            pendingDocumentTimeout?.cancel()
            pendingDocumentTimeout = nil
            pendingDocumentID = nil
            pendingDocumentRequestID = UUID()
            pendingOpeningTrace = nil
            #if os(iOS)
            if oldValue != selectedDocumentID {
                editorCache.model(for: oldValue)?.session.renderRecovery.deactivate(reason: "selected-document-changed")
                if let id = selectedDocumentID, let model = editorCache.model(for: id) {
                    model.session.renderRecovery.activate(documentID: id,
                        parentID: model.document?.parentDocumentID, previousID: oldValue,
                        previousParentID: editorCache.model(for: oldValue)?.document?.parentDocumentID,
                        scrollView: nil)
                }
            }
            #endif
            if selectedDocumentID == nil { calendarDocumentReturnID = nil }
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
            if oldValue != isSwitchingSpace {
                pendingOpeningTrace?.event("switching-space-changed", "previous=\(oldValue) \(documentOpeningTraceState)")
            }
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

    struct BootstrapState: Sendable {
        let spaceID: String?
        let allSpaces: [SpaceRecord]
        let overview: LibraryOverview
        let dailyNoteOnlyTemplateIDs: Set<String>
    }

    nonisolated static func loadBootstrapState(database: AppDatabase, preferredSpaceID: String?,
                                               createsDefaultSpace: Bool) throws -> BootstrapState {
        let spaces = SpaceRepository(database: database)
        var spaceID = try spaces.existingFallback(preferred: preferredSpaceID)
        if spaceID == nil && createsDefaultSpace {
            spaceID = try spaces.fallback(preferred: preferredSpaceID)
        }
        let scope = spaceID ?? "$unavailable"
        // These repositories are owned by this load, not shared with the UI's mutable Space scope.
        let documents = DocumentRepository(database: database)
        let folders = FolderRepository(database: database)
        let templates = TemplateRepository(database: database)
        documents.spaceID = scope; folders.spaceID = scope; templates.spaceID = scope
        let allSpaces = try spaces.includingArchived()
        let overview = try loadOverview(documents: documents, folders: folders, templates: templates, allSpaces: allSpaces)
        return BootstrapState(spaceID: spaceID, allSpaces: allSpaces, overview: overview,
                              dailyNoteOnlyTemplateIDs: try templates.dailyNoteOnlyTemplateIDs(among: overview.templates))
    }

    private nonisolated static func loadOverview(documents: DocumentRepository, folders: FolderRepository,
                                                templates: TemplateRepository, allSpaces: [SpaceRecord]) throws -> LibraryOverview {
        let counts = try documents.topLevelSummaryCountsByFolder()
        return try LibraryOverview(
            recent: documents.recentSummaries(),
            favorites: documents.favoriteSummaries(),
            dailyNotes: documents.allDailyNoteSummaries(),
            trashed: documents.trashedSummaries(),
            documentCount: counts.values.reduce(0, +),
            documentCountsByFolder: counts,
            spaces: allSpaces.filter { !$0.isArchived }.sorted {
                $0.sortOrder == $1.sortOrder ? $0.updatedAt > $1.updatedAt : $0.sortOrder < $1.sortOrder
            },
            folders: folders.all(),
            templates: templates.all(),
            templateDocuments: templates.previewDocuments()
        )
    }

    init(database: AppDatabase, attachmentStore: AttachmentStore, preferences: UserDefaults? = nil,
         createsDefaultSpace: Bool = true, initialState: BootstrapState? = nil) {
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
        self.templateGallery = TemplateGalleryRepository(database: database)
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
                      let content = try? collectionRepository.previewContent(for: document, documents: documents, includeCardPreviews: false) else { return [] }
                return content.payloads
            }
        )
        editorCache.documentPreviews = documentPreviews
        editorCache.ownsEditorPresentation = { [weak self] id in
            guard let self else { return false }
            return self.pendingDocumentID == nil && self.ownsEditorPresentation(documentID: id)
        }
        editorCache.openNestedPage = { [weak self] child, parentID in
            guard let self, self.ownsEditorPresentation(documentID: parentID),
                  self.pendingDocumentID == nil, child.parentDocumentID == parentID else { return }
            self.refresh()
            self.select(child)
        }
        documentPreviews.cardFallbackRenderer = { [weak self] document, scheme, hidesPageSurfaces in
            guard let self else { return nil }
            let renderer = ImageRenderer(content: ImmediateDocumentPreview(document: document, showsPageSurfaces: !hidesPageSurfaces,
                showsDocumentTitle: false, showsDocumentHeader: document.cardStyle?.isBook != true)
                .environmentObject(self).environment(\.colorScheme, scheme)
                .frame(width: document.isThemed ? 376 : 360, height: 740, alignment: .topLeading))
            renderer.scale = 2
            renderer.isOpaque = false
            return renderer.cgImage
        }
        documentPreviews.openPageFallbackRenderer = { [weak self] document, scheme in
            guard let self else { return nil }
            return ImmediateOpenPagePreview.snapshots(for: document, environment: self, colorScheme: scheme)
        }
        editorCache.onDocumentSaved = { [weak self] document in
            guard let self else { return }
            self.documentPreviews.documentDidSave(document)
            let templateID = document.templateID ?? TemplateRepository.documentTemplateID(document.id)
            if document.templateID != nil || self.overview.templateDocuments[templateID] != nil {
                if (try? self.templates.hasInteractiveComponents(id: templateID)) == true {
                    self.dailyNoteOnlyTemplateIDs.insert(templateID)
                } else { self.dailyNoteOnlyTemplateIDs.remove(templateID) }
            }
            if self.overview.templateDocuments[templateID]?.id == document.id {
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
        calendar.completeTask = { [weak self] id, occurrenceID, completed, skipped in
            guard let self else { throw DocumentTaskError.missingTask }
            try await self.setTaskCompleted(id: id, completed: completed, expectedOccurrenceID: occurrenceID, skipped: skipped)
        }
        if let initialState {
            applySpace(initialState.spaceID, persist: createsDefaultSpace)
            allSpaces = initialState.allSpaces
            overview = initialState.overview
            dailyNoteOnlyTemplateIDs = initialState.dailyNoteOnlyTemplateIDs
            return
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
        startDescriptorBackfill()
    }

    // Indexes any documents without a current preview descriptor (e.g. the whole
    // library on the first launch after upgrading) in bounded batches off the main
    // thread. Until a document is indexed the gallery falls back to the correct
    // record path for it, so this never blocks launch or browsing.
    private var descriptorBackfill: Task<Void, Never>?
    func startDescriptorBackfill() {
        guard descriptorBackfill == nil, database.isAccessible else { return }
        // Declare the preview-cache regeneration model once per launch (lazy, on
        // demand). Kept distinct from descriptor backfill completion so previews are
        // never reported complete merely because the backfill finished.
        PennedPreviewDiagnostics.announce(version: DocumentPreviewContent.previewCacheVersion)
        let database = self.database
        descriptorBackfill = Task.detached(priority: .utility) {
            await DocumentPreviewDescriptorIndex.runBackfill(database)
        }
    }

    func refresh(protectingEditorIDs protected: Set<String> = []) {
        do {
            allSpaces = try spaces.includingArchived()
            let nextOverview = try Self.loadOverview(documents: documents, folders: folders, templates: templates, allSpaces: allSpaces)
            dailyNoteOnlyTemplateIDs = try templates.dailyNoteOnlyTemplateIDs(among: nextOverview.templates)
            let cachedIDs = Set(editorCache.preparedModels.map(\.documentID) + [selectedDocumentID, pendingDocumentID].compactMap { $0 })
                .subtracting(protected)
            let current = try cachedIDs.compactMap { try documents.document(id: $0) }
            let existingIDs = Set(current.map(\.id))
            for model in editorCache.preparedModels where !protected.contains(model.documentID) && !existingIDs.contains(model.documentID) {
                editorCache.remove(documentID: model.documentID)
            }
            if let selectedDocumentID, !protected.contains(selectedDocumentID), !existingIDs.contains(selectedDocumentID) {
                self.selectedDocumentID = nil
            }
            if let pendingDocumentID, !protected.contains(pendingDocumentID), !existingIDs.contains(pendingDocumentID) { cancelDocumentOpening() }
            let preparedIDs = Set(editorCache.preparedModels.map(\.documentID))
            editorCache.prepare(current.filter { preparedIDs.contains($0.id) })
            overview = nextOverview
            libraryGeneration &+= 1
            if librarySearch.hasQuery { librarySearch.refresh() }
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

    /// Reads the current Space's personal templates for the document gallery.
    func personalGalleryTemplates() -> [(template: TemplateRecord, document: DocumentRecord)] {
        overview.templates.filter { !$0.isBuiltIn }.compactMap { template in
            guard let document = overview.templateDocuments[template.id] else { return nil }
            var current = template
            current.title = document.title
            current.icon = document.icon
            current.tipTapJSON = document.tipTapJSON
            return (template: current, document: document)
        }
    }

    var canPublishTemplates: Bool {
        (try? templatePublisherIdentity()) != nil
    }

    private func templatePublisherIdentity() throws -> AccountIdentity {
        guard let identity = try KeychainAccountSessionStore().currentIdentity(),
              case .apple(let subject) = identity,
              TemplateGalleryAuthorization.canShowPublishingControls(appleUserID: subject) else {
            throw PublishingFailure.authenticationRequired
        }
        return identity
    }

    func moveTemplateToCategory(_ template: TemplateRecord, category: String) throws {
        guard canPublishTemplates else { throw PublishingFailure.authenticationRequired }
        guard !isSwitchingSpace else { throw LibraryError.staleWorkspace }
        try templates.setCategory(id: template.id, category: category)
        refresh()
    }

    func publishGalleryTemplate(_ selected: TemplateRecord) async throws
        -> (categories: [GalleryCategory], templates: [GalleryTemplate]) {
        let owner = try templatePublisherIdentity()
        guard !isSwitchingSpace, let spaceID = selectedSpaceID,
              let template = try templates.all().first(where: { $0.id == selected.id && !$0.isBuiltIn }) else {
            throw LibraryError.staleWorkspace
        }
        let generation = workspaceGeneration
        for model in editorCache.preparedModels where model.document?.templateID == template.id ||
            template.rootDocumentID.map({ $0 == model.documentID }) == true {
            try await model.captureAndSave()
        }
        async let fetchedCategories = templateGalleryCloud.fetchCategories()
        async let fetchedTemplates = templateGalleryCloud.fetchTemplates()
        let categories = try await fetchedCategories
        var catalog = try await fetchedTemplates
        guard generation == workspaceGeneration, selectedSpaceID == spaceID, !isSwitchingSpace else {
            throw LibraryError.staleWorkspace
        }
        guard try templatePublisherIdentity() == owner else { throw PublishingFailure.authenticationRequired }
        try Task.checkCancellation()
        guard let current = try templates.all().first(where: { $0.id == template.id }) else {
            throw PublishingFailure.invalidContent("This template no longer exists.")
        }
        let category = try TemplateGalleryPublisher.category(for: current, in: categories)
        let root = try templates.editingDocument(id: current.id, attachmentStore: attachmentStore)
        let publicationID = TemplateGalleryPublisher.publicationID(templateID: current.id, libraryID: database.libraryID)
        let existing = catalog.first { $0.id == publicationID }
        let package = try TemplateGalleryPublisher(database: database, attachmentStore: attachmentStore).prepare(
            documentID: root.id, categoryID: category.id, title: current.title, owner: owner,
            galleryTemplateID: publicationID, revision: (existing?.revision ?? 0) + 1)
        let published = try await templateGalleryCloud.saveTemplate(package, description: current.templateDescription,
            sortOrder: existing?.sortOrder ?? 0, updating: existing != nil)
        if let index = catalog.firstIndex(where: { $0.id == published.id }) { catalog[index] = published }
        else { catalog.append(published) }
        // The remote write has succeeded; a cache failure must not report a failed publication.
        try? templateGallery.replaceCatalog(categories: categories, templates: catalog)
        return (categories, catalog)
    }

    func createDocument(fromGallery template: GalleryTemplate) async throws -> DocumentRecord {
        guard !isSwitchingSpace else { throw LibraryError.staleWorkspace }
        try ensureSpaceForCreation()
        guard let spaceID = selectedSpaceID else { throw LibraryError.staleWorkspace }
        let generation = workspaceGeneration
        let package = try await templateGalleryCloud.fetchPackage(templateID: template.id, expectedRevision: template.revision)
        try Task.checkCancellation()
        guard generation == workspaceGeneration, selectedSpaceID == spaceID, !isSwitchingSpace else {
            throw LibraryError.staleWorkspace
        }
        try package.validateForImport(expectedID: template.id, expectedRevision: template.revision)
        if package.nativeSnapshot?.documents.contains(where: { TemplateComponentDefinition.contains(in: $0.tipTapJSON) }) == true {
            throw VellixError.impossibleMove("This template contains Daily Note components. Use it in Daily Notes settings.")
        }
        let document = try TemplateGalleryImporter(database: database, attachmentStore: attachmentStore)
            .importPackage(package, intoSpace: spaceID)
        editorCache.prepare(document)
        refresh()
        select(document)
        return document
    }

    func saveGalleryTemplate(_ template: GalleryTemplate) async throws -> TemplateRecord {
        guard !isSwitchingSpace else { throw LibraryError.staleWorkspace }
        try ensureSpaceForCreation()
        guard let spaceID = selectedSpaceID else { throw LibraryError.staleWorkspace }
        let generation = workspaceGeneration
        let package = try await templateGalleryCloud.fetchPackage(templateID: template.id, expectedRevision: template.revision)
        try Task.checkCancellation()
        guard generation == workspaceGeneration, selectedSpaceID == spaceID, !isSwitchingSpace else {
            throw LibraryError.staleWorkspace
        }
        let importer = TemplateGalleryImporter(database: database, attachmentStore: attachmentStore)
        let saved = try importer.saveTemplate(package, intoSpace: spaceID, description: template.templateDescription)
        refresh()
        return saved
    }

    func createTemplate() {
        do {
            try ensureSpaceForCreation()
            let document = try templates.create(category: canPublishTemplates
                ? TemplateRepository.unsortedCategory : TemplateRepository.myTemplatesCategory)
            editorCache.prepare(document)
            refresh()
            selectedDestination = .templates
            select(document)
        } catch { report(error) }
    }

    func documentForTemplateEditing(_ template: TemplateRecord) throws -> DocumentRecord {
        if let rootID = template.rootDocumentID, let model = editorCache.model(for: rootID) {
            try model.saveCurrentContent()
        }
        let document = try templates.editingDocument(id: template.id, attachmentStore: attachmentStore)
        editorCache.prepare(document)
        refresh()
        return document
    }

    func editTemplate(_ template: TemplateRecord) {
        do {
            let document = try documentForTemplateEditing(template)
            selectedDestination = .templates
            select(document)
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
        guard title.trimmedNonEmpty != nil, VellixAssetIconLibrary.isSupported(icon) else {
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

    // Summary convenience: loads the full record by id, then selects it. Used by the
    // body-free library surfaces (Home strips, sidebar).
    private var documentOpeningTraceState: String {
        "selected=\(selectedDocumentID ?? "-") pending=\(pendingDocumentID ?? "-") currentRequest=\(pendingDocumentID == nil ? "-" : pendingDocumentRequestID.uuidString) active=\(pendingDocumentID != nil) switchingSpace=\(isSwitchingSpace) databaseAccessible=\(database.isAccessible)"
    }

    func traceDocumentCardTap(id: String, source: String, workspaceBusy: Bool? = nil) -> PennedDocumentOpenTrace? {
        guard PennedDocumentOpenTrace.enabled else { return nil }
        #if os(iOS)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        let device = "mac"
        #endif
        let trace = PennedDocumentOpenTrace(documentID: id, source: source)
        trace.event("card-tap", "interface=\(device) workspaceBusy=\(workspaceBusy.map { String($0) } ?? "-") \(documentOpeningTraceState)")
        return trace
    }

    func traceDocumentOpeningSurfaceTap(source: String, workspaceBusy: Bool) {
        guard PennedDocumentOpenTrace.enabled else { return }
        let trace = PennedDocumentOpenTrace(documentID: "-", source: source)
        trace.event("surface-tap", "workspaceBusy=\(workspaceBusy) \(documentOpeningTraceState)")
    }

    func select(_ summary: DocumentSummary, openingTrace: PennedDocumentOpenTrace? = nil) {
        #if os(iOS)
        requestDocumentOpening(id: summary.id, spaceID: summary.spaceID, openingTrace: openingTrace)
        #else
        guard let record = try? documents.document(id: summary.id) else { return }
        select(record)
        #endif
    }

    func select(_ document: DocumentRecord, openingTrace: PennedDocumentOpenTrace? = nil) {
        #if os(iOS)
        requestDocumentOpening(id: document.id, spaceID: document.spaceID, openingTrace: openingTrace)
        #else
        if PennedSyncTrace.documentID == document.id {
            PennedSyncTrace.record("editor.selectRequested", "revision=\(document.revision) switchingSpace=\(isSwitchingSpace)")
        }
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
        if selectedDocumentID == nil { calendarDocumentReturnID = nil }
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
        #endif
    }

    #if os(iOS)
    private func requestDocumentOpening(id: String, spaceID: String?, openingTrace: PennedDocumentOpenTrace?) {
        let intent = openingTrace ?? (PennedDocumentOpenTrace.enabled ? PennedDocumentOpenTrace(documentID: id, source: "select") : nil)
        let started = intent?.event("request-start", documentOpeningTraceState)
        guard !isSwitchingSpace, database.isAccessible, spaceID == selectedSpaceID else {
            intent?.event("request-rejected", "reason=\(isSwitchingSpace ? "switching-space" : !database.isAccessible ? "database-inaccessible" : "space-mismatch") \(documentOpeningTraceState) spaceMatches=\(spaceID == selectedSpaceID)", since: started)
            return
        }
        if tagNavigationTarget?.documentID != id { tagNavigationTarget = nil }
        let replacesRequest = pendingDocumentID == nil ? nil : pendingDocumentRequestID
        let replacesDocument = pendingDocumentID
        cancelDocumentOpening(reason: "superseded-by-opening")
        if selectedDocumentID == nil { calendarDocumentReturnID = nil }
        let requestID = pendingDocumentRequestID
        let trace = intent?.accepted(requestID: requestID)
        pendingOpeningTrace = trace
        trace?.event("request-uuid-assigned")
        let timing = PennedDocumentOpeningTiming(trace: trace)
        pendingDocumentID = id
        trace?.event("request-accepted", "\(documentOpeningTraceState) replacesRequest=\(replacesRequest?.uuidString ?? "-") replacesDocument=\(replacesDocument ?? "-")", since: started)
        let database = database
        pendingDocumentLookup = Task { [weak self] in
            let lookupStarted = trace?.event("document-lookup-start")
            let lookup = Task.detached(priority: .userInitiated) {
                let repository = DocumentRepository(database: database)
                repository.spaceID = spaceID ?? "$unavailable"
                return try repository.document(id: id)
            }
            do {
                let record = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
                trace?.event("document-lookup-completed", "found=\(record != nil) trashed=\(record?.isTrashed == true)", since: lookupStarted)
                guard !Task.isCancelled, let self else {
                    trace?.event("callback-discarded", "callback=lookup reason=\(Task.isCancelled ? "task-cancelled" : "environment-released")")
                    return
                }
                guard self.isCurrentOpening(id, requestID: requestID, trace: trace, caller: "lookup") else { return }
                self.pendingDocumentLookup = nil
                guard let record, !record.isTrashed else {
                    self.cancelDocumentOpening(reason: record == nil ? "document-missing" : "document-trashed")
                    return
                }
                timing.mark("document-read")
                let preparationStarted = trace?.event("model-preparation-start")
                let payloads = try self.collections.openingPayloads(for: record)
                let model = self.editorCache.prepareForOpening(record, payloads: payloads, timing: timing)
                timing.mark("model-prepared")
                trace?.event("model-preparation-completed", "matchesDocument=\(model.documentID == id) \(model.session.openingReadinessState(for: id))", since: preparationStarted)
                guard model.documentID == id else {
                    throw VellixError.editorBridge(model.errorMessage ?? "This page could not be prepared.")
                }
                self.awaitEditorPresentation(model, id: id, requestID: requestID, timing: timing)
            } catch {
                trace?.event("opening-work-failed", "error=\(PennedDocumentOpenTrace.errorCode(error))", since: lookupStarted)
                guard !Task.isCancelled, let self else {
                    trace?.event("callback-discarded", "callback=lookup-or-preparation-error reason=\(Task.isCancelled ? "task-cancelled" : "environment-released")")
                    return
                }
                guard self.isCurrentOpening(id, requestID: requestID, trace: trace, caller: "lookup-or-preparation-error") else { return }
                self.cancelDocumentOpening(reason: "lookup-or-preparation-failed")
                timing.mark("failed")
                self.report(error)
            }
        }
        let timeoutStarted = trace?.event("timeout-scheduled", "delayMS=12000")
        pendingDocumentTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch {
                trace?.event("timeout-cancelled", "reason=sleep-interrupted", since: timeoutStarted)
                return
            }
            trace?.event("timeout-fired", "ownsRequest=\(self?.pendingDocumentRequestID == requestID && self?.pendingDocumentID == id)", since: timeoutStarted)
            guard let self else {
                trace?.event("timeout-skipped-cleanup", "reason=environment-released")
                return
            }
            guard self.isCurrentOpening(id, requestID: requestID, trace: trace, caller: "timeout") else {
                trace?.event("timeout-skipped-cleanup", "reason=\(self.openingValidityFailure(id, requestID: requestID)) \(self.documentOpeningTraceState)")
                return
            }
            self.cancelDocumentOpening(reason: "timeout")
            trace?.event("timeout-cleared-pending", self.documentOpeningTraceState)
            timing.mark("timeout")
            self.errorMessage = "This page could not be prepared. Please try opening it again."
        }
    }

    private func isCurrentOpening(_ id: String, requestID: UUID, trace: PennedDocumentOpenTrace?, caller: String) -> Bool {
        let current = pendingDocumentRequestID == requestID && pendingDocumentID == id && !isSwitchingSpace && database.isAccessible
        trace?.event(current ? "request-validated" : "callback-discarded",
                     "callback=\(caller) reason=\(openingValidityFailure(id, requestID: requestID)) uuidMatches=\(pendingDocumentRequestID == requestID) pendingMatches=\(pendingDocumentID == id) \(documentOpeningTraceState)")
        return current
    }

    private func openingValidityFailure(_ id: String, requestID: UUID) -> String {
        if pendingDocumentRequestID != requestID { return "request-uuid-mismatch" }
        if pendingDocumentID != id { return "pending-document-mismatch" }
        if isSwitchingSpace { return "switching-space" }
        if !database.isAccessible { return "database-inaccessible" }
        return "none"
    }

    private func awaitEditorPresentation(_ model: DocumentEditorModel, id: String, requestID: UUID,
                                         timing: PennedDocumentOpeningTiming) {
        let trace = timing.trace
        let started = trace?.event("await-presentation-start", model.session.openingReadinessState(for: id))
        func present() {
            guard isCurrentOpening(id, requestID: requestID, trace: trace, caller: "present"),
                  model.session.hasLoadedDocument(id), model.session.isPresentationReady else {
                trace?.event("navigation-rejected", "\(documentOpeningTraceState) \(model.session.openingReadinessState(for: id)) observerActive=false", since: started)
                return
            }
            cancelDocumentOpening(reason: "presentation-succeeded")
            timing.mark("workspace-selected")
            selectedDocumentID = id
            trace?.event("navigation-selected", documentOpeningTraceState, since: started)
            let documents = documents, documentID = id
            Task.detached(priority: .utility) { try? documents.markOpened(id: documentID) }
        }
        if model.session.isPresentationReady, model.session.hasLoadedDocument(id) {
            timing.mark("presentation-ready", route: "retained-document")
            trace?.event("presentation-reused", model.session.openingReadinessState(for: id))
            present()
            return
        }
        trace?.event("readiness-observer-start", "oneShot=true")
        pendingDocumentPresentation = Publishers.CombineLatest(model.session.$isPresentationReady, model.session.$bridgeErrorMessage)
            .filter { ready, error in
                let passes = ready || error != nil
                trace?.event("readiness-event", "emittedReady=\(ready) emittedErrorPresent=\(error != nil) passesFilter=\(passes)")
                return passes
            }.first().receive(on: DispatchQueue.main)
            .sink { [weak self] ready, error in
                trace?.event("readiness-observer-delivered", "emittedReady=\(ready) emittedErrorPresent=\(error != nil) observerActive=false", since: started)
                guard let self else {
                    trace?.event("callback-discarded", "callback=readiness-observer reason=environment-released observerActive=false")
                    return
                }
                guard self.isCurrentOpening(id, requestID: requestID, trace: trace, caller: "readiness-observer") else {
                    trace?.event("navigation-rejected", "reason=request-not-current observerActive=false")
                    return
                }
                if let error {
                    trace?.event("readiness-observer-failed", "\(model.session.openingReadinessState(for: id)) observerActive=false")
                    self.cancelDocumentOpening(reason: "bridge-error")
                    timing.mark("failed")
                    self.errorMessage = error
                } else if ready {
                    present()
                }
            }
    }
    #else
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
            cancelDocumentOpening()
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
    #endif

    private func cancelDocumentOpening(reason: String = "caller-cancelled", file: StaticString = #fileID, line: UInt = #line) {
        pendingOpeningTrace?.event("request-cancelled", "reason=\(reason) caller=\(file):\(line) hasObserverHandle=\(pendingDocumentPresentation != nil) hasTimeoutHandle=\(pendingDocumentTimeout != nil) \(documentOpeningTraceState)")
        #if os(iOS)
        pendingDocumentLookup?.cancel()
        pendingDocumentLookup = nil
        #endif
        pendingDocumentPresentation = nil
        pendingDocumentTimeout?.cancel()
        pendingDocumentTimeout = nil
        pendingDocumentID = nil
        pendingDocumentRequestID = UUID()
        pendingOpeningTrace = nil
    }

    func setTaskCompleted(id: String, completed: Bool, expectedOccurrenceID: String? = nil, skipped: Bool = false) async throws {
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
        let occurrenceID = expectedOccurrenceID ?? current.metadata.occurrenceID
        let saved = try tasks.setCompleted(taskID: id, occurrenceID: occurrenceID, completed: completed, skipped: skipped)
        editorCache.model(for: current.documentID)?.receiveExternalTaskChange(saved)
        refresh()
        await taskNotifications.flush()
    }

    func openCalendarDocument(_ document: DocumentRecord, returnToCalendar: Bool = false) {
        do {
            let current = try documents.requireDocument(id: document.id)
            guard !current.isTrashed else { throw VellixError.impossibleMove("Restore this event note from Trash before opening it.") }
            guard !isSwitchingSpace, current.spaceID == selectedSpaceID else { throw LibraryError.staleWorkspace }
            editorCache.prepare(current)
            select(current)
            if returnToCalendar, selectedDestination == .calendar,
               pendingDocumentID == current.id || selectedDocumentID == current.id {
                calendarDocumentReturnID = current.id
            }
        } catch { report(error) }
    }

    func createEventNote(for event: CalendarEvent) throws -> DocumentRecord {
        let document = try calendarEventNotes.createOrFind(for: event)
        editorCache.prepare(document)
        refresh()
        calendar.refresh()
        return document
    }

    func ownsEditorPresentation(documentID: String) -> Bool {
        selectedDocumentID == documentID && !isSwitchingSpace && !isSettingsPresented
    }

    func returnFromDocument(_ document: DocumentRecord) {
        if selectedDestination == .calendar, calendarDocumentReturnID == document.id {
            selectedDocumentID = nil
            refresh()
        } else if let parentID = document.parentDocumentID,
           let parent = editorCache.model(for: parentID)?.document ?? (try? documents.document(id: parentID)),
           !parent.isTrashed {
            #if os(iOS)
            editorCache.model(for: document.id)?.session.renderRecovery.record("back-target-selected",
                ["target": parent.id, "targetParent": parent.parentDocumentID ?? "-",
                 "targetCached": editorCache.model(for: parent.id) != nil])
            #endif
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
        publishing.stop()
        await waitForWorkspace()
        guard database.isAccessible else { return }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        try await commitWorkspaceEdits()
        #if os(iOS)
        editorCache.discardStandbyRuntime()
        #endif
        descriptorBackfill?.cancel()
        await taskNotifications.closeLibrary()
        calendar.deactivate()
        documentPreviews.resetForSpaceChange()
        cancelDocumentOpening()
        for model in editorCache.preparedModels { editorCache.remove(documentID: model.documentID) }
        collections.resetForSpaceChange()
        database.invalidate()
    }

    @discardableResult
    func importLibraryChanges(deferringWhileEditorOpen: Bool = false, _ apply: () throws -> Set<String>) async throws -> Bool {
        try await withLibraryImportPreparation(deferringWhileEditorOpen: deferringWhileEditorOpen) {
            _ = try apply()
            try reloadAfterLibraryImport()
        }
    }

    func librarySyncProtection(alsoProtecting visibleDocumentID: String? = nil) -> LibrarySyncProtection {
        let visible = [selectedDocumentID, pendingDocumentID, visibleDocumentID].compactMap { $0 }
        var protection = LibrarySyncProtection(documentIDs: Set(visible))
        if !visible.isEmpty, let selectedSpaceID { protection.spaceIDs.insert(selectedSpaceID) }
        for model in editorCache.preparedModels where protection.documentIDs.contains(model.documentID) || model.hasUnsavedLibraryContent {
            protection.documentIDs.insert(model.documentID)
            protection.documentIDs.formUnion(model.pageReferenceIDs)
            protection.attachmentPaths.formUnion(EditorAttachment.paths(in: model.document?.tipTapJSON ?? ""))
        }
        return protection
    }

    func importAutomaticLibraryChanges(_ apply: LibrarySyncEngine.ApplyIncoming) async throws -> Bool {
        try Task.checkCancellation()
        guard database.isAccessible else { throw LibraryError.staleWorkspace }
        // The inbox is already durable. Don't hold a CloudKit delegate call
        // open while an editor/Space transition owns the workspace.
        guard !isSwitchingSpace else { return false }
        let protection = librarySyncProtection()
        if try apply(protection) { try reloadAfterLibraryImport(protectingEditorIDs: protection.documentIDs) }
        return true
    }

    private var hasOpenOrOpeningDocument: Bool {
        selectedDocumentID != nil || pendingDocumentID != nil
    }

    @discardableResult
    func withLibraryImportPreparation(deferringWhileEditorOpen: Bool = false, _ perform: () async throws -> Void) async throws -> Bool {
        // Check again after waiting: a document can open while another operation owns the workspace.
        if deferringWhileEditorOpen, hasOpenOrOpeningDocument { return false }
        await waitForWorkspace()
        guard database.isAccessible else { throw LibraryError.staleWorkspace }
        if deferringWhileEditorOpen, hasOpenOrOpeningDocument { return false }
        isSwitchingSpace = true
        defer { isSwitchingSpace = false }
        let models = editorCache.preparedModels
        let editable = models.map { $0.session.editingEnabled }
        models.forEach { $0.session.setEditable(false, preservingBlockSelection: true) }
        defer { for (index, model) in models.enumerated() { model.session.setEditable(editable[index]) } }
        try await commitWorkspaceEdits(preservingBlockSelection: true)
        if deferringWhileEditorOpen, hasOpenOrOpeningDocument { return false }
        try await perform()
        return true
    }

    // Reload from the committed rows without saving any pre-import editor state.
    func reloadAfterLibraryImport(protectingEditorIDs protected: Set<String> = []) throws {
        guard database.isAccessible else { throw LibraryError.staleWorkspace }
        for model in editorCache.preparedModels where !protected.contains(model.documentID) {
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
        if protected.isEmpty {
            documentPreviews.resetForSpaceChange()
            collections.resetForSpaceChange()
            if let selectedDocumentID { collections.watchDocument(selectedDocumentID) }
        }
        refresh(protectingEditorIDs: protected)
        calendar.spaceDidChange()
        taskNotifications.refresh()
    }

    private func waitForWorkspace() async {
        while isSwitchingSpace { await withCheckedContinuation { workspaceWaiters.append($0) } }
    }

    private func commitWorkspaceEdits(preservingBlockSelection: Bool = false) async throws {
        let models = editorCache.preparedModels.filter { !$0.isReadOnlyWarmup }
        let enabled = models.map { $0.session.editingEnabled }
        defer { for (index, model) in models.enumerated() {
            model.session.setEditable(enabled[index], preservingBlockSelection: preservingBlockSelection)
        } }
        models.forEach { $0.session.setEditable(false, preservingBlockSelection: preservingBlockSelection) }
        for model in models {
            await model.waitForPersistentOperations()
            try model.prepareForSpaceChange?()
            if model.session.isReady && !model.session.isLoadingDocument {
                try await model.captureAndSave(suspendingEditing: true, preservingBlockSelection: preservingBlockSelection)
            }
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
        #if os(iOS)
        editorCache.discardStandbyRuntime()
        #endif
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
