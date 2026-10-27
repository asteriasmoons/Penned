import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PadWorkspaceView: View {
    @ObservedObject var environment: AppEnvironment
    @EnvironmentObject private var accounts: AppState
    @StateObject private var workspace: PadWorkspaceModel
    @State private var sidebarVisible = false
    @State private var initializedSidebar = false
    @State private var windowSize: CGSize = .zero
    @State private var sidebarBeforeSettings: Bool?

    init(environment: AppEnvironment) {
        self.environment = environment
        _workspace = StateObject(wrappedValue: PadWorkspaceModel(environment: environment))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = PadWorkspaceMetrics(width: geometry.size.width, height: windowSize.height > 0 ? windowSize.height : geometry.size.height)
            let overlaysSidebar = metrics.overlaysSidebar || workspace.activeTab.location.destination == .settings
            ZStack(alignment: .leading) {
                // This content tree never moves between conditional split/overlay hierarchies.
                workspaceContent
                .padding(.leading, sidebarVisible && !overlaysSidebar ? metrics.sidebarWidth : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(sidebarVisible && overlaysSidebar)

                if sidebarVisible && overlaysSidebar {
                    Color.black.opacity(0.48).ignoresSafeArea()
                        .contentShape(Rectangle()).onTapGesture { toggleSidebar() }
                        .accessibilityLabel("Close sidebar").accessibilityAddTraits(.isButton)
                }
                PadWorkspaceSidebar(workspace: workspace, close: toggleSidebar)
                    .frame(width: min(metrics.sidebarWidth, max(0, geometry.size.width - 44)))
                    .frame(maxHeight: .infinity)
                    .background(VellixSurface.sidebar)
                    .overlay(alignment: .trailing) { Rectangle().fill(VellixSurface.hairline).frame(width: 1) }
                    .offset(x: sidebarVisible ? 0 : -metrics.sidebarWidth - 1)
                    .allowsHitTesting(sidebarVisible).accessibilityHidden(!sidebarVisible)
            }
            .clipped()
            .environment(\.pennedGalleryColumns, metrics.preferredColumns)
            .onAppear {
                if !initializedSidebar { sidebarVisible = !metrics.overlaysSidebar; initializedSidebar = true }
            }
        }
        .background(VellixSurface.appBackground)
        #if os(iOS)
        .background(PadWindowSizeProbe { windowSize = $0 })
        #endif
        .environment(\.pennedWorkspace, workspace)
        .fontDesign(.rounded).foregroundStyle(VellixSurface.ink).tint(VellixSurface.violet)
        .onAppear {
            let accountState = accounts
            workspace.bindAccount(accountState.currentAccountIdentity?.libraryOwnerKey) { [weak accountState] in
                accountState?.currentAccountIdentity?.libraryOwnerKey
            }
            workspace.start()
        }
        .onChange(of: workspace.observedLocation) { _, _ in workspace.capture() }
        .onChange(of: environment.pendingDocumentID) { _, _ in workspace.capture() }
        .onChange(of: environment.selectedSpaceID) { _, _ in workspace.resetForSpaceChange() }
        .onChange(of: environment.overview.all) { _, _ in workspace.reconcile() }
        .onChange(of: workspace.activeTab.location.destination) { _, destination in
            if destination == .settings {
                sidebarBeforeSettings = sidebarVisible
                sidebarVisible = false
            } else if let previous = sidebarBeforeSettings {
                sidebarBeforeSettings = nil
                sidebarVisible = previous
            }
        }
        .disabled(workspace.isBusy)
    }

    private var editorSidebarAction: (() -> Void)? {
        guard !sidebarVisible else { return nil }
        return { toggleSidebar() }
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if environment.selectedDocumentID == nil { header }
            ZStack {
                ForEach(workspace.tabs) { tab in
                    PadWorkspacePane(tab: tab, environment: environment)
                        .environment(\.pennedWorkspaceTabActive, tab.id == workspace.activeID)
                        .opacity(tab.id == workspace.activeID && environment.selectedDocumentID == nil ? 1 : 0)
                        .allowsHitTesting(tab.id == workspace.activeID && environment.selectedDocumentID == nil)
                        .accessibilityHidden(tab.id != workspace.activeID || environment.selectedDocumentID != nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ZStack {
                    PadEditorDeck(cache: environment.editorCache, selectedID: environment.selectedDocumentID,
                                  inspector: environment.isInspectorVisible, sidebarAction: editorSidebarAction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if environment.pendingDocumentID != nil {
                        ProgressView("Opening document").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                PadIconButton("Toggle Sidebar", icon: "sidebar", action: toggleSidebar)
                    .accessibilityIdentifier("ipad-sidebar-toggle")
            }
            Text(workspace.title(for: workspace.activeTab))
                .font(.system(.headline, design: .rounded).weight(.black)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button { perform { try await workspace.newTab() } } label: {
                    Label { Text("New Tab") } icon: { LibraryIcon(name: "addwavy", size: 18) }
                }
                Button { _ = environment.createDocument() } label: {
                    Label { Text("New Document") } icon: { LibraryIcon(name: "writepen", size: 18) }
                }
                Button { environment.createTemplate() } label: {
                    Label { Text("New Template") } icon: { LibraryIcon(name: "copy", size: 18) }
                }
                Button { perform { try await workspace.navigate(.settings) } } label: {
                    Label { Text("Settings") } icon: { LibraryIcon(name: "settings", size: 18) }
                }
                Button("Close Tab") { perform { try await workspace.closeTab(workspace.activeID) } }
            } label: { LibraryIcon(name: "dotswavy", size: 23).frame(width: 40, height: 40) }
                .pennedIconMenuStyle()
                .accessibilityLabel("Workspace actions").help("Workspace actions")
        }
        .padding(.horizontal, 16).frame(minHeight: 60)
        .background(VellixSurface.appBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(VellixSurface.hairline).frame(height: 0.5) }
    }

    private func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }
    private func perform(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { environment.report(error) } }
    }
}

struct PadIconButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    init(_ title: String, icon: String, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) { LibraryIcon(name: icon, size: 20).frame(width: 40, height: 40).contentShape(Circle()) }
            .buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

private struct PadEditorDeck: View {
    @ObservedObject var cache: DocumentEditorCache
    let selectedID: String?
    let inspector: Bool
    let sidebarAction: (() -> Void)?
    var body: some View {
        ZStack {
            ForEach(cache.preparedModels, id: \.documentID) { model in
                HStack(spacing: 0) {
                    DocumentEditorView(model: model, sidebarAction: sidebarAction)
                    if inspector && selectedID == model.documentID {
                        DocumentInspectorView(document: model.document).frame(maxWidth: 300)
                    }
                }
                .opacity(selectedID == model.documentID ? 1 : 0)
                .allowsHitTesting(selectedID == model.documentID)
                .accessibilityHidden(selectedID != model.documentID)
            }
        }.allowsHitTesting(selectedID != nil).accessibilityHidden(selectedID == nil)
    }
}

private struct PadWorkspacePane: View {
    let tab: PadWorkspaceTab
    @ObservedObject var environment: AppEnvironment
    @StateObject private var calendar: CalendarModel
    @StateObject private var search: SearchModel
    @State private var browsingLocation: PadWorkspaceLocation

    init(tab: PadWorkspaceTab, environment: AppEnvironment) {
        self.tab = tab; self.environment = environment
        _calendar = StateObject(wrappedValue: Self.makeCalendar(environment))
        _search = StateObject(wrappedValue: SearchModel(service: environment.search))
        _browsingLocation = State(initialValue: tab.location.destination == .settings ? PadWorkspaceLocation() : tab.location)
    }

    private static func makeCalendar(_ environment: AppEnvironment) -> CalendarModel {
        let calendar = CalendarModel(tasks: environment.tasks, documents: environment.documents,
            notes: environment.calendarEventNotes, database: environment.database, dailyNotes: environment.dailyNotes)
        calendar.completeTask = { [weak environment] id, occurrence, completed, skipped in
            guard let environment else { throw DocumentTaskError.missingTask }
            try await environment.setTaskCompleted(id: id, completed: completed, expectedOccurrenceID: occurrence, skipped: skipped)
        }
        return calendar
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .opacity(tab.location.destination == .settings ? 0 : 1)
                    .allowsHitTesting(tab.location.destination != .settings)
                    .accessibilityHidden(tab.location.destination == .settings)
                PadSettingsView()
                    .opacity(tab.location.destination == .settings ? 1 : 0)
                    .allowsHitTesting(tab.location.destination == .settings)
                    .accessibilityHidden(tab.location.destination != .settings)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .onChange(of: tab.location) { _, location in
            if location.destination != .settings { browsingLocation = location }
        }
    }

    @ViewBuilder private var content: some View {
        switch browsingLocation.destination {
        case .settings: Color.clear
        case .tasks: PadTasksView(model: calendar)
        case .collections: PadCollectionsView()
        case .library(let destination):
            switch destination {
            case .home: HomeView(environment: environment, search: search)
            case .calendar: CalendarView(model: calendar)
            case .recents: DocumentBrowserView(mode: .recent, documents: environment.overview.recent)
            case .favorites: DocumentBrowserView(mode: .favorites, documents: environment.overview.favorites)
            case .folders: DocumentBrowserView(mode: .folders, documents: [])
            case .allDocuments:
                if let id = browsingLocation.folderID {
                    DocumentBrowserView(mode: .folder(id), documents: environment.overview.all.filter { id == "__unsorted" ? $0.folderID == nil : $0.folderID == id },
                        displayTitle: id == "__unsorted" ? "Unsorted" : environment.overview.folders.first { $0.id == id }?.title)
                } else { DocumentBrowserView(mode: .all, documents: environment.overview.all) }
            case .spaces: PadSpaceManagementView()
            case .templates: TemplatesView()
            case .tags: TagBrowserView()
            case .trash: TrashView()
            }
        }
    }
}

#if os(iOS)
private struct PadWindowSizeProbe: UIViewRepresentable {
    let changed: (CGSize) -> Void
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.changed = changed; view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.changed = changed }
    final class Probe: UIView {
        var changed: ((CGSize) -> Void)?
        private var lastSize: CGSize = .zero
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        private func report() {
            guard let size = window?.bounds.size, size != lastSize else { return }
            lastSize = size
            DispatchQueue.main.async { [weak self] in self?.changed?(size) }
        }
    }
}
#endif

private struct PadTasksView: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.pennedWorkspaceTabActive) private var active
    @EnvironmentObject private var environment: AppEnvironment
    @State private var tasks: [DocumentTaskRecord] = []
    @State private var query = ""
    @State private var scope = LibrarySearchScope.keyword
    @State private var filter = "Open"
    @State private var scrollPosition = ScrollPosition(edge: .top)
    private var filteredTasks: [DocumentTaskRecord] {
        tasks.filter { task in
            (filter == "All" || (filter == "Completed" ? task.checked : !task.checked)) &&
            (query.isEmpty || task.documentTitle.localizedCaseInsensitiveContains(query) ||
                (scope == .keyword && task.text.localizedCaseInsensitiveContains(query)))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Tasks").font(.system(.title2, design: .rounded).weight(.black))
                LibrarySearchField(query: $query, scope: $scope, placeholder: "Search Tasks")
                Picker("Task Status", selection: $filter) {
                    Text("Open").tag("Open"); Text("Completed").tag("Completed"); Text("All").tag("All")
                }.pickerStyle(.segmented)
                ForEach(filteredTasks) { task in
                    if let date = task.metadata.scheduledDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    CalendarTaskRow(model: model, entry: CalendarTaskEntry(task: task, occurrenceID: task.metadata.occurrenceID,
                        scheduledDate: task.metadata.scheduledDate, kind: .current))
                    if model.documents[task.documentID] == nil {
                        Button {
                            do { environment.openCalendarDocument(try environment.documents.requireDocument(id: task.documentID)) }
                            catch { environment.report(error) }
                        } label: {
                            Label { Text(task.documentTitle) } icon: { LibraryIcon(name: "linedpages", size: 18) }
                                .font(.subheadline).foregroundStyle(VellixSurface.violet)
                        }.buttonStyle(.plain)
                    }
                    Divider()
                }
                if filteredTasks.isEmpty { Text("No matching tasks").foregroundStyle(.secondary).padding(.vertical, 40) }
                if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(VellixSurface.coral) }
            }.padding(24).frame(maxWidth: 880).frame(maxWidth: .infinity)
        }.scrollPosition($scrollPosition)
            .onAppear { if active { model.activate(); reload() } }.onDisappear { model.deactivate() }
            .onChange(of: active) { _, value in if value { model.activate(); reload() } else { model.deactivate() } }
            .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged)) { _ in if active { reload() } }
    }
    private func reload() {
        do { tasks = try environment.tasks.all() } catch { environment.report(error) }
    }
}

private struct PadCollectionsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var owners: [DocumentRecord] = []
    private var revision: String { environment.overview.all.map { $0.id + String($0.revision) + String($0.updatedAt.timeIntervalSince1970) }.joined() }
    var body: some View {
        DocumentBrowserView(mode: .all, documents: owners, displayTitle: "Collections")
            .task(id: revision) { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .pennedCollectionsChanged)) { _ in reload() }
    }
    private func reload() {
        do {
            owners = try environment.documents.editorDocuments().filter { document in
                guard !document.isTrashed, !document.isArchived, document.templateID == nil else { return false }
                return try !environment.collections.repository.collectionIDs(forDocument: document.id).isEmpty
            }
        } catch { environment.report(error) }
    }
}
