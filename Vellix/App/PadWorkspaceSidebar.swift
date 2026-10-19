import SwiftUI

struct PadWorkspaceSidebar: View {
    @ObservedObject var workspace: PadWorkspaceModel
    @EnvironmentObject private var environment: AppEnvironment
    var close: () -> Void
    @State private var showingSpaces = false
    @State private var starredExpanded = true
    @State private var showingAllStarred = false
    @State private var foldersExpanded = true
    @State private var tagsExpanded = true
    @State private var expandedFolders: Set<String> = []
    @State private var tags: [DocumentTag] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Penned").font(.system(.title3, design: .rounded).weight(.black))
                Spacer()
                PadIconButton("Hide Sidebar", icon: "sidebar", action: close)
            }.padding(.horizontal, 20).frame(height: 60)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    tabsSection
                    spaceSection
                    VStack(spacing: 2) {
                        destination(.library(.allDocuments))
                        destination(.tasks)
                        destination(.library(.calendar))
                        destination(.collections)
                        destination(.library(.home))
                        destination(.library(.recents))
                        destination(.library(.templates))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader("Starred", expanded: $starredExpanded)
                        if starredExpanded {
                            ForEach(environment.overview.favorites.prefix(showingAllStarred ? environment.overview.favorites.count : 8)) { document in
                                Button { open(document) } label: {
                                    HStack(spacing: 12) {
                                        LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 2).frame(width: 20)
                                        Text(document.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                                }.contextMenu {
                                    DocumentContextMenu(document: document)
                                }
                            }
                            if environment.overview.favorites.isEmpty { emptyLabel("No starred documents") }
                            if environment.overview.favorites.count > 8 {
                                Button(showingAllStarred ? "Show Fewer" : "Show \(environment.overview.favorites.count - 8) More") { showingAllStarred.toggle() }
                                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).frame(minHeight: 36)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            sectionHeader("Folders", expanded: $foldersExpanded)
                            PadIconButton("New Folder", icon: "addwavy") { environment.requestFolderCreation(parentFolderID: nil) }
                        }
                        if foldersExpanded {
                            row("Unsorted", icon: "openedfolder", selected: workspace.activeTab.location.folderID == "__unsorted") {
                                navigate(.library(.allDocuments), folder: "__unsorted")
                            }
                            ForEach(folderRows, id: \.folder.id) { item in folderRow(item.folder, depth: item.depth) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader("Tags", expanded: $tagsExpanded)
                        if tagsExpanded {
                            destination(.library(.tags))
                            ForEach(tags) { tag in
                                row("#" + tag.name, icon: "hashtagwavy", selected: workspace.activeTab.location.tagIDs.contains(tag.id)) {
                                    perform { try await workspace.navigate(.library(.tags), tags: [tag.id]) }
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(spacing: 2) {
                        destination(.library(.spaces))
                        destination(.library(.trash))
                        destination(.settings)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 28)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .font(.system(.body, design: .rounded).weight(.heavy))
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSpaces) { SpacePickerSheet() }
        .task(id: environment.selectedSpaceID) { reloadTags() }
        .onReceive(NotificationCenter.default.publisher(for: .pennedTagsChanged)) { _ in reloadTags() }
        .accessibilityIdentifier("ipad-workspace-sidebar")
    }

    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tabs").font(.subheadline.weight(.black)).foregroundStyle(.secondary).padding(.horizontal, 12)
            ForEach(workspace.tabs) { tab in
                HStack(spacing: 0) {
                    Button { perform { try await workspace.selectTab(tab.id) } } label: {
                        HStack(spacing: 12) {
                            LibraryIcon(name: tab.location.documentID.flatMap { environment.editorCache.model(for: $0)?.document?.icon }
                                ?? tab.location.destination.icon, size: 20)
                            Text(workspace.title(for: tab)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.leading, 12).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    PadIconButton("Close \(workspace.title(for: tab))", icon: "xmarkwavy") {
                        perform { try await workspace.closeTab(tab.id) }
                    }
                }
                .foregroundStyle(workspace.activeID == tab.id ? VellixSurface.violet : VellixSurface.ink)
                .background(workspace.activeID == tab.id ? Color.black : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityAddTraits(workspace.activeID == tab.id ? .isSelected : [])
                .accessibilityIdentifier("ipad-tab-\(tab.id)")
                .contextMenu {
                    Button("Duplicate Tab") { perform { try await workspace.newTab(tab.location) } }
                    Button("Close Tab") { perform { try await workspace.closeTab(tab.id) } }
                }
            }
            row("New Tab", icon: "addwavy") { perform { try await workspace.newTab() } }
        }
    }

    private var spaceSection: some View {
        VStack(spacing: 4) {
            Divider().padding(.bottom, 10)
            HStack(spacing: 10) {
                Button { showingSpaces = true } label: {
                    HStack(spacing: 12) {
                        SpaceImage(space: environment.activeSpace, size: 28)
                        Text(environment.activeSpace?.title ?? "Space").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        LibraryIcon(name: "chevdown", size: 12)
                    }.frame(minHeight: 44)
                }.accessibilityLabel("Switch Space")
                Menu {
                    Button("Edit Space") { if let space = environment.activeSpace { environment.spaceSheet = .edit(space) } }
                    Button("Manage Spaces") { navigate(.library(.spaces)) }
                    Button("New Space", action: environment.createSpace)
                    Button("Space Settings") { navigate(.settings) }
                } label: { LibraryIcon(name: "dotswavy", size: 19).frame(width: 36, height: 44) }
                    .accessibilityLabel("Space actions")
            }.padding(.horizontal, 12)
            row("New Document", icon: "writepen") { _ = environment.createDocument() }
        }
    }

    private func destination(_ destination: PadWorkspaceDestination) -> some View {
        row(destination.title, icon: destination.icon,
            selected: workspace.activeTab.location.destination == destination && workspace.activeTab.location.documentID == nil && workspace.activeTab.location.folderID == nil) {
            navigate(destination)
        }.contextMenu {
            Button("Open in New Tab") { perform { try await workspace.navigate(destination, newTab: true) } }
        }
    }

    private func row(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryIcon(name: icon, size: 20).foregroundStyle(selected ? VellixSurface.violet : .secondary)
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Text(title)
                LibraryIcon(name: expanded.wrappedValue ? "chevdown" : "chevright", size: 11)
                Spacer(minLength: 0)
            }.font(.subheadline.weight(.black)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(minHeight: 32)
        }.accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    private var folderRows: [(folder: FolderRecord, depth: Int)] {
        let hierarchy = FolderHierarchy(folders: environment.overview.folders)
        var result: [(FolderRecord, Int)] = [], visited: Set<String> = []
        func append(_ parent: String?, depth: Int) {
            for folder in hierarchy.children(of: parent) where visited.insert(folder.id).inserted {
                result.append((folder, depth))
                if expandedFolders.contains(folder.id) { append(folder.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return result
    }

    private func folderRow(_ folder: FolderRecord, depth: Int) -> some View {
        HStack(spacing: 0) {
            Button { navigate(.library(.allDocuments), folder: folder.id) } label: {
                HStack(spacing: 10) {
                    LibraryFolderIcon(folder: folder, size: 20)
                    Text(folder.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(FolderHierarchy(folders: environment.overview.folders).itemCount(in: folder.id, documents: environment.overview.all)))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 12 + CGFloat(min(depth, 6)) * 16).frame(minHeight: 44).contentShape(Rectangle())
            }
            if environment.overview.folders.contains(where: { $0.parentFolderID == folder.id }) {
                PadIconButton(expandedFolders.contains(folder.id) ? "Collapse folder" : "Expand folder",
                              icon: expandedFolders.contains(folder.id) ? "chevdown" : "chevright") {
                    if !expandedFolders.insert(folder.id).inserted { expandedFolders.remove(folder.id) }
                }
            } else { Color.clear.frame(width: 10) }
        }
        .background(workspace.activeTab.location.folderID == folder.id ? .white.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            FolderContextMenu(folder: folder)
            Button("Open in New Tab") { perform { try await workspace.navigate(.library(.allDocuments), folderID: folder.id, newTab: true) } }
        }
    }

    private func emptyLabel(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8) }
    private func open(_ document: DocumentRecord) { perform { try await workspace.openDocument(document) } }
    private func navigate(_ destination: PadWorkspaceDestination, folder: String? = nil) {
        perform { try await workspace.navigate(destination, folderID: folder) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { environment.report(error) } }
    }
    private func reloadTags() { do { tags = try environment.tags.catalogue() } catch { environment.report(error) } }
}
