import Foundation
import CryptoKit
import GRDB
import os

nonisolated public struct RailwayMigrationManifest:Codable,Equatable,Sendable {
    public let rows:Int
    public let assets:Int
    public let digest:String
    public init(rows:Int,assets:Int,digest:String){self.rows=rows;self.assets=assets;self.digest=digest}
}
nonisolated struct RailwayMigrationRow:Codable,Equatable,Sendable {
    let resource:String;let key:[String:String];let changedAt:String;let deleted:Bool;let payload:RailwayJSON?
    var name:String{RailwayRecordKey(resource:resource,key:key).stable}
    enum CodingKeys:String,CodingKey{case resource,key,changedAt,deleted,payload}
    func encode(to encoder:Encoder)throws{
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(resource,forKey:.resource);try c.encode(key,forKey:.key);try c.encode(changedAt,forKey:.changedAt);try c.encode(deleted,forKey:.deleted)
        if let payload{try c.encode(payload,forKey:.payload)}else{try c.encodeNil(forKey:.payload)}
    }
}
nonisolated struct RailwayMigrationAsset:Codable,Equatable,Sendable {
    let path:String;let sha256:String;let bytes:Int64
}
nonisolated struct RailwayMigrationPackage:Codable,Equatable,Sendable {
    let rows:[RailwayMigrationRow];let assets:[RailwayMigrationAsset]
    func manifest()throws->RailwayMigrationManifest{
        var hash=SHA256()
        // Each stable sorted row and asset is framed by a length and exact canonical byte digest.
        for row in rows.sorted(by:{Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8))}){
            let bytes=try RailwayJSON.encoder.encode(row)
            hash.update(data:Data(("R "+String(bytes.count)+" "+SyncRow.digest(bytes)+"\n").utf8))
        }
        for a in assets.sorted(by:{Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8))}){
            let bytes=try RailwayJSON.encoder.encode(a)
            hash.update(data:Data(("A "+String(bytes.count)+" "+SyncRow.digest(bytes)+"\n").utf8))
        }
        return .init(rows:rows.count,assets:assets.count,digest:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
}
nonisolated enum RailwayMigrationGate {
    static func validate(expected:RailwayMigrationManifest,verified:RailwayMigrationManifest,pending:Int)throws{
        guard expected==verified,expected.rows>=0,expected.assets>=0,expected.digest.count==64,expected.digest.allSatisfy({$0.isASCII&&$0.isHexDigit}),pending==0 else{throw RailwayError.migrationNotVerified}
    }
}
nonisolated struct RailwayMigrationReceipt:Codable,Equatable,Sendable {
    let migrationID:String;let libraryID:String;let manifest:RailwayMigrationManifest;let pending:Int;let headCursor:String;let verified:Bool
    let status:String?
    let authoritative:[RailwayRecord]?
}
// Only the coordinator can create this permit after successful verification and cutover.
nonisolated struct RailwayActivationPermit:Sendable {
    let libraryID:String
    let verified:Bool
    fileprivate init(libraryID:String){self.libraryID=libraryID;self.verified=true}
    // Reconstruct authorization only from a durable, owner-matched cutover.
    static func restore(_ state:RailwayMigrationState,libraryID:String,ownerKey:String)throws->Self{
        guard state.phase == .cutover,state.libraryID==libraryID,state.ownerKey==ownerKey,
              RailwayAccountSession.libraryID(ownerKey:ownerKey)==libraryID,
              let receipt=state.receipt,receipt.libraryID==libraryID,receipt.verified,
              receipt.status=="applied",!receipt.migrationID.isEmpty else{throw RailwayError.migrationNotVerified}
        try RailwayMigrationGate.validate(expected:receipt.manifest,verified:receipt.manifest,pending:receipt.pending)
        _ = try RailwayCursor(receipt.headCursor)
        return .init(libraryID:libraryID)
    }

}
nonisolated enum RailwayMigrationPhase:String,Codable,Sendable {case confirmed,captured,staging,committing,verified,cutover}
nonisolated struct RailwayMigrationState:Codable,Sendable {
    let migrationID:String;let libraryID:String;let ownerKey:String;let confirmedAt:String
    var phase:RailwayMigrationPhase
    var package:RailwayMigrationPackage?
    var receipt:RailwayMigrationReceipt?
}
nonisolated final class RailwayMigrationLogStore:@unchecked Sendable {
    private let database:AppDatabase
    let libraryID:String
    private let logger=Logger(subsystem:Bundle.main.bundleIdentifier ?? "Penned",category:"RailwayMigration")
    init(database:AppDatabase,libraryID:String)throws{
        guard database.libraryID==libraryID,libraryID != "local",libraryID != "*"else{throw RailwayError.accountMismatch}
        self.database=database;self.libraryID=libraryID
    }
    func state()throws->RailwayMigrationState?{
        try database.read{db in
            guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
            return try Data.fetchOne(db,sql:"SELECT payload FROM railwayMigrationState WHERE libraryID=?",arguments:[libraryID]).map{try JSONDecoder().decode(RailwayMigrationState.self,from:$0)}
        }
    }
    func save(_ state:RailwayMigrationState,event:String,rows:Int?=nil,assets:Int?=nil)throws{
        guard state.libraryID==libraryID else{throw RailwayError.accountMismatch}
        try database.writeMetadata{db in
            guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
            try db.execute(sql:"INSERT INTO railwayMigrationState VALUES(?,?) ON CONFLICT(libraryID) DO UPDATE SET payload=excluded.payload",arguments:[libraryID,try RailwayJSON.encoder.encode(state)])
            try db.execute(sql:"INSERT INTO railwayMigrationLog(libraryID,occurredAt,event,rows,assets) VALUES(?,?,?,?,?)",arguments:[libraryID,Date().timeIntervalSince1970,event,rows,assets])
        }
        logger.notice("phase=\(event,privacy:.public) rows=\(rows ?? 0,privacy:.public) assets=\(assets ?? 0,privacy:.public)")
    }
    // Record the irreversible provider switch and remove the write fence in
    // one SQLite transaction. A crash cannot leave legacy enabled after cutover.
    func complete(_ state:RailwayMigrationState)throws->RailwayActivationPermit{
        guard state.phase == .verified,let receipt=state.receipt,let package=state.package,
              receipt.verified,receipt.status=="applied",receipt.libraryID==libraryID,
              receipt.migrationID==state.migrationID else{throw RailwayError.migrationNotVerified}
        try RailwayMigrationGate.validate(expected:package.manifest(),verified:receipt.manifest,pending:receipt.pending)
        var committed=state;committed.phase = .cutover;committed.package=nil
        let permit=try RailwayActivationPermit.restore(committed,libraryID:libraryID,ownerKey:state.ownerKey)
        try database.writeMetadata{db in
            guard try LibraryAccess.current(in:db)==libraryID,
                  try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[libraryID])==state.ownerKey,
                  let device=try String.fetchOne(db,sql:"SELECT deviceID FROM railwayLocalBinding WHERE libraryID=?",arguments:[libraryID]),!device.isEmpty else{throw RailwayError.accountMismatch}
            try RailwayMigrationFence.require(state,in:db)
            for row in package.rows where !row.deleted {
                let provisional=RailwayRecord(resource:row.resource,record_key:row.key,revision:"0",payload:row.payload,deleted:false,changed_at:row.changedAt,edit_source:nil,ordinal:nil,cursor:nil)
                try db.execute(sql:"INSERT OR IGNORE INTO railwayMirror VALUES(?,?,?,?)",arguments:[libraryID,device,provisional.key.stable,try RailwayJSON.encoder.encode(provisional)])
            }
            try db.execute(sql:"DELETE FROM railwayMigrationFence WHERE slot=1 AND libraryID=? AND attemptID=?",arguments:[libraryID,state.migrationID])
            try db.execute(sql:"UPDATE libraries SET syncEnabled=0 WHERE id=?",arguments:[libraryID])
            try db.execute(sql:"UPDATE railwayMigrationState SET payload=? WHERE libraryID=?",arguments:[try RailwayJSON.encoder.encode(committed),libraryID])
            try db.execute(sql:"INSERT INTO railwayMigrationLog(libraryID,occurredAt,event) VALUES(?,?,'cutover_committed')",arguments:[libraryID,Date().timeIntervalSince1970])
        }
        return permit
    }

    func abortPrecommit()throws {
        try database.writeMetadata{db in
            guard let bytes=try Data.fetchOne(db,sql:"SELECT payload FROM railwayMigrationState WHERE libraryID=?",arguments:[libraryID]) else{return}
            let state=try JSONDecoder().decode(RailwayMigrationState.self,from:bytes)
            guard !RailwayMigrationCommitPolicy.mustRetainFence(phase:state.phase.rawValue),state.phase != .cutover else{return}
            if let owner=try RailwayMigrationFence.owner(in:db){
                guard owner==libraryID else{throw RailwayError.accountMismatch}
                try RailwayMigrationFence.require(state,in:db)
                try db.execute(sql:"DELETE FROM railwayMigrationFence WHERE slot=1")
            }
            let reset=RailwayMigrationState(migrationID:UUID().uuidString,libraryID:libraryID,ownerKey:state.ownerKey,confirmedAt:state.confirmedAt,phase:.confirmed,package:nil,receipt:nil)
            try db.execute(sql:"UPDATE railwayMigrationState SET payload=? WHERE libraryID=?",arguments:[try RailwayJSON.encoder.encode(reset),libraryID])
        }
    }
    func log(_ event:String,rows:Int?=nil,assets:Int?=nil,code:String?=nil)throws{
        // Only fixed event names, counts and sanitized error codes; never note contents, paths, tokens or identity.
        try database.writeMetadata{db in
            guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
            try db.execute(sql:"INSERT INTO railwayMigrationLog(libraryID,occurredAt,event,rows,assets,code) VALUES(?,?,?,?,?,?)",arguments:[libraryID,Date().timeIntervalSince1970,event,rows,assets,code])
        }
        logger.notice("event=\(event,privacy:.public) rows=\(rows ?? 0,privacy:.public) assets=\(assets ?? 0,privacy:.public) code=\(code ?? "none",privacy:.public)")
    }
}
// The legacy source remains active until a verified remote commit. A protected
// final fence must suspend local mutations and old-provider imports only for the cutover.
// Implementations use the existing workspace lease and existing CloudKit engine.
nonisolated protocol RailwayLegacyMigrationSource:Sendable {
    func capture(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage
    func fileURL(path:String)async throws->URL
    func beginFinalFence(libraryID:String)async throws
    func captureFinal(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage
    func activateRailway(receipt:RailwayMigrationReceipt)async throws
    func releaseFenceKeepingLegacyActive()async
}
// A server-issued verified receipt is mandatory. The Builder Engine currently
// has no bulk legacy-import server routes; this is a strict, explicit boundary,
// not an invented network endpoint or a client-side success shortcut.
nonisolated protocol RailwayMigrationDestination:Sendable {
    func begin(id:String,libraryID:String,manifest:RailwayMigrationManifest)async throws
    func stageRows(id:String,rows:[RailwayMigrationRow])async throws
    func stageAsset(id:String,asset:RailwayMigrationAsset,from:URL)async throws
    func verifyAndCommit(id:String,expected:RailwayMigrationManifest)async throws->RailwayMigrationReceipt
    func status(id:String)async throws->RailwayMigrationReceipt?
}
actor RailwayMigrationCoordinator {
    private let log:RailwayMigrationLogStore
    private let source:any RailwayLegacyMigrationSource
    private let destination:any RailwayMigrationDestination
    private var busy=false
    init(log:RailwayMigrationLogStore,source:any RailwayLegacyMigrationSource,destination:any RailwayMigrationDestination){self.log=log;self.source=source;self.destination=destination}
    func confirm(ownerKey:String,confirmed:Bool)throws{
        guard confirmed else{throw RailwayError.migrationConfirmationRequired}
        guard RailwayAccountSession.libraryID(ownerKey:ownerKey)==log.libraryID else{throw RailwayError.accountMismatch}
        if let existing=try log.state(){guard existing.ownerKey==ownerKey else{throw RailwayError.accountMismatch};return}
        try log.save(.init(migrationID:UUID().uuidString,libraryID:log.libraryID,ownerKey:ownerKey,confirmedAt:RailwayJSON.timestamp(),phase:.confirmed,package:nil,receipt:nil),event:"confirmed")
    }
    private func stage(_ package:RailwayMigrationPackage,id:String,libraryID:String,commit:Bool=true)async throws->RailwayMigrationReceipt?{
        let manifest=try package.manifest()
        // A retry of the same manifest ID must replay identical immutable rows/assets.
        if let existing=try await destination.status(id:id),existing.verified{
            guard existing.libraryID==libraryID,existing.migrationID==id else{throw RailwayError.accountMismatch}
            try RailwayMigrationGate.validate(expected:manifest,verified:existing.manifest,pending:existing.pending);return existing
        }
        try await destination.begin(id:id,libraryID:libraryID,manifest:manifest)
        let rows=package.rows
        for start in stride(from:0,to:rows.count,by:50){
            try Task.checkCancellation()
            let end=min(start+50,rows.count)
            try await destination.stageRows(id:id,rows:Array(rows[start..<end]))
            try log.log("records_staged",rows:end,assets:0)
        }
        for (index,asset) in package.assets.enumerated(){
            try Task.checkCancellation()
            let file=try await source.fileURL(path:asset.path)
            try RailwayFileIntegrity.verify(file,sha256:asset.sha256,bytes:asset.bytes)
            try await destination.stageAsset(id:id,asset:asset,from:file)
            try log.log("asset_staged",rows:rows.count,assets:index+1)
        }
        guard commit else{return nil}
        let receipt=try await destination.verifyAndCommit(id:id,expected:manifest)
        guard receipt.verified,receipt.libraryID==libraryID,receipt.migrationID==id else{throw RailwayError.migrationNotVerified}
        try RailwayMigrationGate.validate(expected:manifest,verified:receipt.manifest,pending:receipt.pending)
        _ = try RailwayCursor(receipt.headCursor)
        try log.log("verified",rows:manifest.rows,assets:manifest.assets)
        return receipt
    }
    func migrate()async throws->RailwayActivationPermit{
        guard !busy else{throw RailwayError.invalidParameter};busy=true;defer{busy=false}
        guard var state=try log.state()else{throw RailwayError.migrationConfirmationRequired}
        if state.phase == .cutover{return try RailwayActivationPermit.restore(state,libraryID:state.libraryID,ownerKey:state.ownerKey)}
        var fenced=false
        do{
            // One consistent capture, not two uploads of potentially changing
            // attachments. Reuse the persisted package on a crash/retry.
            try await source.beginFinalFence(libraryID:state.libraryID);fenced=true
            if state.package==nil{
                guard !RailwayMigrationCommitPolicy.mustRetainFence(phase:state.phase.rawValue) else{throw RailwayError.migrationNotVerified}
                state.package=try await source.captureFinal(libraryID:state.libraryID,ownerKey:state.ownerKey)
                state.phase = .captured;try log.save(state,event:"captured",rows:state.package?.rows.count,assets:state.package?.assets.count)
            }
            guard let package=state.package else{throw RailwayError.invalidResponse}
            let manifest=try package.manifest()
            if state.phase != .committing && state.phase != .verified{
                state.phase = .staging;try log.save(state,event:"staging")
                _ = try await stage(package,id:state.migrationID,libraryID:state.libraryID,commit:false)
                try Task.checkCancellation()
                // Persist this BEFORE the first commit call. Never resume
                // CloudKit if a commit response could have been lost.
                state.phase = .committing;try log.save(state,event:"commit_pending")
            }
            if state.phase == .committing{
                let receipt:RailwayMigrationReceipt
                if let existing=try await destination.status(id:state.migrationID),existing.verified{receipt=existing}
                else{receipt=try await destination.verifyAndCommit(id:state.migrationID,expected:manifest)}
                guard receipt.verified,receipt.status=="applied",receipt.libraryID==state.libraryID,receipt.migrationID==state.migrationID else{throw RailwayError.migrationNotVerified}
                try RailwayMigrationGate.validate(expected:manifest,verified:receipt.manifest,pending:receipt.pending)
                _ = try RailwayCursor(receipt.headCursor)
                state.receipt=receipt;state.phase = .verified;try log.save(state,event:"final_verified",rows:manifest.rows,assets:manifest.assets)
            }
            guard let receipt=state.receipt else{throw RailwayError.migrationNotVerified}
            try await source.activateRailway(receipt:receipt)
            let permit=try log.complete(state)
            fenced=false
            return permit
        }catch{
            // Consult the durable state, not the last in-memory assignment.
            // If reading it fails, err on the side of retaining the fence.
            if fenced,let saved=try? log.state(),!RailwayMigrationCommitPolicy.mustRetainFence(phase:saved.phase.rawValue),saved.phase != .cutover{
                do{try log.abortPrecommit();await source.releaseFenceKeepingLegacyActive()}catch{}
            }
            try? log.log("retry_required",code:error is CancellationError ? "cancelled":"migration_not_completed")
            throw error
        }
    }
}
