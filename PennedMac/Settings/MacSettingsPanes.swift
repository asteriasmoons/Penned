import AppKit
import SwiftUI
import UserNotifications

struct MacLibrarySettings: View {
    let category: MacSettingsCategory
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var app: MacApplicationModel
    @State private var query = ""
    var body: some View {
        MacSettingsScroll {
            HStack {
                TextField("Search", text: $query)
                if category == .templates { MacIconButton("Create Template", icon: "addwavy", action: environment.createTemplate) }
                if category == .folders { MacIconButton("New Folder", icon: "addwavy") { environment.requestFolderCreation(parentFolderID: nil) } }
            }
            if category == .templates {
                ForEach(environment.overview.templates.filter { matches($0.title) }) { template in
                    if let document = environment.overview.templateDocuments[template.id] {
                        Button {
                            if template.isBuiltIn { environment.createDocument(title: template.title, from: template) }
                            else { open(document) }
                            app.windows.lastActive?.window?.makeKeyAndOrderFront(nil)
                        } label: {
                            HStack(spacing: 14) {
                                LibraryDocumentPreview(document: document, fixedAspectRatio: 0.72, showsStar: false, cornerRadius: 4).frame(width: 40, height: 56)
                                Text(template.title).frame(maxWidth: .infinity, alignment: .leading)
                                LibraryIcon(name: "chevright", size: 12)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            } else if category == .folders {
                ForEach(environment.overview.folders.filter { matches($0.title) }) { folder in
                    HStack(spacing: 12) {
                        LibraryFolderIcon(folder: folder, size: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.title).fontWeight(.semibold)
                            Text(FolderHierarchy(folders: environment.overview.folders).path(to: folder.id).map(\.title).joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Edit") { environment.librarySheet = .folder(FolderEditorRequest(folder: folder, parentFolderID: folder.parentFolderID, spaceID: folder.spaceID)) }
                        Button("Open") { navigate(.folders, folder: folder.id) }
                    }.padding(.vertical, 8).contextMenu { FolderContextMenu(folder: folder) }
                }
                if environment.overview.folders.isEmpty { Text("No folders in this Space").foregroundStyle(.secondary) }
            } else {
                let snapshot = (try? environment.tags.snapshot()) ?? TagBrowserSnapshot()
                ForEach(snapshot.tags.filter { matches($0.name) }) { tag in
                    Button { navigate(.tags, tags: [tag.id]) } label: {
                        HStack(spacing: 12) {
                            LibraryIcon(name: "hashtagwavy", size: 18)
                            Text(tag.name).frame(maxWidth: .infinity, alignment: .leading)
                            Text((snapshot.documentCounts[tag.id] ?? 0).formatted()).foregroundStyle(.secondary)
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if snapshot.tags.isEmpty { Text("No tags in this Space").foregroundStyle(.secondary) }
            }
        }
    }
    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
    private func open(_ document: DocumentRecord) {
        guard let workspace = app.windows.lastActive else { return }
        workspace.perform { try await workspace.open(document); workspace.window?.makeKeyAndOrderFront(nil) }
    }
    private func navigate(_ destination: MacDestination, folder: String? = nil, tags: Set<String> = []) {
        guard let workspace = app.windows.lastActive else { return }
        workspace.perform { try await workspace.navigate(destination, folderID: folder, tags: tags); workspace.window?.makeKeyAndOrderFront(nil) }
    }
}

struct MacStatsSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                MacSettingsRow(label: "Space", value: environment.activeSpace?.title ?? "None")
                MacSettingsRow(label: "Documents", value: environment.overview.all.count.formatted())
                MacSettingsRow(label: "Words", value: environment.overview.all.reduce(0) { $0 + $1.wordCount }.formatted())
                MacSettingsRow(label: "Characters", value: environment.overview.all.reduce(0) { $0 + $1.characterCount }.formatted())
                MacSettingsRow(label: "Folders", value: environment.overview.folders.count.formatted())
                MacSettingsRow(label: "Templates", value: environment.overview.templates.count.formatted())
                MacSettingsRow(label: "Starred", value: environment.overview.favorites.count.formatted())
                MacSettingsRow(label: "Trash", value: environment.overview.trashed.count.formatted())
            }
        }
    }
}

struct MacLanguageSettings: View {
    @State private var language = NSSpellChecker.shared.language()
    @State private var automatic = NSSpellChecker.shared.automaticallyIdentifiesLanguages
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                Toggle("Identify Spelling Language Automatically", isOn: Binding(get: { automatic }, set: { automatic = $0; NSSpellChecker.shared.automaticallyIdentifiesLanguages = $0 }))
                MacOptionPicker("Spelling Language", selection: Binding(get: { language }, set: { value in
                    if NSSpellChecker.shared.setLanguage(value) { language = value }
                }), options: NSSpellChecker.shared.availableLanguages.sorted()) { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.disabled(automatic)
                MacSettingsRow(label: "Application Language", value: Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "en") ?? "English")
                Button("Open macOS Language Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
            }
        }
    }
}

struct MacSecuritySettings: View {
    @EnvironmentObject private var accounts: AppState
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                MacSettingsRow(label: "Sign-In Method", value: accounts.currentUser?.providerName ?? "Not signed in")
                MacSettingsRow(label: "Library Access", value: environment.database.isAccessible ? "Available" : "Closed")
                MacSettingsRow(label: "Library", value: environment.database.libraryID == LibraryRecord.localID ? "On This Mac" : "Account-owned")
                if let email = accounts.currentUser?.authenticationEmail { MacSettingsRow(label: "Sign-In Email", value: email) }
            }
        }
    }
}

struct MacNotificationSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var status = "Checking"
    @State private var feedback: String?
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                MacSettingsRow(label: "Task Reminders", value: status)
                Button("Enable Task Reminder Notifications") {
                    Task { feedback = await environment.taskNotifications.authorizeReminder(); await refresh() }
                }
                Button("Refresh Scheduled Reminders") { Task { await environment.taskNotifications.flush(); feedback = environment.taskNotifications.statusMessage ?? "Reminders refreshed." } }
                Button("Open macOS Notification Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }
        }.task { await refresh() }
    }
    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: status = "Enabled"
        case .denied: status = "Disabled in macOS"
        default: status = "Not requested"
        }
    }
}

struct MacIntegrationSettings: View {
    let showSync: () -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryWorkspace
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                MacSettingsRow(label: "Apple Calendar", value: environment.calendar.access == .allowed ? "Connected" : "Not connected")
                Button("Connect Apple Calendar") { Task { await environment.calendar.requestAccess() } }
                MacSettingsRow(label: "CloudKit", value: library.syncEnabled ? "Enabled" : "Not enabled")
                Button("Library & Sync", action: showSync)
            }
        }
    }
}

struct MacDiagnosticsSettings: View {
    let advanced: Bool
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryWorkspace
    @State private var copied = false
    private var report: String {
        "Penned \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nLibrary accessible: \(environment.database.isAccessible)\nSync enabled: \(library.syncEnabled)\nPending changes: \(library.pendingChanges)\nPending downloads: \(library.pendingDownloads)\nRecovery revisions: \(library.recoveryCount)"
    }
    var body: some View {
        MacSettingsScroll {
            MacSettingsCard {
                MacSettingsRow(label: "Pending Changes", value: library.pendingChanges.formatted())
                MacSettingsRow(label: "Pending Downloads", value: library.pendingDownloads.formatted())
                MacSettingsRow(label: "Recovery Revisions", value: library.recoveryCount.formatted())
                if !library.syncMessage.isEmpty { Text(library.syncMessage).font(.caption).foregroundStyle(.secondary) }
                Button("Refresh Library") { environment.refresh(); library.refreshSyncStatus() }
                Button(copied ? "Diagnostics Copied" : "Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string); copied = true }
                if advanced {
                    Button("Save Pending Edits") { Task { do { try await environment.prepareForWorkspaceNavigation() } catch { environment.report(error) } } }
                }
            }
        }
    }
}
