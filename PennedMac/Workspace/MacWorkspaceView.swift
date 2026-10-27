import SwiftUI

struct MacWorkspaceView: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @EnvironmentObject private var environment: AppEnvironment
    @SceneStorage("penned.mac.sidebarWidth") private var sidebarWidth: Double = 240
    @SceneStorage("penned.mac.inspectorWidth") private var inspectorWidth: Double = 310
    @SceneStorage("penned.mac.sidebarVisible") private var sidebarVisible = true
    @SceneStorage("penned.mac.inspectorVisible") private var inspectorVisible = false
    @State private var windowWidth: CGFloat = 1320
    private var openEditors: [DocumentEditorModel] {
        Set(workspace.tabs.compactMap { $0.location.documentID }).compactMap { environment.editorCache.model(for: $0) }
            .sorted { $0.documentID < $1.documentID }
    }
    var body: some View {
        HSplitView {
            if workspace.sidebarVisible {
                MacNavigationSidebar(workspace: workspace)
                    .frame(minWidth: 200, idealWidth: sidebarWidth, maxWidth: 340)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { sidebarWidth = $0 }
            }
            center.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                .background(MacSplitSizing(sidebarVisible: workspace.sidebarVisible, inspectorVisible: workspace.showsInspector,
                    sidebarWidth: $sidebarWidth, inspectorWidth: $inspectorWidth).frame(width: 0, height: 0))
            if workspace.showsInspector {
                MacDocumentInspector(workspace: workspace)
                    .frame(minWidth: 270, idealWidth: inspectorWidth, maxWidth: 390)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    if workspace.sidebarVisible { Color.clear.frame(width: max(0, sidebarWidth - 130)) }
                    MacIconButton("Toggle Navigation Sidebar", icon: "sidebar") { workspace.sidebarVisible.toggle() }
                    MacWorkspaceTabBar(workspace: workspace)
                }.frame(width: max(400, windowWidth - 150), alignment: .leading)
            }.sharedBackgroundVisibility(.hidden)
            if workspace.canShowInspector {
                ToolbarItem(placement: .primaryAction) {
                    MacIconButton("Toggle Document Inspector", icon: "sidebar") { workspace.inspectorVisible.toggle() }
                }.sharedBackgroundVisibility(.hidden)
            }
        }
        .background(MacWindowBridge(workspace: workspace).frame(width: 0, height: 0))
        .modifier(PublishingRuntime())
        .onAppear { workspace.sidebarVisible = sidebarVisible; workspace.inspectorVisible = inspectorVisible }
        .onChange(of: workspace.sidebarVisible) { _, value in sidebarVisible = value }
        .onChange(of: workspace.inspectorVisible) { _, value in inspectorVisible = value }
        .onChange(of: workspace.activeTab.location.documentID) { _, _ in workspace.styleGalleryVisible = false }
        .onChange(of: environment.selectedDocumentID) { _, _ in workspace.acceptEnvironmentNavigation() }
        .onChange(of: environment.pendingDocumentID) { _, _ in workspace.acceptEnvironmentNavigation() }
        .onChange(of: environment.selectedFolderID) { _, folder in
            guard !workspace.isBusy, environment.selectedFolderID == folder, folder != workspace.activeTab.location.folderID,
                  environment.selectedDocumentID == nil, environment.pendingDocumentID == nil else { return }
            workspace.perform { try await workspace.navigate(.allDocuments, folderID: folder) }
        }
        .onChange(of: environment.selectedSpaceID) { _, _ in workspace.acceptEnvironmentNavigation() }
        .onChange(of: environment.selectedDestination) { _, destination in
            guard !workspace.isBusy, environment.selectedDestination == destination, environment.selectedDocumentID == nil, environment.pendingDocumentID == nil,
                  destination != workspace.activeTab.location.destination.applicationDestination else { return }
            let mapped = MacDestination.allCases.first { $0.applicationDestination == destination } ?? .allDocuments
            workspace.perform { try await workspace.navigate(mapped, folderID: environment.selectedFolderID, tags: environment.selectedTagIDs) }
        }
        .sheet(item: $environment.spaceSheet) { sheet in
            switch sheet {
            case .edit(let space): SpaceEditorSheet(space: space).frame(minWidth: 500, idealHeight: 580)
            case .transfer(let content, let copy): SpaceTransferSheet(item: content, copy: copy).frame(minWidth: 500, idealHeight: 580)
            }
        }
        .sheet(item: $environment.librarySheet) { sheet in
            switch sheet {
            case .folder(let request): FolderEditorSheet(request: request).frame(minWidth: 500, idealHeight: 500)
            case .move(let request): FolderDestinationPicker(request: request).frame(minWidth: 480, idealHeight: 520)
            }
        }
        .background(MacStyleGalleryPresenter(workspace: workspace).frame(width: 0, height: 0))
        .sheet(isPresented: $workspace.showHistory) {
            if let model = workspace.activeEditor { MacVersionHistory(model: model).frame(width: 540, height: 540) }
        }
        .macConfirmationDialog("Move selected documents to Trash?", isPresented: $workspace.confirmingTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                workspace.perform {
                    try await workspace.flush()
                    _ = environment.trashDocuments(workspace.trashIDs)
                    workspace.trashIDs = []; workspace.reconcile()
                }
            }
        } message: { Text("Nested pages move with their parent. Documents can be restored from Trash.") }
        .macConfirmationDialog("Permanently delete this document?", isPresented: Binding(get: { environment.documentPendingDeletion != nil }, set: { if !$0 { environment.documentPendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let document = environment.documentPendingDeletion { environment.permanentlyDelete(document); environment.documentPendingDeletion = nil }
            }
        } message: { Text("This removes the document and its retained content. This cannot be undone.") }
        .macAlert("Unable to Complete Action", isPresented: Binding(get: { workspace.errorMessage != nil || environment.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil; environment.errorMessage = nil } })) {
            Button("OK") { workspace.errorMessage = nil; environment.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? environment.errorMessage ?? "") }
    }
    private var center: some View {
        ZStack {
            if workspace.activeTab.location.documentID == nil {
                MacBrowserDestination(workspace: workspace, tab: workspace.activeTab).id(workspace.activeID)
            }
            ForEach(openEditors, id: \.documentID) { model in
                MacDocumentEditorContainer(workspace: workspace, model: model)
                    .opacity(workspace.activeTab.location.documentID == model.documentID ? 1 : 0)
                    .allowsHitTesting(workspace.activeTab.location.documentID == model.documentID)
                    .accessibilityHidden(workspace.activeTab.location.documentID != model.documentID)
            }
        }.clipped()
    }
}

private struct MacBrowserDestination: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var tab: MacWorkspaceTab
    var body: some View {
        Group {
            switch tab.location.destination {
            case .calendar: MacCalendarBrowser(workspace: workspace, tab: tab)
            case .tasks: MacTaskBrowser(workspace: workspace, browser: tab.browser)
            case .spaces: SpaceManagementView()
            default: MacDocumentBrowser(workspace: workspace, tab: tab)
            }
        }
    }
}
