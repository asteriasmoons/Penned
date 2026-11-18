import CloudKit
import Combine
import Foundation
import GRDB
import Network

@MainActor
final class LibrarySyncRequests {
    private var task: Task<Void, Error>?
    private var needsFetch = false
    private var needsSend = false
    var isRunning: Bool { task != nil }

    func run(fetch: Bool, send: Bool, perform: @escaping (Bool, Bool) async throws -> Void) async throws {
        try Task.checkCancellation()
        needsFetch = needsFetch || fetch
        needsSend = needsSend || send
        if let task {
            try await task.value
            try Task.checkCancellation()
            return
        }
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
        try Task.checkCancellation()
    }

    func cancel() {
        needsFetch = false; needsSend = false
        task?.cancel()
    }

    func waitUntilIdle() async { _ = await task?.result }
}

@MainActor
final class LibrarySyncEngine: CKSyncEngineDelegate {
    private let container: CKContainer
    private let store: LibrarySyncStore
    private let attachments: AttachmentStore
    private let currentOwner: () -> String?
    typealias ApplyIncoming = @MainActor (LibrarySyncProtection) throws -> Bool
    private let importChanges: (@escaping ApplyIncoming) async throws -> Bool
    private let report: (String) -> Void
    private var engine: CKSyncEngine?
    private var callbackFailure: (error: Error, phase: String)?
    private var sendRetry: CKError?
    private var passPhase = "idle"
    private var stopping: Task<Void, Never>?
    private var establishingZone = false
    private var requiresInitialFetch = true
    private var journalObservation: AnyDatabaseCancellable?
    private var accountObserver: NSObjectProtocol?
    private var importResumeObservation: AnyCancellable?
    private var active = true
    private let requests = LibrarySyncRequests()
    private var identityCheck: (id: UUID, task: Task<String, Error>)?
    private let connectivity = NWPathMonitor()
    private var wasReachable: Bool?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2
    private var periodicSyncTask: Task<Void, Never>?
    private var localSyncTask: Task<Void, Never>?
    private var pendingLocalChanges = true
    private let syncInterval: Duration = .seconds(300)

    init(store: LibrarySyncStore, attachments: AttachmentStore,
         currentOwner: @escaping () -> String?,
         resumeImportsOn: AnyPublisher<Void, Never>? = nil,
         importChanges: @escaping (@escaping ApplyIncoming) async throws -> Bool,
         report: @escaping (String) -> Void) {
        self.store = store; self.attachments = attachments; self.currentOwner = currentOwner
        self.importChanges = importChanges; self.report = report
        container = CKContainer(identifier: "iCloud.im.lystaria.Penned")
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.stop() }
        }
        importResumeObservation = resumeImportsOn?.sink { [weak self] _ in self?.resumeStagedImport() }
    }

    deinit {
        connectivity.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    func start() async throws {
        try validateWorkspace()
        guard journalObservation == nil else { return }
        PennedSyncTrace.record("sync.start", "library=\(PennedSyncTrace.token(store.libraryID))")
        journalObservation = try store.database.observeSyncJournal(libraryID: store.libraryID, onError: { [weak self] error in
            guard let self, self.active else { return }
            PennedCrashLog.failure("category=sync phase=journalObservation", error, outcome: "periodicSyncStillActive")
            self.report(error.localizedDescription)
        }, onCommit: { [weak self] in
            self?.scheduleLocalSync()
        })
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
        periodicSyncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.active else { return }
                do { try await self.synchronize(fetch: true) }
                catch { self.report(error.localizedDescription) }
                do { try await Task.sleep(for: self.syncInterval) } catch { return }
            }
        }
    }

    private func prepareEngine() async throws {
        guard engine == nil else { return }
        try await validateContext()
        let recoveringLegacyPause = try store.needsLegacyOwnershipRecovery()
        let savedState: CKSyncEngine.State.Serialization? = recoveringLegacyPause ? nil : try store.state()
        PennedSyncTrace.record("sync.prepare", "hasCheckpoint=\(savedState != nil) legacyRecovery=\(recoveringLegacyPause)")
        // Clear the legacy pause only after current ownership checks pass.
        let applied = try await applyPendingChanges(validateEvenIfEmpty: recoveringLegacyPause)
        if recoveringLegacyPause, !applied {
            report("iCloud changes will apply when you close the document.")
            return
        }
        try validateWorkspace()
        if recoveringLegacyPause { try store.finishLegacyOwnershipRecovery() }
        guard engine == nil else { return }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: savedState, delegate: self)
        // Explicitly scheduled batches prevent CloudKit from initiating work on each edit.
        configuration.automaticallySync = false
        configuration.subscriptionID = "penned-sync-" + store.libraryID
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if savedState == nil && !recoveringLegacyPause {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: store.zoneID))])
        }
    }

    func stop() async {
        if let stopping { return await stopping.value }
        active = false
        store.database.invalidate()
        importResumeObservation?.cancel()
        importResumeObservation = nil
        requests.cancel()
        identityCheck?.task.cancel()
        retryTask?.cancel()
        retryTask = nil
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        localSyncTask?.cancel()
        localSyncTask = nil
        connectivity.cancel()
        journalObservation?.cancel()
        journalObservation = nil
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver); self.accountObserver = nil }
        let previous = engine; engine = nil
        let stopping = Task { [requests] in
            await previous?.cancelOperations()
            await requests.waitUntilIdle()
        }
        self.stopping = stopping
        await stopping.value
    }

    private func validateContext() async throws {
        try validateWorkspace()
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
        try await validateLocalContext()
        guard owner == store.cloudAccountID else { throw LibraryError.cloudIdentityChanged }
    }

    private func validateWorkspace() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        guard currentOwner() == store.ownerKey else { throw LibraryError.wrongOwner }
    }

    private func validateLocalContext() async throws {
        try validateWorkspace()
        let store = self.store
        try await store.database.readAsync { try store.requireBinding(in: $0) }
        try validateWorkspace()
    }

    @discardableResult
    private func applyPendingChanges(validateEvenIfEmpty: Bool = false) async throws -> Bool {
        if !validateEvenIfEmpty, !(try await store.hasIncomingChanges()) { return true }
        try validateWorkspace()
        var drained = false
        let attempted = try await importChanges { [store, weak self] protection in
            guard let self else { throw LibraryError.staleWorkspace }
            try self.validateWorkspace()
            PennedSyncTrace.record("sync.import", "watchedEditorProtected=\(PennedSyncTrace.documentID.map { protection.documentIDs.contains($0) } ?? false)")
            // Binding and protection are checked inside this write; don't open
            // a second database access for ownership validation or to count rows.
            let result = try store.applyIncomingBatch(protecting: protection, validateEvenIfEmpty: validateEvenIfEmpty)
            drained = result.drained
            if result.consumedRows { self.pendingLocalChanges = true }
            return result.consumedRows
        }
        return attempted && drained
    }

    private func resumeStagedImport() {
        guard active else { return }
        // Use the same drain as a journal wakeup; never run an independent import
        // while a fetch callback or previous pass is applying the durable inbox.
        scheduleLocalSync()
    }

    private func scheduleLocalSync() {
        guard active else { return }
        pendingLocalChanges = true
        // One short window per burst; continuous editing must not starve sync.
        guard localSyncTask == nil else { return }
        localSyncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.active else { return }
            self.localSyncTask = nil
            do { try await self.synchronize(fetch: false, onlyWhenLocalWorkExists: true) }
            catch {
                if self.active { self.report(error.localizedDescription) }
            }
        }
    }

    private func enqueue(_ engine: CKSyncEngine) async throws {
        let names = try await store.sendableRecordNames()
        try checkEngine(engine)
        let changes = names.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: store.zoneID)) }
        if let watched = PennedSyncTrace.recordName {
            PennedSyncTrace.record("sync.enqueue", "watchedSendable=\(names.contains(watched))")
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func requestImmediateSync(fetch: Bool) {
        Task { [weak self] in
            guard let self, self.active else { return }
            do { try await self.synchronize(fetch: fetch) }
            catch { if self.active { self.report(error.localizedDescription) } }
        }
    }

    private func scheduleRetry(after error: Error, phase: String) {
        guard retryTask == nil else { return }
        let retryAfter = (error as? CKError)?.retryAfterSeconds ?? 0
        let delay = max(retryDelay, retryAfter.isFinite ? retryAfter : 0)
        retryDelay = min(60, retryDelay * 2)
        PennedCrashLog.deferred("category=sync phase=\(phase)", seconds: delay)
        report("Changes saved on this device; waiting for iCloud. " + error.localizedDescription)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.requestImmediateSync(fetch: true)
        }
    }

    func synchronize(fetch: Bool = true, onlyWhenLocalWorkExists: Bool = false) async throws {
        try validateWorkspace()
        try await requests.run(fetch: fetch, send: true) { [weak self] fetch, send in
            guard let self else { throw CancellationError() }
            do {
                try await self.runPass(fetch: fetch, send: send, onlyWhenLocalWorkExists: onlyWhenLocalWorkExists)
            } catch {
                try await self.recoverPassFailure(error)
            }
        }
    }

    private func runPass(fetch: Bool, send: Bool, onlyWhenLocalWorkExists: Bool) async throws {
        passPhase = "validateWorkspace"
        try validateWorkspace()
        if let callbackFailure { throw callbackFailure.error }
        guard retryTask == nil else { return }
        passPhase = "checkLocalWork"
        if !fetch, onlyWhenLocalWorkExists, !(try await store.hasLocalWork()) { return }
        try validateWorkspace()
        let initial = engine == nil
        passPhase = "prepare"
        if initial { try await prepareEngine() }
        guard let engine else { return }
        try checkEngine(engine)
        let group = CKOperationGroup()
        group.name = "PennedImmediateLibrarySync"
        group.defaultConfiguration.qualityOfService = .utility
        let needsZone = engine.state.pendingDatabaseChanges.contains {
            if case .saveZone(let zone) = $0 { return zone.zoneID == store.zoneID }
            return false
        }
        let willFetch = fetch || requiresInitialFetch || needsZone
        PennedSyncTrace.record("sync.pass", "initial=\(initial) fetch=\(willFetch) send=\(send) needsZone=\(needsZone)")
        report("Syncing library with iCloud")
        // Ensure that a zone exists and fetch its latest state before sending rows.
        if send && needsZone {
            passPhase = "establishZone"
            establishingZone = true
            do {
                defer { establishingZone = false }
                try await engine.sendChanges(.init(scope: .zoneIDs([store.zoneID]), operationGroup: group))
            }
            try checkEngine(engine)
        }
        if willFetch {
            passPhase = "fetch"
            PennedSyncTrace.record("cloud.fetchBegin")
            try await engine.fetchChanges(.init(scope: .zoneIDs([store.zoneID]), operationGroup: group))
            PennedSyncTrace.record("cloud.fetchReturned")
            try checkEngine(engine)
            requiresInitialFetch = false
        } else {
            passPhase = "applyInbox"
            _ = try await applyPendingChanges()
            try checkEngine(engine)
        }
        if pendingLocalChanges || initial {
            passPhase = "enqueue"
            pendingLocalChanges = false
            try await enqueue(engine)
        }
        try checkEngine(engine)
        if send {
            passPhase = "send"
            sendRetry = nil
            try await engine.sendChanges(.init(scope: .zoneIDs([store.zoneID]), operationGroup: group))
            try checkEngine(engine)
            if let sendRetry { throw sendRetry }
            report("Library changes sent to iCloud")
        }
        if retryDelay > 2 {
            PennedCrashLog.recovered("category=sync phase=pass")
            retryDelay = 2
        }
    }

    private func checkEngine(_ engine: CKSyncEngine) throws {
        try validateWorkspace()
        guard self.engine === engine else { throw CancellationError() }
        if let callbackFailure { throw callbackFailure.error }
    }

    nonisolated func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        await fetchOptions(context.options, engine: syncEngine)
    }
    private func fetchOptions(_ options: CKSyncEngine.FetchChangesOptions, engine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard self.engine === engine, active, callbackFailure == nil else { return .init(scope: .zoneIDs([])) }
        do {
            try await validateContext()
            try checkEngine(engine)
            return .init(scope: .zoneIDs([store.zoneID]), operationGroup: options.operationGroup)
        }
        catch { failCallback(error, phase: "fetchOptions", engine: engine); return .init(scope: .zoneIDs([])) }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await batch(context, engine: syncEngine)
    }
    private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !establishingZone, self.engine === engine, active, callbackFailure == nil else { return nil }
        do {
            try checkEngine(engine)
            let store = self.store
            let orderedNames = try await store.sendableRecordNames()
            try checkEngine(engine)
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
            let selectedNames = Array(selected)
            if let watched = PennedSyncTrace.recordName, names.contains(watched) {
                PennedSyncTrace.record("cloud.uploadCandidate", "selected=\(selectedNames.contains(watched))")
            }
            let attachments = self.attachments
            let result = try await Self.runWorker {
                let batchItems = try store.pending(recordNames: selectedNames)
                let blocked = try store.quarantineStaleUploads(batchItems)
                let records = try batchItems.filter { !blocked.contains($0.row.recordName) }.map { item in
                    try Task.checkCancellation()
                    return try store.makeRecord(item, attachments: attachments)
                }
                return (records, blocked)
            }
            var records = result.0
            let blocked = result.1
            try await validateContext()
            try checkEngine(engine)
            if !blocked.isEmpty {
                engine.state.remove(pendingRecordZoneChanges: blocked.map {
                    .saveRecord(CKRecord.ID(recordName: $0, zoneID: store.zoneID))
                })
                report("An older queued document was not uploaded. Its copy is in Recovery Revisions.")
                scheduleLocalSync()
            }
            let mutations = try store.currentUploadMutations(recordNames: records.map { $0.recordID.recordName })
            records.removeAll { record in
                guard let mutation = record["mutationID"] as? String else { return true }
                let superseded = mutations[record.recordID.recordName] != mutation
                if superseded {
                    PennedSyncTrace.decision("skipSupersededOrBlockedUpload", recordName: record.recordID.recordName)
                }
                return superseded
            }
            if let watched = PennedSyncTrace.recordName,
               let record = records.first(where: { $0.recordID.recordName == watched }) {
                PennedSyncTrace.record("cloud.uploadBatch",
                    "mutation=\(PennedSyncTrace.token(record["mutationID"] as? String)) tag=\(PennedSyncTrace.token(record.recordChangeTag))")
            }
            return records.isEmpty ? nil : .init(recordsToSave: records, atomicByZone: false)
        } catch {
            failCallback(error, phase: "prepareOutgoing", engine: engine)
            return nil
        }
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await process(event, engine: syncEngine)
    }
    private func process(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard self.engine === engine, active, callbackFailure == nil else { return }
        var phase = "delegate"
        do {
            try checkEngine(engine)
            switch event {
            case .willFetchChanges:
                phase = "validateBeforeFetch"
                try await validateContext()
            case .willSendChanges:
                phase = "validateBeforeSend"
                try await validateContext()
            case .stateUpdate(let event):
                phase = "checkpoint"
                let store = self.store, checkpoint = event.stateSerialization
                try await Self.runWorker { try store.saveState(checkpoint) }
            case .accountChange(let event):
                phase = "cloudAccountChange"
                switch event.changeType {
                case .signIn: try await validateContext()
                case .signOut, .switchAccounts:
                    throw LibraryError.cloudIdentityChanged
                @unknown default: throw LibraryError.cloudIdentityChanged
                }
            case .fetchedDatabaseChanges(let event):
                phase = "fetchedZones"
                if event.deletions.contains(where: { $0.zoneID == store.zoneID }) { throw LibrarySyncError.zoneRemoved }
            case .fetchedRecordZoneChanges(let event):
                phase = "stageIncoming"
                let records = event.modifications.map(\.record).filter { $0.recordID.zoneID == store.zoneID }
                let deletions = event.deletions.map(\.recordID).filter { $0.zoneID == store.zoneID }
                try await stageRecords(records, deletions: deletions, source: "fetch", engine: engine)
                phase = "applyInbox"
                try await applyPendingChanges()
                pendingLocalChanges = true
            case .sentRecordZoneChanges(let event):
                phase = "acknowledgeOutgoing"
                let store = self.store
                let saved = event.savedRecords.filter { $0.recordID.zoneID == store.zoneID }
                try await Self.runWorker {
                    for record in saved {
                        try Task.checkCancellation()
                        try store.acknowledge(record)
                    }
                }
                try checkEngine(engine)
                phase = "reconcileSendFailures"
                for failure in event.failedRecordSaves where failure.record.recordID.zoneID == store.zoneID {
                    if PennedSyncTrace.isWatched(failure.record.recordID.recordName) {
                        PennedSyncTrace.record("cloud.uploadFailed", "code=\(failure.error.code.rawValue) mutation=\(PennedSyncTrace.token(failure.record["mutationID"] as? String))")
                    }
                    switch failure.error.code {
                    case .serverRecordChanged:
                        guard let reference = failure.error.serverRecord else { throw failure.error }
                        // Conflict errors do not include downloaded CKAsset bytes. Fetch the complete record first.
                        let server = try await container.privateCloudDatabase.record(for: reference.recordID)
                        try await validateContext()
                        try checkEngine(engine)
                        try await stageRecords([server], source: "serverRecordChanged", engine: engine)
                        try await applyPendingChanges()
                    case .zoneNotFound, .userDeletedZone: throw LibrarySyncError.zoneRemoved
                    case .unknownItem:
                        // An externally deleted row must not be resurrected by a stale upload.
                        try await stageRecords([], deletions: [failure.record.recordID], source: "sendConflict", engine: engine)
                        try await applyPendingChanges()
                    case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .requestRateLimited:
                        // The engine retains the failed record, and our outbox stays
                        // dirty. Retry the pass without discarding a valid checkpoint.
                        if (failure.error.retryAfterSeconds ?? 0) >= (sendRetry?.retryAfterSeconds ?? 0) || sendRetry == nil {
                            sendRetry = failure.error
                        }
                    default: throw failure.error
                    }
                }
                phase = "reenqueueNewerEdits"
                let acknowledgedIDs = Set(event.savedRecords.map(\.recordID))
                let newerEdits = try await store.sendableRecordNames()
                    .map { CKRecord.ID(recordName: $0, zoneID: store.zoneID) }.filter { acknowledgedIDs.contains($0) }
                try checkEngine(engine)
                engine.state.add(pendingRecordZoneChanges: newerEdits.map { .saveRecord($0) })
            case .sentDatabaseChanges(let event):
                phase = "sendZone"
                if let failure = event.failedZoneSaves.first(where: { $0.zone.zoneID == store.zoneID }) { throw failure.error }
            case .didFetchChanges:
                phase = "finishFetch"
                if try await applyPendingChanges() {
                    pendingLocalChanges = true
                    report("Library changes received from iCloud")
                } else {
                    report("Some iCloud changes are staged until the affected document closes or its dependencies arrive.")
                }
            default: break
            }
        } catch {
            failCallback(error, phase: phase, engine: engine)
        }
    }

    private func failCallback(_ error: Error, phase: String, engine: CKSyncEngine) {
        guard active, self.engine === engine, callbackFailure == nil else { return }
        // Delegate events are serial. Once local handling fails, no subsequent
        // event may save a checkpoint that skips work we didn't make durable.
        callbackFailure = (error, phase)
        if !requests.isRunning { requestImmediateSync(fetch: true) }
    }

    private func recoverPassFailure(_ thrownError: Error) async throws {
        guard active, !Task.isCancelled, currentOwner() == store.ownerKey else { throw thrownError }
        let failure = callbackFailure
        let error = failure?.error ?? thrownError
        let phase = failure?.phase ?? passPhase
        let retryable = Self.isRecoverable(error)
        pendingLocalChanges = true
        PennedCrashLog.failure("category=sync phase=\(phase)", error,
                               outcome: retryable ? "workRetained" : "syncPaused")

        if failure != nil || !retryable {
            // Do not cancel or create an engine from inside its own delegate.
            // Retire the failed instance and load the last durable checkpoint on retry.
            let previous = engine
            engine = nil
            callbackFailure = nil
            requiresInitialFetch = true
            if !retryable {
                active = false
                localSyncTask?.cancel()
                retryTask?.cancel()
                journalObservation?.cancel()
                persistPause(for: error)
            }
            await previous?.cancelOperations()
        }
        if retryable {
            try validateWorkspace()
            scheduleRetry(after: error, phase: phase)
            return
        }
        report(error.localizedDescription)
        throw error
    }

    private func persistPause(for error: Error) {
        if let syncError = error as? LibrarySyncError {
            if case .paused = syncError { return }
            if case .requiresResolution(let recordName, _) = syncError {
                do { try store.archiveStagedRevision(recordName: recordName, reason: error.localizedDescription) }
                catch { PennedCrashLog.failure("category=sync phase=archiveConflict", error, outcome: "inboxRetained") }
            }
        }
        do { try store.pause(error.localizedDescription) }
        catch { PennedCrashLog.failure("category=sync phase=persistPause", error, outcome: "engineStopped") }
    }

    nonisolated private static func isRecoverable(_ error: Error) -> Bool {
        if error is CancellationError || PennedCrashLog.isTemporarySQLiteError(error) { return true }
        if let syncError = error as? LibrarySyncError, case .assetMissing = syncError { return true }
        if let fileError = error as? CocoaError, [.fileReadNoPermission, .fileReadNoSuchFile, .fileNoSuchFile].contains(fileError.code) {
            return true
        }
        if let cloudError = error as? CKError {
            return [.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                    .accountTemporarilyUnavailable, .operationCancelled, .requestRateLimited].contains(cloudError.code)
        }
        return (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains($0.code) } ?? false
    }

    private func stageRecords(_ records: [CKRecord], deletions: [CKRecord.ID] = [], source: String,
                              engine: CKSyncEngine) async throws {
        let store = self.store, attachments = self.attachments
        try await Self.runWorker {
            for record in records {
                try Task.checkCancellation()
                try store.stageIncoming(record, attachments: attachments, source: source)
            }
            for recordID in deletions {
                try Task.checkCancellation()
                try store.stagePhysicalDeletion(recordID)
            }
        }
        try checkEngine(engine)
    }

    nonisolated private static func runWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let work = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
