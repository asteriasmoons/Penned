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
    static let galleryHorizontalInset: CGFloat = 20
    var preferredColumns: Int { Self.galleryColumns(width: Self.galleryWidth(available: width), preferred: Int.max) }
    static func galleryColumns(width: CGFloat, preferred: Int, compact: Bool = false) -> Int {
        min(max(1, preferred), max(1, Int((width + 10) / ((compact ? 144 : galleryPreferredCardWidth) + 10))))
    }
    static func galleryWidth(available: CGFloat) -> CGFloat {
        max(0, available - 2 * galleryHorizontalInset)
    }
    static func galleryCardWidth(available: CGFloat, columns: Int) -> CGFloat {
        max(0, (galleryWidth(available: available) - CGFloat(max(0, columns - 1)) * 10) / CGFloat(max(1, columns)))
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
            case .dailyNotes: return "mooncal"
            case .connect: return "cloudie"
            case .recents: return "clockwavy"
            case .favorites: return "starfill"
            case .allDocuments: return "linedpages"
            case .folders: return "openedfolder"
            case .spaces: return "spaces"
            case .templates: return "bentpages"
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

    func selectTab(_ id: UUID, openingTrace: PennedDocumentOpenTrace? = nil) async throws {
        guard id != activeID, tabs.contains(where: { $0.id == id }) else {
            openingTrace?.event("workspace-tab-ignored", "reason=\(id == activeID ? "already-active" : "tab-missing")")
            return
        }
        try await transition(openingTrace: openingTrace) {
            self.activeID = id
            self.apply(self.activeTab.location, openingTrace: openingTrace)
        }
    }

    func newTab(_ location: PadWorkspaceLocation = PadWorkspaceLocation(), openingTrace: PennedDocumentOpenTrace? = nil) async throws {
        try await transition(openingTrace: openingTrace) {
            try self.validate(location)
            var tab = PadWorkspaceTab()
            tab.location = location; tab.history = [location]
            self.tabs.append(tab); self.activeID = tab.id
            self.apply(location, openingTrace: openingTrace)
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
        try await openDocument(id: document.id, newTab: newTab)
    }

    // Open by id so body-free library surfaces (gallery, sidebar) open a document
    // with exactly one record fetch — the authoritative read this method already
    // performed — instead of loading the record at the call site and again here.
    func openDocument(id documentID: String, newTab: Bool = false, openingTrace: PennedDocumentOpenTrace? = nil) async throws {
        let trace = openingTrace ?? (PennedDocumentOpenTrace.enabled ? PennedDocumentOpenTrace(documentID: documentID, source: "ipad-workspace") : nil)
        let opened = trace?.event("workspace-request-start", "busy=\(isBusy) newTab=\(newTab) selected=\(environment.selectedDocumentID ?? "-") pending=\(environment.pendingDocumentID ?? "-")")
        do {
            print("🛠️ PENNED-OPEN workspace-request id=\(documentID) busy=\(isBusy) activeTab=\(activeID)")
            let record = try environment.documents.document(id: documentID)
            guard let current = record, current.spaceID == spaceID, !current.isTrashed else {
                trace?.event("workspace-request-rejected", "reason=document-validation found=\(record != nil) spaceMatches=\(record?.spaceID == spaceID) trashed=\(record?.isTrashed == true)", since: opened)
                throw LibraryError.wrongOwner
            }
            if newTab, let existing = tabs.first(where: { $0.location.documentID == documentID }) {
                trace?.event("workspace-request-routed", "route=existing-tab")
                try await selectTab(existing.id, openingTrace: trace)
                trace?.event("workspace-request-returned", since: opened)
                return
            }
            var location = activeTab.location
            location.documentID = current.id
            print("🛠️ PENNED-OPEN workspace-location id=\(current.id) destination=\(location.destination) newTab=\(newTab)")
            trace?.event("workspace-request-routed", "route=\(newTab ? "new-tab" : "active-tab")")
            if newTab { try await self.newTab(location, openingTrace: trace) }
            else {
                try await transition(openingTrace: trace) { self.record(location); self.apply(location, openingTrace: trace) }
            }
            trace?.event("workspace-request-returned", since: opened)
        } catch {
            trace?.event("workspace-request-failed", "error=\(PennedDocumentOpenTrace.errorCode(error))", since: opened)
            throw error
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
            if let title = environment.editorCache.model(for: id)?.document?.title { return title }
            if let summary = (try? environment.documents.summary(id: id)) ?? nil { return summary.title }
            return "Document"
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

    private func transition(openingTrace: PennedDocumentOpenTrace? = nil, _ change: () throws -> Void) async throws {
        let started = openingTrace?.event("workspace-transition-start", "busy=\(isBusy) switchingSpace=\(environment.isSwitchingSpace)")
        print("🛠️ PENNED-OPEN transition-enter busy=\(isBusy) selected=\(environment.selectedDocumentID ?? "nil")")
        guard !isBusy else {
            openingTrace?.event("workspace-transition-ignored", "reason=workspace-busy", since: started)
            print("🛠️ PENNED-OPEN transition-skipped-busy")
            return
        }
        guard accountIsCurrent else {
            openingTrace?.event("workspace-transition-rejected", "reason=account-not-current", since: started)
            throw LibraryError.wrongOwner
        }
        start()
        capture()
        isBusy = true
        defer {
            isBusy = false
            openingTrace?.event("workspace-transition-ended", "busy=\(isBusy)", since: started)
        }
        let startingSpace = spaceID
        print("🛠️ PENNED-OPEN transition-prepare-start")
        let preparation = openingTrace?.event("workspace-save-start")
        do {
            try await environment.prepareForWorkspaceNavigation()
        } catch {
            openingTrace?.event("workspace-save-failed", "error=\(PennedDocumentOpenTrace.errorCode(error))", since: preparation)
            throw error
        }
        openingTrace?.event("workspace-save-completed", since: preparation)
        print("🛠️ PENNED-OPEN transition-prepare-finished")
        guard environment.database.isAccessible, environment.database.libraryID == libraryID,
              environment.selectedSpaceID == startingSpace else {
            openingTrace?.event("workspace-transition-rejected", "databaseAccessible=\(environment.database.isAccessible) libraryMatches=\(environment.database.libraryID == libraryID) spaceMatches=\(environment.selectedSpaceID == startingSpace)", since: started)
            throw LibraryError.staleWorkspace
        }
        guard accountIsCurrent else {
            openingTrace?.event("workspace-transition-rejected", "reason=account-changed-after-save", since: started)
            throw LibraryError.wrongOwner
        }
        do { try change() } catch {
            openingTrace?.event("workspace-transition-failed", "reason=apply-threw error=\(PennedDocumentOpenTrace.errorCode(error))", since: started)
            throw error
        }
        openingTrace?.event("workspace-transition-applied", since: started)
        print("🛠️ PENNED-OPEN transition-applied selected=\(environment.selectedDocumentID ?? "nil")")
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

    private func apply(_ location: PadWorkspaceLocation, openingTrace: PennedDocumentOpenTrace? = nil) {
        let started = openingTrace?.event("workspace-apply-start")
        print("🛠️ PENNED-OPEN apply-start id=\(location.documentID ?? "nil") destination=\(location.destination)")
        environment.selectedDocumentID = nil
        environment.selectedDestination = location.destination.base
        environment.selectedFolderID = location.folderID
        environment.selectedTagIDs = location.tagIDs
        environment.isSettingsPresented = location.destination == .settings
        if let id = location.documentID {
            let record: DocumentRecord?
            do { record = try environment.documents.document(id: id) } catch {
                openingTrace?.event("workspace-apply-ignored", "reason=lookup-failed error=\(PennedDocumentOpenTrace.errorCode(error))", since: started)
                return
            }
            guard let document = record, document.spaceID == spaceID, !document.isTrashed else {
                openingTrace?.event("workspace-apply-ignored", "reason=document-validation found=\(record != nil) spaceMatches=\(record?.spaceID == spaceID) trashed=\(record?.isTrashed == true)", since: started)
                return
            }
            environment.select(document, openingTrace: openingTrace)
            openingTrace?.event("workspace-apply-returned", "selected=\(environment.selectedDocumentID ?? "-") pending=\(environment.pendingDocumentID ?? "-")", since: started)
            print("🛠️ PENNED-OPEN apply-selected id=\(document.id) selected=\(environment.selectedDocumentID ?? "nil")")
            if location.destination.base == .calendar {
                environment.calendarDocumentReturnID = location.calendarDocumentReturnID
            }
        } else {
            openingTrace?.event("workspace-apply-ignored", "reason=no-document-in-location", since: started)
        }
    }
}

private struct PadWorkspaceKey: EnvironmentKey { static let defaultValue: PadWorkspaceModel? = nil }
private struct PadGalleryColumnsKey: EnvironmentKey { static let defaultValue = 2 }
private struct PadGalleryContentWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
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
    // The real width the gallery has to lay out in, handed down from the pad
    // workspace's live geometry (full width minus the sidebar when it pushes).
    // Reliable across rotation, unlike a view's own onGeometryChange reading.
    var pennedGalleryContentWidth: CGFloat {
        get { self[PadGalleryContentWidthKey.self] }
        set { self[PadGalleryContentWidthKey.self] = newValue }
    }
    var pennedWorkspaceTabActive: Bool {
        get { self[PadWorkspaceActiveKey.self] }
        set { self[PadWorkspaceActiveKey.self] = newValue }
    }
}
