import AppKit
import Combine
import SwiftUI

struct MacNavigationSidebar: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var state: MacSidebarState
    @State private var switchingSpace = false
    init(workspace: MacWorkspaceModel) {
        self.workspace = workspace; environment = workspace.environment; state = workspace.sidebar
    }
    var body: some View {
        VStack(spacing: 0) {
            Button { switchingSpace = true } label: {
                HStack(spacing: 9) {
                    SpaceImage(space: environment.activeSpace, size: 24)
                    Text(environment.activeSpace?.title ?? "Spaces").fontWeight(.heavy).lineLimit(1)
                    Spacer(minLength: 2)
                    LibraryIcon(name: "chevdown", size: 17).frame(width: 28, height: 30)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Switch Space").accessibilityLabel("Switch Space")
                .padding(.horizontal, 14).padding(.vertical, 14)
                .popover(isPresented: $switchingSpace) { MacSpaceSwitcher(workspace: workspace).frame(width: 300, height: 360) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button { workspace.createDocument() } label: { rowLabel("New Document", icon: "writepen") }
                    Divider()
                    VStack(spacing: 2) {
                        ForEach([MacDestination.allDocuments, .recents, .tasks, .calendar, .collections, .templates]) { destination in
                            Button { navigate(destination) } label: {
                                rowLabel(destination.title, icon: destination.icon, selected: workspace.activeTab.location.documentID == nil &&
                                    workspace.activeTab.location.folderID == nil && workspace.activeTab.location.destination == destination)
                            }.contextMenu { Button("Open in New Tab") { navigate(destination, newTab: true) } }
                        }
                    }
                    DisclosureGroup(isExpanded: $state.starredExpanded) {
                        VStack(spacing: 2) {
                            ForEach(environment.overview.favorites) { document in
                                Button { workspace.perform { try await workspace.open(document) } } label: {
                                    HStack(spacing: 9) {
                                        LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 2)
                                            .frame(width: 20, height: 28).accessibilityHidden(true)
                                        Text(document.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.horizontal, 8).frame(minHeight: 36).contentShape(Rectangle())
                                        .background(workspace.activeTab.location.documentID == document.id ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .accessibilityAddTraits(workspace.activeTab.location.documentID == document.id ? .isSelected : [])
                                }.contextMenu { MacDocumentMenu(document: document, workspace: workspace) }
                            }
                        }
                    } label: { sectionTitle("Starred") }
                    DisclosureGroup(isExpanded: $state.foldersExpanded) {
                        VStack(spacing: 1) {
                            Button { navigate(.allDocuments, folder: "__unsorted") } label: { rowLabel("Unsorted", icon: "openedfolder") }
                                .dropDestination(for: String.self) { values, _ in drop(values, to: nil) }
                            ForEach(FolderHierarchy(folders: environment.overview.folders).children(of: nil)) { folder in
                                folderRow(folder, depth: 0)
                            }
                            Button { environment.requestFolderCreation(parentFolderID: nil) } label: { rowLabel("New Folder", icon: "addwavy") }.foregroundStyle(.secondary)
                        }
                    } label: { sectionTitle("Folders") }
                    DisclosureGroup(isExpanded: $state.tagsExpanded) {
                        VStack(spacing: 2) {
                            ForEach((try? environment.tags.catalogue()) ?? []) { tag in
                                Button { workspace.perform { try await workspace.navigate(.tags, tags: [tag.id]) } } label: {
                                    rowLabel(tag.name, icon: "hashtagwavy", selected: workspace.activeTab.location.tagIDs.contains(tag.id))
                                }
                            }
                            Button { navigate(.tags) } label: { rowLabel("All Tags", icon: "hashtagwavy") }
                        }
                    } label: { sectionTitle("Tags") }
                    Button { navigate(.trash) } label: { rowLabel("Trash", icon: "trash", selected: workspace.activeTab.location.destination == .trash) }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }.scrollPosition($state.scroll)
            Divider()
            HStack {
                SettingsLink { LibraryIcon(name: "settings", size: 18).frame(width: 30, height: 30) }.help("Settings")
                Spacer()
                Text(environment.database.libraryID == LibraryRecord.localID ? "On This Mac" : "Account Library")
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded)).buttonStyle(.plain)
        .background(.regularMaterial)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.secondary).padding(.vertical, 5)
    }
    private func rowLabel(_ title: String, icon: String, selected: Bool = false, count: Int? = nil) -> some View {
        HStack(spacing: 9) {
            LibraryIcon(name: icon, size: 16).foregroundStyle(selected ? VellixSurface.violet : .secondary)
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let count { Text(String(count)).font(.caption).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            .background(selected ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func folderRow(_ folder: FolderRecord, depth: Int) -> AnyView {
        let children = FolderHierarchy(folders: environment.overview.folders).children(of: folder.id)
        return AnyView(VStack(spacing: 1) {
            HStack(spacing: 0) {
                if !children.isEmpty {
                    Button {
                        if !state.expandedFolders.insert(folder.id).inserted { state.expandedFolders.remove(folder.id) }
                    } label: { LibraryIcon(name: state.expandedFolders.contains(folder.id) ? "chevdown" : "chevright", size: 10).frame(width: 18, height: 28) }
                        .accessibilityLabel("Expand \(folder.title)")
                }
                Button { navigate(.allDocuments, folder: folder.id) } label: {
                    rowLabel(folder.title, icon: folder.icon ?? "linesfolderfill", selected: workspace.activeTab.location.folderID == folder.id,
                        count: FolderHierarchy(folders: environment.overview.folders).itemCount(in: folder.id, documents: environment.overview.all))
                }
            }.padding(.leading, CGFloat(depth) * 12)
                .contextMenu {
                    Button("Open in New Tab") { navigate(.allDocuments, folder: folder.id, newTab: true) }
                    FolderContextMenu(folder: folder)
                }
                .dropDestination(for: String.self) { values, _ in drop(values, to: folder.id) }
            if state.expandedFolders.contains(folder.id) {
                ForEach(children) { folderRow($0, depth: depth + 1) }
            }
        })
    }
    private func navigate(_ destination: MacDestination, folder: String? = nil, newTab: Bool = false) {
        workspace.perform { try await workspace.navigate(destination, folderID: folder, newTab: newTab) }
    }
    private func drop(_ values: [String], to folder: String?) -> Bool {
        let ids = Set(values.compactMap { $0.hasPrefix("penned-document:") ? String($0.dropFirst(16)) : nil })
        guard !ids.isEmpty else { return false }
        workspace.perform {
            try await environment.prepareForWorkspaceNavigation()
            try environment.moveLibraryItems(LibraryMoveRequest(documentIDs: ids, folderIDs: []), to: folder)
        }
        return true
    }
}

struct MacSpaceSwitcher: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search Spaces", text: $query).textFieldStyle(MacInputStyle())
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(workspace.environment.allSpaces.filter { !$0.isArchived && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { space in
                        Button { workspace.perform { try await workspace.switchSpace(space.id); dismiss() } } label: {
                            HStack(spacing: 10) {
                                SpaceImage(space: space, size: 24)
                                Text(space.title).frame(maxWidth: .infinity, alignment: .leading)
                                if workspace.spaceID == space.id { LibraryIcon(name: "checkwavy", size: 16) }
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Button("New Space") { dismiss(); workspace.environment.createSpace() }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).fontDesign(.rounded)
    }
}
