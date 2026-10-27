import SwiftUI

enum PadSetting: String, CaseIterable, Identifiable {
    case space = "Space Settings", templates = "Templates", folders = "Folders", tags = "Tags"
    case dailyNotes = "Daily Notes", spaces = "My Spaces", account = "Account Settings", library = "Library & Sync", about = "About"
    case appearance = "Appearance"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .space: return "settings"
        case .templates: return "copy"
        case .folders: return "openedfolder"
        case .tags: return "hashtagwavy"
        case .dailyNotes: return "mooncal"
        case .spaces: return "spaces"
        case .account: return "profilewavy"
        case .library: return "cloudie"
        case .about: return "infowavy"
        case .appearance: return "text"
        }
    }
}

struct PadSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var accounts: AppState
    @State private var selected: PadSetting = .space
    @State private var showingCategories = false

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 760
            HStack(spacing: 0) {
                if columns { categories.background(VellixSurface.sidebar).frame(width: min(336, max(260, geometry.size.width * 0.38))) }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        if !columns { PadIconButton("Settings Categories", icon: "columns") { showingCategories = true } }
                        Text(selected.rawValue).font(.system(.title3, design: .rounded).weight(.black))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if selected == .templates {
                            PadIconButton("Create Template", icon: "addwavy", action: environment.createTemplate)
                        }
                        if selected == .folders {
                            PadIconButton("New Folder", icon: "addwavy") { environment.requestFolderCreation(parentFolderID: nil) }
                        }
                    }.padding(.horizontal, 24).frame(minHeight: 60)
                    NavigationStack { page }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(isPresented: $showingCategories) {
                categories.pennedSheet(title: "Settings", close: { showingCategories = false })
                    .presentationDetents([.medium, .large])
            }
        }
        .background(VellixSurface.appBackground).foregroundStyle(VellixSurface.ink)
        .fontDesign(.rounded).tint(VellixSurface.violet)
        .accessibilityIdentifier("ipad-settings-workspace")
    }

    private var categories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 16) {
                    SpaceImage(space: environment.activeSpace, size: 88)
                    Text(environment.activeSpace?.title ?? "Space").font(.system(.headline, design: .rounded).weight(.black))
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
                section("Space Settings", items: [.templates, .folders, .tags, .space, .dailyNotes, .spaces])
                section("Your Account", items: [.account, .library])
                section("General Settings", items: [.appearance])
                section("Penned", items: [.about])
            }.padding(14).padding(.bottom, 20)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(VellixSurface.hairline).frame(width: 0.5) }
    }

    private func section(_ title: String, items: [PadSetting]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.subheadline, design: .rounded).weight(.black)).foregroundStyle(.secondary).padding(10)
            ForEach(items) { item in
                Button { selected = item; showingCategories = false } label: {
                    HStack(spacing: 12) {
                        LibraryIcon(name: item.icon, size: 20)
                        Text(item.rawValue).font(.system(.subheadline, design: .rounded).weight(.heavy))
                            .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    }.padding(.horizontal, 12).frame(minHeight: 46).contentShape(Rectangle())
                        .foregroundStyle(selected == item ? VellixSurface.violet : VellixSurface.ink)
                        .background(selected == item ? VellixSurface.controlInk.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(selected == item ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch selected {
        case .appearance: PennedAppearanceSettingsView()
        case .space: PadSpaceSettingsPage()
        case .account: AccountSettingsView(embeddedInWorkspace: true)
        case .library:
            if let identity = accounts.currentAccountIdentity {
                AccountLibrarySheet(identity: identity, embeddedInWorkspace: true)
            } else { AccountSettingsView(embeddedInWorkspace: true) }
        case .templates: TemplatesView()
        case .folders: DocumentBrowserView(mode: .folders, documents: [])
        case .tags: TagBrowserView()
        case .dailyNotes: DailyNotesSettingsView(isWorkspaceEmbedded: true)
        case .spaces: PadSpaceManagementView()
        case .about:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Penned").font(.system(.largeTitle, design: .rounded).weight(.black))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
        }
    }
}

struct PadSpaceManagementView: View {
    @EnvironmentObject private var environment: AppEnvironment
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    var body: some View {
        #if os(iOS)
        SpaceManagementView()
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button(action: environment.createSpace) {
                        Label { Text("New Space") } icon: { LibraryIcon(name: "addwavy", size: 20) }
                    }.buttonStyle(.plain)
                    Spacer()
                    EditButton()
                }.font(.system(.subheadline, design: .rounded).weight(.black))
                    .padding(.horizontal, 24).frame(minHeight: 48).background(VellixSurface.appBackground)
            }
            .environment(\.editMode, $editMode)
        #else
        SpaceManagementView()
        #endif
    }
}

private struct PadSpaceSettingsPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmingArchive = false
    @State private var confirmingDelete = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Button(action: edit) {
                    ZStack(alignment: .bottomTrailing) {
                        SpaceImage(space: environment.activeSpace, size: 132)
                        LibraryIcon(name: "imagesign", size: 22).padding(10).background(.regularMaterial, in: Circle())
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 28).accessibilityLabel("Change Space image")
                Button(action: edit) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Space Name").font(.footnote).foregroundStyle(.secondary)
                            Text(environment.activeSpace?.title ?? "Space").font(.system(.headline, design: .rounded).weight(.black))
                            if let text = environment.activeSpace?.spaceDescription, !text.isEmpty {
                                Text(text).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        LibraryIcon(name: "writepen", size: 20).foregroundStyle(.secondary)
                    }.padding(20).pennedSheetField()
                }
                Text("Danger Zone").font(.system(.headline, design: .rounded).weight(.black))
                Button { confirmingArchive = true } label: {
                    Label { Text("Archive Space") } icon: { LibraryIcon(name: "openedfolder", size: 20) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20).pennedSheetField()
                }.foregroundStyle(VellixSurface.violet)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete Space").foregroundStyle(VellixSurface.coral)
                        Text("Permanently delete this Space and all its documents, folders, templates, attachments and history.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20).pennedSheetField()
                }
            }.padding(28).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).disabled(busy)
        .confirmationDialog("Archive this Space?", isPresented: $confirmingArchive, titleVisibility: .visible) {
            Button("Archive Space") { perform { try await environment.archiveSpace($0, archived: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its content is preserved. Restore it from My Spaces.") }
        .confirmationDialog("Permanently delete this Space and all its content?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Space and All Contents", role: .destructive) { perform { try await environment.deleteSpace($0) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone. Other Spaces and account libraries are not deleted.") }
    }
    private func edit() { if let space = environment.activeSpace { environment.spaceSheet = .edit(space) } }
    private func perform(_ action: @escaping (String) async throws -> Void) {
        guard let id = environment.selectedSpaceID, !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await action(id) } catch { environment.report(error) } }
    }
}
