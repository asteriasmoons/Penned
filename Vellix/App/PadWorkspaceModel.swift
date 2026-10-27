import Combine
import Foundation
import SwiftUI

nonisolated struct PadWorkspaceMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    var sidebarWidth: CGFloat { min(336, max(280, width * 0.38)) }
    var overlaysSidebar: Bool { width < 1000 || height > width }
    // Match the existing two-column iPhone 16 Plus gallery at standard display scale.
    static let phoneGalleryCardWidth: CGFloat = (430 - 16 * 2 - 10) / 2
    static let galleryWidthIncrease: CGFloat = 1.1
    static let galleryCornerEnlargement: CGFloat = 1.05
    static let galleryPreviewHeightFraction: CGFloat = 0.8 / galleryWidthIncrease
    static let galleryPreferredCardWidth = phoneGalleryCardWidth * galleryWidthIncrease * galleryCornerEnlargement
    var preferredColumns: Int { max(1, Int((width - 32 + 10) / (Self.galleryPreferredCardWidth + 10))) }
    static func galleryColumns(width: CGFloat, preferred: Int, compact: Bool = false) -> Int {
        min(max(1, preferred), max(1, Int((width + 10) / ((compact ? 144 : galleryPreferredCardWidth) + 10))))
    }
    static func galleryWidth(available: CGFloat, columns: Int, compact: Bool = false) -> CGFloat {
        min(max(0, available - 32), CGFloat(columns) * (compact ? 144 : galleryPreferredCardWidth) + CGFloat(max(0, columns - 1)) * 10)
    }
    static func galleryCardWidth(available: CGFloat, columns: Int, compact: Bool = false) -> CGFloat {
        max(0, (galleryWidth(available: available, columns: columns, compact: compact) - CGFloat(max(0, columns - 1)) * 10) / CGFloat(max(1, columns)))
    }
}

enum PadWorkspaceDestination: Equatable {
    case library(AppDestination), tasks, collections, settings
    var base: AppDestination {
        switch self {
        case .library(let destination): return destination
        case .tasks: return .calendar
        case .collections, .settings: return .allDocuments
        }
    }
    var title: String {
        switch self {
        case .library(let destination): return destination.title
        case .tasks: return "Tasks"
        case .collections: return "Collections"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .tasks: return "checklist"
        case .collections: return "gridboard"
        case .settings: return "settings"
        case .library(let destination):
            switch destination {
            case .home: return "houseoutline"
            case .calendar: return "mooncal"
            case .recents: return "clockwavy"
            case .favorites: return "starfill"
            case .allDocuments: return "linedpages"
            case .folders: return "openedfolder"
            case .spaces: return "spaces"
            case .templates: return "copy"
            case .tags: return "hashtagwavy"
            case .trash: return "trash"
            }
        }
    }
}

struct PadWorkspaceLocation: Equatable {
    var destination: PadWorkspaceDestination = .library(.allDocuments)
    var folderID: String?
    var documentID: String?
    var tagIDs: Set<String> = []
    var calendarDocumentReturnID: String?
}

struct PadWorkspaceTab: Identifiable {
    let id = UUID()
    var location = PadWorkspaceLocation()
    var history = [PadWorkspaceLocation()]
    var historyIndex = 0
}

@MainActor
final class PadWorkspaceModel: ObservableObject {
    @Published private(set) var tabs: [PadWorkspaceTab]
    @Published private(set) var activeID: UUID
    @Published private(set) var isBusy = false
    @Published private(set) var spaceID: String?
    let environment: AppEnvironment
    private let libraryID: String
    private var ownerKey: String?
    private var currentOwner: (() -> String?)?
    private var hasStarted = false

    init(environment: AppEnvironment) {
        self.environment = environment
        libraryID = environment.database.libraryID
        spaceID = environment.selectedSpaceID
        var tab = PadWorkspaceTab()
        if environment.selectedDocumentID != nil || environment.pendingDocumentID != nil ||
            environment.selectedDestination != .home || environment.selectedFolderID != nil || environment.isSettingsPresented {
            tab.location = PadWorkspaceLocation(destination: environment.isSettingsPresented && environment.selectedDocumentID == nil
                ? .settings : .library(environment.selectedDestination),
                folderID: environment.selectedFolderID, documentID: environment.selectedDocumentID ?? environment.pendingDocumentID,
                tagIDs: environment.selectedTagIDs, calendarDocumentReturnID: environment.calendarDocumentReturnID)
        }
        tab.history = [tab.location]
        tabs = [tab]; activeID = tab.id
    }

    var activeTab: PadWorkspaceTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var canGoBack: Bool { activeTab.historyIndex > 0 }
    var canGoForward: Bool { activeTab.historyIndex + 1 < activeTab.history.count }

    func bindAccount(_ ownerKey: String?, currentOwner: @escaping () -> String?) {
        self.ownerKey = ownerKey
        self.currentOwner = currentOwner
    }

    private var accountIsCurrent: Bool { currentOwner.map { $0() == ownerKey } ?? true }

    func start() {
        guard !hasStarted, accountIsCurrent, environment.database.isAccessible,
              environment.selectedSpaceID == spaceID else { return }
        hasStarted = true
        apply(activeTab.location)
    }

    var observedLocation: PadWorkspaceLocation {
        let old = activeTab.location.destination
        let destination: PadWorkspaceDestination
        if environment.isSettingsPresented { destination = .settings }
        else if old.base == environment.selectedDestination, environment.selectedFolderID == nil,
                old != .settings { destination = old }
        else { destination = .library(environment.selectedDestination) }
        return PadWorkspaceLocation(destination: destination, folderID: environment.selectedFolderID,
            documentID: environment.selectedDocumentID, tagIDs: environment.selectedTagIDs,
            calendarDocumentReturnID: environment.calendarDocumentReturnID)
    }

    func capture() {
        guard hasStarted, !isBusy, accountIsCurrent, environment.database.isAccessible, environment.selectedSpaceID == spaceID,
              environment.pendingDocumentID == nil,
              let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let next = observedLocation
        guard tabs[index].location != next else { return }
        tabs[index].location = next
        tabs[index].history = Array(tabs[index].history.prefix(tabs[index].historyIndex + 1)) + [next]
        tabs[index].historyIndex = tabs[index].history.count - 1
    }

    func selectTab(_ id: UUID) async throws {
        guard id != activeID, tabs.contains(where: { $0.id == id }) else { return }
        try await transition {
            self.activeID = id
            self.apply(self.activeTab.location)
        }
    }

    func newTab(_ location: PadWorkspaceLocation = PadWorkspaceLocation()) async throws {
        try await transition {
            try self.validate(location)
            var tab = PadWorkspaceTab()
            tab.location = location; tab.history = [location]
            self.tabs.append(tab); self.activeID = tab.id
            self.apply(location)
        }
    }

    func closeTab(_ id: UUID) async throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        try await transition {
            self.tabs.remove(at: index)
            if self.tabs.isEmpty { self.tabs = [PadWorkspaceTab()] }
            if self.activeID == id {
                self.activeID = self.tabs[min(index, self.tabs.count - 1)].id
                self.apply(self.activeTab.location)
            }
        }
    }

    func navigate(_ destination: PadWorkspaceDestination, folderID: String? = nil, tags: Set<String> = [], newTab: Bool = false) async throws {
        let location = PadWorkspaceLocation(destination: destination, folderID: folderID, tagIDs: tags)
        if newTab { try await self.newTab(location); return }
        try await transition {
            try self.validate(location)
            self.record(location)
            self.apply(location)
        }
    }

    func openDocument(_ document: DocumentRecord, newTab: Bool = false) async throws {
        guard document.spaceID == spaceID, let current = try environment.documents.document(id: document.id),
              !current.isTrashed, current.spaceID == spaceID else { throw LibraryError.wrongOwner }
        if newTab, let existing = tabs.first(where: { $0.location.documentID == document.id }) {
            try await selectTab(existing.id); return
        }
        var location = activeTab.location
        location.documentID = current.id
        if newTab { try await self.newTab(location) }
        else {
            try await transition { self.record(location); self.apply(location) }
        }
    }

    func travel(_ direction: Int) async throws {
        let index = activeTab.historyIndex + direction
        guard activeTab.history.indices.contains(index) else { return }
        try await transition {
            guard let tab = self.tabs.firstIndex(where: { $0.id == self.activeID }) else { return }
            self.tabs[tab].historyIndex = index
            let location = self.tabs[tab].history[index]
            self.tabs[tab].location = location
            self.apply(location)
        }
    }

    func resetForSpaceChange() {
        guard spaceID != environment.selectedSpaceID else { return }
        let settings = activeTab.location.destination == .settings
        spaceID = environment.selectedSpaceID
        var tab = PadWorkspaceTab()
        if settings { tab.location.destination = .settings; tab.history = [tab.location] }
        tabs = [tab]; activeID = tab.id
        hasStarted = true
        environment.selectedDestination = .allDocuments
        environment.isSettingsPresented = settings
    }

    func reconcile() {
        guard accountIsCurrent, environment.database.isAccessible, spaceID == environment.selectedSpaceID, !isBusy else { return }
        for index in tabs.indices {
            func validated(_ location: PadWorkspaceLocation) -> PadWorkspaceLocation {
                var result = location
                if let id = result.documentID,
                   (try? environment.documents.document(id: id)).map({ $0.spaceID == spaceID && !$0.isTrashed }) != true { result.documentID = nil }
                if result.documentID == nil { result.calendarDocumentReturnID = nil }
                if let id = result.folderID, id != "__unsorted", !environment.overview.folders.contains(where: { $0.id == id }) { result.folderID = nil }
                return result
            }
            tabs[index].location = validated(tabs[index].location)
            tabs[index].history = tabs[index].history.map(validated)
        }
        if activeTab.location.documentID == nil, let id = environment.selectedDocumentID,
           (try? environment.documents.document(id: id)).map({ $0.spaceID == spaceID && !$0.isTrashed }) != true {
            environment.selectedDocumentID = nil
        }
    }

    func title(for tab: PadWorkspaceTab) -> String {
        if let id = tab.location.documentID {
            return environment.editorCache.model(for: id)?.document?.title ?? environment.overview.all.first { $0.id == id }?.title ?? "Document"
        }
        if let id = tab.location.folderID {
            return id == "__unsorted" ? "Unsorted" : environment.overview.folders.first { $0.id == id }?.title ?? "Folder"
        }
        if !tab.location.tagIDs.isEmpty, let tags = try? environment.tags.catalogue() {
            let names = tags.filter { tab.location.tagIDs.contains($0.id) }.map { "#" + $0.name }
            if !names.isEmpty { return names.joined(separator: " + ") }
        }
        return tab.location.destination.title
    }

    private func record(_ location: PadWorkspaceLocation) {
        guard let index = tabs.firstIndex(where: { $0.id == activeID }), tabs[index].location != location else { return }
        tabs[index].location = location
        tabs[index].history = Array(tabs[index].history.prefix(tabs[index].historyIndex + 1)) + [location]
        tabs[index].historyIndex = tabs[index].history.count - 1
    }

    private func transition(_ change: () throws -> Void) async throws {
        guard !isBusy else { return }
        guard accountIsCurrent else { throw LibraryError.wrongOwner }
        start()
        capture()
        isBusy = true
        defer { isBusy = false }
        let startingSpace = spaceID
        try await environment.prepareForWorkspaceNavigation()
        guard environment.database.isAccessible, environment.database.libraryID == libraryID,
              environment.selectedSpaceID == startingSpace else { throw LibraryError.staleWorkspace }
        guard accountIsCurrent else { throw LibraryError.wrongOwner }
        try change()
    }

    private func validate(_ location: PadWorkspaceLocation) throws {
        if let id = location.documentID {
            guard let document = try environment.documents.document(id: id), document.spaceID == spaceID,
                  !document.isTrashed else { throw LibraryError.wrongOwner }
        }
        if let id = location.folderID, id != "__unsorted" {
            guard environment.overview.folders.contains(where: { $0.id == id && $0.spaceID == spaceID }) else { throw LibraryError.wrongOwner }
        }
        if !location.tagIDs.isEmpty {
            guard location.tagIDs.isSubset(of: Set(try environment.tags.catalogue().map(\.id))) else { throw LibraryError.wrongOwner }
        }
    }

    private func apply(_ location: PadWorkspaceLocation) {
        environment.selectedDocumentID = nil
        environment.selectedDestination = location.destination.base
        environment.selectedFolderID = location.folderID
        environment.selectedTagIDs = location.tagIDs
        environment.isSettingsPresented = location.destination == .settings
        if let id = location.documentID, let document = try? environment.documents.document(id: id),
           document.spaceID == spaceID, !document.isTrashed {
            environment.select(document)
            if location.destination.base == .calendar {
                environment.calendarDocumentReturnID = location.calendarDocumentReturnID
            }
        }
    }
}

private struct PadWorkspaceKey: EnvironmentKey { static let defaultValue: PadWorkspaceModel? = nil }
private struct PadGalleryColumnsKey: EnvironmentKey { static let defaultValue = 2 }
private struct PadWorkspaceActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var pennedWorkspace: PadWorkspaceModel? {
        get { self[PadWorkspaceKey.self] }
        set { self[PadWorkspaceKey.self] = newValue }
    }
    var pennedGalleryColumns: Int {
        get { self[PadGalleryColumnsKey.self] }
        set { self[PadGalleryColumnsKey.self] = newValue }
    }
    var pennedWorkspaceTabActive: Bool {
        get { self[PadWorkspaceActiveKey.self] }
        set { self[PadWorkspaceActiveKey.self] = newValue }
    }
}
