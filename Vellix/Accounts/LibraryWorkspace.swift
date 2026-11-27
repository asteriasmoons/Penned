import Combine
import Foundation
import CloudKit
import GRDB

@MainActor
final class LibraryWorkspace: ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSwitching = false
    @Published private(set) var syncMessage = ""
    @Published private(set) var syncEnabled = false
    @Published private(set) var pendingChanges = 0
    @Published private(set) var pendingDownloads = 0
    @Published private(set) var recoveryCount = 0
    @Published private(set) var syncNeedsRetry = false
    @Published private(set) var cloudZoneRemoved = false
    private var root: AppDatabase?
    private var openingDatabase: Task<AppDatabase, Error>?
    private var store: AttachmentStore?
    private var request = UUID()
    private var transition: Task<Void, Never>?
    private var synchronizer: LibrarySyncEngine?
    private let railwayRuntime = RailwayWorkspaceRuntime()
    @Published private(set) var migrationInProgress=false
    var canPrepareRailwayMigration:Bool {
        guard !usesLocalLibrary,let environment,environment.database.isAccessible,
              !environment.database.isInMemory,identity?.libraryOwnerKey==currentOwner(),
              currentOwner() != nil,!migrationInProgress else{return false}
        return syncRoute == .legacy || ((try? RailwayMigrationFence.held(database:environment.database)) == true)
    }

    weak var railwayAccount: RailwayNativeAccountBinding?
    var syncRoute: RailwayWorkspaceRoute {
        RailwayWorkspaceRoute.read(environment?.database,ownerKey:currentOwner())
    }
    var syncProviderTitle: String {
        switch syncRoute {
        case .railway: "Penned Cloud Sync"
        case .blocked: "Sync Unavailable"
        default: "iCloud Sync"
        }
    }
    private func reportRailway(_ status:RailwayWorkspaceStatus) {
        if syncEnabled != status.enabled {syncEnabled=status.enabled}
        if pendingChanges != status.pending {pendingChanges=status.pending}
        if pendingDownloads != status.downloads {pendingDownloads=status.downloads}
        if recoveryCount != status.recovery {recoveryCount=status.recovery}
        if syncNeedsRetry != status.needsRetry {syncNeedsRetry=status.needsRetry}
        if cloudZoneRemoved {cloudZoneRemoved=false}
        if syncMessage != status.message {syncMessage=status.message}
    }

    private var syncControl: UUID?
    private var syncEnable: Task<Void, Error>?
    private let preferences: UserDefaults
    private let defersStartupServices: Bool
    private var startedServicesFor: UUID?
    private var syncStatusRevision = 0
    var currentOwner: () -> String? = { nil }
    private(set) var identity: AccountIdentity?

    init(database: AppDatabase? = nil, attachmentStore: AttachmentStore? = nil, preferences: UserDefaults = .standard,
         defersStartupServices: Bool = false) {
        root = database; store = attachmentStore; self.preferences = preferences
        self.defersStartupServices = defersStartupServices
    }

    var usesLocalLibrary: Bool { environment?.database.libraryID == LibraryRecord.localID }
    var libraries: LibraryRepository? { root.map(LibraryRepository.init(database:)) }
    var localSpaces: [SpaceRecord] {
        guard let root else { return [] }
        return (try? SpaceRepository(database: root.scoped(to: LibraryRecord.localID)).includingArchived()) ?? []
    }

    func matches(_ identity: AccountIdentity?) -> Bool {
        self.identity == identity && environment?.database.isAccessible == true && errorMessage == nil && !isSwitching
    }

    // Opening and migrating the device-local file does not grant access to any
    // account library. It can overlap credential validation, but scoping cannot.
    func prepareDatabase() {
        guard root == nil, openingDatabase == nil else { return }
        openingDatabase = Task {
            let started = PennedDiagnostics.markStartup("document-store.start")
            do {
                let database = try await AppDatabase.openSharedInBackground()
                PennedDiagnostics.markStartup("document-store.ready", since: started)
                return database
            } catch {
                PennedDiagnostics.markStartup("document-store.failed", since: started)
                throw error
            }
        }
    }

    func activate(_ identity: AccountIdentity?, local: Bool? = nil, force: Bool = false, assigningLocalLibrary: Bool = true) async {
        let token = UUID(); request = token
        isSwitching = true
        let previous = transition
        let work = Task { [weak self] in
            await previous?.value
            guard let self, self.request == token else { return }
            await self.open(identity, local: local, force: force, assigningLocalLibrary: assigningLocalLibrary, token: token)
        }
        transition = work
        await work.value
    }

    private func open(_ identity: AccountIdentity?, local: Bool?, force: Bool, assigningLocalLibrary: Bool, token: UUID) async {
        defer { if request == token { isSwitching = false } }
        do {
            await stopSync()
            if root == nil {
                prepareDatabase()
                guard let openingDatabase else { throw LibraryError.unavailable }
                defer { self.openingDatabase = nil }
                root = try await openingDatabase.value
            }
            guard request == token else { return }
            if store == nil {
                store = root?.isInMemory == true
                    ? AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
                    : try AttachmentStore.liveStore()
            }
            guard let root, let store else { throw LibraryError.unavailable }
            let key = "penned.localLibrary.\(identity.map { LibraryRecord.accountID(ownerKey: $0.libraryOwnerKey) } ?? "local")"
            let savedLocalChoice = preferences.object(forKey: key) as? Bool
            let useLocal = identity == nil || (local ?? savedLocalChoice ?? false)
            let libraries = LibraryRepository(database: root)
            let libraryID = useLocal ? LibraryRecord.localID : identity.map { LibraryRecord.accountID(ownerKey: $0.libraryOwnerKey) } ?? LibraryRecord.localID
            let targetRoute = RailwayWorkspaceRoute.read(root.scoped(to:libraryID),ownerKey:identity?.libraryOwnerKey)
            let claimLocalContent: Bool
            if assigningLocalLibrary && !useLocal && targetRoute == .legacy {
                claimLocalContent = try await Task.detached(priority: .userInitiated) {
                    try libraries.hasUnownedLocalContent()
                }.value
            } else {
                claimLocalContent = false
            }
            guard request == token else { return }
            PennedSyncTrace.record("workspace.open",
                "library=\(PennedSyncTrace.token(libraryID)) local=\(useLocal) force=\(force) claimLocal=\(claimLocalContent)")
            if force || environment?.database.libraryID != libraryID || environment?.database.isAccessible != true || claimLocalContent {
                let localSelection = environment?.database.libraryID == LibraryRecord.localID
                    ? environment?.selectedSpaceID : preferences.string(forKey: "penned.activeSpaceID")
                if let environment, environment.database.isAccessible { try await environment.closeLibrary() }
                guard request == token else { return }
                if !useLocal, let identity {
                    guard currentOwner() == identity.libraryOwnerKey else { throw LibraryError.wrongOwner }
                    if claimLocalContent {
                        let claimed = try libraries.claimLocalLibrary(ownerKey: identity.libraryOwnerKey, preferredSpaceID: localSelection)
                        if let selected = claimed.selectedSpaceID {
                            preferences.set(selected, forKey: "penned.activeSpaceID.\(libraryID)")
                        }
                    } else { try libraries.accountLibrary(ownerKey: identity.libraryOwnerKey) }
                }
                let database = root.scoped(to: libraryID)
                let preferred = preferences.string(forKey: useLocal ? "penned.activeSpaceID" : "penned.activeSpaceID.\(libraryID)")
                let started = PennedDiagnostics.markStartup("library-overview.start")
                let initial = try await Task.detached(priority: .userInitiated) {
                    try AppEnvironment.loadBootstrapState(database: database, preferredSpaceID: preferred, createsDefaultSpace: useLocal)
                }.value
                PennedDiagnostics.markStartup("library-overview.ready", since: started)
                guard request == token else { database.invalidate(); return }
                var primed: DocumentPreviewCache.PrimedPreviews?
                if defersStartupServices, !database.isInMemory {
                    let recent = preferences.object(forKey: "library.showPreviewStrip") as? Bool ?? true
                    let starred = preferences.object(forKey: "library.showStarred") as? Bool ?? true
                    let ids = (recent ? Array(initial.overview.recent.prefix(4)) : [])
                        + (starred ? Array(initial.overview.favorites.prefix(2)) : [])
                    if !ids.isEmpty {
                        let previewStart = PennedDiagnostics.markStartup("home-previews.start")
                        primed = await DocumentPreviewCache.readInitialPreviews(ids.map(\.id))
                        PennedDiagnostics.markStartup("home-previews.ready", since: previewStart)
                    }
                }
                guard request == token else { database.invalidate(); return }
                if !useLocal, let identity, currentOwner() != identity.libraryOwnerKey {
                    database.invalidate()
                    throw LibraryError.wrongOwner
                }
                let envStart = PennedDiagnostics.markStartup("env-init.start")
                let next = AppEnvironment(database: database, attachmentStore: store, preferences: preferences,
                                          createsDefaultSpace: useLocal, initialState: initial)
                PennedDiagnostics.markStartup("env-init.ready", since: envStart)
                if let primed {
                    let installStart = PennedDiagnostics.markStartup("install-previews.start")
                    next.documentPreviews.installInitialPreviews(primed)
                    PennedDiagnostics.markStartup("install-previews.ready", since: installStart)
                }
                environment = next
                PennedDiagnostics.markStartup("env-assigned", since: envStart)
            }
            guard request == token else { return }
            self.identity = identity
            if local != nil { preferences.set(useLocal, forKey: key) }
            errorMessage = nil
            if !defersStartupServices {
                Task { [weak self] in
                    guard let self, self.request == token else { return }
                    await self.startOpenedLibraryServices()
                }
            }
        } catch {
            if request == token {
                PennedDiagnostics.markStartup("workspace.failed")
                errorMessage = error.localizedDescription
            }
        }
    }

    func startOpenedLibraryServices() async {
        guard !isSwitching, errorMessage == nil, let environment, environment.database.isAccessible,
              startedServicesFor != request else { return }
        let token = request
        startedServicesFor = token
        // Reminders and descriptors are independent of CloudKit availability.
        environment.taskNotifications.refreshAfterOpening()
        environment.startDescriptorBackfill()
        if syncRoute != .legacy {
            await startSync()
            return
        }
        let statusIsCurrent = await refreshSyncStatusAfterOpening(token: token)
        guard request == token else { return }
        if statusIsCurrent {
            await autoActivateSync(identity: identity, token: token)
        } else {
            // A newer status/explicit sync action takes precedence over the
            // background snapshot. Never auto-enable from that old snapshot.
            await startSync()
        }
    }

    func adopt(spaceIDs: Set<String>, includeSavedStyles: Bool, identity: AccountIdentity) async throws {
        guard !migrationInProgress else{throw RailwayError.staleCheckpoint}
        guard syncRoute == .legacy || syncRoute == .local else { throw RailwayError.releaseDisabled }
        guard self.identity == identity, currentOwner() == identity.libraryOwnerKey, !isSwitching, let root else { throw LibraryError.wrongOwner }
        guard RailwayWorkspaceRoute.read(root.scoped(to:LibraryRecord.accountID(ownerKey:identity.libraryOwnerKey)),ownerKey:identity.libraryOwnerKey) == .legacy else {throw RailwayError.releaseDisabled}
        let token = request
        isSwitching = true
        defer { if request == token { isSwitching = false } }
        await stopSync()
        guard request == token, currentOwner() == identity.libraryOwnerKey else { throw LibraryError.staleWorkspace }
        if let environment { try await environment.closeLibrary() }
        guard request == token, currentOwner() == identity.libraryOwnerKey else { throw LibraryError.staleWorkspace }
        do {
            let libraries = LibraryRepository(database: root)
            let target = try libraries.accountLibrary(ownerKey: identity.libraryOwnerKey)
            try libraries.adopt(spaceIDs: spaceIDs, into: target.id, ownerKey: identity.libraryOwnerKey,
                                includeSavedStyles: includeSavedStyles, confirmed: true)
        } catch {
            await activate(identity, force: true, assigningLocalLibrary: false)
            throw error
        }
        await activate(identity, local: false, force: true, assigningLocalLibrary: false)
    }

    private func syncStore() throws -> LibrarySyncStore {
        guard syncRoute == .legacy else { throw RailwayError.releaseDisabled }
        guard let root, let identity, currentOwner() == identity.libraryOwnerKey,
              let library = try libraries?.library(id: LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)),
              let cloud = library.cloudAccountID else { throw LibraryError.syncDisabled }
        return LibrarySyncStore(database: root, libraryID: library.id, ownerKey: identity.libraryOwnerKey, cloudAccountID: cloud)
    }

    private struct SyncStatus: Sendable {
        var enabled = false
        var changes = 0
        var downloads = 0
        var revisions = 0
        var paused: String?
    }

    private nonisolated static func loadSyncStatus(_ root: AppDatabase, libraryID id: String) throws -> SyncStatus {
        try root.read { db in
            try SyncStatus(
                enabled: LibraryRecord.fetchOne(db, key: id)?.syncEnabled == true,
                changes: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncItems WHERE libraryID=? AND dirty=1", arguments: [id]) ?? 0,
                downloads: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncInbox WHERE libraryID=?", arguments: [id]) ?? 0,
                revisions: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncConflicts WHERE libraryID=?", arguments: [id]) ?? 0,
                paused: String.fetchOne(db, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [id])
            )
        }
    }

    private func applySyncStatus(_ status: SyncStatus) {
        if syncEnabled != status.enabled { syncEnabled = status.enabled }
        if pendingChanges != status.changes { pendingChanges = status.changes }
        if pendingDownloads != status.downloads { pendingDownloads = status.downloads }
        if recoveryCount != status.revisions { recoveryCount = status.revisions }
        let needsRetry = status.paused != nil
        let zoneRemoved = status.paused == LibrarySyncError.zoneRemoved.localizedDescription
        if syncNeedsRetry != needsRetry { syncNeedsRetry = needsRetry }
        if cloudZoneRemoved != zoneRemoved { cloudZoneRemoved = zoneRemoved }
    }

    func refreshSyncStatus() {
        if syncRoute == .railway || syncRoute == .blocked {
            let token=request
            if syncRoute == .blocked {reportRailway(.init(message:"Migration verification required. Neither cloud provider will start."));return}
            Task { [weak self] in
                guard let self else{return}
                let status=await self.railwayRuntime.status()
                guard self.request==token,self.syncRoute == .railway else{return}
                self.reportRailway(status)
            }
            return
        }
        syncStatusRevision &+= 1
        guard let root, let identity else { applySyncStatus(SyncStatus()); syncMessage = ""; return }
        do { applySyncStatus(try Self.loadSyncStatus(root, libraryID: LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey))) }
        catch { syncMessage = error.localizedDescription }
    }

    private func refreshSyncStatusAfterOpening(token: UUID) async -> Bool {
        guard let root, let identity else { refreshSyncStatus(); return true }
        let id = LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)
        let revision = syncStatusRevision
        do {
            let status = try await Task.detached(priority: .utility) { try Self.loadSyncStatus(root, libraryID: id) }.value
            guard request == token, syncStatusRevision == revision else { return false }
            applySyncStatus(status)
            return true
        } catch {
            if request == token, syncStatusRevision == revision { syncMessage = error.localizedDescription }
            return false
        }
    }

    /// Signed in means synced. On the account library we switch iCloud sync on
    /// automatically when it isn't already, so no one has to tap "Enable" or
    /// "Retry" — sync is supposed to be automatic. Local-only libraries and the
    /// removed-cloud-zone case (which needs an explicit restore) are left alone.
    private func autoActivateSync(identity: AccountIdentity?, token: UUID) async {
        guard request == token, syncRoute == .legacy else { return }
        PennedSyncTrace.record("workspace.autoActivateSync", "local=\(usesLocalLibrary) enabled=\(syncEnabled) needsRetry=\(syncNeedsRetry)")
        if let identity, !usesLocalLibrary, !syncEnabled {
            // enableSync seeds the library, flips the flag, and starts the engine.
            try? await enableSync(identity: identity)
        } else {
            await startSync()
        }
    }

    private func startSync(migrationPreparation:Bool=false) async {
        guard !isSwitching,syncControl==nil,(!migrationInProgress || migrationPreparation) else{return}
        let route=syncRoute
        if route != .legacy {
            if let old=synchronizer{await old.stop();if synchronizer === old{synchronizer=nil}}
            guard route == .railway,let environment,let store,let owner=identity?.libraryOwnerKey,let railwayAccount,
                  root?.isInMemory == false else{
                if route == .blocked {reportRailway(.init(message:"Migration verification required. Neither cloud provider will start."))}
                else if route == .railway {reportRailway(.init())}
                return
            }
            let token=request
            do{
                let editors=Publishers.Merge(environment.$selectedDocumentID.removeDuplicates().dropFirst().map{_ in ()},
                    environment.$isSwitchingSpace.removeDuplicates().dropFirst().filter{!$0}.map{_ in ()}).eraseToAnyPublisher()
                try await railwayRuntime.start(database:environment.database,ownerKey:owner,attachments:store,binding:railwayAccount,
                    editorChanges:editors,isCurrent:{[weak self,weak environment] in
                        guard let self,let environment else{return false}
                        return self.request==token && self.environment === environment && environment.database.isAccessible && self.currentOwner()==owner && self.syncRoute == .railway
                    },importer:{[weak self,weak environment] apply in
                        guard let self,let environment,self.request==token,self.currentOwner()==owner else{throw LibraryError.staleWorkspace}
                        return try await environment.importAutomaticLibraryChanges(apply)
                    },report:{[weak self] status in
                        guard let self,self.request==token,self.currentOwner()==owner else{return}
                        self.reportRailway(status)
                    })
            }catch is CancellationError{}catch{
                if request==token {reportRailway(.init(needsRetry:true,message:"Cloud sync is unavailable. Local edits remain saved."))}
            }
            return
        }
        await railwayRuntime.stop()
        guard syncRoute == .legacy else{return}
        guard !isSwitching, syncControl == nil, syncEnable == nil, root?.isInMemory == false, synchronizer == nil,
              !usesLocalLibrary, syncEnabled, let environment, let store else { return }
        let owner = identity?.libraryOwnerKey
        do {
            let storage = try syncStore()
            let editorChanged = Publishers.Merge(
                environment.$selectedDocumentID.removeDuplicates().dropFirst().map { _ in () },
                environment.$isSwitchingSpace.removeDuplicates().dropFirst().filter { !$0 }.map { _ in () }
            )
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
            let sync = LibrarySyncEngine(store: storage, attachments: store,
                currentOwner: { [weak self] in
                    guard self?.environment?.database.libraryID == storage.libraryID else { return nil }
                    return self?.currentOwner()
                }, resumeImportsOn: editorChanged, importChanges: { [weak environment] apply in
                    guard let environment else { throw LibraryError.staleWorkspace }
                    return try await environment.importAutomaticLibraryChanges(apply)
                }, report: { [weak self] message in
                    guard let self, self.currentOwner() == storage.ownerKey,
                          self.environment?.database.libraryID == storage.libraryID else { return }
                    if self.syncMessage != message { self.syncMessage = message }
                    if message != "Syncing library with iCloud" {
                        self.refreshSyncStatus()
                    }
                })
            synchronizer = sync
            do {
                syncMessage = "Connecting to iCloud"
                try await sync.start()
            } catch {
                await sync.stop()
                if synchronizer === sync { synchronizer = nil; throw error }
            }
        } catch {
            if self.environment === environment, currentOwner() == owner { syncMessage = error.localizedDescription }
        }
    }

    func enableSync(identity: AccountIdentity) async throws {
        guard !migrationInProgress else{throw RailwayError.staleCheckpoint}
        if syncRoute == .railway {
            guard self.identity==identity,currentOwner()==identity.libraryOwnerKey else{throw LibraryError.wrongOwner}
            await startSync()
            try await railwayRuntime.resume()
            refreshSyncStatus()
            return
        }
        guard syncRoute == .legacy else{throw RailwayError.releaseDisabled}
        guard !isSwitching, syncControl == nil, syncEnable == nil, self.identity == identity,
              currentOwner() == identity.libraryOwnerKey, !usesLocalLibrary,
              let root else { throw LibraryError.wrongOwner }
        let token = request
        let cloud = try await AccountCloudStore().accountID()
        guard request == token, !isSwitching, syncControl == nil, syncEnable == nil,
              self.identity == identity, currentOwner() == identity.libraryOwnerKey else { throw LibraryError.wrongOwner }
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: identity.libraryOwnerKey)
        let store = LibrarySyncStore(database: root, libraryID: library.id, ownerKey: identity.libraryOwnerKey, cloudAccountID: cloud)
        let work = Task.detached(priority: .utility) { try store.enable(confirmed: true) }
        syncEnable = work
        do {
            defer { syncEnable = nil }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        guard request == token, !isSwitching, syncControl == nil,
              currentOwner() == identity.libraryOwnerKey else { throw LibraryError.staleWorkspace }
        if !syncEnabled { syncEnabled = true }
        _ = await refreshSyncStatusAfterOpening(token: token)
        await startSync()
    }

    func pauseSync() async throws {
        guard !migrationInProgress else{throw RailwayError.staleCheckpoint}
        if syncRoute == .railway {
            try await railwayRuntime.pause()
            refreshSyncStatus()
            return
        }
        guard syncRoute == .legacy else{throw RailwayError.releaseDisabled}
        try await withStoppedSync { try syncStore().disable() }
        refreshSyncStatus()
        syncMessage = "Sync paused. Your library and queued edits remain on this device."
    }

    func cloudSessionChanged(_ libraryID:String?) async {
        guard let environment,!isSwitching,environment.database.isAccessible,
              let owner=currentOwner(),environment.database.libraryID==RailwayAccountSession.libraryID(ownerKey:owner) else{return}
        if syncRoute == .railway {
            await railwayRuntime.stop()
            if libraryID==environment.database.libraryID{await startSync()}
        }else if libraryID==environment.database.libraryID{
            await prepareAutomaticCloudMigration()
        }
    }

    private func prepareAutomaticCloudMigration()async{
        guard let environment,let owner=currentOwner(),canPrepareRailwayMigration,
              PennedCloudRollout.shouldMigrate(enabled:PennedCloudRollout.automaticMigrationEnabled,
                accountReady:railwayAccount?.connectedLibraryID==environment.database.libraryID,
                legacy:syncRoute == .legacy,
                fenced:(try? RailwayMigrationFence.held(database:environment.database)) == true,
                hasEditor:!environment.librarySyncProtection().isEmpty),
              owner==identity?.libraryOwnerKey else{return}
        do{try await migrateToRailway(confirmed:true)}catch{/* Retry on subsequent safe lifecycle events. */}
    }

    func synchronize(retry: Bool = false, restoreCloud: Bool = false) async {
        guard !migrationInProgress else{return}
        await prepareAutomaticCloudMigration()
        if syncRoute == .railway {
            guard !isSwitching,syncControl==nil,!restoreCloud else{return}
            let token=request
            await startSync()
            guard request==token,syncRoute == .railway else{return}
            do{try await railwayRuntime.synchronize(retry:retry)}catch{syncNeedsRetry=true}
            refreshSyncStatus()
            return
        }
        guard syncRoute == .legacy else{return}
        guard !isSwitching, retry || syncControl == nil else { return }
        let token = request
        do {
            if retry {
                try await withStoppedSync { try syncStore().prepareRetry(restoringRemovedZone: restoreCloud) }
            }
            if synchronizer == nil { await startSync() }
            guard request == token, syncControl == nil else { return }
            try await synchronizer?.synchronize()
            if request == token { refreshSyncStatus() }
        } catch is CancellationError {
            return
        } catch {
            if request == token { syncMessage = error.localizedDescription }
        }
    }

    func cloudIdentityChanged() async {
        guard !migrationInProgress else{return}
        guard syncRoute == .legacy else{return}
        do { try await withStoppedSync {} } catch { return }
        await startSync()
    }

    // Development-only cutover entrypoint until the full native migration and
    // physical-device suite has passed. Never triggered by normal app launch.
    private func migrateToRailway(confirmed:Bool) async throws {
        guard PennedCloudRollout.automaticMigrationEnabled,confirmed,canPrepareRailwayMigration,!isSwitching,syncControl==nil,
              let environment,let store,let owner=identity?.libraryOwnerKey,
              let railwayAccount else{throw RailwayError.migrationConfirmationRequired}
        let database=environment.database,token=request
        migrationInProgress=true
        let current: @MainActor ()throws->Void = { [weak self,weak environment] in
            guard let self,let environment,self.request==token,self.environment === environment,
                  database.isAccessible,self.currentOwner()==owner else{throw LibraryError.staleWorkspace}
        }
        do {
            let account=try railwayAccount.client()
            guard let session=try await railwayAccount.restore(),session.ownerKey==owner else{throw RailwayError.signedOut}
            _ = try await railwayAccount.verify(account,ownerKey:owner)
            try current()
            _ = try await railwayAccount.bind(to:database)
            try current()
            let log=try RailwayMigrationLogStore(database:database,libraryID:database.libraryID)
            let transport=try RailwayTransport(baseURL:URL(string:"https://api.penned.im")!)
            let storage=try database.railwayCaptureStorage()
            let stage=storage.staging.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Migration",isDirectory:true).appendingPathComponent(database.libraryID,isDirectory:true)
            let source=RailwayLegacyMigrationAdapter(reader:RailwayLegacyCapture(database:database,attachments:store),attachments:store,staging:stage,
                freeze:{ [weak self,weak environment] id in
                    guard let self,let environment else{throw LibraryError.staleWorkspace}
                    try await self.prepareRailwayFence(database:database,environment:environment,owner:owner,id:id,current:current)
                },activate:{receipt in
                    try await current()
                    guard receipt.libraryID==database.libraryID else{throw RailwayError.accountMismatch}
                },unfreeze:{})
            let destination=RailwayMigrationHTTPDestination(account:account,transport:transport,stagingDirectory:stage.appendingPathComponent("multipart",isDirectory:true))
            let coordinator=RailwayMigrationCoordinator(log:log,source:source,destination:destination)
            try await coordinator.confirm(ownerKey:owner,confirmed:true)
            syncMessage="Preparing your cloud library upgrade…"
            _ = try await coordinator.migrate()
            try current()
            try? FileManager.default.removeItem(at:stage)
            syncMessage="Library upgrade verified. Starting Penned Cloud Sync."
            migrationInProgress=false
            refreshSyncStatus()
            await startSync()
        }catch{
            migrationInProgress=false
            if request==token,currentOwner()==owner{
                if (try? RailwayMigrationFence.held(database:database)) == true{
                    syncMessage="Your library upgrade is protected. Verification will resume automatically."
                }else{
                    refreshSyncStatus()
                    syncMessage="Migration did not complete. Your library is retained."
                    await startSync()
                }
            }
            throw error
        }
    }

    private func prepareRailwayFence(database:AppDatabase,environment:AppEnvironment,owner:String,id:String,
                                     current: @MainActor ()throws->Void) async throws {
        try current()
        guard id==database.libraryID else{throw RailwayError.accountMismatch}
        if try RailwayMigrationFence.held(database:database){
            guard environment.librarySyncProtection().isEmpty else{throw RailwayError.staleCheckpoint}
            await stopSync()
            try current()
            try RailwayMigrationFence.acquire(database:database,ownerKey:owner)
            return
        }
        
        try await environment.prepareForWorkspaceNavigation()
        try current()
        guard environment.librarySyncProtection().isEmpty else{throw RailwayError.staleCheckpoint}
        // If the library ever had a CloudKit binding, its final pass must be
        // successful; a paused/offline or unflushed library cannot be migrated.
        let library=try database.read {try LibraryRecord.fetchOne($0,key:id)}
        if library?.cloudAccountID != nil{
            guard library?.syncEnabled==true else{throw RailwayError.staleCheckpoint}
            refreshSyncStatus()
            await startSync(migrationPreparation:true)
            guard let synchronizer else{throw RailwayError.staleCheckpoint}
            try await synchronizer.flushForRailwayMigration()
        }
        try current()
        
        guard environment.librarySyncProtection().isEmpty else{throw RailwayError.staleCheckpoint}
        await stopSync()
        try current()
        // Serialized with every SQLite writer. Dirty rows/inbox are rechecked
        // here to catch edits or imports since the CloudKit pass.
        try RailwayMigrationFence.acquire(database:database,ownerKey:owner)
        syncMessage="Uploading your protected library to Penned Cloud…"
    }

    private func stopSync() async {
        await railwayRuntime.stop()
        if let syncEnable {
            syncEnable.cancel()
            _ = try? await syncEnable.value
        }
        guard let previous = synchronizer else { return }
        await previous.stop()
        if synchronizer === previous { synchronizer = nil }
    }

    private func withStoppedSync(_ update: () throws -> Void) async throws {
        guard !isSwitching else { throw CancellationError() }
        let control = UUID(), workspace = request
        syncControl = control
        defer { if syncControl == control { syncControl = nil } }
        await stopSync()
        guard syncControl == control, request == workspace, !isSwitching else { throw CancellationError() }
        try update()
    }

    func recoveryRevisions() throws -> [LibrarySyncConflict] { try syncStore().conflicts() }
    /// Restore only one tracked reminder's configuration. Keep the current
    /// document, task text, completion state, and all other blocks untouched.
    func recoverTask(_ revision: LibrarySyncConflict, blockID: String) async throws {
        guard revision.row.table == "documents", !revision.deleted,
              let documentID = revision.row.values["id"]?.text,
              let oldJSON = revision.row.values["tipTapJSON"]?.text,
              let archived = try DocumentTaskIndex.contexts(in: oldJSON)
                .first(where: { $0.blockID == blockID }),
              let metadata = archived.metadata else { throw DocumentTaskError.missingTask }
        let storage = try syncStore()
        guard let environment, environment.database.libraryID == storage.libraryID else {
            throw LibraryError.wrongOwner
        }
        try await environment.importLibraryChanges {
            let document = try environment.documents.requireDocument(id: documentID)
            // The current task may have lost its trackedTask attribute entirely.
            // Locate the checklist block itself, not only indexed tracked tasks.
            func findTask(_ node: [String: Any]) -> [String: Any]? {
                let attrs = node["attrs"] as? [String: Any] ?? [:]
                if node["type"] as? String == "taskItem", attrs["id"] as? String == blockID {
                    return attrs
                }
                for child in node["content"] as? [[String: Any]] ?? [] {
                    if let match = findTask(child) { return match }
                }
                return nil
            }
            guard let currentAttrs = findTask(TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)) else {
                throw DocumentTaskError.missingTask
            }
            let currentMetadata = DocumentTaskMetadata.decode(currentAttrs["trackedTask"])
            // Reapply configuration only; preserve current identity and history.
            var restored = currentMetadata ?? metadata
            restored.scheduledAt = metadata.scheduledAt
            restored.reminderEnabled = metadata.reminderEnabled
            restored.recurrence = metadata.recurrence
            let updated = try DocumentTaskIndex.updating(document.tipTapJSON, blockID: blockID,
                                                         metadata: restored, checked: currentAttrs["checked"] as? Bool ?? false)
            _ = try environment.documents.saveEditorJSON(id: documentID, canonicalJSON: updated)
            return [documentID]
        }
        refreshSyncStatus()
    }

    func recover(_ revision: LibrarySyncConflict) async throws {
        let storage = try syncStore()
        guard let environment, environment.database.libraryID == storage.libraryID else { throw LibraryError.wrongOwner }
        try await environment.importLibraryChanges { try storage.recover(conflictID: revision.id); return [] }
        refreshSyncStatus()
    }
}
