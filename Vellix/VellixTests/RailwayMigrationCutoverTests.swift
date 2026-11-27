import Foundation
import GRDB
import Testing
@testable import Vellix

private enum CutoverFixtureError:Error {case lostResponse,stagingFailed,unexpected}

private actor CutoverFixtureSource:RailwayLegacyMigrationSource {
    let database:AppDatabase
    let owner:String
    private(set) var captures=0
    init(database:AppDatabase,owner:String){self.database=database;self.owner=owner}
    func capture(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage{
        try await captureFinal(libraryID:libraryID,ownerKey:ownerKey)
    }
    func fileURL(path:String)async throws->URL{throw CutoverFixtureError.unexpected}
    func beginFinalFence(libraryID:String)async throws{
        try RailwayMigrationFence.acquire(database:database,ownerKey:owner)
    }
    func captureFinal(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage{
        captures+=1
        return .init(rows:[.init(resource:"folders",key:["id":"fixture"],changedAt:"2026-01-01T00:00:00Z",deleted:true,payload:nil)],assets:[])
    }
    func activateRailway(receipt:RailwayMigrationReceipt)async throws{}
    func releaseFenceKeepingLegacyActive()async{}
}

private actor CutoverFixtureDestination:RailwayMigrationDestination {
    let libraryID:String
    let failStage:Bool
    private var receipt:RailwayMigrationReceipt?
    private(set) var commits=0
    init(libraryID:String,failStage:Bool=false){self.libraryID=libraryID;self.failStage=failStage}
    func begin(id:String,libraryID:String,manifest:RailwayMigrationManifest)async throws{}
    func stageRows(id:String,rows:[RailwayMigrationRow])async throws{
        if failStage{throw CutoverFixtureError.stagingFailed}
    }
    func stageAsset(id:String,asset:RailwayMigrationAsset,from:URL)async throws{}
    func verifyAndCommit(id:String,expected:RailwayMigrationManifest)async throws->RailwayMigrationReceipt{
        commits+=1
        receipt = .init(migrationID:id,libraryID:libraryID,manifest:expected,pending:0,headCursor:"1",verified:true,status:"applied",authoritative:nil)
        throw CutoverFixtureError.lostResponse
    }
    func status(id:String)async throws->RailwayMigrationReceipt?{receipt}
}

@Suite @MainActor
struct RailwayMigrationCutoverTests {
    private func fixture()throws->(AppDatabase,AppDatabase,String,String){
        let root=try AppDatabase.makeInMemory(),owner="apple:cutover-"+UUID().uuidString
        let library=try LibraryRepository(database:root).accountLibrary(ownerKey:owner)
        let database=root.scoped(to:library.id)
        let space=try SpaceRepository(database:database).create(title:"Retained source")
        try database.writeMetadata{db in
            try db.execute(sql:"UPDATE libraries SET syncEnabled=1 WHERE id=?",arguments:[library.id])
            try db.execute(sql:"INSERT INTO railwayLocalBinding VALUES (?,?)",arguments:[library.id,"fixture-device"])
        }
        return (root,database,owner,space.id)
    }

    @Test func lostCommitResponsePreservesFenceAcrossRestartAndSwitchesAtomically() async throws {
        let (root,database,owner,space)=try fixture()
        let log=try RailwayMigrationLogStore(database:database,libraryID:database.libraryID)
        let destination=CutoverFixtureDestination(libraryID:database.libraryID)
        let coordinator=RailwayMigrationCoordinator(log:log,source:CutoverFixtureSource(database:database,owner:owner),destination:destination)
        try await coordinator.confirm(ownerKey:owner,confirmed:true)
        let attempt=try #require(log.state()?.migrationID)
        await #expect(throws:CutoverFixtureError.lostResponse){_ = try await coordinator.migrate()}
        #expect(try log.state()?.phase == .committing)
        #expect(try RailwayMigrationFence.held(database:database))
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .blocked)
        #expect(throws:DatabaseError.self){
            try root.scoped(to:"*").writeMetadata{db in
                try db.execute(sql:"UPDATE spaces SET title='Unsafe' WHERE id=?",arguments:[space])
            }
        }
        let resumedSource=CutoverFixtureSource(database:database,owner:owner)
        let resumed=RailwayMigrationCoordinator(log:log,source:resumedSource,destination:destination)
        let permit=try await resumed.migrate()
        #expect(permit.libraryID==database.libraryID)
        #expect(try log.state()?.phase == .cutover)
        #expect(try log.state()?.receipt?.migrationID==attempt)
        #expect(await resumedSource.captures==0)
        #expect(await destination.commits==1)
        #expect(try !RailwayMigrationFence.held(database:database))
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .railway)
        #expect(try database.read{try Bool.fetchOne($0,sql:"SELECT syncEnabled FROM libraries WHERE id=?",arguments:[database.libraryID])} == false)
        #expect(try SpaceRepository(database:database).space(id:space)?.title=="Retained source")
    }

    @Test func precommitFailureReleasesFenceAndRetainsLegacySource() async throws {
        let (_,database,owner,space)=try fixture()
        let log=try RailwayMigrationLogStore(database:database,libraryID:database.libraryID)
        let destination=CutoverFixtureDestination(libraryID:database.libraryID,failStage:true)
        let coordinator=RailwayMigrationCoordinator(log:log,source:CutoverFixtureSource(database:database,owner:owner),destination:destination)
        try await coordinator.confirm(ownerKey:owner,confirmed:true)
        await #expect(throws:CutoverFixtureError.stagingFailed){_ = try await coordinator.migrate()}
        #expect(try log.state()?.phase == .confirmed)
        #expect(try !RailwayMigrationFence.held(database:database))
        #expect(RailwayWorkspaceRoute.read(database,ownerKey:owner) == .legacy)
        try SpaceRepository(database:database).rename(id:space,title:"Retained edit")
        #expect(try SpaceRepository(database:database).space(id:space)?.title=="Retained edit")
        #expect(await destination.commits==0)
    }
}
