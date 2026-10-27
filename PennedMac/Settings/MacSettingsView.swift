import AppKit
import SwiftUI

struct MacSettingsRoot: View {
    @EnvironmentObject private var app: MacApplicationModel
    @EnvironmentObject private var library: LibraryWorkspace
    @EnvironmentObject private var accounts: AppState
    var body: some View {
        Group {
            if library.matches(accounts.currentAccountIdentity), let environment = app.windows.lastActive?.environment ?? library.environment,
               environment.database.isAccessible {
                MacSettingsView().environmentObject(environment).id(ObjectIdentifier(environment))
            } else { ProgressView("Opening Settings").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(minWidth: 840, idealWidth: 940, minHeight: 580, idealHeight: 700)
            .background(MacWindowAppearance().frame(width: 0, height: 0))
            .fontDesign(.rounded).tint(VellixSurface.violet).foregroundStyle(VellixSurface.ink)
            .listStyle(.plain).scrollContentBackground(.hidden)
    }
}

private struct MacSettingsView: View {
    @EnvironmentObject private var app: MacApplicationModel
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var accounts: AppState
    @EnvironmentObject private var library: LibraryWorkspace
    @State private var selection = MacSettingsCategory.account
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.rawValue)
                    .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(VellixSurface.ink)
                    .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 10)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(minWidth: 540).background(VellixSurface.appBackground)
        }
        .sheet(item: $environment.spaceSheet) { sheet in
            switch sheet {
            case .edit(let space): SpaceEditorSheet(space: space).frame(width: 520, height: 580)
            case .transfer(let content, let copy): SpaceTransferSheet(item: content, copy: copy).frame(width: 520, height: 580)
            }
        }
        .sheet(item: $environment.librarySheet) { sheet in
            switch sheet {
            case .folder(let request): FolderEditorSheet(request: request).frame(width: 520, height: 520)
            case .move(let request): FolderDestinationPicker(request: request).frame(width: 520, height: 520)
            }
        }
        .macAlert("Unable to Update Settings", isPresented: Binding(get: { environment.errorMessage != nil }, set: { if !$0 { environment.errorMessage = nil } })) { Button("OK") { environment.errorMessage = nil } } message: { Text(environment.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let space = environment.activeSpace {
                HStack(spacing: 10) {
                    SpaceImage(space: space, size: 34)
                    Text(space.title).font(.system(size: 15, weight: .heavy, design: .rounded)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Space Settings", [.templates, .published, .stats, .folders, .tags, .space])
                    section("Daily Notes", [.dailyNotes])
                    section("General Settings", [.appearance, .language, .security, .advanced])
                    section("Your Account", [.account, .subscription, .spaces, .team, .integrations, .assistant, .notifications, .library])
                    section("Penned", [.diagnostics, .about])
                }.padding(.horizontal, 10).padding(.bottom, 14)
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(.regularMaterial)
    }

    private func section(_ title: String, _ categories: [MacSettingsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk).padding(.horizontal, 9).padding(.bottom, 5)
            ForEach(categories) { category in
                Button { selection = category } label: { navRow(category) }.buttonStyle(.plain)
            }
        }
    }

    private func navRow(_ category: MacSettingsCategory) -> some View {
        let selected = selection == category
        return HStack(spacing: 10) {
            LibraryIcon(name: category.icon, size: 16).foregroundStyle(selected ? VellixSurface.violet : VellixSurface.secondaryInk)
            Text(category.rawValue).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if category.requiresUnavailableService { Text("Unavailable").font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(VellixSurface.tertiaryInk) }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(selected ? VellixSurface.ink : VellixSurface.secondaryInk)
        .padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
        .background(selected ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .space: MacSpaceSettings()
        case .spaces: SpaceManagementView()
        case .dailyNotes: DailyNotesSettingsView(isWorkspaceEmbedded: true)
        case .appearance: MacAppearanceSettings()
        case .templates, .folders, .tags: MacLibrarySettings(category: selection)
        case .stats: MacStatsSettings()
        case .language: MacLanguageSettings()
        case .security: MacSecuritySettings()
        case .advanced, .diagnostics: MacDiagnosticsSettings(advanced: selection == .advanced)
        case .notifications: MacNotificationSettings()
        case .integrations: MacIntegrationSettings { selection = .library }
        case .published, .subscription, .team, .assistant:
            MacSettingsScroll {
                Text("\(selection.rawValue) is not available in the current Penned application.")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk).padding(.top, 16)
            }
        case .account: MacAccountSettings()
        case .library:
            if let identity = accounts.currentAccountIdentity { AccountLibrarySheet(identity: identity, embeddedInWorkspace: true) }
            else {
                MacSettingsScroll {
                    MacSettingsCard {
                        Text("On This Mac").font(.system(size: 14, weight: .heavy, design: .rounded))
                        Text("Documents are stored locally on this Mac. Sign in from Account to open your account-owned library and configure iCloud synchronization.")
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk).fixedSize(horizontal: false, vertical: true)
                        Text(environment.database.libraryID).font(.system(size: 10, design: .monospaced)).foregroundStyle(VellixSurface.secondaryInk).textSelection(.enabled)
                    }
                }
            }
        case .about:
            MacSettingsScroll {
                MacSettingsCard {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Penned").font(.system(size: 20, weight: .heavy, design: .rounded))
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk)
                            Text("Native macOS workspace").font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Custom panes

private struct MacSpaceSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var archive = false
    @State private var deleting = false
    @State private var busy = false
    var body: some View {
        MacSettingsScroll {
            if let space = environment.activeSpace {
                MacSettingsCard {
                    HStack(spacing: 14) {
                        SpaceImage(space: space, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(space.title).font(.system(size: 15, weight: .bold, design: .rounded))
                            if let description = space.spaceDescription, !description.isEmpty {
                                Text(description).font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    MacSettingsRow(label: "Documents", value: environment.overview.all.count.formatted())
                    Button("Edit Name, Description & Image") { environment.spaceSheet = .edit(space) }.buttonStyle(MacSettingsButtonStyle())
                }
                Text("Danger Zone").font(.system(size: 13, weight: .heavy, design: .rounded)).padding(.top, 12)
                Button("Archive Space") { archive = true }
                Button("Delete Space and All Contents", role: .destructive) { deleting = true }
            }
            Button("New Space", action: environment.createSpace).buttonStyle(MacSettingsButtonStyle())
        }.disabled(busy)
            .macConfirmationDialog("Archive this Space?", isPresented: $archive, titleVisibility: .visible) {
                Button("Archive Space") { perform { try await environment.archiveSpace($0, archived: true) } }
            } message: { Text("Its contents are preserved and can be restored from My Spaces.") }
            .macConfirmationDialog("Permanently delete this Space and all its content?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Space and All Contents", role: .destructive) { perform { try await environment.deleteSpace($0) } }
            } message: { Text("Documents, folders, templates, attachments and history in this Space will be permanently removed. This cannot be undone.") }
    }
    private func perform(_ action: @escaping (String) async throws -> Void) {
        guard let id = environment.selectedSpaceID, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(id) } catch { environment.report(error) }
        }
    }
}

private struct MacAppearanceSettings: View {
    @ObservedObject private var store = PennedMacAppearanceStore.shared
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                Text("Theme").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk)
                ForEach(PennedAppearancePreference.allCases) { option in
                    Button { store.preference = option } label: {
                        HStack {
                            Text(option.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(VellixSurface.ink)
                            Spacer()
                            if store.preference == option { LibraryIcon(name: "checkwavy", size: 16).foregroundStyle(VellixSurface.violet) }
                        }.padding(.vertical, 9).padding(.horizontal, 10).contentShape(Rectangle())
                            .background(store.preference == option ? VellixSurface.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            Text("Reminder Sounds").font(.system(size: 12, weight: .heavy, design: .rounded))
            Text("Task reminders use the sound and alert preferences configured for Penned in macOS.")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(VellixSurface.secondaryInk)
            Button("Open macOS Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
        }.accessibilityIdentifier("mac-appearance-preference")
    }
}

// MARK: - Shared settings styling

struct MacSettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 26).padding(.bottom, 26).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct MacSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(VellixSurface.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VellixSurface.hairline))
    }
}

struct MacSettingsRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(VellixSurface.secondaryInk)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(VellixSurface.ink)
        }.font(.system(size: 13, design: .rounded))
    }
}

struct MacSettingsButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(destructive ? Color.red : VellixSurface.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(VellixSurface.input, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
