import Foundation
import GRDB
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// Integration entrypoints for the existing LibraryWorkspace, AppDatabase and editor.
// No app lifecycle hook is installed by generating these files.
@MainActor final class RailwayWorkspaceIntegration {
    let journal:RailwayJournal
    let mutations:RailwayMutationFactory
    let sync:RailwaySyncEngine
    let transfers:RailwayAttachmentTransfers
    let account:RailwayAccountSession
    private let database:AppDatabase
    private var active=false
    private let stopLegacyAndCloseWorkspace:@MainActor ()async->Void
    init(database:AppDatabase,account:RailwayAccountSession,journal:RailwayJournal,sync:RailwaySyncEngine,transfers:RailwayAttachmentTransfers,stopLegacyAndCloseWorkspace:@escaping @MainActor ()async->Void){
        self.database=database;self.account=account;self.journal=journal;self.mutations = .init(journal:journal);self.sync=sync;self.transfers=transfers;self.stopLegacyAndCloseWorkspace=stopLegacyAndCloseWorkspace
    }
    // Invoke during an explicitly authorized native GRDB schema migration.
    nonisolated static func install(in db:Database)throws{try RailwayJournal.install(in:db);try RailwayNativeRecordCapture.install(in:db)}
    nonisolated static func configureConnection(_ db:Database){RailwayNativeRecordCapture.configure(db)}
    func activate(_ permit:RailwayActivationPermit)async throws{
        guard permit.libraryID==database.libraryID,database.isAccessible else{throw RailwayError.accountMismatch}
        let binding=try await account.binding()
        guard binding.libraryID==database.libraryID,binding.deviceID==journal.deviceID else{throw RailwayError.accountMismatch}
        try await sync.start(authorization:permit);active=true
    }
    func saved(){guard active else{return};Task{await sync.trigger(.saved)}}
    func foreground(){guard active else{return};Task{await sync.trigger(.foreground)}}
    func syncNow(){guard active else{return};Task{await sync.trigger(.manual)}}
    func retry()async throws{guard active else{throw RailwayError.releaseDisabled};try await sync.retryFailed()}
    func pause()async throws{try await sync.pause()}
    func resume()async throws{guard active else{throw RailwayError.releaseDisabled};try await sync.resume()}
    func configure(_ preferences:RailwaySyncPreferences)async throws{try await sync.updatePreferences(preferences)}
    func signOut()async throws{
        active=false
        await sync.stop()
        await stopLegacyAndCloseWorkspace()
        // The existing lease prevents an old editor from accessing a new account.
        database.invalidate()
        // No SQLite delete, attachment cache eviction or Library transfer.
        try await account.signOut()
    }
}
#if canImport(BackgroundTasks) && os(iOS)
@MainActor final class RailwayBackgroundScheduler {
    private let identifier:String
    private let work:@Sendable ()async throws->Void
    init(identifier:String,work:@escaping @Sendable ()async throws->Void){self.identifier=identifier;self.work=work}
    // Called by the future app startup only after identifier/entitlement verification.
    // Apple controls actual scheduling; this is never a guaranteed periodic task.
    func register()->Bool{
        BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:nil){[work] task in
            let operation=Task{
                do{try await work();task.setTaskCompleted(success:!Task.isCancelled)}
                catch{task.setTaskCompleted(success:false)}
            }
            task.expirationHandler={operation.cancel()}
        }
    }
    func submit()throws{
        let request=BGProcessingTaskRequest(identifier:identifier)
        request.requiresNetworkConnectivity=true
        request.requiresExternalPower=false
        request.earliestBeginDate=Date().addingTimeInterval(15*60)
        try BGTaskScheduler.shared.submit(request)
    }
    func cancel(){BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)}
}
#endif
