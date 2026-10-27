import AppKit
import SwiftUI

struct MacDocumentBrowser: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var tab: MacWorkspaceTab
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var browser: MacBrowserState
    @FocusState private var searchFocused: Bool
    @State private var width: CGFloat = 800
    private let previewHeightFraction: CGFloat = 0.65
    init(workspace: MacWorkspaceModel, tab: MacWorkspaceTab) {
        self.workspace = workspace; self.tab = tab; environment = workspace.environment; browser = tab.browser
    }
    private var allRecords: [DocumentRecord] {
        let overview = environment.overview
        if !tab.location.tagIDs.isEmpty { return (try? environment.tags.snapshot(selected: tab.location.tagIDs).documents.map(\.document)) ?? [] }
        if let folder = tab.location.folderID {
            return overview.all.filter { $0.folderID == (folder == "__unsorted" ? nil : folder) && $0.parentDocumentID == nil }
        }
        switch tab.location.destination {
        case .trash: return overview.trashed
        case .starred: return overview.favorites
        case .recents, .home: return overview.recent
        case .templates: return overview.templates.compactMap { overview.templateDocuments[$0.id] }
        case .collections:
            return overview.all.filter { !((try? environment.collections.repository.collectionIDs(forDocument: $0.id)) ?? []).isEmpty }
        default: return overview.all.filter { $0.parentDocumentID == nil }
        }
    }
    private var records: [DocumentRecord] {
        browser.sort.sorted(allRecords.filter { browser.query.isEmpty || $0.title.localizedCaseInsensitiveContains(browser.query) || $0.plainText.localizedCaseInsensitiveContains(browser.query) })
    }
    private var folders: [FolderRecord] {
        guard [.allDocuments, .folders].contains(tab.location.destination) else { return [] }
        return FolderHierarchy(folders: environment.overview.folders).children(of: tab.location.folderID == "__unsorted" ? nil : tab.location.folderID)
            .filter { browser.query.isEmpty || $0.title.localizedCaseInsensitiveContains(browser.query) }
    }
    private var columns: Int { max(1, Int((width - 36 + 14) / 224)) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if tab.location.destination == .tags && tab.location.tagIDs.isEmpty { tags }
            else if browser.showsList { list }
            else { gallery }
        }
        .background(VellixSurface.workspace)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: environment.isLibrarySearchRequested) { _, requested in if requested && tab.id == workspace.activeID { searchFocused = true; environment.isLibrarySearchRequested = false } }
        .onChange(of: records.map(\.id)) { _, ids in browser.selectedIDs.formIntersection(Set(ids)) }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(workspace.title(tab)).font(.system(size: 16, weight: .heavy, design: .rounded)).lineLimit(1)
            Spacer(minLength: 8)
            MacOptionPicker("Sort", selection: $browser.sort, options: MacDocumentSort.allCases, label: { $0.rawValue }).frame(width: 130)
            MacSegmentedControl("Presentation", selection: $browser.showsList, options: [false, true], label: { $0 ? "List" : "Gallery" }, icon: { $0 ? "listcircle" : "layoutgal" }).frame(width: 76)
            TextField("Search", text: $browser.query).textFieldStyle(MacInputStyle()).frame(minWidth: 100, idealWidth: 170, maxWidth: 230).focused($searchFocused)
            MacPopoverMenu {
                Button("New Document") { workspace.createDocument() }
                Button("New Folder") { environment.requestFolderCreation(parentFolderID: tab.location.folderID) }
                Button("New Template") { environment.createTemplate() }
                if !browser.selectedIDs.isEmpty {
                    Divider()
                    Button("Star Selected") { environment.starDocuments(browser.selectedIDs) }
                    Button("Move Selected") { environment.requestMove(documentIDs: browser.selectedIDs) }
                    Button("Move Selected to Trash", role: .destructive) { workspace.requestTrash(browser.selectedIDs) }
                }
            } label: { LibraryIcon(name: "addwavy", size: 20).frame(width: 28, height: 32) }.help("Create or Manage Documents")
        }.controlSize(.small).padding(.horizontal, 18).frame(height: 52)
    }
    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !folders.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 10) {
                        ForEach(folders) { folder in
                            Button { workspace.perform { try await workspace.navigate(.allDocuments, folderID: folder.id) } } label: {
                                HStack(spacing: 10) {
                                    LibraryFolderIcon(folder: folder, size: 22)
                                    Text(folder.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(FolderHierarchy(folders: environment.overview.folders).itemCount(in: folder.id, documents: environment.overview.all))).foregroundStyle(.secondary)
                                }.padding(12).background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).contextMenu { FolderContextMenu(folder: folder) }
                        }
                    }
                }
                if records.isEmpty && folders.isEmpty {
                    ContentUnavailableView {
                        Label { Text(browser.query.isEmpty ? "No Documents" : "No Results") } icon: { LibraryIcon(name: "linedpages", size: 30) }
                    } actions: {
                        if browser.query.isEmpty && tab.location.destination != .trash { Button("New Document") { workspace.createDocument() } }
                    }.frame(maxWidth: .infinity, minHeight: 350)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(0..<columns, id: \.self) { column in
                            LazyVStack(spacing: 14) {
                                ForEach(documentColumns[column]) { document in card(document) }
                            }.frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                }
            }.padding(18)
        }
        .scrollPosition($browser.scroll).focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { openSelection(); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
        .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(columns); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-columns); return .handled }
        .onDeleteCommand { workspace.requestTrash(browser.selectedIDs) }
    }
    private var documentColumns: [[DocumentRecord]] {
        var result = Array(repeating: [DocumentRecord](), count: columns), heights = Array(repeating: CGFloat(0), count: columns)
        for document in records {
            let column = heights.enumerated().min(by: { $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element })?.offset ?? 0
            result[column].append(document)
            let image = environment.documentPreviews.cachedImage(for: document)
            heights[column] += (image.map { CGFloat($0.height) / CGFloat($0.width) } ?? 1.6) * previewHeightFraction
        }
        return result
    }
    private func card(_ document: DocumentRecord) -> some View {
        LibraryDocumentPreview(document: document, visibleHeightFraction: previewHeightFraction)
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(browser.selectedIDs.contains(document.id) ? VellixSurface.violet : .clear, lineWidth: 2) }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(document) }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    if !browser.selectedIDs.insert(document.id).inserted { browser.selectedIDs.remove(document.id) }
                } else { browser.selectedIDs = [document.id] }
            }
            .draggable("penned-document:" + document.id)
            .contextMenu { MacDocumentMenu(document: document, workspace: workspace) }
            .accessibilityAction(named: "Open") { open(document) }
    }
    private var list: some View {
        List(selection: $browser.selectedIDs) {
            ForEach(records) { document in
                HStack(spacing: 12) {
                    LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 3).frame(width: 30, height: 42)
                    Text(document.title).fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading)
                    if document.isFavorite { LibraryIcon(name: "starfill", size: 13).foregroundStyle(VellixSurface.gold) }
                    Text(document.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }.tag(document.id).padding(.vertical, 3).contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(document) }
                    .contextMenu { MacDocumentMenu(document: document, workspace: workspace) }
            }
        }.onKeyPress(.return) { openSelection(); return .handled }.onDeleteCommand { workspace.requestTrash(browser.selectedIDs) }
    }
    private var tags: some View {
        List((try? environment.tags.catalogue()) ?? []) { tag in
            Button { workspace.perform { try await workspace.navigate(.tags, tags: [tag.id]) } } label: {
                Label { Text(tag.name) } icon: { LibraryIcon(name: "hashtagwavy", size: 16) }
            }.buttonStyle(.plain)
        }
    }
    private func open(_ document: DocumentRecord) {
        if document.isTrashed { return }
        if tab.location.destination == .templates, let template = environment.overview.templates.first(where: { environment.overview.templateDocuments[$0.id]?.id == document.id }), template.isBuiltIn {
            if let created = environment.createDocument(title: template.title, from: template) { workspace.perform { try await workspace.open(created, newTab: true) } }
        } else { workspace.perform { try await workspace.open(document, newTab: NSEvent.modifierFlags.contains(.command)) } }
    }
    private func openSelection() { if let document = records.first(where: { browser.selectedIDs.contains($0.id) }) { open(document) } }
    private func moveSelection(_ offset: Int) {
        guard !records.isEmpty else { return }
        let index = records.firstIndex(where: { browser.selectedIDs.contains($0.id) }) ?? (offset > 0 ? -1 : records.count)
        browser.selectedIDs = [records[min(max(index + offset, 0), records.count - 1)].id]
    }
}

struct MacDocumentMenu: View {
    let document: DocumentRecord
    @ObservedObject var workspace: MacWorkspaceModel
    var body: some View {
        if document.isTrashed {
            Button("Restore") { workspace.environment.restore(document) }
            Button("Delete Permanently", role: .destructive) { workspace.environment.documentPendingDeletion = document }
        } else {
            Button("Open") { workspace.perform { try await workspace.open(document) } }
            Button("Open in New Tab") { workspace.perform { try await workspace.open(document, newTab: true) } }
            Button(document.isFavorite ? "Remove Star" : "Star") { workspace.environment.starDocuments([document.id], isFavorite: !document.isFavorite) }
            Button("Move to Folder") { workspace.environment.requestMove(documentIDs: [document.id]) }.disabled(document.parentDocumentID != nil)
            SpaceTransferActions(item: .document(document.id))
            Button("Duplicate") {
                workspace.perform {
                    try await workspace.flush()
                    let copy = try workspace.environment.documents.duplicate(id: document.id, attachmentStore: workspace.environment.attachmentStore)
                    workspace.environment.refresh(); try await workspace.open(copy, newTab: true)
                }
            }
            Button("Save as Template") { workspace.environment.saveAsTemplate(document) }
            Button("Move to Trash", role: .destructive) { workspace.requestTrash([document.id]) }
        }
    }
}
