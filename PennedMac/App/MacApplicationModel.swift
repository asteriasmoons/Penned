import AppKit
import AuthenticationServices
import CloudKit
import Combine
import SwiftUI

@MainActor final class MacApplicationModel: ObservableObject {
    let accounts: AppState
    let library: LibraryWorkspace
    let windows = MacWindowRegistry()
    let verificationMode: Bool
    @Published var startupError: String?
    private var activation: Task<Void, Never>?
    private var activatedKey: String?

    init() {
        verificationMode = CommandLine.arguments.contains("--penned-mac-ui-test")
        if verificationMode {
            do {
                accounts = AppState(container: try AccountPersistence.makeContainer(inMemory: true))
                let database = try AppDatabase.makeInMemory()
                let store = AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("PennedMacVerification-" + UUID().uuidString))
                let seed = AppEnvironment(database: database.scoped(to: LibraryRecord.localID), attachmentStore: store)
                try seed.bootstrap(seedSampleData: true)
                try MacVerificationFixtures.populate(seed)
                let preferences = UserDefaults(suiteName: "PennedMacVerification." + UUID().uuidString)!
                preferences.set(seed.selectedSpaceID, forKey: "penned.activeSpaceID")
                library = LibraryWorkspace(database: database, attachmentStore: store,
                    preferences: preferences)
            } catch { fatalError("Temporary Mac verification library could not open: \(error)") }
        } else { accounts = AppState(); library = LibraryWorkspace() }
        library.currentOwner = { [weak accounts] in
            accounts?.currentUser?.remoteAuthDeleted == false ? accounts?.currentAccountIdentity?.libraryOwnerKey : nil
        }
        library.beforeLibraryChange = { [weak self] in try await self?.windows.closeLibraries() }
        library.importIntoWindows = { [weak self] apply, root in
            guard let self else { throw LibraryError.staleWorkspace }
            try await self.windows.importChanges(apply, root: root)
        }
        MacApplicationDelegate.application = self
        PennedSyncNotifications.synchronize = { [weak self] in await self?.library.synchronize() }
    }

    var activationKey: String {
        if verificationMode { return "verification" }
        if case .checking = accounts.status { return "checking" }
        return accounts.currentAccountIdentity?.libraryOwnerKey ?? "signed-out"
    }
    func activate() async {
        let key = activationKey
        guard key != "checking" else { return }
        if activatedKey == key { await activation?.value; return }
        activatedKey = key
        activation = Task { [weak self] in
            guard let self else { return }
            await self.library.activate(self.verificationMode ? nil : self.accounts.currentAccountIdentity)
        }
        await activation?.value
    }
    func prepareAccountChange() async throws { try await windows.flushAll() }
    func foreground() {
        guard !verificationMode else { return }
        accounts.bootstrap(force: true)
        for workspace in windows.workspaces {
            workspace.environment.calendar.refresh()
            workspace.tabs.forEach { $0.calendar?.refresh() }
            workspace.environment.taskNotifications.refresh()
        }
        Task { await library.synchronize() }
    }
}

@MainActor final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var application: MacApplicationModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !CommandLine.arguments.contains("--penned-mac-ui-test") { NSApp.registerForRemoteNotifications() }
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await Self.application?.library.synchronize() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            do { try await Self.application?.windows.flushAll(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                terminating = false
                let alert = NSAlert(); alert.messageText = "Your edits could not be saved"
                alert.informativeText = error.localizedDescription; alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

struct MacLibraryWindowRoot: View {
    @EnvironmentObject private var app: MacApplicationModel
    @EnvironmentObject private var accounts: AppState
    @EnvironmentObject private var library: LibraryWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("penned.mac.sceneID") private var sceneID = UUID().uuidString
    @State private var pendingDocumentLink: URL?
    var body: some View {
        Group {
            if library.matches(app.verificationMode ? nil : accounts.currentAccountIdentity), let environment = library.environment {
                MacWorkspaceEntry(parent: environment, sceneID: sceneID, app: app, pendingDocumentLink: $pendingDocumentLink)
                    .id(String(describing: ObjectIdentifier(environment)) + (accounts.currentAccountIdentity?.libraryOwnerKey ?? "local"))
            } else if let error = library.errorMessage {
                VStack(spacing: 16) {
                    Text("Library Unavailable").font(.title2.bold())
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Retry") { Task { await library.activate(accounts.currentAccountIdentity, force: true) } }
                    if let previous = library.identity, let account = accounts.savedAccounts.first(where: { $0.identity == previous }) {
                        Button("Return to Previous Account") { Task { try? await accounts.activate(account) } }
                    }
                }.padding(40)
            } else { ProgressView("Opening library").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 980, minHeight: 650).background(VellixSurface.appBackground)
        .background(MacWindowAppearance().frame(width: 0, height: 0))
        .fontDesign(.rounded).foregroundStyle(VellixSurface.ink).tint(VellixSurface.violet)
        .task { if !app.verificationMode { await accounts.bootstrap()?.value }; await app.activate() }
        .task(id: app.activationKey) { await app.activate() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { app.foreground() } }
        .onOpenURL { url in if url.scheme?.lowercased() == "penned" { pendingDocumentLink = url } }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await accounts.handleAppleCredentialRevoked() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            accounts.refreshProfile(); Task { await library.cloudIdentityChanged() }
        }
    }
}

private struct MacWorkspaceEntry: View {
    @StateObject private var workspace: MacWorkspaceModel
    @Binding private var pendingDocumentLink: URL?
    let app: MacApplicationModel
    init(parent: AppEnvironment, sceneID: String, app: MacApplicationModel, pendingDocumentLink: Binding<URL?>) {
        self.app = app
        _pendingDocumentLink = pendingDocumentLink
        let owner = app.accounts.currentAccountIdentity?.libraryOwnerKey
        if let retained = app.windows.existing(sceneID, libraryID: parent.database.libraryID, ownerKey: owner) {
            _workspace = StateObject(wrappedValue: retained)
        } else {
            let preferences = UserDefaults(suiteName: "penned.mac.window." + sceneID) ?? .standard
            let spaceKey = parent.database.libraryID == LibraryRecord.localID ? "penned.activeSpaceID" : "penned.activeSpaceID." + parent.database.libraryID
            if preferences.string(forKey: spaceKey).flatMap({ try? parent.spaces.space(id: $0) }) == nil {
                preferences.set(parent.selectedSpaceID, forKey: spaceKey)
            }
            let environment = AppEnvironment(database: parent.database.scoped(to: parent.database.libraryID),
                attachmentStore: parent.attachmentStore, preferences: preferences, createsDefaultSpace: false)
            try? environment.bootstrap()
            let model = MacWorkspaceModel(environment: environment, ownerKey: owner, sceneID: sceneID, preferences: preferences,
                currentOwner: { [weak accounts = app.accounts] in accounts?.currentAccountIdentity?.libraryOwnerKey })
            app.windows.register(model)
            let previous = environment.editorCache.onDocumentSaved
            environment.editorCache.onDocumentSaved = { [weak app, weak environment] document in
                previous?(document)
                if let environment { environment.refresh(); app?.windows.refreshOthers(except: environment) }
            }
            _workspace = StateObject(wrappedValue: model)
        }
    }
    var body: some View {
        MacWorkspaceView(workspace: workspace).environmentObject(workspace.environment)
            .environmentObject(workspace).focusedSceneObject(workspace)
            .onAppear { workspace.start() }
            .task(id: pendingDocumentLink) {
                guard let url = pendingDocumentLink else { return }
                pendingDocumentLink = nil
                workspace.perform {
                    if let document = try await DocumentInternalLink.resolve(url, environment: workspace.environment, switchSpace: { try await workspace.switchSpace($0) }) {
                        try await workspace.open(document)
                    }
                }
            }
    }
}
