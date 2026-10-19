import CloudKit
import Foundation
import Network

@MainActor
final class LibrarySyncRequests {
    private var task: Task<Void, Error>?
    private var needsFetch = false
    private var needsSend = false

    func run(fetch: Bool, send: Bool, perform: @escaping (Bool, Bool) async throws -> Void) async throws {
        needsFetch = needsFetch || fetch
        needsSend = needsSend || send
        if let task { return try await task.value }
        let work = Task {
            defer { self.task = nil }
            while self.needsFetch || self.needsSend {
                try Task.checkCancellation()
                let fetch = self.needsFetch, send = self.needsSend
                self.needsFetch = false; self.needsSend = false
                try await perform(fetch, send)
                try Task.checkCancellation()
            }
        }
        task = work
        try await work.value
    }

    func cancel() {
        needsFetch = false; needsSend = false
        task?.cancel()
    }
}

@MainActor
final class LibrarySyncEngine: CKSyncEngineDelegate {
    private let container: CKContainer
    private let store: LibrarySyncStore
    private let attachments: AttachmentStore
    private let currentOwner: () -> String?
    private let importChanges: (@escaping () throws -> Set<String>) async throws -> Void
    private let report: (String) -> Void
    private var engine: CKSyncEngine?
    private var observer: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private var active = true
    private let requests = LibrarySyncRequests()
    private var identityCheck: (id: UUID, task: Task<String, Error>)?
    private let connectivity = NWPathMonitor()
    private var wasReachable: Bool?

    init(store: LibrarySyncStore, attachments: AttachmentStore, database: AppDatabase,
         currentOwner: @escaping () -> String?,
         importChanges: @escaping (@escaping () throws -> Set<String>) async throws -> Void,
         report: @escaping (String) -> Void) {
        self.store = store; self.attachments = attachments; self.currentOwner = currentOwner
        self.importChanges = importChanges; self.report = report
        container = CKContainer(identifier: "iCloud.im.lystaria.Penned")
        observer = NotificationCenter.default.addObserver(forName: .pennedCollectionsChanged, object: database, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.enqueue() { self.requestImmediateSync(fetch: false) }
            }
        }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.active = false
                self.requests.cancel()
                self.identityCheck?.task.cancel()
                Task { await self.engine?.cancelOperations() }
            }
        }
    }

    deinit {
        connectivity.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func start() async throws {
        try validateLocalContext()
        connectivity.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                let restored = self.wasReachable == false && reachable
                self.wasReachable = reachable
                guard restored else { return }
                do { try await self.synchronize() } catch { self.report(error.localizedDescription) }
            }
        }
        connectivity.start(queue: DispatchQueue(label: "Penned.LibrarySync.Connectivity"))
        do { try await prepareEngine() }
        catch {
            guard Self.isRecoverable(error) else { throw error }
            report("Changes saved on this device; waiting for iCloud. " + error.localizedDescription)
            return
        }
        requestImmediateSync(fetch: true)
    }

    private func prepareEngine() async throws {
        guard engine == nil else { return }
        try await validateContext()
        let savedState = try store.state()
        try await applyPendingChanges()
        try validateLocalContext()
        guard engine == nil else { return }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: savedState, delegate: self)
        configuration.automaticallySync = true
        configuration.subscriptionID = "penned-sync-" + store.libraryID
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if savedState == nil { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: store.zoneID))]) }
        enqueue()
    }

    func stop() async {
        active = false
        requests.cancel()
        identityCheck?.task.cancel()
        connectivity.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver); self.accountObserver = nil }
        let previous = engine; engine = nil
        await previous?.cancelOperations()
    }

    private func validateContext() async throws {
        try validateLocalContext()
        let check: (id: UUID, task: Task<String, Error>)
        if let identityCheck { check = identityCheck }
        else {
            check = (UUID(), Task { [container] in
                switch try await container.accountStatus() {
                case .available: break
                case .couldNotDetermine: throw CKError(.networkFailure)
                case .temporarilyUnavailable: throw CKError(.accountTemporarilyUnavailable)
                default: throw LibraryError.cloudIdentityChanged
                }
                return try await container.userRecordID().recordName
            })
            identityCheck = check
        }
        defer { if identityCheck?.id == check.id { identityCheck = nil } }
        let owner = try await check.task.value
        try validateLocalContext()
        guard owner == store.cloudAccountID else { throw LibraryError.cloudIdentityChanged }
    }

    private func validateLocalContext() throws {
        guard active, currentOwner() == store.ownerKey else { throw LibraryError.wrongOwner }
        try store.database.read { try store.requireBinding(in: $0) }
    }

    private func applyPendingChanges() async throws {
        guard try store.incomingCount() > 0 else { return }
        try await importChanges { [store, weak self] in
            guard let self else { throw LibraryError.staleWorkspace }
            try self.validateLocalContext()
            return try store.applyIncoming()
        }
    }

    @discardableResult private func enqueue() -> Bool {
        guard active, currentOwner() == store.ownerKey else { return false }
        do {
            let names = try store.pendingRecordNames()
            let changes = names.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: store.zoneID)) }
            engine?.state.add(pendingRecordZoneChanges: changes)
            return !names.isEmpty
        } catch { report(error.localizedDescription); return false }
    }

    private func requestImmediateSync(fetch: Bool) {
        Task { [weak self] in
            guard let self, self.active else { return }
            do { try await self.synchronize(fetch: fetch) }
            catch { if self.active { self.report(error.localizedDescription) } }
        }
    }

    func synchronize(fetch: Bool = true) async throws {
        try validateLocalContext()
        if engine == nil { try await prepareEngine() }
        try await requests.run(fetch: fetch, send: true) { [weak self] fetch, send in
            guard let self else { throw CancellationError() }
            try self.validateLocalContext()
            guard let engine = self.engine else { return }
            self.report("Syncing library with iCloud")
            self.enqueue()
            let group = CKOperationGroup()
            group.name = "PennedImmediateLibrarySync"
            group.defaultConfiguration.qualityOfService = .userInitiated
            let needsZone = engine.state.pendingDatabaseChanges.contains {
                if case .saveZone(let zone) = $0 { return zone.zoneID == self.store.zoneID }
                return false
            }
            // Establish a new zone before fetching it. Existing zones fetch immediately.
            if send && needsZone { try await engine.sendChanges(.init(scope: .zoneIDs([self.store.zoneID]), operationGroup: group)) }
            if fetch { try await engine.fetchChanges(.init(scope: .zoneIDs([self.store.zoneID]), operationGroup: group)) }
            try self.validateLocalContext()
            if send && !needsZone { try await engine.sendChanges(.init(scope: .zoneIDs([self.store.zoneID]), operationGroup: group)) }
        }
    }

    nonisolated func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        await fetchOptions(context.options)
    }
    private func fetchOptions(_ options: CKSyncEngine.FetchChangesOptions) async -> CKSyncEngine.FetchChangesOptions {
        do {
            try await validateContext()
            return .init(scope: .zoneIDs([store.zoneID]), operationGroup: options.operationGroup)
        }
        catch { report(error.localizedDescription); return .init(scope: .zoneIDs([])) }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await batch(context, engine: syncEngine)
    }
    private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            try validateLocalContext()
            let orderedNames = try store.pendingRecordNames()
            let names = Set(orderedNames)
            let obsolete = engine.state.pendingRecordZoneChanges.filter {
                switch $0 {
                case .saveRecord(let id): return id.zoneID != store.zoneID || !names.contains(id.recordName)
                case .deleteRecord: return true // Penned publishes durable tombstones instead of destructive remote deletes.
                @unknown default: return true
                }
            }
            engine.state.remove(pendingRecordZoneChanges: obsolete)
            let pending = Set(engine.state.pendingRecordZoneChanges)
            let selected = orderedNames.filter {
                let id = CKRecord.ID(recordName: $0, zoneID: store.zoneID)
                return pending.contains(.saveRecord(id)) && context.options.scope.contains(id)
            }.prefix(100)
            let batchItems = try store.pending(recordNames: Array(selected))
            let work = Task.detached(priority: .utility) { [store, attachments] in
                try batchItems.map { item in try Task.checkCancellation(); return try store.makeRecord(item, attachments: attachments) }
            }
            let records = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try await validateContext()
            return records.isEmpty ? nil : .init(recordsToSave: records, atomicByZone: false)
        } catch {
            report(error.localizedDescription)
            return nil
        }
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await process(event, engine: syncEngine)
    }
    private func process(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard active else { return }
        do {
            try validateLocalContext()
            switch event {
            case .willSendChanges: try await validateContext()
            default: break
            }
            switch event {
            case .stateUpdate(let event): try store.saveState(event.stateSerialization)
            case .accountChange(let event):
                switch event.changeType {
                case .signIn: try await validateContext()
                case .signOut, .switchAccounts:
                    requests.cancel()
                    throw LibraryError.cloudIdentityChanged
                @unknown default: throw LibraryError.cloudIdentityChanged
                }
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == store.zoneID }) { throw LibrarySyncError.zoneRemoved }
            case .fetchedRecordZoneChanges(let event):
                try await stageRecords(event.modifications.map(\.record).filter { $0.recordID.zoneID == store.zoneID })
                for deletion in event.deletions where deletion.recordID.zoneID == store.zoneID { try store.stagePhysicalDeletion(deletion.recordID) }
                try await applyPendingChanges()
                enqueue()
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords where record.recordID.zoneID == store.zoneID { try store.acknowledge(record) }
                for failure in event.failedRecordSaves where failure.record.recordID.zoneID == store.zoneID {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        guard let reference = failure.error.serverRecord else { throw failure.error }
                        // Conflict errors do not include downloaded CKAsset bytes. Fetch the complete record first.
                        let server = try await container.privateCloudDatabase.record(for: reference.recordID)
                        try await validateContext()
                        try await stageRecords([server])
                        try await applyPendingChanges()
                    case .zoneNotFound, .userDeletedZone: throw LibrarySyncError.zoneRemoved
                    case .unknownItem:
                        // An externally deleted row must not be resurrected by a stale upload.
                        try store.stagePhysicalDeletion(failure.record.recordID)
                        try await applyPendingChanges()
                    case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .requestRateLimited:
                        report("Changes saved on this device; iCloud will retry. " + failure.error.localizedDescription)
                    default: throw failure.error
                    }
                }
                let acknowledgedIDs = Set(event.savedRecords.map(\.recordID))
                let newerEdits = try store.pendingRecordNames().map { CKRecord.ID(recordName: $0, zoneID: store.zoneID) }.filter { acknowledgedIDs.contains($0) }
                engine.state.add(pendingRecordZoneChanges: newerEdits.map { .saveRecord($0) })
            case .sentDatabaseChanges(let event):
                if let failure = event.failedZoneSaves.first(where: { $0.zone.zoneID == store.zoneID }) { throw failure.error }
            case .didSendChanges: report("Library changes sent to iCloud")
            case .didFetchChanges:
                try await applyPendingChanges()
                report("Library changes received from iCloud")
            default: break
            }
        } catch {
            guard active, currentOwner() == store.ownerKey else { return }
            if error is CancellationError { return }
            if Self.isRecoverable(error) {
                report("Changes saved on this device; waiting for iCloud. " + error.localizedDescription)
                return
            }
            active = false
            if let conflict = error as? LibrarySyncError, case .requiresResolution(let recordName, _) = conflict {
                try? store.archiveStagedRevision(recordName: recordName, reason: error.localizedDescription)
            }
            // Do not persist an advanced fetch token after an import failure. A confirmed retry re-fetches safely.
            try? store.pause(error.localizedDescription)
            report(error.localizedDescription)
            Task { await engine.cancelOperations() }
        }
    }

    nonisolated private static func isRecoverable(_ error: Error) -> Bool {
        if let cloudError = error as? CKError {
            return [.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                    .accountTemporarilyUnavailable, .operationCancelled, .requestRateLimited].contains(cloudError.code)
        }
        return (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains($0.code) } ?? false
    }

    private func stageRecords(_ records: [CKRecord]) async throws {
        let work = Task.detached(priority: .utility) { [store, attachments] in
            for record in records {
                try Task.checkCancellation()
                try store.stageIncoming(record, attachments: attachments)
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try validateLocalContext()
    }
}
