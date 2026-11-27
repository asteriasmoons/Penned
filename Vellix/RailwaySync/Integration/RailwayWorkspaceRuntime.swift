import Foundation
import Combine
import GRDB

extension RailwayWorkspaceRoute {
    nonisolated static func read(_ database: AppDatabase?, ownerKey: String?) -> Self {
        guard let database else {return .local}
        if database.libraryID == LibraryRecord.localID {return .local}
        guard let ownerKey, database.isAccessible,
              LibraryRecord.accountID(ownerKey:ownerKey)==database.libraryID else{return .blocked}
        do {
            if try database.read({try RailwayMigrationFence.owner(in:$0)}) != nil{return .blocked}
            let log=try RailwayMigrationLogStore(database:database,libraryID:database.libraryID)
            guard let state=try log.state() else{return .legacy}
            let storedOwner=try database.read {db in try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[database.libraryID])}
            let valid = storedOwner==ownerKey && (try? RailwayActivationPermit.restore(state,libraryID:database.libraryID,ownerKey:ownerKey)) != nil
            return select(local:false,phase:state.phase.rawValue,verified:valid)
        }catch{return .blocked}
    }
}

nonisolated struct RailwayWorkspaceStatus: Sendable {
    var enabled=false
    var pending=0
    var downloads=0
    var recovery=0
    var needsRetry=false
    var message="Penned Cloud Sync is waiting for account authentication."
}

// A single runtime per selected workspace, not per window or editor.
// No provider is switched here: migration must first commit its verified receipt.
@MainActor final class RailwayWorkspaceRuntime {
    typealias Import = @MainActor (@escaping LibrarySyncEngine.ApplyIncoming) async throws -> Bool
    private var engine:RailwaySyncEngine?
    private var journal:RailwayJournal?
    private var generation=UUID()
    private var starting=false
    private var stopping:Task<Void,Never>?
    private var subscriptions=Set<AnyCancellable>()
    private var statusTask:Task<Void,Never>?
    var isRunning:Bool {engine != nil}

    func start(database:AppDatabase,ownerKey:String,attachments:AttachmentStore,
               binding:RailwayNativeAccountBinding,
               editorChanges:AnyPublisher<Void,Never>,
               isCurrent:@escaping @MainActor ()->Bool,
               importer:@escaping Import,
               report:@escaping @MainActor (RailwayWorkspaceStatus)->Void) async throws {
        if let stopping{await stopping.value}
        guard engine==nil,!starting,self.stopping==nil else{return}
        guard RailwayWorkspaceRoute.read(database,ownerKey:ownerKey) == .railway,isCurrent() else{throw RailwayError.releaseDisabled}
        let fence=UUID();generation=fence;starting=true
        defer{if generation==fence{starting=false}}
        let log=try RailwayMigrationLogStore(database:database,libraryID:database.libraryID)
        guard let state=try log.state() else{throw RailwayError.migrationNotVerified}
        let permit=try RailwayActivationPermit.restore(state,libraryID:database.libraryID,ownerKey:ownerKey)
        let account=try binding.client()
        let session=try await binding.bind(to:database)
        guard generation==fence,isCurrent(),session.ownerKey==ownerKey else{throw CancellationError()}
        let transport=try RailwayTransport(baseURL:URL(string:"https://api.penned.im")!)
        let rows=RailwayGRDBRows(deviceID:session.deviceID,editorProtected:{_,_ in false})
        let journal=try RailwayJournal(database:database,libraryID:database.libraryID,deviceID:session.deviceID,applier:rows)
        _ = try journal.checkpoint()
        let storage=try database.railwayCaptureStorage()
        let temporary=storage.staging.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Transfers",isDirectory:true).appendingPathComponent(database.libraryID,isDirectory:true)
        let transfers=RailwayAttachmentTransfers(account:account,transport:transport,
            store:try RailwayTransferStore(database:database,libraryID:database.libraryID,deviceID:session.deviceID),
            stagingDirectory:temporary,fileURL:{try attachments.validatedFileURL(relativePath:$0)})
        let capture=try RailwayNativeRecordCapture(database:database,attachments:attachments,staging:storage.staging,deviceID:session.deviceID)
        let destination=RailwayMigrationHTTPDestination(account:account,transport:transport,stagingDirectory:temporary,nativeTransactions:true)
        let sender=RailwayNativeRecordSender(account:account,capture:capture,destination:destination,journal:journal)
        let api=RailwaySyncAPI(account:account)
        let engine=RailwaySyncEngine(api:api,account:account,transport:transport,journal:journal,transfers:transfers,nativeRecords:sender,
            applyIncoming:{ [weak self] apply in
                guard let self else{throw CancellationError()}
                try await self.apply(fence:fence,isCurrent:isCurrent,importer:importer,operation:apply)
            })
        self.engine=engine;self.journal=journal
        do{
            try await engine.start(authorization:permit)
            guard generation==fence,isCurrent() else{throw CancellationError()}
        }catch{
            await engine.stop()
            if generation==fence{self.engine=nil;self.journal=nil}
            throw error
        }
        // Every authored AppDatabase write posts this existing notification after
        // commit; filter by library rather than handle identity for Mac windows.
        NotificationCenter.default.publisher(for:.pennedCollectionsChanged)
            .receive(on:DispatchQueue.main)
            .sink{[weak self] notification in
                guard let source=notification.object as? AppDatabase,(source.libraryID==database.libraryID || source.libraryID=="*") else{return}
                Task{@MainActor in guard let self,self.generation==fence,isCurrent() else{return};await engine.trigger(.saved)}
            }.store(in:&subscriptions)
        editorChanges.receive(on:DispatchQueue.main).sink{[weak self] _ in
            Task{@MainActor in guard let self,self.generation==fence,isCurrent() else{return};await engine.trigger(.manual)}
        }.store(in:&subscriptions)
        statusTask=Task{[weak self] in
            while !Task.isCancelled{
                guard let self,self.generation==fence,isCurrent() else{return}
                let status=await self.status()
                guard self.generation==fence,isCurrent() else{return}
                report(status)
                do{try await Task.sleep(for:.seconds(2))}catch{return}
            }
        }
    }

    private func apply(fence:UUID,isCurrent:@escaping @MainActor ()->Bool,importer:Import,operation:@escaping @Sendable (Bool)throws->Bool)async throws{
        try Task.checkCancellation()
        guard generation==fence,isCurrent() else{throw CancellationError()}
        var executed=false
        _ = try await importer{protection in
            try Task.checkCancellation()
            guard self.generation==fence,isCurrent() else{throw CancellationError()}
            // Stage the complete remote page durably even while an editor is
            // open. Do not alter authored rows or advance past an uncommitted
            // page; the journal replays deferred rows once the editor closes.
            let safe=protection.isEmpty && protection.folderIDs.isEmpty && protection.templateIDs.isEmpty &&
                protection.collectionIDs.isEmpty && protection.taskIDs.isEmpty && protection.attachmentPaths.isEmpty
            executed=true
            return try operation(safe)
        }
        if !executed{
            // A workspace/window transition declined the import altogether.
            // Only the mirror and durable inbox may be changed in that case.
            try Task.checkCancellation()
            guard generation==fence,isCurrent() else{throw CancellationError()}
            _ = try operation(false)
        }
    }

    func status()async->RailwayWorkspaceStatus{
        guard let engine,let journal else{return .init()}
        do{
            let d=try journal.localDiagnostics()
            let state=await engine.lastStatus
            var result=RailwayWorkspaceStatus()
            result.enabled = !d.paused;result.pending=d.pendingMutations
            result.downloads=d.pendingTransfers+d.deferredRecords;result.recovery=d.recoveryRecords;result.needsRetry=state=="failed" || d.failedOperations>0
            result.message=d.paused ? "Penned Cloud Sync paused" : (["idle":"Penned Cloud Sync ready","syncing":"Syncing with Penned Cloud","offline":"Offline — changes saved on this device","waitingForEditor":"Cloud changes waiting for open editors","failed":"Cloud sync will retry"][state] ?? "Connecting to Penned Cloud")
            if !d.paused,d.deferredRecords>0,state=="idle"{result.message="Cloud changes queued until the workspace is ready"}
            return result
        }catch{return .init(needsRetry:true,message:"Cloud sync journal unavailable. Local content retained.")}
    }
    func synchronize(retry:Bool)async throws{
        guard let engine else{throw RailwayError.signedOut}
        if retry{try await engine.retryFailed()}
        await engine.trigger(.manual)
    }
    func pause()async throws{guard let engine else{throw RailwayError.signedOut};try await engine.pause()}
    func resume()async throws{guard let engine else{throw RailwayError.signedOut};try await engine.resume()}
    func stop()async{
        generation=UUID();starting=false
        subscriptions.removeAll();statusTask?.cancel();statusTask=nil
        if let stopping{await stopping.value;return}
        let previous=engine;engine=nil;journal=nil
        guard let previous else{return}
        let task=Task{await previous.stop()}
        stopping=task
        await task.value
        stopping=nil
    }
}
