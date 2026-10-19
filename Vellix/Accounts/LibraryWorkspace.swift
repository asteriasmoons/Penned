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
    private var store: AttachmentStore?
    private var request = UUID()
    private var transition: Task<Void, Never>?
    private var synchronizer: LibrarySyncEngine?
    private let preferences: UserDefaults
    var currentOwner: () -> String? = { nil }
    private(set) var identity: AccountIdentity?

    init(database: AppDatabase? = nil, attachmentStore: AttachmentStore? = nil, preferences: UserDefaults = .standard) {
        root = database; store = attachmentStore; self.preferences = preferences
    }

    var usesLocalLibrary: Bool { environment?.database.libraryID == LibraryRecord.localID }
    var libraries: LibraryRepository? { root.map(LibraryRepository.init(database:)) }
    var localSpaces: [SpaceRecord] {
        guard let root else { return [] }
        return (try? SpaceRepository(database: root.scoped(to: LibraryRecord.localID)).includingArchived()) ?? []
    }

    func matches(_ identity: AccountIdentity?) -> Bool {
        self.identity == identity && environment != nil && errorMessage == nil && !isSwitching
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
            await synchronizer?.stop(); synchronizer = nil
            if root == nil { root = try AppDatabase.makeShared() }
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
            let claimLocalContent = try assigningLocalLibrary && !useLocal && libraries.hasUnownedLocalContent()
            if force || environment?.database.libraryID != libraryID || claimLocalContent {
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
                let next = AppEnvironment(database: root.scoped(to: libraryID), attachmentStore: store, preferences: preferences, createsDefaultSpace: useLocal)
                try next.bootstrap()
                environment = next
                next.taskNotifications.refresh()
            }
            guard request == token else { return }
            self.identity = identity
            if local != nil { preferences.set(useLocal, forKey: key) }
            errorMessage = nil
            refreshSyncStatus()
            Task { [weak self] in
                guard let self, self.request == token else { return }
                await self.startSync()
            }
        } catch {
            if request == token { errorMessage = error.localizedDescription }
        }
    }

    func adopt(spaceIDs: Set<String>, includeSavedStyles: Bool, identity: AccountIdentity) async throws {
        guard self.identity == identity, currentOwner() == identity.libraryOwnerKey, !isSwitching, let root else { throw LibraryError.wrongOwner }
        await synchronizer?.stop(); synchronizer = nil
        if let environment { try await environment.closeLibrary() }
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
        guard let root, let identity, currentOwner() == identity.libraryOwnerKey,
              let library = try libraries?.library(id: LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)),
              let cloud = library.cloudAccountID else { throw LibraryError.syncDisabled }
        return LibrarySyncStore(database: root, libraryID: library.id, ownerKey: identity.libraryOwnerKey, cloudAccountID: cloud)
    }

    func refreshSyncStatus() {
        guard let root, let identity else {
            syncEnabled = false; pendingChanges = 0; pendingDownloads = 0; recoveryCount = 0; syncMessage = ""; syncNeedsRetry = false; cloudZoneRemoved = false; return
        }
        let id = LibraryRecord.accountID(ownerKey: identity.libraryOwnerKey)
        do {
            syncEnabled = try libraries?.library(id: id)?.syncEnabled == true
            let counts = try root.read { db in
                try (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncItems WHERE libraryID=? AND dirty=1", arguments: [id]) ?? 0,
                     Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncInbox WHERE libraryID=?", arguments: [id]) ?? 0,
                     Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncConflicts WHERE libraryID=?", arguments: [id]) ?? 0)
            }
            pendingChanges = counts.0; pendingDownloads = counts.1; recoveryCount = counts.2
            let paused = try root.read { try String.fetchOne($0, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [id]) }
            syncNeedsRetry = paused != nil
            cloudZoneRemoved = paused == LibrarySyncError.zoneRemoved.localizedDescription
        } catch { syncMessage = error.localizedDescription }
    }

    private func startSync() async {
        guard root?.isInMemory == false, synchronizer == nil, !usesLocalLibrary, syncEnabled, let environment, let store else { return }
        let owner = identity?.libraryOwnerKey
        do {
            let storage = try syncStore()
            let sync = LibrarySyncEngine(store: storage, attachments: store, database: environment.database,
                currentOwner: { [weak self] in
                    guard self?.environment?.database.libraryID == storage.libraryID else { return nil }
                    return self?.currentOwner()
                }, importChanges: { [weak environment] apply in
                    guard let environment else { throw LibraryError.staleWorkspace }
                    try await environment.importLibraryChanges(apply)
                }, report: { [weak self] message in
                    guard let self, self.currentOwner() == storage.ownerKey,
                          self.environment?.database.libraryID == storage.libraryID else { return }
                    self.syncMessage = message; self.refreshSyncStatus()
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
        guard self.identity == identity, currentOwner() == identity.libraryOwnerKey, !usesLocalLibrary,
              let root else { throw LibraryError.wrongOwner }
        let cloud = try await AccountCloudStore().accountID()
        guard self.identity == identity, currentOwner() == identity.libraryOwnerKey else { throw LibraryError.wrongOwner }
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: identity.libraryOwnerKey)
        try LibrarySyncStore(database: root, libraryID: library.id, ownerKey: identity.libraryOwnerKey, cloudAccountID: cloud).enable(confirmed: true)
        refreshSyncStatus()
        await startSync()
    }

    func pauseSync() async throws {
        await synchronizer?.stop(); synchronizer = nil
        try syncStore().disable()
        refreshSyncStatus()
        syncMessage = "Sync paused. Your library and queued edits remain on this device."
    }

    func synchronize(retry: Bool = false, restoreCloud: Bool = false) async {
        do {
            if retry {
                await synchronizer?.stop(); synchronizer = nil
                try syncStore().prepareRetry(restoringRemovedZone: restoreCloud)
            }
            if synchronizer == nil { await startSync() }
            try await synchronizer?.synchronize()
            refreshSyncStatus()
        } catch { syncMessage = error.localizedDescription }
    }

    func cloudIdentityChanged() async {
        await synchronizer?.stop(); synchronizer = nil
        await startSync()
    }

    func recoveryRevisions() throws -> [LibrarySyncConflict] { try syncStore().conflicts() }
    func recover(_ revision: LibrarySyncConflict) async throws {
        let storage = try syncStore()
        guard let environment, environment.database.libraryID == storage.libraryID else { throw LibraryError.wrongOwner }
        try await environment.importLibraryChanges { try storage.recover(conflictID: revision.id); return [] }
        refreshSyncStatus()
    }
}
