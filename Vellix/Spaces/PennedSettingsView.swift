import SwiftUI

private enum PennedSetting: String, Identifiable, Hashable {
    case templates = "Templates", published = "Published Content", stats = "Stats"
    case folders = "On-device Folders", tags = "Tags", space = "Space Settings"
    case appearance = "Appearance & Sound", language = "Language & Spelling", security = "Security", advanced = "Advanced"
    case account = "Account Settings", subscription = "My Subscription", spaces = "My Spaces", team = "My Team"
    case integrations = "Integrations", assistant = "Assistant", notifications = "Notifications"
    case diagnostics = "Diagnostics", about = "About", dailyNotes = "Daily Notes"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .templates: return "quote"
        case .published: return "linkcircle"
        case .stats: return "chartcircle"
        case .folders: return "openedfolder"
        case .tags: return "hashtagwavy"
        case .space: return "settings"
        case .appearance: return "text"
        case .language: return "text"
        case .security: return "lockwavy"
        case .advanced: return "settingswavy"
        case .account: return "profilewavy"
        case .subscription: return "subscription"
        case .spaces: return "spaces"
        case .team: return "arrowsprofile"
        case .integrations: return "link"
        case .assistant: return "sparklecircle"
        case .notifications: return "bellfill"
        case .diagnostics: return "heartpulse"
        case .about: return "infowavy"
        case .dailyNotes: return "mooncal"
        }
    }
}

struct PennedSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showingSpaces = false
    @State private var showingTitle = false
    @State private var destination: PennedSetting?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SettingsBackButton()
                Spacer()
                Text("Settings").font(.headline).opacity(showingTitle ? 1 : 0)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 18).frame(height: 60)
            .background { if showingTitle { Rectangle().fill(.ultraThinMaterial) } }

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    spaceHeader
                    settingsSection("Space Settings", items: [.templates, .published, .stats, .folders, .tags, .space])
                    settingsSection("Daily Notes", items: [.dailyNotes])
                    settingsSection("General Settings", items: [.appearance, .language, .security, .advanced])
                    settingsSection("Your Account", items: [.account, .subscription, .spaces, .team, .integrations, .assistant, .notifications])
                    VStack(spacing: 0) { settingsRow(.diagnostics); settingsRow(.about, separator: false) }
                    VStack(spacing: 8) {
                        Text("PENNED").font(.system(size: 28, weight: .black, design: .rounded))
                        Text("version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.footnote)
                    }.foregroundStyle(VellixSurface.controlInk.opacity(0.18)).frame(maxWidth: .infinity).padding(.top, 90).padding(.bottom, 50)
                }
                .padding(.horizontal, 20).frame(maxWidth: 660).frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 180 } action: { _, value in
                showingTitle = value
            }
        }
        .background(VellixSurface.workspace).foregroundStyle(VellixSurface.controlInk)
        .navigationBarBackButtonHidden()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showingSpaces) { SpacePickerSheet() }
        .navigationDestination(item: $destination) { setting in
            if setting == .account {
                AccountSettingsView()
            } else {
                settingDestination(setting)
                    .navigationTitle(setting.rawValue).navigationBarBackButtonHidden()
                    #if os(iOS)
                    .toolbar(.visible, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { ToolbarItem(placement: .cancellationAction) { SettingsBackButton() } }
            }
        }
    }

    private var spaceHeader: some View {
        VStack(spacing: 22) {
            Button {
                if let space = environment.activeSpace { environment.spaceSheet = .edit(space) }
            } label: {
                SpaceImage(space: environment.activeSpace, size: 104)
            }.accessibilityLabel("Change Space image")
            Button { showingSpaces = true } label: {
                HStack(spacing: 12) {
                    Text(environment.activeSpace?.title ?? "Space").font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                    LibraryIcon(name: "chevdown", size: 12).foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.45))
                }.padding(.horizontal, 10).frame(minHeight: 36)
            }.accessibilityLabel("Switch or create a Space")
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 2)
    }

    private func settingsSection(_ title: String, items: [PennedSetting]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .semibold)).padding(.bottom, 2)
            VStack(spacing: 0) {
                ForEach(items) { item in settingsRow(item, separator: item != items.last) }
            }
        }
    }

    private func settingsRow(_ item: PennedSetting, separator: Bool = true) -> some View {
        VStack(spacing: 0) {
            Button {
                switch item {
                case .space:
                    if let space = environment.activeSpace { environment.spaceSheet = .edit(space) }
                case .tags:
                    Task { await environment.browseTags() }
                case .templates, .folders:
                    environment.isSettingsPresented = false
                    environment.selectedFolderID = nil
                    environment.selectedDestination = item == .templates ? .templates : .folders
                default: destination = item
                }
            } label: {
                HStack(spacing: 14) {
                    LibraryIcon(name: item.icon, size: 19).foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.45)).frame(width: 20)
                    Text(item.rawValue).font(.system(size: 16)).foregroundStyle(VellixSurface.controlInk.opacity(0.72)).frame(maxWidth: .infinity, alignment: .leading)
                    LibraryIcon(name: "chevright", size: 11).foregroundStyle(VellixSurface.secondaryControlInk(opacity: 0.28))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if separator { Rectangle().fill(VellixSurface.controlInk.opacity(0.055)).frame(height: 0.5).padding(.leading, 34) }
        }
    }

    @ViewBuilder private func settingDestination(_ setting: PennedSetting) -> some View {
        switch setting {
        case .appearance: PennedAppearanceSettingsView()
        case .spaces: SpaceManagementView()
        case .dailyNotes: DailyNotesSettingsView()
        case .about:
            VStack(spacing: 12) {
                Text("Penned").font(.largeTitle.bold())
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(VellixSurface.workspace)
        default:
            VStack(spacing: 14) {
                LibraryIcon(name: setting.icon, size: 32).foregroundStyle(.secondary)
                Text("Not available yet").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(VellixSurface.workspace)
        }
    }
}

struct SettingsBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            LibraryIcon(name: "chevleft", size: 20).foregroundStyle(VellixSurface.controlInk)
                .frame(width: 40, height: 40).background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(VellixSurface.controlInk.opacity(0.10)))
        }.buttonStyle(.plain).accessibilityLabel("Back")
    }
}

struct SpacePickerSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var creating = false
    @State private var switching = false
    @State private var startingSpaceID: String?
    @State private var error: String?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44

    private var spaces: [SpaceRecord] {
        environment.allSpaces.filter { !$0.isArchived && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    private var compactHeight: CGFloat {
        min(480, max(220, CGFloat(environment.allSpaces.filter { !$0.isArchived }.count) * rowHeight + 140))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(spaces) { space in
                        Button { select(space) } label: {
                            HStack(spacing: 12) {
                                SpaceImage(space: space, size: 26)
                                Text(space.title).font(.system(.body, design: .rounded).weight(.black))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if space.id == environment.selectedSpaceID {
                                    LibraryIcon(name: "checkwavy", size: 20).foregroundStyle(PennedSheetStyle.accent)
                                }
                            }.frame(minHeight: rowHeight).contentShape(Rectangle())
                        }.accessibilityAddTraits(space.id == environment.selectedSpaceID ? .isSelected : [])
                    }
                    if spaces.isEmpty { Text("No Spaces found").foregroundStyle(.secondary).padding(20) }
                }
            }.scrollBounceBehavior(.basedOnSize)
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.bottom, 8) }
        }
        .buttonStyle(.plain).foregroundStyle(VellixSurface.controlInk)
        .padding(.horizontal, 20).padding(.top, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                createSpaceButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .pennedSheet(header: searchField, closeDisabled: switching || environment.isSwitchingSpace, close: { dismiss() })
        .presentationDragIndicator(.hidden)
        .presentationDetents([.height(compactHeight), .large])
        .disabled(switching || environment.isSwitchingSpace)
        .interactiveDismissDisabled(switching)
        .onAppear { startingSpaceID = environment.selectedSpaceID }
        .sheet(isPresented: $creating, onDismiss: {
            if startingSpaceID != environment.selectedSpaceID { dismiss() }
        }) { SpaceEditorSheet(space: nil) }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            LibraryIcon(name: "searchwavy", size: 19).foregroundStyle(.secondary)
            TextField("Open Space...", text: $query).textFieldStyle(.plain).submitLabel(.search)
                .font(.system(.body, design: .rounded).weight(.black)).accessibilityLabel("Search Spaces")
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44).pennedSheetField()
    }

    @ViewBuilder private var createSpaceButton: some View {
        let button = Button { creating = true } label: {
            Label { Text("Create Space") } icon: { LibraryIcon(name: "addwavy", size: 20) }
        }
        .font(.system(.subheadline, design: .rounded).weight(.black))
        .controlSize(.large).tint(PennedSheetStyle.accent)
        if #available(iOS 26, macOS 26, *) {
            button.buttonStyle(.glassProminent).buttonBorderShape(.capsule).frame(minHeight: 44)
        } else {
            button.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).frame(minHeight: 44)
        }
    }

    private func select(_ space: SpaceRecord) {
        switching = true; error = nil
        Task {
            defer { switching = false }
            do { try await environment.switchSpace(to: space.id); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
