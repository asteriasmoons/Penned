import Foundation
import GRDB

// Installed only by a future authorized AppDatabase migration. No new database is opened.
nonisolated struct RailwayCheckpoint:Sendable {
    let cursor:String
    let pendingAck:String?
    let snapshotID:String?
    let snapshotCursor:String?
    let snapshotAfter:String
    let initialized:Bool
    let paused:Bool
}
nonisolated struct RailwayQueuedBatch:Sendable {
    let id:String
    let atomic:Bool
    let mutations:[RailwayMutation]
}
nonisolated protocol RailwayRowApplying:Sendable {
    // Called within the very same scoped GRDB transaction as mirror/cursor/outbox changes.
    func apply(_ records:[RailwayRecord],in db:Database,libraryID:String)throws
}
nonisolated final class RailwayJournal:@unchecked Sendable {
    private let database:AppDatabase
    let libraryID:String
    let deviceID:String
    private let applier:any RailwayRowApplying
    init(database:AppDatabase,libraryID:String,deviceID:String,applier:any RailwayRowApplying)throws{
        guard database.libraryID==libraryID,libraryID != "*",libraryID != "local",!deviceID.isEmpty else{throw RailwayError.accountMismatch}
        self.database=database;self.libraryID=libraryID;self.deviceID=deviceID;self.applier=applier
    }
    static func install(in db:Database)throws{
        try db.execute(sql:"""
        CREATE TABLE railwayLocalBinding (libraryID TEXT PRIMARY KEY NOT NULL,deviceID TEXT NOT NULL);
        CREATE TABLE railwayNativeRowOutbox (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,batchID TEXT NOT NULL,payload BLOB NOT NULL,createdAt DOUBLE NOT NULL,PRIMARY KEY(libraryID,deviceID,batchID));
        CREATE TABLE railwayCheckpoint (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,cursor TEXT NOT NULL DEFAULT '0',pendingAck TEXT,snapshotID TEXT,snapshotCursor TEXT,snapshotAfter TEXT NOT NULL DEFAULT '0',reconcileThrough TEXT NOT NULL DEFAULT '0',initialized INTEGER NOT NULL DEFAULT 0,paused INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(libraryID,deviceID));
        CREATE TABLE railwayOutbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT,libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,batchID TEXT NOT NULL,atomicBatch INTEGER NOT NULL,mutationID TEXT NOT NULL,payload BLOB NOT NULL,targets BLOB NOT NULL,transferDependencies BLOB NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,retryAfter DOUBLE NOT NULL DEFAULT 0,lastError TEXT,UNIQUE(libraryID,deviceID,mutationID));
        CREATE INDEX railwayOutboxReady ON railwayOutbox(libraryID,deviceID,sequence);
        CREATE TABLE railwayMirror (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(libraryID,deviceID,recordName));
        CREATE TABLE railwaySnapshotStage (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,snapshotID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(libraryID,deviceID,snapshotID,recordName));
        CREATE TABLE railwayReceipt (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,mutationID TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(libraryID,deviceID,mutationID));
        CREATE TABLE railwayRecovery (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,createdAt DOUBLE NOT NULL,PRIMARY KEY(libraryID,deviceID,recordName));
        CREATE TABLE railwayDeferredApply (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(libraryID,deviceID,recordName));
        CREATE TABLE railwayTransfer (libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,transferID TEXT NOT NULL,payload BLOB NOT NULL,status TEXT NOT NULL,PRIMARY KEY(libraryID,deviceID,transferID));
        CREATE TABLE railwayPinnedAsset (libraryID TEXT NOT NULL,path TEXT NOT NULL,PRIMARY KEY(libraryID,path));
        CREATE TABLE railwayMigrationState (libraryID TEXT PRIMARY KEY NOT NULL,payload BLOB NOT NULL);
        CREATE TABLE railwayMigrationLog (sequence INTEGER PRIMARY KEY AUTOINCREMENT,libraryID TEXT NOT NULL,occurredAt DOUBLE NOT NULL,event TEXT NOT NULL,rows INTEGER,assets INTEGER,code TEXT);
        """)
    }
    private func check(_ db:Database)throws{
        guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
        guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM libraries WHERE id=? AND ownerKey IS NOT NULL)",arguments:[libraryID]) == true else{throw RailwayError.accountMismatch}
    }
    private func ensure(_ db:Database)throws{
        try check(db);try db.execute(sql:"INSERT OR IGNORE INTO railwayCheckpoint(libraryID,deviceID) VALUES (?,?)",arguments:[libraryID,deviceID])
    }
    // Domain saves must call this in the existing AppDatabase.write transaction; never enqueue after commit.
    func enqueue(in db:Database,mutations:[RailwayMutation],targets:[[RailwayRecordKey]],atomic:Bool=true,batchID:String=UUID().uuidString,transferIDs:[String]=[])throws{
        try ensure(db)
        guard !mutations.isEmpty,mutations.count<=100,mutations.count==targets.count,Set(mutations.map(\.id)).count==mutations.count else{throw RailwayError.invalidParameter}
        for (index,mutation) in mutations.enumerated(){
            guard !targets[index].isEmpty else{throw RailwayError.invalidParameter}
            let payload=try RailwayJSON.encoder.encode(mutation),keys=try RailwayJSON.encoder.encode(targets[index]),transfers=try RailwayJSON.encoder.encode(transferIDs)
            try db.execute(sql:"INSERT INTO railwayOutbox(libraryID,deviceID,batchID,atomicBatch,mutationID,payload,targets,transferDependencies) VALUES (?,?,?,?,?,?,?,?)",arguments:[libraryID,deviceID,batchID,atomic,mutation.id,payload,keys,transfers])
        }
    }
    func base(in db:Database,key:RailwayRecordKey)throws->RailwayBase{
        try check(db)
        let pending=try Row.fetchAll(db,sql:"SELECT mutationID,targets FROM railwayOutbox WHERE libraryID=? AND deviceID=? ORDER BY sequence DESC",arguments:[libraryID,deviceID])
        for row in pending{
            let keys=try JSONDecoder().decode([RailwayRecordKey].self,from:row["targets"])
            if keys.contains(key){return .init(resource:key.resource,key:key.key,revision:"after:"+(row["mutationID"] as String))}
        }
        let data=try Data.fetchOne(db,sql:"SELECT payload FROM railwayMirror WHERE libraryID=? AND deviceID=? AND recordName=?",arguments:[libraryID,deviceID,key.stable])
        let record=try data.map{try JSONDecoder().decode(RailwayRecord.self,from:$0)}
        var revision=record?.revision
        for bytes in try Data.fetchAll(db,sql:"SELECT payload FROM railwayReceipt WHERE libraryID=? AND deviceID=? ORDER BY rowid DESC",arguments:[libraryID,deviceID]){
            let receipt=try JSONDecoder().decode(RailwayOutcome.self,from:bytes)
            if let matching=receipt.changes?.first(where:{$0.resource==key.resource && $0.key==key.key}){
                if let current=revision { if try RailwayCursor(matching.revision)>RailwayCursor(current){revision=matching.revision} } else { revision=matching.revision }
                break
            }
        }
        return .init(resource:key.resource,key:key.key,revision:revision)
    }
    func checkpoint()throws->RailwayCheckpoint{
        try database.writeMetadata{db in
            try ensure(db)
            guard let r=try Row.fetchOne(db,sql:"SELECT * FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])else{throw RailwayError.invalidResponse}
            return .init(cursor:r["cursor"],pendingAck:r["pendingAck"],snapshotID:r["snapshotID"],snapshotCursor:r["snapshotCursor"],snapshotAfter:r["snapshotAfter"],initialized:r["initialized"],paused:r["paused"])
        }
    }
    func setPaused(_ paused:Bool)throws{try database.writeMetadata{db in try ensure(db);try db.execute(sql:"UPDATE railwayCheckpoint SET paused=? WHERE libraryID=? AND deviceID=?",arguments:[paused,libraryID,deviceID])}}
    func nextBatch()throws->RailwayQueuedBatch?{
        try database.read{db in
            try check(db)
            guard let first=try Row.fetchOne(db,sql:"SELECT batchID,atomicBatch,retryAfter,transferDependencies FROM railwayOutbox WHERE libraryID=? AND deviceID=? ORDER BY sequence LIMIT 1",arguments:[libraryID,deviceID]),(first["retryAfter"] as Double)<=Date().timeIntervalSince1970 else{return nil}
            let required=try JSONDecoder().decode([String].self,from:first["transferDependencies"])
            for transfer in required{
                guard try String.fetchOne(db,sql:"SELECT status FROM railwayTransfer WHERE libraryID=? AND deviceID=? AND transferID=?",arguments:[libraryID,deviceID,transfer])=="completed"else{return nil}
            }
            let id:String=first["batchID"]
            let rows=try Row.fetchAll(db,sql:"SELECT payload FROM railwayOutbox WHERE libraryID=? AND deviceID=? AND batchID=? ORDER BY sequence",arguments:[libraryID,deviceID,id])
            return .init(id:id,atomic:first["atomicBatch"],mutations:try rows.map{try JSONDecoder().decode(RailwayMutation.self,from:$0["payload"])})
        }
    }
    func delay(_ batch:RailwayQueuedBatch,code:String)throws{
        try database.writeMetadata{db in
            try check(db)
            let attempts=try Int.fetchOne(db,sql:"SELECT max(attempts) FROM railwayOutbox WHERE libraryID=? AND deviceID=? AND batchID=?",arguments:[libraryID,deviceID,batch.id]) ?? 0
            let retry=Date().timeIntervalSince1970+min(300,pow(2,Double(min(attempts,8))))+Double.random(in:0...1)
            try db.execute(sql:"UPDATE railwayOutbox SET attempts=attempts+1,retryAfter=?,lastError=? WHERE libraryID=? AND deviceID=? AND batchID=?",arguments:[retry,code,libraryID,deviceID,batch.id])
        }
    }
    func retryNow()throws{try database.writeMetadata{db in try check(db);try db.execute(sql:"UPDATE railwayOutbox SET retryAfter=0 WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])}}
    private func pendingKeys(_ db:Database)throws->Set<String>{
        let values=try Data.fetchAll(db,sql:"SELECT targets FROM railwayOutbox WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
        return Set(try values.flatMap{try JSONDecoder().decode([RailwayRecordKey].self,from:$0)}.map(\.stable))
    }
    private func reconcile(_ records:[RailwayRecord],in db:Database)throws{
        // Stage complete remote transaction groups, not individual pieces of a
        // graph that may depend on a still-pending local edit.
        for r in records{
            _ = try RailwayCursor(r.revision)
            let key=r.key.stable
            let bytes=try RailwayJSON.encoder.encode(r)
            if let old=try Data.fetchOne(db,sql:"SELECT payload FROM railwayMirror WHERE libraryID=? AND deviceID=? AND recordName=?",arguments:[libraryID,deviceID,key]){
                let previous=try JSONDecoder().decode(RailwayRecord.self,from:old)
                if try RailwayCursor(previous.revision)>RailwayCursor(r.revision){continue}
            }
            try db.execute(sql:"INSERT INTO railwayMirror VALUES(?,?,?,?) ON CONFLICT(libraryID,deviceID,recordName) DO UPDATE SET payload=excluded.payload",arguments:[libraryID,deviceID,key,bytes])
            try db.execute(sql:"INSERT INTO railwayDeferredApply VALUES(?,?,?,?) ON CONFLICT(libraryID,deviceID,recordName) DO UPDATE SET payload=excluded.payload",arguments:[libraryID,deviceID,key,bytes])
        }
    }
    private func flush(in db:Database,through:String)throws->Bool{
        guard try pendingKeys(db).isEmpty, try Int.fetchOne(db,sql:"SELECT count(*) FROM railwayNativeRowOutbox WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])==0 else{return false}
        let barrier=try String.fetchOne(db,sql:"SELECT reconcileThrough FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]) ?? "0"
        guard try RailwayCursor(through)>=RailwayCursor(barrier)else{return false}
        let ready=try Row.fetchAll(db,sql:"SELECT recordName,payload FROM railwayDeferredApply WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
        try applier.apply(try ready.map{try JSONDecoder().decode(RailwayRecord.self,from:$0["payload"])},in:db,libraryID:libraryID)
        try db.execute(sql:"DELETE FROM railwayDeferredApply WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
        return !ready.isEmpty
    }
    func receive(_ response:RailwayPushResponse,batch:RailwayQueuedBatch)throws{
        try database.writeMetadata{db in
            try check(db)
            let expected=Set(batch.mutations.map(\.id))
            let returned=Set(response.results.map(\.id))
            guard returned.isSubset(of:expected),returned.count==response.results.count else{throw RailwayError.invalidResponse}
            for outcome in response.results where outcome.terminal{
                let id=outcome.id
                let receipt=try RailwayJSON.encoder.encode(outcome)
                if outcome.status=="superseded",let payload=try Data.fetchOne(db,sql:"SELECT payload FROM railwayOutbox WHERE libraryID=? AND deviceID=? AND mutationID=?",arguments:[libraryID,deviceID,id]){
                    try db.execute(sql:"INSERT OR IGNORE INTO railwayRecovery VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,"mutation:"+id,payload,Date().timeIntervalSince1970])
                }
                try db.execute(sql:"INSERT OR IGNORE INTO railwayReceipt VALUES(?,?,?,?)",arguments:[libraryID,deviceID,id,receipt])
                try db.execute(sql:"DELETE FROM railwayOutbox WHERE libraryID=? AND deviceID=? AND mutationID=?",arguments:[libraryID,deviceID,id])
                if let versions=outcome.authoritative{try reconcile(versions.map(\.record),in:db)}
            }
            let barrier=try String.fetchOne(db,sql:"SELECT reconcileThrough FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]) ?? "0"
            let next=try RailwayCursor(response.headCursor)>RailwayCursor(barrier) ? response.headCursor:barrier
            try db.execute(sql:"UPDATE railwayCheckpoint SET reconcileThrough=? WHERE libraryID=? AND deviceID=?",arguments:[next,libraryID,deviceID])
            // Do not apply deferred cloud rows from before the receipt. The next
            // durable pull supplies the final server state, then flushes safely.

        }
    }
    func stageSnapshot(_ snapshot:RailwaySnapshot)throws{
        try database.writeMetadata{db in
            try ensure(db)
            let existing=try String.fetchOne(db,sql:"SELECT snapshotID FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
            if existing==snapshot.snapshotID{return}
            try db.execute(sql:"DELETE FROM railwaySnapshotStage WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
            try db.execute(sql:"UPDATE railwayCheckpoint SET snapshotID=?,snapshotCursor=?,snapshotAfter='0',initialized=0 WHERE libraryID=? AND deviceID=?",arguments:[snapshot.snapshotID,snapshot.cursor,libraryID,deviceID])
        }
    }
    func stagePage(_ page:RailwaySnapshotPage,id:String)throws{
        try database.writeMetadata{db in
            try check(db)
            guard try String.fetchOne(db,sql:"SELECT snapshotID FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])==id else{throw RailwayError.staleCheckpoint}
            for row in page.items{try db.execute(sql:"INSERT OR REPLACE INTO railwaySnapshotStage VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,id,row.key.stable,try RailwayJSON.encoder.encode(row)])}
            try db.execute(sql:"UPDATE railwayCheckpoint SET snapshotAfter=? WHERE libraryID=? AND deviceID=?",arguments:[page.nextAfter,libraryID,deviceID])
        }
    }
    @discardableResult func finishSnapshot(_ snapshot:RailwaySnapshot,allowApply:Bool=true)throws->Bool{
        try database.writeMetadata{db in
            try check(db)
            let stage=try Data.fetchAll(db,sql:"SELECT payload FROM railwaySnapshotStage WHERE libraryID=? AND deviceID=? AND snapshotID=?",arguments:[libraryID,deviceID,snapshot.snapshotID])
            guard String(stage.count)==snapshot.itemCount else{throw RailwayError.migrationNotVerified}
            let records=try stage.map{try JSONDecoder().decode(RailwayRecord.self,from:$0)}
            // Never delete an unknown local row. Remove only previously acknowledged identities absent in the fresh snapshot.
            let seen=Set(records.map{$0.key.stable})
            let old=try Data.fetchAll(db,sql:"SELECT payload FROM railwayMirror WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]).map{try JSONDecoder().decode(RailwayRecord.self,from:$0)}
            let absent=old.filter{!seen.contains($0.key.stable) && !$0.isDeleted}.map{RailwayRecord(resource:$0.resource,record_key:$0.record_key,revision:$0.revision,payload:nil,deleted:true,changed_at:$0.changed_at,edit_source:nil,ordinal:nil,cursor:nil)}
            try reconcile(absent+records,in:db)
            let changed=allowApply ? try flush(in:db,through:snapshot.cursor):false
            try db.execute(sql:"UPDATE railwayCheckpoint SET cursor=?,pendingAck=?,initialized=1 WHERE libraryID=? AND deviceID=?",arguments:[snapshot.cursor,"snapshot:"+snapshot.snapshotID,libraryID,deviceID])
            return changed
        }
    }
    @discardableResult func apply(_ page:RailwayPull,after:String,allowApply:Bool=true)throws->Bool{
        try database.writeMetadata{db in
            try check(db)
            guard try String.fetchOne(db,sql:"SELECT cursor FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])==after,try RailwayCursor(page.nextCursor)>=RailwayCursor(after) else{throw RailwayError.staleCheckpoint}
            // Transactions are applied in ledger order; durable cursor advances only after the complete page commits.
            for transaction in page.transactions{try reconcile(transaction.changes,in:db)}
            let changed=allowApply ? try flush(in:db,through:page.nextCursor):false
            try db.execute(sql:"UPDATE railwayCheckpoint SET cursor=?,pendingAck=? WHERE libraryID=? AND deviceID=?",arguments:[page.nextCursor,page.nextCursor,libraryID,deviceID])
            return changed
        }
    }
    func didAcknowledge(_ cursor:String,pending:String)throws{
        try database.writeMetadata{db in
            try check(db)
            guard let row=try Row.fetchOne(db,sql:"SELECT cursor,pendingAck FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]),(row["cursor"] as String)==cursor,(row["pendingAck"] as String?)==pending else{throw RailwayError.staleCheckpoint}
            try db.execute(sql:"UPDATE railwayCheckpoint SET pendingAck=NULL,snapshotID=NULL,snapshotCursor=NULL,snapshotAfter='0' WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
            try db.execute(sql:"DELETE FROM railwaySnapshotStage WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
        }
    }
    func resetSnapshot()throws{
        try database.writeMetadata{db in try check(db);try db.execute(sql:"UPDATE railwayCheckpoint SET initialized=0,pendingAck=NULL,snapshotID=NULL,snapshotCursor=NULL,snapshotAfter='0' WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]);try db.execute(sql:"DELETE FROM railwaySnapshotStage WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])}
    }
    func receiveNativeRecordBatch(_ batch:RailwayNativePendingBatch,receipt:RailwayMigrationReceipt)throws{
        try database.writeMetadata{db in
            try check(db)
            guard receipt.libraryID==libraryID,receipt.migrationID==batch.id,["applied","superseded"].contains(receipt.status ?? "")else{throw RailwayError.invalidResponse}
            if receipt.status=="superseded"{
                try db.execute(sql:"INSERT OR IGNORE INTO railwayRecovery VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,"native:"+batch.id,try RailwayJSON.encoder.encode(batch),Date().timeIntervalSince1970])
                try reconcile(receipt.authoritative ?? [],in:db)
            }
            let barrier=try String.fetchOne(db,sql:"SELECT reconcileThrough FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]) ?? "0"
            let next=try RailwayCursor(receipt.headCursor)>RailwayCursor(barrier) ? receipt.headCursor:barrier
            try db.execute(sql:"UPDATE railwayCheckpoint SET reconcileThrough=? WHERE libraryID=? AND deviceID=?",arguments:[next,libraryID,deviceID])
            try db.execute(sql:"DELETE FROM railwayNativeRowOutbox WHERE libraryID=? AND deviceID=? AND batchID=?",arguments:[libraryID,deviceID,batch.id])
        }
    }
    func localDiagnostics()throws->RailwayLocalDiagnostics{
        try database.read{db in
            try check(db)
            let pending=try Int.fetchOne(db,sql:"SELECT (SELECT count(*) FROM railwayOutbox WHERE libraryID=? AND deviceID=?)+(SELECT count(*) FROM railwayNativeRowOutbox WHERE libraryID=? AND deviceID=?)",arguments:[libraryID,deviceID,libraryID,deviceID]) ?? 0
            let failed=try Int.fetchOne(db,sql:"SELECT count(*) FROM railwayOutbox WHERE libraryID=? AND deviceID=? AND lastError IS NOT NULL",arguments:[libraryID,deviceID]) ?? 0
            let transfers=try Int.fetchOne(db,sql:"SELECT count(*) FROM railwayTransfer WHERE libraryID=? AND deviceID=? AND status<>'completed'",arguments:[libraryID,deviceID]) ?? 0
            let deferred=try Int.fetchOne(db,sql:"SELECT count(*) FROM railwayDeferredApply WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]) ?? 0
            let recovery=try Int.fetchOne(db,sql:"SELECT count(*) FROM railwayRecovery WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID]) ?? 0
            let row=try Row.fetchOne(db,sql:"SELECT cursor,paused FROM railwayCheckpoint WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
            return .init(pendingMutations:pending,failedOperations:failed,pendingTransfers:transfers,deferredRecords:deferred,recoveryRecords:recovery,paused:row?["paused"] ?? false,cursor:row?["cursor"] ?? "0")
        }
    }
}
