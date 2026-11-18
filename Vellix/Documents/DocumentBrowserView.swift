//
//  DocumentBrowserView.swift
//  Vellix
//

import SwiftUI

enum DocumentBrowserMode: Equatable {
    case all
    case dailyNotes
    case folders
    case today
    case recent
    case favorites
    case trash
    case space(String)
    case folder(String)
    case children(String)

    var title: String {
        switch self {
        case .all:
            return "All Docs"
        case .dailyNotes:
            return "Daily Notes"
        case .folders:
            return "Folders"
        case .today:
            return "Today"
        case .recent:
            return "Recents"
        case .favorites:
            return "Starred"
        case .trash:
            return "Trash"
        case .space:
            return "Space"
        case .folder:
            return "Folder"
        case .children:
            return "Child Pages"
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return "Every page in your local library."
        case .dailyNotes:
            return "Your notes, organized by month and year."
        case .folders:
            return "Folders in your library."
        case .today:
            return "A focused landing spot for what is active now."
        case .recent:
            return "Pages ordered by your latest opens and edits."
        case .favorites:
            return "Pages you pinned for quick return."
        case .trash:
            return "Recover pages or remove them permanently."
        case .space:
            return "Pages inside this space."
        case .folder:
            return "Pages inside this folder."
        case .children:
            return "Pages nested below the current document."
        }
    }
}

struct DocumentBrowserView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.pennedWorkspace) private var workspace
    @Environment(\.pennedGalleryColumns) private var preferredColumns
    @Environment(\.pennedGalleryContentWidth) private var providedWidth
    var mode: DocumentBrowserMode
    // Explicit summaries for the bounded, non-paginated surfaces (recents, starred,
    // trash, daily notes, children, ad-hoc lists). The large surfaces (All Docs and a
    // single folder) ignore this and page from the database via `store`.
    var summaries: [DocumentSummary] = []
    // When false, the large surfaces use the explicit `summaries` list instead of
    // paging from the database (for ad-hoc galleries such as the Collections list).
    var allowsPagination: Bool = true
    var displayTitle: String?
    @StateObject private var store = LibraryBrowseStore()
    @State private var query = ""
    @State private var searchScope = LibrarySearchScope.keyword
    // Database-resolved full-content matches for the bounded, non-paginated sections.
    // nil means no active search (show the whole section); a set lists the ids that
    // matched by title or FTS body. Recomputed when the query, scope, or section
    // contents change, so bounded search mirrors the paginated surfaces' coverage.
    @State private var boundedMatches: Set<String>?
    @State private var sort = LibraryDocumentSort.updated
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectedFolderIDs: Set<String> = []
    @State private var confirmTrash = false
    @State private var confirmEmptyTrash = false
    @State private var documentToRestore: DocumentRecord?
    @State private var availableWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)

    // Prefer the width handed down from the pad workspace's live geometry; it is
    // correct the moment the device rotates or the sidebar pushes. Fall back to
    // the locally measured width only when no workspace width is provided.
    private var effectiveWidth: CGFloat { providedWidth > 0 ? providedWidth : availableWidth }
    private var columnCount: Int {
        workspace == nil ? 2 : (effectiveWidth > 0
            ? PadWorkspaceMetrics.galleryColumns(width: PadWorkspaceMetrics.galleryWidth(available: effectiveWidth), preferred: preferredColumns)
            : preferredColumns)
    }
    private let gallerySpacing: CGFloat = 10
    private var cardWidth: CGFloat? {
        workspace != nil && effectiveWidth > 0
            ? PadWorkspaceMetrics.galleryCardWidth(available: effectiveWidth, columns: columnCount) : nil
    }
    private var galleryWidth: CGFloat? {
        workspace != nil && effectiveWidth > 0
            ? PadWorkspaceMetrics.galleryWidth(available: effectiveWidth) : nil
    }
    private var previewHeightFraction: CGFloat {
        if let phoneFraction = LibraryDocumentPreview.phoneGalleryHeightFraction {
            return mode == .all && displayTitle == nil ? 0.7 : phoneFraction
        }
        return workspace == nil ? 1 : PadWorkspaceMetrics.galleryPreviewHeightFraction
    }

    // The large surfaces page from the database; everything else uses the explicit list.
    private var paginatedScope: LibraryBrowseStore.Scope? {
        guard allowsPagination else { return nil }
        switch mode {
        case .all: return .all
        case .folder(let id): return .folder(id == "__unsorted" ? nil : id)
        default: return nil
        }
    }
    private var isPaginated: Bool { paginatedScope != nil }
    private var sortDescriptor: DocumentSummarySort {
        switch sort {
        case .updated: return .updated
        case .created: return .created
        case .title: return .title
        }
    }

    // The documents shown now. Paginated surfaces return the loaded database window
    // (already filtered and sorted by the query across the whole library); bounded
    // surfaces filter and sort their explicit list in memory.
    private var filteredDocuments: [DocumentSummary] {
        guard !isPaginated else { return store.items }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [DocumentSummary]
        if trimmed.isEmpty {
            matched = summaries
        } else if let boundedMatches {
            // Database full-content result: titles plus complete FTS body matches.
            matched = summaries.filter { boundedMatches.contains($0.id) }
        } else {
            // Instant title results while the database match resolves; upgraded to
            // full-content matches the moment `boundedMatches` is set.
            matched = summaries.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }
        return matched.sorted(by: sortComparator)
    }

    private func sortComparator(_ left: DocumentSummary, _ right: DocumentSummary) -> Bool {
        switch sort {
        case .updated: return left.updatedAt == right.updatedAt ? left.id < right.id : left.updatedAt > right.updatedAt
        case .created: return left.createdAt == right.createdAt ? left.id < right.id : left.createdAt > right.createdAt
        case .title:
            let comparison = left.title.localizedStandardCompare(right.title)
            return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
        }
    }

    private func configureStore() {
        guard let scope = paginatedScope else { return }
        store.attach(environment.documents)
        store.configure(scope: scope, sort: sortDescriptor, query: query, searchesBody: searchScope == .keyword)
    }

    // Resolves full-content matches for the bounded sections at the database level so
    // their search covers complete document bodies (FTS), not just title/previewText.
    // The paginated surfaces search in the store, so this is a no-op there.
    private func refreshBoundedSearch() {
        guard !isPaginated else { boundedMatches = nil; return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { boundedMatches = nil; return }
        boundedMatches = try? environment.documents.fullTextMatches(
            amongst: summaries.map(\.id), query: trimmed, searchesBody: searchScope == .keyword)
    }

    // True only when the list is genuinely empty, not merely still loading its first
    // page — so the empty state never flashes while the first page is being fetched.
    private var settledEmpty: Bool {
        guard filteredDocuments.isEmpty else { return false }
        return !isPaginated || (store.reachedEnd && !store.isLoading)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if workspace == nil || !query.isEmpty { LibrarySearchField(query: $query, scope: $searchScope) }

                if settledEmpty && query.isEmpty && childFolders.isEmpty {
                    VellixEmptyState(
                        title: emptyTitle,
                        message: emptyMessage,
                        systemImage: mode == .trash ? "trash" : (mode == .folders ? "linesfolderfill" : "linedpages"),
                        actionTitle: mode == .trash ? nil : (mode == .dailyNotes ? "Create Today’s Note" : (mode == .folders ? "New Folder" : "Create Page"))
                    ) {
                        if mode == .folders { environment.requestFolderCreation(parentFolderID: nil) }
                        else if mode == .dailyNotes { createTodayNote() }
                        else { _ = environment.createDocument(folderID: folderID, parentDocumentID: parentID) }
                    }
                    .frame(minHeight: 440)
                } else if settledEmpty && filteredFolders.isEmpty {
                    Text(mode == .folders ? "No matching folders" : "No matching items").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(spacing: 10) {
                        if !filteredFolders.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount), spacing: 10) {
                                ForEach(filteredFolders) { folder in folderTile(folder) }
                            }
                        }
                        if !filteredDocuments.isEmpty && mode == .dailyNotes {
                            ForEach(dailyNoteYears, id: \.self) { year in
                                VStack(alignment: .leading, spacing: 18) {
                                    Text(String(year))
                                        .font(.system(.title2, design: .rounded).weight(.black))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(dailyNoteMonths(in: year), id: \.self) { month in
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(monthName(month))
                                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gallerySpacing), count: columnCount), spacing: gallerySpacing) {
                                                ForEach(dailyNoteDocuments(year: year, month: month)) { document in
                                                    preview(document)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else if !filteredDocuments.isEmpty {
                            HStack(alignment: .top, spacing: gallerySpacing) {
                                ForEach(0..<columnCount, id: \.self) { column in
                                    LazyVStack(spacing: gallerySpacing) {
                                        ForEach(documentColumns[column]) { document in
                                            preview(document)
                                        }
                                    }
                                    .frame(width: cardWidth)
                                    .frame(maxWidth: workspace == nil ? .infinity : nil)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: galleryWidth, alignment: .leading)
            .padding(.horizontal, workspace == nil ? 16 : PadWorkspaceMetrics.galleryHorizontalInset)
            .frame(maxWidth: .infinity, alignment: workspace == nil ? .center : .leading)
            .padding(.top, 12).padding(.bottom, workspace == nil ? 100 : 24)
        }
        .simultaneousGesture(TapGesture().onEnded {
            environment.traceDocumentOpeningSurfaceTap(source: "document-browser-scroll", workspaceBusy: workspace?.isBusy ?? false)
            print("🛠️ PENNED-OPEN browser-scroll-tap mode=\(mode) busy=\(workspace?.isBusy.description ?? "no-workspace") selecting=\(isSelecting) docs=\(filteredDocuments.count)")
        })
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .background {
            #if os(iOS)
            PadWorkspacePageBackground(fallback: VellixSurface.workspace)
            #else
            VellixSurface.workspace
            #endif
        }
        .navigationTitle(mode == .all && displayTitle == nil ? "" : (displayTitle ?? mode.title))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    environment.returnFromFolder(folderID)
                } label: { LibraryIcon(name: "chevleft") }
                .accessibilityLabel(folderID == nil ? "Home" : "Parent folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting {
                        selectedIDs.removeAll()
                        selectedFolderIDs.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    browserOptions
                } label: { LibraryIcon(name: "dotswavy") }
                .pennedIconMenuStyle()
                .accessibilityLabel("Document options")
            }
        }
        .confirmationDialog("Move selected pages to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trashSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their nested pages will also move to Trash. You can restore them later.")
        }
        .confirmationDialog("Permanently delete all trashed documents?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { environment.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also removes their nested pages, snapshots and attachments. This cannot be undone.")
        }
        .confirmationDialog("Restore this document?", isPresented: Binding(
            get: { documentToRestore != nil },
            set: { if !$0 { documentToRestore = nil } }
        ), titleVisibility: .visible, presenting: documentToRestore) { document in
            Button("Restore") {
                environment.restore(document)
                documentToRestore = nil
            }
            Button("Cancel", role: .cancel) { documentToRestore = nil }
        } message: { document in
            Text(document.title)
        }
        .onChange(of: filteredDocuments.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .onChange(of: childFolders.map(\.id)) { _, ids in
            selectedFolderIDs.formIntersection(Set(ids))
        }
        .onAppear { configureStore(); refreshBoundedSearch() }
        .onChange(of: query) { _, _ in configureStore(); refreshBoundedSearch() }
        .onChange(of: sort) { _, _ in configureStore() }
        .onChange(of: searchScope) { _, _ in configureStore(); refreshBoundedSearch() }
        .onChange(of: summaries.map(\.id)) { _, _ in refreshBoundedSearch() }
        .onChange(of: environment.libraryGeneration) { _, _ in if isPaginated { store.refresh() } }
        .onChange(of: availableWidth) { _, width in
            print("🛠️ PENNED-OPEN browser-width mode=\(mode) width=\(width) columns=\(columnCount) cardWidth=\(String(describing: cardWidth))")
        }
        .onChange(of: isSelecting) { _, value in
            print("🛠️ PENNED-OPEN browser-selection-mode=\(value)")
        }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIDs.removeAll()
            selectedFolderIDs.removeAll()
            isSelecting = false
            configureStore()
            refreshBoundedSearch()
        }
    }

    @ViewBuilder private var browserOptions: some View {
        if workspace != nil && mode == .trash && !filteredDocuments.isEmpty {
            Button("Empty Trash", role: .destructive) { confirmEmptyTrash = true }
        }
        if workspace == nil {
            Picker("Sort", selection: $sort) { ForEach(LibraryDocumentSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        }
        if isSelecting {
            Button("Select All") { selectedIDs = Set(filteredDocuments.map(\.id)); selectedFolderIDs = Set(filteredFolders.map(\.id)) }
            if mode != .trash {
                if parentID == nil {
                    Button("Move Selected") { environment.requestMove(documentIDs: selectedIDs, folderIDs: selectedFolderIDs) }
                        .disabled(selectedIDs.isEmpty && selectedFolderIDs.isEmpty)
                }
                Button("Star Selected") { starSelection() }.disabled(selectedIDs.isEmpty)
                Button("Remove Stars") { environment.starDocuments(selectedIDs, isFavorite: false) }.disabled(selectedIDs.isEmpty)
                Button("Move Selected to Trash", role: .destructive) { confirmTrash = true }.disabled(selectedIDs.isEmpty)
            } else {
                Button("Restore Selected") {
                    for id in selectedIDs {
                        if let record = try? environment.documents.document(id: id) { environment.restore(record) }
                    }
                    selectedIDs.removeAll()
                }.disabled(selectedIDs.isEmpty)
            }
        } else if mode != .trash {
            if parentID == nil {
                Button("New Folder") { environment.requestFolderCreation(parentFolderID: folderID) }
                if let folder = environment.overview.folders.first(where: { $0.id == folderID }) {
                    Button("Edit Folder") { environment.editFolder(folder) }
                    Button("Move Folder") { environment.requestMove(folderIDs: [folder.id]) }
                }
            }
            if mode == .dailyNotes {
                Button("Create Today’s Note") { createTodayNote() }
            } else {
                Button("New Page") { _ = environment.createDocument(folderID: folderID, parentDocumentID: parentID) }
            }
        }
    }

    private var childFolders: [FolderRecord] {
        let hierarchy = FolderHierarchy(folders: environment.overview.folders)
        switch mode {
        case .folders: return hierarchy.children(of: nil)
        case .folder(let id): return id == "__unsorted" ? [] : hierarchy.children(of: id)
        default: return []
        }
    }

    private var filteredFolders: [FolderRecord] {
        childFolders.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted { left, right in
            switch sort {
            case .updated: return left.updatedAt == right.updatedAt ? left.id < right.id : left.updatedAt > right.updatedAt
            case .created: return left.createdAt == right.createdAt ? left.id < right.id : left.createdAt > right.createdAt
            case .title:
                let comparison = left.title.localizedStandardCompare(right.title)
                return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
            }
        }
    }

    private func folderTile(_ folder: FolderRecord) -> some View {
        Button {
            if isSelecting {
                if selectedFolderIDs.contains(folder.id) { selectedFolderIDs.remove(folder.id) }
                else { selectedFolderIDs.insert(folder.id) }
            } else { environment.openFolder(folder.id) }
        } label: {
            LibraryFolderTile(folder: folder,
                itemCount: folderItemCount(folder.id),
                isSelected: selectedFolderIDs.contains(folder.id))
        }
        .buttonStyle(.plain)
        .contextMenu { FolderContextMenu(folder: folder) }
        .accessibilityAddTraits(selectedFolderIDs.contains(folder.id) ? .isSelected : [])
    }

    // Direct subfolders plus direct documents, matching FolderHierarchy.itemCount but
    // counting documents in the database rather than over a materialized library list.
    private func folderItemCount(_ folderID: String) -> Int {
        let subfolders = FolderHierarchy(folders: environment.overview.folders).children(of: folderID).count
        let documents = (try? environment.documents.folderSummaryCount(folderID: folderID)) ?? 0
        return subfolders + documents
    }

    private func preview(_ document: DocumentSummary) -> some View {
        Button {
            let trace = environment.traceDocumentCardTap(id: document.id, source: "document-browser", workspaceBusy: workspace?.isBusy)
            if isSelecting {
                trace?.event("card-tap-not-opening", "reason=selection-mode")
                if selectedIDs.contains(document.id) { selectedIDs.remove(document.id) }
                else { selectedIDs.insert(document.id) }
            } else if mode == .trash {
                trace?.event("card-tap-not-opening", "reason=trash-restore")
                documentToRestore = try? environment.documents.document(id: document.id)
            } else if let workspace {
                trace?.event("card-tap-routed", "route=ipad-workspace")
                Task {
                    do { try await workspace.openDocument(id: document.id, openingTrace: trace) }
                    catch { environment.report(error) }
                }
            } else {
                trace?.event("card-tap-routed", "route=direct-select")
                environment.select(document, openingTrace: trace)
            }
        } label: {
            LibraryDocumentCell(summary: document, visibleHeightFraction: previewHeightFraction)
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        LibraryIcon(name: selectedIDs.contains(document.id) ? "checkwavy" : "selectsparkle", size: 20)
                            .padding(9).pennedPhoneDarkChrome(cornerRadius: 100).padding(8)
                    }
                }
                .overlay {
                    if selectedIDs.contains(document.id) {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(VellixSurface.accent, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    DocumentSummaryContextMenu(summary: document)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedIDs.contains(document.id) ? .isSelected : [])
        .onAppear { if isPaginated { store.loadMoreIfNeeded(current: document) } }
    }

    private func createTodayNote() {
        Task {
            do { _ = try await environment.openDailyNote(day: DailyNoteDay(date: Date())) }
            catch { environment.report(error) }
        }
    }

    private func dailyNoteParts(_ document: DocumentSummary) -> (year: Int, month: Int)? {
        guard let key = document.dailyNoteDate, key.count >= 7 else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return (year, month)
    }

    private var dailyNoteYears: [Int] {
        Array(Set(filteredDocuments.compactMap { dailyNoteParts($0)?.year })).sorted(by: >)
    }

    private func dailyNoteMonths(in year: Int) -> [Int] {
        Array(Set(filteredDocuments.compactMap { document -> Int? in
            guard let parts = dailyNoteParts(document), parts.year == year else { return nil }
            return parts.month
        })).sorted(by: >)
    }

    private func dailyNoteDocuments(year: Int, month: Int) -> [DocumentSummary] {
        filteredDocuments.filter { document in
            guard let parts = dailyNoteParts(document) else { return false }
            return parts.year == year && parts.month == month
        }.sorted { ($0.dailyNoteDate ?? "") > ($1.dailyNoteDate ?? "") }
    }

    private func monthName(_ month: Int) -> String {
        Calendar.current.monthSymbols[month - 1]
    }

    // Stable reading order down each column; each cached image keeps its own height.
    private var documentColumns: [[DocumentSummary]] {
        var result = Array(repeating: [DocumentSummary](), count: columnCount)
        for (index, document) in filteredDocuments.enumerated() { result[index % columnCount].append(document) }
        return result
    }

    private var folderID: String? {
        if case .folder(let id) = mode, id != "__unsorted" { return id }
        return nil
    }
    private var parentID: String? {
        if case .children(let id) = mode { return id }
        return nil
    }

    private func starSelection() {
        environment.starDocuments(selectedIDs)
    }

    private func trashSelection() {
        selectedIDs.subtract(environment.trashDocuments(selectedIDs))
    }

    private var emptyTitle: String {
        switch mode {
        case .dailyNotes: return "No Daily Notes yet"
        case .trash: return "Trash is empty"
        case .folders: return "No folders yet"
        case .folder: return "This folder is empty"
        default: return "No pages yet"
        }
    }

    private var emptyMessage: String {
        mode == .trash
            ? "Deleted pages stay here until you restore or permanently remove them."
            : ""
    }
}

private enum LibraryDocumentSort: String, CaseIterable {
    case updated = "Last Edited"
    case created = "Date Created"
    case title = "Title"
}

struct DocumentCard: View {
    enum Style {
        case compact
        case paper
    }

    var document: DocumentRecord
    var style: Style = .paper

    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            HStack(alignment: .top) {
                Text(locationText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if document.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(VellixSurface.gold)
                        .accessibilityLabel("Starred")
                }
            }

            VStack(alignment: .leading, spacing: VellixSpacing.xs) {
                Text(document.title)
                    .font(.system(style == .compact ? .headline : .title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink)
                    .lineLimit(2)
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .compact ? 2 : 4)
                    .frame(minHeight: style == .compact ? 38 : 76, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(updatedText)
                if document.wordCount > 0 {
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 3, height: 3)
                    Text("\(document.wordCount) words")
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(style == .compact ? VellixSpacing.md : VellixSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: style == .compact ? 154 : 228, alignment: .topLeading)
        .vellixPaper()
    }

    private var preview: String {
        document.previewText == "No content yet" ? "Blank page" : document.previewText
    }

    private var updatedText: String {
        document.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var locationText: String {
        if document.isTrashed {
            return "Trash"
        }
        if document.parentDocumentID != nil {
            return "Nested page"
        }
        if document.spaceID != nil {
            return "Space"
        }
        return "Library"
    }
}

struct DocumentContextMenu: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.pennedWorkspace) private var workspace
    var document: DocumentRecord
    var trashAction: (() -> Void)? = nil

    var body: some View {
        if document.isTrashed {
            Button {
                environment.restore(document)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                environment.documentPendingDeletion = document
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
        } else {
            if let workspace {
                Button {
                    Task { do { try await workspace.openDocument(document, newTab: true) } catch { environment.report(error) } }
                } label: { Label { Text("Open in New Tab") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
            }
            Button {
                environment.select(document)
            } label: {
                Label("Open", systemImage: "arrow.right")
            }
            if document.parentDocumentID == nil {
                Button { environment.requestMove(documentIDs: [document.id]) } label: {
                    Label { Text("Move To Folder") } icon: { LibraryIcon(name: "openedfolder", size: 18) }
                }
                SpaceTransferActions(item: .document(document.id))
            }
            Button {
                do {
                    _ = try environment.documents.setFavorite(
                        id: document.id,
                        isFavorite: !document.isFavorite
                    )
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label(document.isFavorite ? "Remove Star" : "Star", systemImage: "star")
            }
            Button {
                do {
                    let duplicate = try environment.documents.duplicate(id: document.id, attachmentStore: environment.attachmentStore)
                    environment.refresh()
                    environment.select(duplicate)
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                if let trashAction {
                    trashAction()
                    return
                }
                do {
                    _ = try environment.documents.trash(id: document.id)
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

// The context menu for a body-free gallery cell. Identical to DocumentContextMenu,
// but keyed by a DocumentSummary; the few actions that need a document body load the
// full record lazily when invoked.
struct DocumentSummaryContextMenu: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.pennedWorkspace) private var workspace
    var summary: DocumentSummary

    private func record() -> DocumentRecord? { try? environment.documents.document(id: summary.id) }

    var body: some View {
        if summary.isTrashed {
            Button {
                if let record = record() { environment.restore(record) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                environment.documentPendingDeletion = record()
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
        } else {
            if let workspace {
                Button {
                    Task {
                        do { try await workspace.openDocument(id: summary.id, newTab: true) } catch { environment.report(error) }
                    }
                } label: { Label { Text("Open in New Tab") } icon: { LibraryIcon(name: "addwavy", size: 18) } }
            }
            Button {
                environment.select(summary)
            } label: {
                Label("Open", systemImage: "arrow.right")
            }
            if summary.parentDocumentID == nil {
                Button { environment.requestMove(documentIDs: [summary.id]) } label: {
                    Label { Text("Move To Folder") } icon: { LibraryIcon(name: "openedfolder", size: 18) }
                }
                SpaceTransferActions(item: .document(summary.id))
            }
            Button {
                do {
                    _ = try environment.documents.setFavorite(id: summary.id, isFavorite: !summary.isFavorite)
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label(summary.isFavorite ? "Remove Star" : "Star", systemImage: "star")
            }
            Button {
                do {
                    let duplicate = try environment.documents.duplicate(id: summary.id, attachmentStore: environment.attachmentStore)
                    environment.refresh()
                    environment.select(duplicate)
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                do {
                    _ = try environment.documents.trash(id: summary.id)
                    environment.refresh()
                } catch {
                    environment.report(error)
                }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}
