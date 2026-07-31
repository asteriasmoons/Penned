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

            if horizontalSizeClass == .compact {
                compactWorkspace
            } else {
                regularWorkspace
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
            Group {
                if environment.selectedDocumentID == nil {
                    destinationContent
                } else {
                    compactEditorDetail
                }
            }
        }
    }

    @ViewBuilder
    private var compactEditorDetail: some View {
        #if os(iOS)
        editorDetail
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
        #else
        editorDetail
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

    private var editorDetail: some View {
        HStack(spacing: 0) {
            DocumentEditorView(environment: environment)
            if environment.isInspectorVisible {
                Divider().opacity(0.45)
                DocumentInspectorView(document: selectedDocument)
            }
        }
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
                                count: count(for: destination),
                                isSelected: environment.selectedDestination == destination
                            ) {
                                environment.selectedDestination = destination
                                if destination != .spaces {
                                    environment.selectedSpaceID = nil
                                }
                            }
                        }
                    }

                    if !environment.overview.spaces.isEmpty {
                        SidebarSection(title: "Spaces") {
                            ForEach(environment.overview.spaces) { space in
                                SidebarRow(
                                    title: space.title,
                                    systemImage: space.icon ?? "rectangle.stack",
                                    count: documentsInSpaceCount(space.id),
                                    isSelected: environment.selectedDestination == .spaces && environment.selectedSpaceID == space.id
                                ) {
                                    environment.selectedDestination = .spaces
                                    environment.selectedSpaceID = space.id
                                }
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
                IconTile(systemName: "sparkle", size: 38, tint: VellixSurface.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vellix")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Personal space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                environment.selectedDestination = .search
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
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
        switch environment.selectedDestination {
        case .home:
            HomeView()
        case .today:
            DocumentBrowserView(mode: .today, documents: environment.overview.recent)
        case .recents:
            DocumentBrowserView(mode: .recent, documents: environment.overview.recent)
        case .favorites:
            DocumentBrowserView(mode: .favorites, documents: environment.overview.favorites)
        case .allDocuments:
            DocumentBrowserView(mode: .all, documents: environment.overview.all)
        case .spaces:
            SpacesView()
        case .templates:
            TemplatesView()
        case .trash:
            TrashView()
        case .search:
            SearchView(environment: environment)
        }
    }

    private var selectedDocument: DocumentRecord? {
        guard let selectedDocumentID = environment.selectedDocumentID else {
            return nil
        }

        return try? environment.documents.requireDocument(id: selectedDocumentID)
    }

    private func count(for destination: AppDestination) -> Int? {
        switch destination {
        case .home, .search:
            return nil
        case .today, .recents:
            return environment.overview.recent.count
        case .favorites:
            return environment.overview.favorites.count
        case .allDocuments:
            return environment.overview.all.count
        case .spaces:
            return environment.overview.spaces.count
        case .templates:
            return environment.overview.templates.count
        case .trash:
            return environment.overview.trashed.count
        }
    }

    private func documentsInSpaceCount(_ spaceID: String) -> Int {
        ((try? environment.documents.documents(inSpace: spaceID)) ?? []).count
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
    var count: Int?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? VellixSurface.accent : .secondary)
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
    @EnvironmentObject private var environment: AppEnvironment

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: VellixSpacing.md)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                VellixSectionHeader(
                    title: "Spaces",
                    subtitle: "Separate desks for different parts of your life.",
                    actionTitle: "New Space"
                ) {
                    environment.createSpace()
                }

                LazyVGrid(columns: columns, spacing: VellixSpacing.md) {
                    ForEach(environment.overview.spaces) { space in
                        Button {
                            environment.selectedSpaceID = space.id
                        } label: {
                            SpaceCard(
                                space: space,
                                count: documentsInSpaceCount(space.id),
                                isSelected: environment.selectedSpaceID == space.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedSpaceID = environment.selectedSpaceID {
                    DocumentBrowserView(
                        mode: .space(selectedSpaceID),
                        documents: (try? environment.documents.documents(inSpace: selectedSpaceID)) ?? []
                    )
                    .frame(minHeight: 360)
                }
            }
            .padding(VellixSpacing.xl)
        }
        .background(VellixBackground())
        .navigationTitle("Spaces")
    }

    private func documentsInSpaceCount(_ spaceID: String) -> Int {
        ((try? environment.documents.documents(inSpace: spaceID)) ?? []).count
    }
}

struct SpaceCard: View {
    var space: SpaceRecord
    var count: Int
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VellixSpacing.md) {
            HStack {
                IconTile(systemName: space.icon, tint: VellixSurface.teal)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VellixSpacing.xl) {
                VellixSectionHeader(
                    title: "Templates",
                    subtitle: "Start from useful structure, then make it yours.",
                    actionTitle: nil,
                    action: nil
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: VellixSpacing.md)], spacing: VellixSpacing.md) {
                    ForEach(environment.overview.templates) { template in
                        TemplateCard(template: template) {
                            _ = environment.createDocument(title: template.title, from: template)
                        }
                        .contextMenu {
                            if !template.isBuiltIn {
                                Button(role: .destructive) {
                                    do {
                                        try environment.templates.delete(id: template.id)
                                        environment.refresh()
                                    } catch {
                                        environment.report(error)
                                    }
                                } label: {
                                    Label("Delete Template", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(VellixSpacing.xl)
        }
        .background(VellixBackground())
        .navigationTitle("Templates")
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
