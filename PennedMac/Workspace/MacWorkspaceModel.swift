import AppKit
import Combine
import SwiftUI

enum MacDestination: String, Codable, CaseIterable, Identifiable {
    case home, allDocuments, recents, starred, tasks, calendar, collections, folders, tags, templates, spaces, trash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allDocuments: return "All Docs"
        case .home: return "All Docs"
        case .recents: return "Recents"
        case .starred: return "Starred"
        case .tasks: return "Tasks"
        case .calendar: return "Calendar"
        case .collections: return "Collections"
        case .folders: return "Folders"
        case .tags: return "Tags"
        case .templates: return "Templates"
        case .spaces: return "Spaces"
        case .trash: return "Trash"
        }
    }
    var icon: String {
        switch self {
        case .home: return "houseoutline"
        case .allDocuments: return "linedpages"
        case .recents: return "clockwavy"
        case .starred: return "starfill"
        case .tasks: return "checklist"
        case .calendar: return "mooncal"
        case .collections: return "gridboard"
        case .folders: return "openedfolder"
        case .tags: return "hashtagwavy"
        case .templates: return "copy"
        case .spaces: return "spaces"
        case .trash: return "trash"
        }
    }
    var applicationDestination: AppDestination {
        switch self {
        case .starred: return .favorites
        case .tasks: return .calendar
        case .collections: return .allDocuments
        default: return AppDestination(rawValue: rawValue) ?? .allDocuments
        }
    }
}

struct MacWorkspaceLocation: Codable, Equatable {
    var destination: MacDestination = .allDocuments
    var folderID: String?
    var documentID: String?
    var tagIDs: Set<String> = []
}

enum MacDocumentSort: String, Codable, CaseIterable, Identifiable {
    case updated = "Last Edited", created = "Date Created", title = "Title", opened = "Last Opened"
    var id: String { rawValue }
    func sorted(_ records: [DocumentRecord]) -> [DocumentRecord] {
        records.sorted {
            switch self {
            case .updated: return $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
            case .created: return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            case .title: return $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case .opened: return ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
            }
        }
    }
}

@MainActor final class MacBrowserState: ObservableObject {
    @Published var query = ""
    @Published var sort = MacDocumentSort.updated
    @Published var showsList = false
    @Published var showsCompletedTasks = false
    @Published var selectedIDs: Set<String> = []
    @Published var scroll = ScrollPosition(edge: .top)
}

@MainActor final class MacWorkspaceTab: ObservableObject, Identifiable {
    let id: UUID
    @Published var location: MacWorkspaceLocation
    var history: [MacWorkspaceLocation]
    var historyIndex: Int
    let browser = MacBrowserState()
    var calendar: CalendarModel?
    init(id: UUID = UUID(), location: MacWorkspaceLocation? = nil, history: [MacWorkspaceLocation]? = nil, historyIndex: Int = 0) {
        let location = location ?? MacWorkspaceLocation()
        self.id = id; self.location = location; self.history = history ?? [location]
        self.historyIndex = min(max(0, historyIndex), max(0, self.history.count - 1))
    }
}

private struct MacWorkspaceArchive: Codable {
    struct Tab: Codable {
        var id: UUID
        var location: MacWorkspaceLocation
        var history: [MacWorkspaceLocation]
        var historyIndex: Int
        var query: String
        var sort: MacDocumentSort
        var showsList: Bool
        var showsCompletedTasks: Bool?
        var calendarDate: Date?
    }
    var activeID: UUID
    var tabs: [Tab]
}

@MainActor final class MacWorkspaceModel: ObservableObject, Identifiable {
    let id: String
    let environment: AppEnvironment
    let ownerKey: String?
    private let preferences: UserDefaults
    private let currentOwner: () -> String?
    private var queuedOperation: Task<Void, Never>?
    weak var registry: MacWindowRegistry?
    weak var window: NSWindow?
    @Published private(set) var tabs: [MacWorkspaceTab] = []
    @Published private(set) var activeID = UUID()
    @Published private(set) var isBusy = false
    @Published private(set) var spaceID: String?
    @Published var inspector = MacInspectorSection.insert
    @Published var sidebarVisible = true
    @Published var inspectorVisible = false
    @Published var styleGalleryVisible = false
    @Published var showHistory = false
    @Published var showIconPicker = false
    @Published var findInDocument = false
    @Published var errorMessage: String?
    @Published var trashIDs: Set<String> = []
    @Published var confirmingTrash = false
    let sidebar = MacSidebarState()
    private var documentViewStates: [String: MacDocumentViewState] = [:]

    func viewState(for documentID: String) -> MacDocumentViewState {
        if let state = documentViewStates[documentID] { return state }
        let state = MacDocumentViewState(); documentViewStates[documentID] = state; return state
    }

    func calendar(for tab: MacWorkspaceTab) -> CalendarModel {
        if let calendar = tab.calendar { return calendar }
        let calendar = CalendarModel(tasks: environment.tasks, documents: environment.documents, notes: environment.calendarEventNotes,
            database: environment.database, dailyNotes: environment.dailyNotes)
        calendar.completeTask = { [weak environment] id, occurrence, completed, skipped in
            guard let environment else { throw LibraryError.staleWorkspace }
            try await environment.setTaskCompleted(id: id, completed: completed, expectedOccurrenceID: occurrence, skipped: skipped)
        }
        tab.calendar = calendar; return calendar
    }

    init(environment: AppEnvironment, ownerKey: String?, sceneID: String, preferences: UserDefaults = .standard,
         currentOwner: @escaping () -> String? = { nil }) {
        self.environment = environment; self.ownerKey = ownerKey; id = sceneID
        self.preferences = preferences; self.currentOwner = currentOwner; spaceID = environment.selectedSpaceID
        restoreTabs()
    }
    var activeTab: MacWorkspaceTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var activeEditor: DocumentEditorModel? { environment.editorCache.model(for: activeTab.location.documentID) }
    var canShowInspector: Bool { activeEditor != nil }
    var showsInspector: Bool { canShowInspector && inspectorVisible }
    var canGoBack: Bool { activeTab.historyIndex > 0 || parentBackLocation != nil }
    var canGoForward: Bool { activeTab.historyIndex + 1 < activeTab.history.count }
    private var parentBackLocation: MacWorkspaceLocation? {
        let tab = activeTab
        // A page opened directly or in a reused tab may have no document return path.
        guard tab.historyIndex == 0 || tab.history[tab.historyIndex - 1].documentID == nil,
              let id = tab.location.documentID,
              let document = try? environment.documents.document(id: id),
              let parentID = document.parentDocumentID,
              let parent = try? environment.documents.document(id: parentID),
              parent.spaceID == spaceID, !parent.isTrashed, !parent.isArchived else { return nil }
        var location = tab.location
        location.documentID = parent.id
        return location
    }
    private var archiveKey: String { "penned.mac.workspace.\(environment.database.libraryID).\(ownerKey ?? "signed-out").\(id).\(spaceID ?? "empty")" }
    var isAuthorized: Bool { environment.database.isAccessible && currentOwner() == ownerKey }

    func start() {
        guard isAuthorized else { return }
        let claimed = Set((registry?.workspaces ?? []).filter { $0 !== self && $0.ownerKey == ownerKey && $0.environment.database.libraryID == environment.database.libraryID }.flatMap { $0.tabs.compactMap { $0.location.documentID } })
        for tab in tabs where tab.location.documentID.map(claimed.contains) == true { tab.location.documentID = nil }
        apply(activeTab.location)
    }
    func title(_ tab: MacWorkspaceTab) -> String {
        if let id = tab.location.documentID {
            return environment.editorCache.model(for: id)?.document?.title
                ?? (try? environment.documents.document(id: id))?.title ?? "Document"
        }
        if let folder = tab.location.folderID {
            return folder == "__unsorted" ? "Unsorted" : environment.overview.folders.first { $0.id == folder }?.title ?? "Folder"
        }
        if !tab.location.tagIDs.isEmpty, let tags = try? environment.tags.catalogue() {
            return tags.filter { tab.location.tagIDs.contains($0.id) }.map { "#" + $0.name }.joined(separator: " + ")
        }
        return tab.location.destination.title
    }
    func icon(_ tab: MacWorkspaceTab) -> String {
        if let id = tab.location.documentID { return environment.editorCache.model(for: id)?.document?.icon ?? "linedpages" }
        return tab.location.folderID == nil ? tab.location.destination.icon : "openedfolder"
    }

    func newTab(_ location: MacWorkspaceLocation = .init()) async throws {
        guard isAuthorized else { throw LibraryError.wrongOwner }
        if let id = location.documentID, registry?.focusDocument(id, except: self) == true { return }
        try await transition {
            try self.validate(location)
            let tab = MacWorkspaceTab(location: location)
            self.tabs.append(tab); self.activeID = tab.id; self.apply(location)
        }
    }
    func selectTab(_ id: UUID) async throws {
        guard id != activeID, let tab = tabs.first(where: { $0.id == id }) else { return }
        try await transition { self.activeID = tab.id; self.apply(tab.location) }
    }
    func closeTab(_ id: UUID) async throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        try await transition {
            self.tabs.remove(at: index)
            if self.tabs.isEmpty { self.tabs = [MacWorkspaceTab()] }
            if self.activeID == id { self.activeID = self.tabs[min(index, self.tabs.count - 1)].id }
            self.apply(self.activeTab.location)
        }
    }
    func moveTab(_ id: UUID, before destination: UUID) {
        guard isAuthorized, id != destination, let source = tabs.firstIndex(where: { $0.id == id }),
              tabs.contains(where: { $0.id == destination }) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: tabs.firstIndex(where: { $0.id == destination }) ?? tabs.count)
        saveTabs()
    }
    func navigate(_ destination: MacDestination, folderID: String? = nil, tags: Set<String> = [], newTab: Bool = false) async throws {
        let location = MacWorkspaceLocation(destination: destination, folderID: folderID, tagIDs: tags)
        if newTab { try await self.newTab(location) }
        else { try await transition { try self.validate(location); self.record(location); self.apply(location) } }
    }
    func open(_ document: DocumentRecord, newTab: Bool = false) async throws {
        guard isAuthorized else { throw LibraryError.wrongOwner }
        try validate(MacWorkspaceLocation(documentID: document.id))
        if registry?.focusDocument(document.id, except: self) == true { return }
        if let tab = tabs.first(where: { $0.location.documentID == document.id }) { try await selectTab(tab.id); return }
        var location = activeTab.location; location.documentID = document.id
        if newTab { try await self.newTab(location) }
        else { try await transition { self.record(location); self.apply(location) } }
    }
    func travel(_ direction: Int) async throws {
        guard isAuthorized else { throw LibraryError.wrongOwner }
        let tab = activeTab
        let parent = direction == -1 ? parentBackLocation : nil
        let index = tab.historyIndex + direction
        guard parent != nil || tab.history.indices.contains(index) else { return }
        let location = parent ?? tab.history[index]
        if let id = location.documentID, registry?.focusDocument(id, except: self) == true { return }
        try await transition {
            guard self.activeID == tab.id else { throw LibraryError.staleWorkspace }
            try self.validate(location)
            if let parent {
                // Insert before the current page so Forward returns to that same page.
                tab.history.insert(parent, at: tab.historyIndex)
            } else { tab.historyIndex = index }
            tab.location = location
            self.apply(location)
        }
    }
    func switchSpace(_ id: String) async throws {
        guard isAuthorized, !isBusy else { throw LibraryError.staleWorkspace }
        saveTabs(); isBusy = true
        defer { isBusy = false }
        try await environment.switchSpace(to: id)
        spaceID = environment.selectedSpaceID
        restoreTabs(); apply(activeTab.location)
    }
    func acceptEnvironmentNavigation() {
        guard isAuthorized, !isBusy else { return }
        if spaceID != environment.selectedSpaceID {
            saveTabs(); spaceID = environment.selectedSpaceID; restoreTabs()
            if environment.selectedDocumentID == nil && environment.pendingDocumentID == nil { apply(activeTab.location) }
        }
        if let document = environment.selectedDocumentID ?? environment.pendingDocumentID,
           activeTab.location.documentID != document,
           let record = try? environment.documents.document(id: document) {
            perform { try await self.open(record) }
        }
    }
    func createDocument() {
        perform {
            try await self.environment.prepareForWorkspaceNavigation()
            if let document = self.environment.createDocument(folderID: self.activeTab.location.folderID == "__unsorted" ? nil : self.activeTab.location.folderID) {
                try await self.open(document, newTab: true)
            }
        }
    }
    func requestTrash(_ ids: Set<String>) { trashIDs = ids; confirmingTrash = !ids.isEmpty }
    func saveTabs() {
        guard isAuthorized else { return }
        let archive = MacWorkspaceArchive(activeID: activeID, tabs: tabs.map { .init(id: $0.id, location: $0.location,
            history: $0.history, historyIndex: $0.historyIndex, query: $0.browser.query, sort: $0.browser.sort, showsList: $0.browser.showsList,
            showsCompletedTasks: $0.browser.showsCompletedTasks, calendarDate: $0.calendar?.selectedDate) })
        if let data = try? JSONEncoder().encode(archive) { preferences.set(data, forKey: archiveKey) }
    }
    func flush() async throws { try await environment.prepareForWorkspaceNavigation(); saveTabs() }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = queuedOperation
        queuedOperation = Task {
            await previous?.value
            do { try await operation() } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func waitForOperations() async { await queuedOperation?.value }
    func reconcile() {
        guard isAuthorized else { return }
        for tab in tabs {
            if (try? validate(tab.location)) == nil, tab.location.documentID != nil {
                tab.location.documentID = nil
                if tab.id == activeID { apply(tab.location) }
            }
        }
        objectWillChange.send()
    }
    private func transition(_ change: () throws -> Void) async throws {
        guard !isBusy else { throw LibraryError.staleWorkspace }
        guard isAuthorized, environment.selectedSpaceID == spaceID else { throw LibraryError.wrongOwner }
        isBusy = true; defer { isBusy = false }
        try await flush()
        guard isAuthorized, environment.selectedSpaceID == spaceID else { throw LibraryError.staleWorkspace }
        try change(); saveTabs()
    }
    private func record(_ location: MacWorkspaceLocation) {
        guard activeTab.location != location else { return }
        activeTab.location = location
        activeTab.history = Array(activeTab.history.prefix(activeTab.historyIndex + 1)) + [location]
        activeTab.historyIndex = activeTab.history.count - 1
        objectWillChange.send()
    }
    private func validate(_ location: MacWorkspaceLocation) throws {
        if let id = location.documentID {
            guard let record = try environment.documents.document(id: id), record.spaceID == spaceID,
                  !record.isTrashed, !record.isArchived else { throw LibraryError.wrongOwner }
        }
        if let id = location.folderID, id != "__unsorted" {
            guard environment.overview.folders.contains(where: { $0.id == id && $0.spaceID == spaceID }) else { throw LibraryError.wrongOwner }
        }
        if !location.tagIDs.isEmpty,
           !location.tagIDs.isSubset(of: Set(try environment.tags.catalogue().map(\.id))) { throw LibraryError.wrongOwner }
    }
    private func apply(_ location: MacWorkspaceLocation) {
        environment.selectedDocumentID = nil
        environment.selectedDestination = location.destination.applicationDestination
        environment.selectedFolderID = location.folderID; environment.selectedTagIDs = location.tagIDs
        if let id = location.documentID, let document = try? environment.documents.document(id: id) { environment.select(document) }
        objectWillChange.send()
    }
    private func restoreTabs() {
        tabs = []
        if let data = preferences.data(forKey: archiveKey), let archive = try? JSONDecoder().decode(MacWorkspaceArchive.self, from: data) {
            tabs = archive.tabs.filter { (try? validate($0.location)) != nil }.prefix(40).map {
                let tab = MacWorkspaceTab(id: $0.id, location: $0.location, history: $0.history, historyIndex: $0.historyIndex)
                tab.browser.query = $0.query; tab.browser.sort = $0.sort; tab.browser.showsList = $0.showsList
                tab.browser.showsCompletedTasks = $0.showsCompletedTasks ?? false
                if let date = $0.calendarDate { calendar(for: tab).select(date) }
                return tab
            }
            activeID = archive.activeID
        }
        if tabs.isEmpty { tabs = [MacWorkspaceTab()] }
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs[0].id }
    }
}
