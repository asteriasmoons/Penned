import Foundation
import GRDB
import Testing
@testable import Vellix

@Suite @MainActor
struct RailwayBindingCaptureTests {
    @Test func credentialsAreScopedToProviderOwnerAndLibrary() throws {
        let a = try RailwayAccountScope(ownerKey: "apple:fixture-a")
        let b = try RailwayAccountScope(ownerKey: "apple:fixture-b")
        #expect(a.keychainService != b.keychainService)
        #expect(a.libraryID == LibraryRecord.accountID(ownerKey: a.ownerKey))
        #expect(!a.keychainService.contains(a.ownerKey))
        #expect(throws: RailwayError.accountMismatch) {
            try a.validate(RailwaySession(accessToken:"fixture",refreshToken:"fixture",expiresAt:"2027-01-01T00:00:00Z",deviceID:"fixture",libraryID:b.libraryID,ownerKey:b.ownerKey))
        }
    }

    @Test func nativeWriteCaptureStartsOnlyAfterVerifiedCutoverAndIsAtomic() throws {
        let root = try AppDatabase.makeInMemory()
        let owner = "apple:railway-capture-fixture"
        let library = try LibraryRepository(database: root).accountLibrary(ownerKey: owner)
        let scoped = root.scoped(to: library.id)
        let space = try SpaceRepository(database: scoped).create(title: "Before cutover")
        let device = UUID().uuidString
        try scoped.writeMetadata { db in
            try db.execute(sql:"INSERT INTO railwayLocalBinding VALUES (?,?)",arguments:[library.id,device])
        }
        func pending() throws -> [RailwayNativePendingBatch] {
            try scoped.read { db in
                try Data.fetchAll(db,sql:"SELECT payload FROM railwayNativeRowOutbox WHERE libraryID=? ORDER BY rowid",arguments:[library.id]).map { try JSONDecoder().decode(RailwayNativePendingBatch.self,from:$0) }
            }
        }
        try SpaceRepository(database: scoped).rename(id:space.id,title:"Still CloudKit")
        #expect(try pending().isEmpty)
        let manifest = RailwayMigrationManifest(rows:0,assets:0,digest:String(repeating:"a",count:64))
        let receipt = RailwayMigrationReceipt(migrationID:"fixture",libraryID:library.id,manifest:manifest,pending:0,headCursor:"0",verified:true,status:"applied",authoritative:nil)
        let state = RailwayMigrationState(migrationID:"fixture",libraryID:library.id,ownerKey:owner,confirmedAt:RailwayJSON.timestamp(),phase:.cutover,package:nil,receipt:receipt)
        try RailwayMigrationLogStore(database:scoped,libraryID:library.id).save(state,event:"fixture")
        try SpaceRepository(database:scoped).rename(id:space.id,title:"Offline edit")
        let batches = try pending()
        #expect(batches.count == 1)
        #expect(batches.first?.package.rows.first?.payload?["title"]?.string == "Offline edit")
        enum FixtureError: Error {case rollback}
        #expect(throws: FixtureError.rollback) {
            try scoped.write { db in
                try db.execute(sql:"UPDATE spaces SET title='Rolled back' WHERE id=?",arguments:[space.id])
                throw FixtureError.rollback
            }
        }
        #expect(try pending().count == 1)
        #expect(try SpaceRepository(database:scoped).space(id:space.id)?.title == "Offline edit")
        try scoped.writeMetadata { db in
            try db.execute(sql:"UPDATE librarySyncControl SET remote=1")
        }
        try scoped.write { db in
            try db.execute(sql:"UPDATE spaces SET title='Remote edit' WHERE id=?",arguments:[space.id])
        }
        try scoped.writeMetadata { db in try db.execute(sql:"UPDATE librarySyncControl SET remote=0") }
        #expect(try pending().count == 1)
        let other = try LibraryRepository(database:root).accountLibrary(ownerKey:"apple:other-fixture")
        _ = try SpaceRepository(database:root.scoped(to:other.id)).create(title:"Other library")
        #expect(try pending().count == 1)
        try root.scoped(to:"*").write {db in
            try db.execute(sql:"UPDATE spaces SET title='Root-scoped edit' WHERE id=?",arguments:[space.id])
        }
        #expect(try pending().count == 2)
        #expect(try pending().last?.package.rows.first?.payload?["title"]?.string=="Root-scoped edit")
    }

    @Test func automaticMigrationRemainsGated() {
        #expect(!PennedCloudRollout.automaticMigrationEnabled)
        #expect(!PennedCloudRollout.shouldMigrate(enabled:false,accountReady:true,legacy:true,fenced:false,hasEditor:false))
        #expect(!PennedCloudRollout.shouldMigrate(enabled:true,accountReady:false,legacy:true,fenced:false,hasEditor:false))
        #expect(!PennedCloudRollout.shouldMigrate(enabled:true,accountReady:true,legacy:true,fenced:false,hasEditor:true))
        #expect(PennedCloudRollout.shouldMigrate(enabled:true,accountReady:true,legacy:true,fenced:false,hasEditor:false))
    }

    @Test func normalAppleSignInUsesThePublishingCompatibleNonce() throws {
        let challenge=RailwayAppleChallenge(challengeId:UUID().uuidString,nonce:String(repeating:"a",count:64))
        let nonce=try PublishingAppleNonce(cloudChallenge:challenge)
        #expect(nonce.rawValue==challenge.nonce)
        #expect(nonce.hashedValue=="ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        #expect(throws:RailwayError.invalidResponse){
            _ = try PublishingAppleNonce(cloudChallenge:.init(challengeId:"bad",nonce:"bad"))
        }
    }
}
