import Foundation
import GRDB
import Testing
@testable import Vellix

nonisolated private struct RailwayFixtureApplier: RailwayRowApplying {
    func apply(_ records:[RailwayRecord],in db:Database,libraryID:String)throws {
        for record in records {
            try db.execute(sql:"INSERT OR REPLACE INTO railwayWorkspaceFixture VALUES (?,?)",
                arguments:[record.key.stable,record.revision])
        }
    }
}

@Suite @MainActor
struct RailwayWorkspaceIntegrationTests {
    @Test func providerSelectionRequiresDurableVerifiedCutover() throws {
        let root=try AppDatabase.makeInMemory()
        let owner="apple:workspace-fixture"
        let library=try LibraryRepository(database:root).accountLibrary(ownerKey:owner)
        let database=root.scoped(to:library.id)
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .legacy)
        let log=try RailwayMigrationLogStore(database:database,libraryID:library.id)
        let manifest=RailwayMigrationManifest(rows:0,assets:0,digest:String(repeating:"a",count:64))
        let receipt=RailwayMigrationReceipt(migrationID:"fixture",libraryID:library.id,manifest:manifest,pending:0,headCursor:"1",verified:true,status:"applied",authoritative:nil)
        var state=RailwayMigrationState(migrationID:"fixture",libraryID:library.id,ownerKey:owner,confirmedAt:RailwayJSON.timestamp(),phase:.verified,package:nil,receipt:receipt)
        try log.save(state,event:"fixture")
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .blocked)
        state.phase = .cutover
        try log.save(state,event:"fixture")
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .railway)
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:"apple:other") == .blocked)
        state.receipt=nil
        try log.save(state,event:"fixture")
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .blocked)
        #expect(RailwayWorkspaceRoute.read(root.scoped(to:"local"),ownerKey:owner) == .local)
    }

    @Test func protectedEditorKeepsRemoteRowsDurableUntilSafeToApply() throws {
        let root=try AppDatabase.makeInMemory()
        let library=try LibraryRepository(database:root).accountLibrary(ownerKey:"apple:editor-fixture")
        let database=root.scoped(to:library.id)
        try database.writeMetadata { db in
            try db.execute(sql:"CREATE TABLE railwayWorkspaceFixture (recordName TEXT PRIMARY KEY,revision TEXT NOT NULL)")
        }
        let device=UUID().uuidString
        let journal=try RailwayJournal(database:database,libraryID:library.id,deviceID:device,applier:RailwayFixtureApplier())
        let row=RailwayRecord(resource:"folders",record_key:["id":"fixture"],revision:"1",payload:.object(["title":.string("Remote")]),deleted:false,changed_at:nil,edit_source:nil,ordinal:nil,cursor:nil)
        let snapshot=RailwaySnapshot(snapshotID:UUID().uuidString,cursor:"1",itemCount:"1",expiresAt:RailwayJSON.timestamp())
        try journal.stageSnapshot(snapshot)
        try journal.stagePage(.init(items:[row],nextAfter:"1",hasMore:false,cursor:"1"),id:snapshot.snapshotID)
        #expect(try !journal.finishSnapshot(snapshot,allowApply:false))
        #expect(try journal.localDiagnostics().deferredRecords == 1)
        #expect(try journal.checkpoint().pendingAck == "snapshot:"+snapshot.snapshotID)
        #expect(try database.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM railwayWorkspaceFixture")} == 0)
        try journal.didAcknowledge("1",pending:"snapshot:"+snapshot.snapshotID)

        // Recreate the journal to prove this is persisted SQLite state, not an
        // in-memory editor queue that vanishes on process termination.
        let reopened=try RailwayJournal(database:database,libraryID:library.id,deviceID:device,applier:RailwayFixtureApplier())
        let empty=RailwayPull(transactions:[],nextCursor:"1",hasMore:false)
        #expect(try reopened.apply(empty,after:"1",allowApply:true))
        #expect(try reopened.localDiagnostics().deferredRecords == 0)
        #expect(try database.read {try String.fetchOne($0,sql:"SELECT revision FROM railwayWorkspaceFixture")} == "1")
        #expect(try !reopened.apply(empty,after:"1",allowApply:true))
    }
}
