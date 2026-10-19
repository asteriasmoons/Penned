//
//  HomeView.swift
//  Vellix
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.pennedWorkspaceTabActive) private var workspaceTabActive
    @ObservedObject private var searchModel: SearchModel
    @FocusState private var isSearchFocused: Bool
    @State private var searchScope = LibrarySearchScope.keyword
    @State private var customizeHome = false
    @State private var expandedStarred = false
    @AppStorage("library.showPreviewStrip") private var showPreviewStrip = true
    @AppStorage("library.showStarred") private var showStarred = true
    @AppStorage("library.showFolders") private var showFolders = true

    init(environment: AppEnvironment, search: SearchModel? = nil) {
        _searchModel = ObservedObject(wrappedValue: search ?? environment.librarySearch)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                searchField

                if searchModel.hasQuery {
                    searchResults
                } else {
                    if environment.overview.all.isEmpty {
                        emptyDesk
                    } else {
                        if showPreviewStrip { previewStrip }
                    }
                    libraryLinks
                    if showStarred { starredList }
                    if showFolders { folderList }
                    Button("Customize Home") { customizeHome = true }
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 100)
        }
        .background(Color.black)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { LibraryBrandMark() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Customize Home") { customizeHome = true }
                    Button("Recents") { open(.recents) }
                    Button("Templates") { open(.templates) }
                    Button("Trash") { open(.trash) }
                } label: { LibraryIcon(name: "dotswavy") }
                .accessibilityLabel("Home options")
            }
        }
        .sheet(isPresented: $customizeHome) {
            NavigationStack {
                Form {
                    Toggle("Document previews", isOn: $showPreviewStrip).pennedSheetRows(showsSeparator: true)
                    Toggle("Starred", isOn: $showStarred).pennedSheetRows(showsSeparator: true)
                    Toggle("Folders", isOn: $showFolders).pennedSheetRows()
                }
                .navigationTitle("Customize Home")
                .pennedSheet(title: "Customize Home", close: { customizeHome = false })
            }
            .presentationDetents([.medium])
        }
        .onAppear {
            focusRequestedSearch()
        }
        .onChange(of: environment.isLibrarySearchRequested) { _, _ in
            focusRequestedSearch()
        }
        .onChange(of: environment.selectedDocumentID) { _, documentID in
            if documentID != nil {
                isSearchFocused = false
            }
        }
    }

    private var searchField: some View {
        LibrarySearchField(query: Binding(
                get: { searchModel.query },
                set: { searchModel.updateQuery($0) }
            ), scope: $searchScope, placeholder: "Search in Vellix", focus: $isSearchFocused)
    }

    @ViewBuilder
    private var searchResults: some View {
        if let error = searchModel.errorMessage {
            VellixEmptyState(
                title: "Search unavailable",
                message: error,
                systemImage: "searchwavy",
                actionTitle: "Try Again",
                action: { searchModel.refresh() }
            )
        } else if searchModel.results.isEmpty && searchModel.templates.isEmpty {
            VellixEmptyState(
                title: "No results",
                message: "Try another title, phrase, or template name.",
                systemImage: "searchwavy",
                actionTitle: nil,
                action: nil
            )
        } else {
            if !searchModel.results.isEmpty {
                resultSection(title: "Pages") {
                    ForEach(searchModel.results.filter { searchScope == .keyword || $0.title.localizedCaseInsensitiveContains(searchModel.query) }) { result in
                        Button {
                            do {
                                let document = try environment.documents.requireDocument(id: result.documentID)
                                isSearchFocused = false
                                environment.select(document)
                            } catch {
                                environment.report(error)
                            }
                        } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !searchModel.templates.isEmpty {
                resultSection(title: "Templates") {
                    ForEach(searchModel.templates) { template in
                        TemplateResultRow(template: template) {
                            isSearchFocused = false
                            _ = environment.createDocument(title: template.title, from: template)
                        }
                        .disabled(environment.dailyNoteOnlyTemplateIDs.contains(template.id))
                    }
                }
            }
        }
    }

    private func resultSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            VellixSectionHeader(title: title, actionTitle: nil, action: nil)
            LazyVStack(spacing: VellixSpacing.sm) {
                content()
            }
        }
    }

    private func focusRequestedSearch() {
        guard workspaceTabActive, environment.isLibrarySearchRequested else { return }
        isSearchFocused = true
        environment.isLibrarySearchRequested = false
    }

    private func open(_ destination: AppDestination) {
        environment.selectedFolderID = nil
        environment.selectedDestination = destination
    }

    private var previewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(environment.overview.recent.prefix(10)) { document in
                    Button { environment.select(document) } label: {
                        LibraryDocumentPreview(document: document, fixedAspectRatio: 0.82)
                            .frame(width: 138)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { DocumentContextMenu(document: document) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .padding(.vertical, 2)
    }

    private var libraryLinks: some View {
        VStack(spacing: 0) {
            libraryRow("All Docs", icon: "linedpages") { open(.allDocuments) }
            libraryRow("Spaces", icon: "spaces") { open(.spaces) }
            libraryRow("Templates", icon: "copy") { open(.templates) }
            libraryRow("All Tags", icon: "hashtagwavy") { open(.tags) }
        }
    }

    private var starredList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { open(.favorites) } label: {
                    HStack(spacing: 7) {
                        Text("Starred").font(.headline)
                        LibraryIcon(name: "chevright", size: 12).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button(expandedStarred ? "Show Fewer" : "Show All") { expandedStarred.toggle() }
                    Button("Open Starred") { open(.favorites) }
                } label: { LibraryIcon(name: "dotswavy", size: 18).foregroundStyle(.secondary) }
                .accessibilityLabel("Starred options")
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(environment.overview.favorites.prefix(expandedStarred ? environment.overview.favorites.count : 5)) { document in
                    Button { environment.select(document) } label: {
                        HStack(spacing: 12) {
                            LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 2).frame(width: 19)
                            Text(document.title).font(.system(size: 17)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 48).padding(.horizontal, 10).contentShape(Rectangle())
                    }
                    .contextMenu { DocumentContextMenu(document: document) }
                    Divider().opacity(0.15).padding(.leading, 41)
                }
                if environment.overview.favorites.isEmpty {
                    Text("No starred pages").foregroundStyle(.secondary).padding(.vertical, 14).padding(.leading, 10)
                } else if !expandedStarred && environment.overview.favorites.count > 5 {
                    Button("Show \(environment.overview.favorites.count - 5) more") { expandedStarred = true }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 41).padding(.top, 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { open(.folders) } label: {
                    HStack(spacing: 7) {
                        Text("Folders").font(.headline)
                        LibraryIcon(name: "chevright", size: 12).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("New Folder") { environment.requestFolderCreation(parentFolderID: nil) }
                } label: { LibraryIcon(name: "dotswavy", size: 18).foregroundStyle(.secondary) }
                .accessibilityLabel("Folder options")
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                libraryRow("Unsorted", icon: "openedfolder", count: environment.overview.all.filter { $0.folderID == nil }.count) {
                    environment.selectedFolderID = "__unsorted"
                    environment.selectedDestination = .allDocuments
                }
                ForEach(FolderHierarchy(folders: environment.overview.folders).children(of: nil)) { folder in
                    libraryRow(folder.title, icon: VellixAssetIconLibrary.names.contains(folder.icon ?? "") ? (folder.icon ?? "linesfolderfill") : "linesfolderfill",
                        count: FolderHierarchy(folders: environment.overview.folders).itemCount(in: folder.id, documents: environment.overview.all),
                        iconColor: Color(vellixHex: folder.iconColorHex ?? "#909090")) {
                        environment.openFolder(folder.id)
                    }
                    .contextMenu { FolderContextMenu(folder: folder) }
                }
            }
        }
    }

    private func libraryRow(_ title: String, icon: String, count: Int? = nil, iconColor: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    LibraryIcon(name: icon, size: 20).foregroundStyle(iconColor)
                    Text(title).font(.system(size: 17)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let count { Text(String(count)).foregroundStyle(.tertiary).font(.callout) }
                    if count != nil { LibraryIcon(name: "chevright", size: 12).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 10).frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().opacity(0.15).padding(.leading, 41)
        }
    }

    private var emptyDesk: some View {
        VellixEmptyState(
            title: "Start with a page",
            message: "",
            systemImage: "linedpages",
            actionTitle: "Create Page"
        ) {
            _ = environment.createDocument()
        }
        .frame(minHeight: 180)
    }
}

struct QuickActionCard: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VellixSpacing.md) {
                IconTile(systemName: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(VellixSurface.ink)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(VellixSpacing.lg)
            .vellixPaper(cornerRadius: VellixRadius.md)
        }
        .buttonStyle(.plain)
    }
}

struct TemplateCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    var template: TemplateRecord
    var document: DocumentRecord? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NestedPageThumbnail(json: document?.tipTapJSON ?? template.tipTapJSON,
                    title: template.title, appearance: document?.appearance ?? .plain,
                    size: CGSize(width: 43, height: 56),
                    cover: document?.cover, attachmentStore: environment.attachmentStore)
                    .equatable()
                    .shadow(color: .black.opacity(0.48), radius: 6, x: 0, y: 4)
                    .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(VellixSurface.ink)
                        .lineLimit(2)
                    Text(previewText)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel(template.isBuiltIn ? "Use \(template.title)" : "Edit \(template.title)")
    }

    private var previewText: String {
        if let description = template.templateDescription.trimmedNonEmpty { return description }
        if let document, document.previewText != "No content yet" { return document.previewText }
        return document?.appearance.displaysCover == true ? "Template" : "Empty template"
    }
}
