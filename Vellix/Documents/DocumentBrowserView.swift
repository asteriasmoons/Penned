//
//  DocumentBrowserView.swift
//  Vellix
//

import SwiftUI

enum DocumentBrowserMode: Equatable {
    case all
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
    var mode: DocumentBrowserMode
    var documents: [DocumentRecord]
    var displayTitle: String?
    @State private var query = ""
    @State private var searchScope = LibrarySearchScope.keyword
    @State private var sort = LibraryDocumentSort.updated
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectedFolderIDs: Set<String> = []
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LibrarySearchField(query: $query, scope: $searchScope)

                if documents.isEmpty && childFolders.isEmpty {
                    VellixEmptyState(
                        title: emptyTitle,
                        message: emptyMessage,
                        systemImage: mode == .trash ? "trash" : (mode == .folders ? "linesfolderfill" : "linedpages"),
                        actionTitle: mode == .trash ? nil : (mode == .folders ? "New Folder" : "Create Page")
                    ) {
                        if mode == .folders { environment.requestFolderCreation(parentFolderID: nil) }
                        else { _ = environment.createDocument(folderID: folderID, parentDocumentID: parentID) }
                    }
                    .frame(minHeight: 440)
                } else if filteredDocuments.isEmpty && filteredFolders.isEmpty {
                    Text(mode == .folders ? "No matching folders" : "No matching items").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(spacing: 10) {
                        if !filteredFolders.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(filteredFolders) { folder in folderTile(folder) }
                            }
                        }
                        if !filteredDocuments.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(0..<2, id: \.self) { column in
                                    LazyVStack(spacing: 10) {
                                        ForEach(documentColumns[column]) { document in
                                            preview(document)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 100)
        }
        .background(Color.black)
        .navigationTitle(displayTitle ?? mode.title)
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
                    Picker("Sort", selection: $sort) {
                        ForEach(LibraryDocumentSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if isSelecting {
                        Button("Select All") {
                            selectedIDs = Set(filteredDocuments.map(\.id))
                            selectedFolderIDs = Set(filteredFolders.map(\.id))
                        }
                        if mode != .trash {
                            if parentID == nil {
                                Button("Move Selected") {
                                    environment.requestMove(documentIDs: selectedIDs, folderIDs: selectedFolderIDs)
                                }.disabled(selectedIDs.isEmpty && selectedFolderIDs.isEmpty)
                            }
                            Button("Star Selected") { starSelection() }.disabled(selectedIDs.isEmpty)
                            Button("Remove Stars") { environment.starDocuments(selectedIDs, isFavorite: false) }
                                .disabled(selectedIDs.isEmpty)
                            Button("Move Selected to Trash", role: .destructive) { confirmTrash = true }
                                .disabled(selectedIDs.isEmpty)
                        } else {
                            Button("Restore Selected") {
                                for document in documents where selectedIDs.contains(document.id) { environment.restore(document) }
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
                        Button("New Page") {
                            _ = environment.createDocument(folderID: folderID, parentDocumentID: parentID)
                        }
                    }
                } label: { LibraryIcon(name: "dotswavy") }
                .accessibilityLabel("Document options")
            }
        }
        .confirmationDialog("Move selected pages to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trashSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their nested pages will also move to Trash. You can restore them later.")
        }
        .onChange(of: documents.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .onChange(of: childFolders.map(\.id)) { _, ids in
            selectedFolderIDs.formIntersection(Set(ids))
        }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIDs.removeAll()
            selectedFolderIDs.removeAll()
            isSelecting = false
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
                itemCount: FolderHierarchy(folders: environment.overview.folders).itemCount(in: folder.id, documents: environment.overview.all),
                isSelected: selectedFolderIDs.contains(folder.id))
        }
        .buttonStyle(.plain)
        .contextMenu { FolderContextMenu(folder: folder) }
        .accessibilityAddTraits(selectedFolderIDs.contains(folder.id) ? .isSelected : [])
    }

    private func preview(_ document: DocumentRecord) -> some View {
        Button {
            if isSelecting {
                if selectedIDs.contains(document.id) { selectedIDs.remove(document.id) }
                else { selectedIDs.insert(document.id) }
            } else { environment.select(document) }
        } label: {
            LibraryDocumentPreview(document: document)
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        LibraryIcon(name: selectedIDs.contains(document.id) ? "checkwavy" : "selectsparkle", size: 20)
                            .padding(9).background(.regularMaterial, in: Circle()).padding(8)
                    }
                }
                .overlay {
                    if selectedIDs.contains(document.id) {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(VellixSurface.accent, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu { DocumentContextMenu(document: document) }
        .accessibilityAddTraits(selectedIDs.contains(document.id) ? .isSelected : [])
    }

    private var filteredDocuments: [DocumentRecord] {
        documents.filter { document in
            query.isEmpty || document.title.localizedCaseInsensitiveContains(query)
                || (searchScope == .keyword && document.plainText.localizedCaseInsensitiveContains(query))
        }.sorted { left, right in
            switch sort {
            case .updated: return left.updatedAt == right.updatedAt ? left.id < right.id : left.updatedAt > right.updatedAt
            case .created: return left.createdAt == right.createdAt ? left.id < right.id : left.createdAt > right.createdAt
            case .title:
                let comparison = left.title.localizedStandardCompare(right.title)
                return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
            }
        }
    }

    // Stable reading order down each column; each cached image keeps its own height.
    private var documentColumns: [[DocumentRecord]] {
        var result: [[DocumentRecord]] = [[], []]
        for (index, document) in filteredDocuments.enumerated() { result[index % 2].append(document) }
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
                VStack(alignment: .leading, spacing: 9) {
                    IconTile(systemName: document.icon, size: style == .compact ? 30 : 36, tint: accent)
                    Text(locationText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var accent: Color {
        if document.isFavorite {
            return VellixSurface.gold
        }
        if document.spaceID != nil {
            return VellixSurface.teal
        }
        if document.parentDocumentID != nil {
            return VellixSurface.violet
        }
        return VellixSurface.accent
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
            Button {
                environment.select(document)
            } label: {
                Label("Open", systemImage: "arrow.right")
            }
            if document.parentDocumentID == nil {
                Button { environment.requestMove(documentIDs: [document.id]) } label: {
                    Label { Text("Move To Folder") } icon: { LibraryIcon(name: "openedfolder", size: 18) }
                }
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
