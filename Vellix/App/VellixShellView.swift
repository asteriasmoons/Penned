//
//  VellixShellView.swift
//  Vellix
//

import SwiftUI

struct VellixShellView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            VellixBackground()

            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadWorkspaceView(environment: environment)
            } else if horizontalSizeClass == .compact {
                compactWorkspace
            } else {
                regularWorkspace
            }
            #else
            if horizontalSizeClass == .compact {
                compactWorkspace
            } else {
                regularWorkspace
            }
            #endif
        }
        .disabled(environment.isSwitchingSpace)
        .modifier(PublishingRuntime())
        .onChange(of: environment.selectedDocumentID) { _, id in
            if id != nil { environment.isSettingsPresented = false }
        }
        .sheet(item: $environment.librarySheet) { sheet in
            switch sheet {
            case .folder(let request): FolderEditorSheet(request: request)
            case .move(let request): FolderDestinationPicker(request: request)
            }
        }
        .sheet(item: $environment.spaceSheet) { sheet in
            switch sheet {
            case .edit(let space): SpaceEditorSheet(space: space)
            case .transfer(let item, let copy): SpaceTransferSheet(item: item, copy: copy)
            }
        }
        .alert("Vellix", isPresented: Binding(
            get: { environment.errorMessage != nil },
            set: { if !$0 { environment.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.errorMessage ?? "")
        }
        .confirmationDialog(environment.documentPendingDeletion?.templateID != nil && environment.documentPendingDeletion?.parentDocumentID == nil
            ? "Delete this template?" : "Delete this page permanently?", isPresented: Binding(
            get: { environment.documentPendingDeletion != nil },
            set: { if !$0 { environment.documentPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let document = environment.documentPendingDeletion {
                Button(document.templateID != nil && document.parentDocumentID == nil ? "Delete Template" : "Delete Page and Nested Pages", role: .destructive) {
                    environment.permanentlyDelete(document)
                    environment.documentPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { environment.documentPendingDeletion = nil }
        } message: {
            Text("This permanently removes the page and every page nested inside it, including their snapshots and attachments.")
        }
    }

    private var regularWorkspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            destinationContent
        } detail: {
            editorDetail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactWorkspace: some View {
        NavigationStack {
            destinationContent
                .opacity(environment.selectedDocumentID == nil ? 1 : 0)
                .allowsHitTesting(environment.selectedDocumentID == nil)
                .accessibilityHidden(environment.selectedDocumentID != nil)
                .overlay {
                    compactEditorDeck
                }
                .overlay(alignment: .bottom) {
                    if environment.selectedDocumentID == nil && !environment.isSettingsPresented { LibraryBottomBar() }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(environment.selectedDocumentID == nil && environment.selectedDestination != .templates && environment.selectedDestination != .tags ? .large : .inline)
                .toolbar(environment.selectedDocumentID == nil ? .visible : .hidden, for: .navigationBar)
                #endif
        }
    }

    private var compactEditorDeck: some View {
        ZStack {
            ForEach(environment.editorCache.preparedModels, id: \.documentID) { model in
                compactEditorDetail(model: model)
                    .opacity(environment.selectedDocumentID == model.documentID ? 1 : 0)
                    .allowsHitTesting(environment.selectedDocumentID == model.documentID)
                    .accessibilityHidden(environment.selectedDocumentID != model.documentID)
            }
        }
    }

    @ViewBuilder
    private func compactEditorDetail(model: DocumentEditorModel) -> some View {
        #if os(iOS)
        editorContent(model: model)
        #else
        editorContent(model: model)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    compactLibraryButton
                }
            }
        #endif
    }

    private var compactLibraryButton: some View {
        Button {
            environment.selectedDocumentID = nil
            environment.refresh()
        } label: {
            Label("Library", systemImage: "chevron.left")
        }
    }

    @ViewBuilder
    private var editorDetail: some View {
        ZStack {
            if environment.selectedDocumentID == nil {
                VellixEmptyState(
                    title: "Choose a page",
                    message: "Open a page from the library or create a new one.",
                    systemImage: "linedpages",
                    actionTitle: "New Page"
                ) {
                    _ = environment.createDocument()
                }
                .frame(maxWidth: 520)
                .vellixPaper()
                .padding(VellixSpacing.xl)
            }
            ForEach(environment.editorCache.preparedModels, id: \.documentID) { model in
                editorContent(model: model)
                    .opacity(environment.selectedDocumentID == model.documentID ? 1 : 0)
                    .allowsHitTesting(environment.selectedDocumentID == model.documentID)
                    .accessibilityHidden(environment.selectedDocumentID != model.documentID)
            }
        }
    }

    private func editorContent(model: DocumentEditorModel) -> some View {
        HStack(spacing: 0) {
            DocumentEditorView(model: model)
            if environment.isInspectorVisible {
                Divider().opacity(0.45)
                DocumentInspectorView(document: model.document)
            }
        }
        .id(model.documentID)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView {
                VStack(alignment: .leading, spacing: VellixSpacing.lg) {
                    SidebarSection(title: "Workspace") {
                        ForEach(AppDestination.primaryCases) { destination in
                            SidebarRow(
                                title: destination.title,
                                systemImage: destination.fallbackSymbol,
                                assetImage: destination == .tags ? "hashtagwavy" : nil,
                                count: count(for: destination),
                                isSelected: environment.selectedDestination == destination,
                                tint: destination == .calendar ? CalendarStyle.accent : VellixSurface.accent
                            ) {
                                environment.selectedDestination = destination
                                environment.selectedFolderID = nil
                            }
                        }
                    }

                    if !environment.overview.spaces.isEmpty {
                        SidebarSection(title: "Spaces") {
                            ForEach(environment.overview.spaces) { space in
                                Button {
                                    Task { do { try await environment.switchSpace(to: space.id) } catch { environment.report(error) } }
                                } label: {
                                    HStack(spacing: 10) {
                                        SpaceImage(space: space, size: 26)
                                        Text(space.title).lineLimit(1)
                                        Spacer()
                                        if environment.selectedSpaceID == space.id { LibraryIcon(name: "checkwavy", size: 16) }
                                    }.padding(10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    SidebarSection(title: "More") {
                        SidebarRow(
                            title: AppDestination.trash.title,
                            systemImage: AppDestination.trash.fallbackSymbol,
                            count: environment.overview.trashed.count,
                            isSelected: environment.selectedDestination == .trash
                        ) {
                            environment.selectedDestination = .trash
                        }
                    }
                }
                .padding(.horizontal, VellixSpacing.md)
                .padding(.bottom, VellixSpacing.lg)
            }

            sidebarFooter
        }
        .background(VellixSurface.sidebar)
        .navigationTitle("")
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            HStack(spacing: VellixSpacing.sm) {
                LibraryBrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Penned")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
                Spacer()
                Button {
                    _ = environment.createDocument()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("New Page")
            }

            Button {
                environment.focusLibrarySearch()
            } label: {
                HStack(spacing: 8) {
                    Image("searchwavy")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                    Text("Search")
                    Spacer()
                    Text("Cmd-F")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: VellixRadius.md, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(VellixSpacing.md)
    }

    private var sidebarFooter: some View {
        VStack(spacing: VellixSpacing.sm) {
            HStack(spacing: VellixSpacing.sm) {
                WorkspacePill(
                    title: "Pages",
                    value: "\(environment.overview.all.count)",
                    systemImage: "doc.text",
                    tint: VellixSurface.accent
                )
                WorkspacePill(
                    title: "Spaces",
                    value: "\(environment.overview.spaces.count)",
                    systemImage: "rectangle.stack",
                    tint: VellixSurface.teal
                )
            }
            Button {
                environment.createSpace()
            } label: {
                Label("New Space", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(VellixSpacing.md)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var destinationContent: some View {
        destinationScreen
            .navigationDestination(isPresented: $environment.isSettingsPresented) { PennedSettingsView() }
    }

    @ViewBuilder
    private var destinationScreen: some View {
        switch environment.selectedDestination {
        case .home:
            HomeView(environment: environment)
        case .calendar:
            CalendarView(model: environment.calendar)
        case .recents:
            DocumentBrowserView(mode: .recent, documents: environment.overview.recent)
        case .favorites:
            DocumentBrowserView(mode: .favorites, documents: environment.overview.favorites)
        case .folders:
            DocumentBrowserView(mode: .folders, documents: [])
        case .allDocuments:
            if let folderID = environment.selectedFolderID {
                DocumentBrowserView(mode: .folder(folderID),
                    documents: environment.overview.all.filter { folderID == "__unsorted" ? $0.folderID == nil : $0.folderID == folderID },
                    displayTitle: folderID == "__unsorted" ? "Unsorted" : environment.overview.folders.first { $0.id == folderID }?.title)
            } else {
                DocumentBrowserView(mode: .all, documents: environment.overview.all)
            }
        case .spaces:
            SpacesView()
        case .templates:
            TemplatesView()
        case .tags:
            TagBrowserView()
        case .trash:
            TrashView()
        }
    }

    private func count(for destination: AppDestination) -> Int? {
        switch destination {
        case .home:
            return nil
        case .calendar:
            return nil
        case .recents:
            return environment.overview.recent.count
        case .favorites:
            return environment.overview.favorites.count
        case .allDocuments:
            return environment.overview.all.count
        case .folders:
            return FolderHierarchy(folders: environment.overview.folders).children(of: nil).count
        case .spaces:
            return environment.overview.spaces.count
        case .templates:
            return environment.overview.templates.count
        case .tags: return nil
        case .trash:
            return environment.overview.trashed.count
        }
    }

    private func documentsInSpaceCount(_ spaceID: String) -> Int {
        (try? environment.spaces.contentCount(id: spaceID)) ?? 0
    }
}

private struct SidebarSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            VStack(spacing: 2) {
                content
            }
        }
    }
}

private struct SidebarRow: View {
    var title: String
    var systemImage: String
    var assetImage: String? = nil
    var count: Int?
    var isSelected: Bool
    var tint: Color = VellixSurface.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let assetImage { LibraryIcon(name: assetImage, size: 15) }
                    else { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                }
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VellixSurface.ink : .primary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.045), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: VellixRadius.sm, style: .continuous)
                        .stroke(VellixSurface.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct SpacesView: View {
    var body: some View { SpaceManagementView() }
}

struct SpaceCard: View {
    var space: SpaceRecord
    var count: Int
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            HStack {
                SpaceImage(space: space, size: 38)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.black.opacity(0.045), in: Circle())
            }
            Text(space.title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
            Text(space.spaceDescription ?? "A focused place for related pages.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(VellixSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .vellixPaper()
        .overlay(alignment: .topLeading) {
            if isSelected {
                Rectangle()
                    .fill(VellixSurface.teal)
                    .frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.vertical, 16)
            }
        }
    }
}

struct TemplatesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var renameTarget: TemplateRecord?
    @State private var renamedTitle = ""
    @State private var deleteTarget: TemplateRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                if environment.overview.templates.isEmpty {
                    VellixEmptyState(title: "No templates yet", message: "", systemImage: "copy",
                        actionTitle: "Create Template", actionIcon: "writepen", action: environment.createTemplate)
                        .frame(minHeight: 300)
                }
                LazyVStack(spacing: VellixSpacing.md) {
                    ForEach(environment.overview.templates) { template in
                        HStack(spacing: VellixSpacing.md) {
                            TemplateCard(template: template,
                                document: environment.overview.templateDocuments[template.id]) {
                                if template.isBuiltIn { _ = environment.createDocument(title: template.title, from: template) }
                                else { environment.editTemplate(template) }
                            }
                            Menu {
                                templateActions(template)
                            } label: {
                                LibraryIcon(name: "dotswavy")
                                    .foregroundStyle(VellixSurface.ink)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .pennedIconMenuStyle()
                            .accessibilityLabel("Actions for \(template.title)")
                        }
                        .contextMenu {
                            templateActions(template)
                        }
                    }
                }
            }
            .padding(.horizontal, VellixSpacing.xl)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .background(VellixBackground())
        .navigationTitle("Templates")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    environment.selectedDestination = .home
                } label: { LibraryIcon(name: "chevleft") }
                .accessibilityLabel("Home")
            }
            ToolbarItem(placement: .principal) {
                Text("Templates").font(.system(size: 22, weight: .black, design: .rounded))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: environment.createTemplate) {
                    LibraryIcon(name: "writefeather").frame(width: 46, height: 46).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .accessibilityLabel("New Template")
            }
        }
        .alert("Rename Template", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renamedTitle)
            Button("Save") {
                guard let template = renameTarget else { return }
                do { try environment.templates.rename(id: template.id, title: renamedTitle); environment.refresh() }
                catch { environment.report(error) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete this template?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                guard let template = deleteTarget else { return }
                do { try environment.templates.delete(id: template.id, attachmentStore: environment.attachmentStore); environment.refresh() }
                catch { environment.report(error) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    @ViewBuilder
    private func templateActions(_ template: TemplateRecord) -> some View {
        Button("Use Template") { _ = environment.createDocument(title: template.title, from: template) }
            .disabled(environment.dailyNoteOnlyTemplateIDs.contains(template.id))
        SpaceTransferActions(item: .template(template.id))
        Button("Duplicate Template") {
            do {
                _ = try environment.templates.duplicate(id: template.id, attachmentStore: environment.attachmentStore)
                environment.refresh()
            } catch { environment.report(error) }
        }
        if !template.isBuiltIn {
            Button("Edit Template") { environment.editTemplate(template) }
            Button("Rename") { renamedTitle = template.title; renameTarget = template }
            Button("Delete Template", role: .destructive) { deleteTarget = template }
        }
    }
}

struct TrashView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmEmptyTrash = false

    var body: some View {
        DocumentBrowserView(mode: .trash, documents: environment.overview.trashed)
            .toolbar {
                if !environment.overview.trashed.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            confirmEmptyTrash = true
                        } label: {
                            Label("Empty Trash", systemImage: "trash.slash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Permanently delete all trashed documents?",
                isPresented: $confirmEmptyTrash,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) {
                    environment.emptyTrash()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also removes owned snapshots, search records, attachment records, and local attachment files.")
            }
    }
}
