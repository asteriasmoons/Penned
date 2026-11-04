import SwiftUI
import UIKit

private enum ClipperPalette {
    static let background = Color(red: 36/255, green: 36/255, blue: 36/255)
    static let surface = Color(red: 48/255, green: 48/255, blue: 48/255)
    static let text = Color(red: 246/255, green: 246/255, blue: 246/255)
    static let muted = Color(red: 168/255, green: 168/255, blue: 173/255)
    static let accent = Color(red: 188/255, green: 118/255, blue: 1)
    static let border = Color.white.opacity(0.09)
}

struct ShareClipperView: View {
    let extensionItems: [NSExtensionItem]
    let onClose: () -> Void

    @State private var state = ShareExtensionState()
    @State private var screen: Screen = .article
    @State private var showNotes = false
    @State private var showTags = false
    @State private var showMetadata = false
    @State private var search = ""
    @State private var folderParent: String?
    @AppStorage("pennedShareClipperTheme") private var theme = "system"

    private enum Screen { case article, spaces, folders, settings }
    private var selectedFolderName: String { state.selectedFolder?.title ?? "Unsorted" }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.isLoading {
                        ProgressView("Loading article…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if state.connection == nil {
                        connectionScreen
                    } else {
                        switch screen {
                        case .article: articleScreen
                        case .spaces: spacesScreen
                        case .folders: foldersScreen
                        case .settings: settingsScreen
                        }
                    }
                    if let error = state.errorMessage {
                        Text(error).font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.53, blue: 0.64))
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 6)
            }
            if screen == .article && state.connection != nil && !state.isLoading {
                footer
            }
        }
        .padding(12)
        .background(ClipperPalette.background.ignoresSafeArea())
        .foregroundStyle(ClipperPalette.text)
        .font(.system(size: 15, design: .rounded))
        .tint(ClipperPalette.accent)
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .task { await loadClip() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if screen != .article {
                iconButton("chevron.left", label: "Back") {
                    screen = .article
                    search = ""
                }
            }
            Button {
                screen = .spaces
                search = ""
            } label: {
                HStack(spacing: 8) {
                    Image("ClipperLogo").resizable().scaledToFit()
                        .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(state.selectedSpace?.title ?? "Penned")
                        .fontWeight(.bold).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ClipperPalette.muted)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button { screen = .settings } label: {
                Image("settingswavy").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 20, height: 20).frame(width: 36, height: 36)
            }.buttonStyle(.plain).accessibilityLabel("Clipper settings")
            iconButton("xmark", label: "Close clipper", action: onClose)
        }
        .frame(height: 42)
        .padding(.bottom, 10)
    }

    private var articleScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Article title", text: $state.draft.title, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .padding(12)
                .clipperField()

            HStack(spacing: 6) {
                Button { showNotes.toggle() } label: {
                    Image("writepen").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 20, height: 20).frame(width: 36, height: 36)
                        .foregroundStyle(showNotes ? ClipperPalette.accent : ClipperPalette.muted)
                }.buttonStyle(.plain).accessibilityLabel("Personal notes")
                iconButton("number", label: "Tags", active: showTags) { showTags.toggle() }
                if !state.draft.tagIDs.isEmpty {
                    Text("\(state.draft.tagIDs.count)").font(.caption).foregroundStyle(ClipperPalette.accent)
                }
                iconButton("info.circle", label: "Article metadata", active: showMetadata) { showMetadata.toggle() }
            }
            if showNotes {
                TextField("Add a note", text: $state.draft.notes, axis: .vertical)
                    .lineLimit(3...6).padding(12).clipperField()
            }
            if showTags { tagsPanel }
            if showMetadata { metadataPanel }

            sectionLabel("Destination")
            Button {
                folderParent = nil
                search = ""
                screen = .folders
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                    Text(selectedFolderName).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12)).foregroundStyle(ClipperPalette.muted)
                }
                .padding(12).frame(minHeight: 46)
                .clipperField()
            }
            .buttonStyle(.plain)
        }
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Metadata")
            metadataRow("Author", text: $state.draft.author)
            metadataRow("Website", text: $state.draft.siteName)
            VStack(alignment: .leading, spacing: 5) {
                Text("Original URL").foregroundStyle(ClipperPalette.muted)
                Text(state.draft.sourceURL)
                    .foregroundStyle(ClipperPalette.accent)
                    .font(.system(size: 13, design: .rounded))
                    .textSelection(.enabled)
            }.padding(.horizontal, 8)
        }
    }

    private func metadataRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 75, alignment: .leading)
            TextField(title, text: text).padding(10).clipperField()
        }.padding(.horizontal, 8)
    }

    private var tagsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField("Search tags")
            ForEach(state.tags.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }, id: \.id) { tag in
                Button {
                    state.toggleTag(tag.id)
                } label: {
                    HStack {
                        Text(tag.title)
                        Spacer()
                        Image(systemName: state.draft.tagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.draft.tagIDs.contains(tag.id) ? ClipperPalette.accent : ClipperPalette.muted)
                    }.padding(10)
                }.buttonStyle(.plain)
            }
        }
    }

    private var spacesScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Space").font(.system(size: 20, weight: .black, design: .rounded)).padding(8)
            searchField("Search Spaces")
            ForEach(state.spaces.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }, id: \.id) { space in
                Button {
                    state.selectSpace(space.id)
                    screen = .article
                    search = ""
                } label: {
                    HStack {
                        Image(systemName: "square.stack.3d.up")
                        Text(space.title)
                        Spacer()
                        if state.draft.spaceID == space.id { Image(systemName: "checkmark").foregroundStyle(ClipperPalette.accent) }
                    }.padding(12)
                }.buttonStyle(.plain)
            }
        }
    }

    private var foldersScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Folder").font(.system(size: 20, weight: .black, design: .rounded)).padding(8)
            searchField("Search folders")
            if let parent = folderParent, let folder = state.folders.first(where: { $0.id == parent }) {
                Button {
                    folderParent = folder.parentID
                    search = ""
                } label: { Label("Back", systemImage: "chevron.left").padding(12) }
                    .buttonStyle(.plain)
            }
            Button {
                state.selectFolder(folderParent)
                screen = .article
            } label: {
                Label(folderParent == nil ? "Unsorted" : "Save in This Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.plain)
            ForEach(state.folders.filter { $0.parentID == folderParent && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }, id: \.id) { folder in
                HStack {
                    Button {
                        state.selectFolder(folder.id)
                        screen = .article
                    } label: {
                        Label(folder.title, systemImage: "folder.fill")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.buttonStyle(.plain)
                    if state.folders.contains(where: { $0.parentID == folder.id }) {
                        Button {
                            folderParent = folder.id
                            search = ""
                        } label: { Image(systemName: "chevron.right").padding(12) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var settingsScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("Theme")
            HStack(spacing: 4) {
                ForEach(["system", "light", "dark"], id: \.self) { option in
                    Button {
                        theme = option
                    } label: {
                        Text(option.capitalized)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(theme == option ? ClipperPalette.background : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(theme == option ? ClipperPalette.text : ClipperPalette.muted)
                    }.buttonStyle(.plain)
                }
            }.padding(4).background(ClipperPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            Text(state.connection?.accountName ?? "Not connected")
                .foregroundStyle(ClipperPalette.muted).padding(.horizontal, 8)
            Link("Manage Account", destination: URL(string: "penned://clipper/connect")!)
                .frame(maxWidth: .infinity).padding(12).clipperField()
            Button("Refresh Connection") { state.loadCatalogue() }
                .frame(maxWidth: .infinity).padding(12).clipperField()
        }
    }

    private var connectionScreen: some View {
        VStack(spacing: 14) {
            Image("ClipperLogo").resizable().scaledToFit().frame(width: 52, height: 52)
            Text("Connect to Penned").font(.system(size: 20, weight: .black, design: .rounded))
            Text("Open Penned and sign in under Account Settings.")
                .foregroundStyle(ClipperPalette.muted)
            Link("Connect to Penned", destination: URL(string: "penned://clipper/connect")!)
            Button("Refresh Connection") { state.loadCatalogue() }
        }.frame(maxWidth: .infinity).padding(12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if state.isSaved {
                Button("Done", action: onClose)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ClipperPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color(red: 21/255, green: 16/255, blue: 24/255))
            } else {
                Button {
                    Task { await performSave() }
                } label: {
                    HStack(spacing: 8) {
                        if state.isSaving { ProgressView().tint(.black) }
                        Text(state.isSaving ? "Saving Clip…" : "Save Clip").fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ClipperPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color(red: 21/255, green: 16/255, blue: 24/255))
                }
                .disabled(!state.draft.canSave || state.isSaving)
                .opacity(state.draft.canSave ? 1 : 0.5)
            }
        }.padding(.top, 12)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(ClipperPalette.muted)
            .padding(.horizontal, 8).padding(.top, 8)
    }

    private func searchField(_ prompt: String) -> some View {
        TextField(prompt, text: $search)
            .padding(12).clipperField()
    }

    private func iconButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(active ? ClipperPalette.accent : ClipperPalette.text)
                .frame(width: 36, height: 36)
                .background(active ? ClipperPalette.surface : .clear, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func loadClip() async {
        state.loadCatalogue()
        guard state.connection != nil else { return }
        state.isLoading = true
        defer { state.isLoading = false }
        do {
            let shared = try await SharedContentReceiver().receive(from: extensionItems)
            let article = try await ArticleExtractor().extract(from: shared.url)
            let nodes = try await ArticleConverter().convert(article)
            state.draft.sourceURL = shared.url.absoluteString
            state.draft.title = article.title
            state.draft.author = article.author
            state.draft.siteName = article.siteName
            state.draft.thumbnailURL = article.thumbnailURL
            state.draft.content = nodes
            state.errorMessage = nil
        } catch { state.showError(error) }
    }

    private func performSave() async {
        guard state.draft.canSave, !state.isSaving else { return }
        state.isSaving = true
        state.errorMessage = nil
        do {
            _ = try await ClipSubmissionService().submit(state.draft)
            state.isSaved = true
        } catch { state.showError(error) }
        state.isSaving = false
    }
}

private extension View {
    func clipperField() -> some View {
        self.background(ClipperPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ClipperPalette.border))
    }
}
