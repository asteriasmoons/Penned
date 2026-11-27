import Foundation
import GRDB

// All authored tables, including the native default Space record. Derived tags,
// search indexes, task references and previews are rebuilt rather than transmitted.
nonisolated enum RailwayNativeRecordMapping {
    static let authored=["spaces","folders","templates","documents","documentSnapshots","attachments","documentStyles","collections","collectionFields","collectionViews","collectionEntries","collectionValues","taskCompletions","dailyNoteSettings","calendarEventNotes","librarySpaceDefaults"]
    static func ownerExpression(_ table:String,alias:String)->String?{
        if table=="librarySpaceDefaults"{return alias+".libraryID"}
        return LibraryAccess.owners[table]?.replacingOccurrences(of:"$",with:alias)
    }
    static func convert(_ native:SyncRow,deleted:Bool,changedAt:String)throws->RailwayMigrationRow{
        guard authored.contains(native.table),let def=RailwayNativeSchema.tables[native.table] else{throw RailwayError.unsupportedRecord}
        let key=try Dictionary(uniqueKeysWithValues:def.keys.map{k in guard let value=native.values[k]?.text else{throw RailwayError.invalidResponse};return(k,value)})
        if deleted{return .init(resource:native.table,key:key,changedAt:changedAt,deleted:true,payload:nil)}
        var fields:[String:RailwayJSON]=[:]
        for (column,type) in def.types{
            guard let value=native.values[column]else{throw RailwayError.unsupportedRecord}
            fields[column]=try RailwayGRDBConversion.wireValue(value.databaseValue,type:type)
        }
        return .init(resource:native.table,key:key,changedAt:changedAt,deleted:false,payload:.object(fields))
    }
    static func mirroredAssetPaths(in db:Database,libraryID:String,deviceID:String)throws->Set<String>{
        let records=try Data.fetchAll(db,sql:"SELECT payload FROM railwayMirror WHERE libraryID=? AND deviceID=?",arguments:[libraryID,deviceID])
        return try records.reduce(into:Set<String>()){paths,bytes in
            let record=try JSONDecoder().decode(RailwayRecord.self,from:bytes)
            guard !record.isDeleted,record.revision != "0" else{return}
            paths.formUnion(assetPaths(.init(resource:record.resource,key:record.record_key,changedAt:record.changed_at ?? "1970-01-01T00:00:00Z",deleted:false,payload:record.payload)))
        }
    }
    static func assetPaths(_ row:RailwayMigrationRow)->Set<String>{
        guard let p=row.payload else{return []}
        var paths=Set<String>()
        func add(_ value:RailwayJSON?){if let s=value?.string,AttachmentStore.validRelativePath(s){paths.insert(s)}}
        func nodes(_ root:RailwayJSON?){
            guard let root else{return}
            let attrs=root["attrs"]
            switch root["type"]?.string{
            case "attachment":add(attrs?["file"]?["relativePath"]);add(attrs?["file"]?["previewPath"])
            case "plainCallout":add(attrs?["clipSource"]?["file"]?["relativePath"]);add(attrs?["clipSource"]?["file"]?["previewPath"])
            case "divider","iconCallout","countdown":add(attrs?["imagePath"])
            default:break
            }
            if case .array(let children)?=root["content"]{for child in children{nodes(child)}}
        }
        func appearance(_ value:RailwayJSON?){add(value?["editorBackground"]?["imagePath"]);add(value?["innerPageBackground"]?["imagePath"])}
        switch row.resource{
        case "attachments":add(p["relativePath"]);add(p["thumbnailRelativePath"])
        case "documents":add(p["cover"]);appearance(p["appearanceJSON"]);nodes(p["tipTapJSON"])
        case "templates","documentSnapshots":nodes(p["tipTapJSON"])
        case "documentStyles":add(p["styleJSON"]?["cover"]);appearance(p["styleJSON"]?["appearance"])
        default:break
        }
        return paths
    }
}
nonisolated struct RailwayNativePendingBatch:Codable,Sendable{
    let id:String;let package:RailwayMigrationPackage
}
// Install only in the later authorized native database migration. These triggers
// are inactive unless a scoped save opens a capture context. They preserve the
// actual native IDs and group all authored writes in the existing transaction.
nonisolated final class RailwayNativeRecordCapture:@unchecked Sendable{
    private let database:AppDatabase
    private let attachments:AttachmentStore
    private let staging:URL
    let libraryID:String
    let deviceID:String
    init(database:AppDatabase,attachments:AttachmentStore,staging:URL,deviceID:String)throws{
        guard database.libraryID != "*",database.libraryID != "local" else{throw RailwayError.accountMismatch}
        self.database=database;self.attachments=attachments;self.staging=staging;self.libraryID=database.libraryID;self.deviceID=deviceID
    }
    // Persisted cutover state is the durable activation fence. Binding a user
    // or creating the new tables alone is not permission to capture content.
    static func preparedAll(database:AppDatabase,in db:Database)throws->[RailwayNativeRecordCapture]{
        if database.libraryID=="*"{
            guard try LibraryAccess.current(in:db)=="*" else{throw RailwayError.accountMismatch}
            let libraries=try String.fetchAll(db,sql:"SELECT libraryID FROM railwayMigrationState ORDER BY libraryID")
            return try libraries.compactMap{try prepared(database:database.scoped(to:$0),in:db)}
        }
        return try prepared(database:database,in:db).map{[$0]} ?? []
    }
    static func prepared(database:AppDatabase,in db:Database)throws->RailwayNativeRecordCapture?{
        let libraryID=database.libraryID
        guard libraryID != "*",libraryID != LibraryRecord.localID,
              try LibraryAccess.allows(libraryID,in:db),
              try Int.fetchOne(db,sql:"SELECT remote FROM librarySyncControl")==0,
              let bytes=try Data.fetchOne(db,sql:"SELECT payload FROM railwayMigrationState WHERE libraryID=?",arguments:[libraryID]) else{return nil}
        let state=try JSONDecoder().decode(RailwayMigrationState.self,from:bytes)
        guard state.phase == .cutover else{return nil}
        guard state.libraryID==libraryID,RailwayAccountSession.libraryID(ownerKey:state.ownerKey)==libraryID,
              try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[libraryID])==state.ownerKey,
              let receipt=state.receipt,receipt.libraryID==libraryID,receipt.verified,receipt.pending==0,receipt.status=="applied",
              let deviceID=try String.fetchOne(db,sql:"SELECT deviceID FROM railwayLocalBinding WHERE libraryID=?",arguments:[libraryID]),!deviceID.isEmpty else{throw RailwayError.migrationNotVerified}
        try RailwayMigrationGate.validate(expected:receipt.manifest,verified:receipt.manifest,pending:receipt.pending)
        _ = try RailwayCursor(receipt.headCursor)
        let storage=try database.railwayCaptureStorage()
        return try .init(database:database,attachments:storage.attachments,staging:storage.staging,deviceID:deviceID)
    }
    func discardStaging(batchID:String){
        guard UUID(uuidString:batchID) != nil else{return}
        try? FileManager.default.removeItem(at:staging.appendingPathComponent(batchID,isDirectory:true))
    }
    static func install(in db:Database)throws{
        try db.execute(sql:"""
        CREATE TABLE railwayNativeCaptureContext(libraryID TEXT PRIMARY KEY NOT NULL,deviceID TEXT NOT NULL,batchID TEXT NOT NULL,changedAt TEXT NOT NULL);
        CREATE TABLE railwayNativeCaptured(libraryID TEXT NOT NULL,deviceID TEXT NOT NULL,batchID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,deleted INTEGER NOT NULL,changedAt TEXT NOT NULL,PRIMARY KEY(libraryID,deviceID,batchID,recordName));
        """)
        for table in RailwayNativeRecordMapping.authored{
            let cols=try db.columns(in:table).map(\.name)
            for event in ["INSERT","UPDATE","DELETE"]{
                let row=event=="DELETE" ? "OLD":"NEW"
                guard let owner=RailwayNativeRecordMapping.ownerExpression(table,alias:row)else{throw RailwayError.unsupportedRecord}
                let fields=cols.map{"'\($0)',\(row).\"\($0)\""}.joined(separator:",")
                let payload="penned_sync_row('\(table)',\(fields))"
                // The default-Space table is not in the old CloudKit journal;
                // build its native SyncRow with a registered dedicated function.
                let data=table=="librarySpaceDefaults" ? "railway_default_row(\(row).libraryID,\(row).spaceID)":payload
                let name=table=="librarySpaceDefaults" ? "'librarySpaceDefaults:'||\(row).libraryID":"penned_sync_name(\(data))"
                let resolved="COALESCE(\(owner),(SELECT libraryID FROM librarySyncItems WHERE recordName=\(name) LIMIT 1),penned_library())"
                let changed=event=="UPDATE" ? " AND ("+cols.filter{$0 != "lastOpenedAt"}.map{"OLD.\"\($0)\" IS NOT NEW.\"\($0)\""}.joined(separator:" OR ")+")":""
                try db.execute(sql:"""
                CREATE TRIGGER railway_capture_\(table)_\(event) AFTER \(event) ON "\(table)"
                WHEN (SELECT remote FROM librarySyncControl)=0 AND EXISTS(SELECT 1 FROM railwayNativeCaptureContext WHERE libraryID=\(resolved))\(changed)
                BEGIN
                  INSERT INTO railwayNativeCaptured(libraryID,deviceID,batchID,recordName,payload,deleted,changedAt)
                  SELECT libraryID,deviceID,batchID,\(name),\(data),\(event=="DELETE" ? 1:0),changedAt FROM railwayNativeCaptureContext WHERE libraryID=\(resolved)
                  ON CONFLICT(libraryID,deviceID,batchID,recordName) DO UPDATE SET payload=excluded.payload,deleted=excluded.deleted,changedAt=excluded.changedAt;
                END
                """)
            }
        }
    }
    static func configure(_ db:Database){
        db.add(function:DatabaseFunction("railway_default_row",argumentCount:2,pure:true){args->Data? in
            guard let library=String.fromDatabaseValue(args[0])else{return nil}
            return try SyncRow(table:"librarySpaceDefaults",values:["libraryID":.text(library),"spaceID":SyncValue(args[1])]).encoded
        })
    }
    // Future AppDatabase.write hook: begin before the native repository write,
    // finish after native derived-index reconciliation but before the same COMMIT.
    func begin(in db:Database,changedAt:String=RailwayJSON.timestamp())throws->String{
        guard try LibraryAccess.allows(libraryID,in:db),try String.fetchOne(db,sql:"SELECT deviceID FROM railwayLocalBinding WHERE libraryID=?",arguments:[libraryID])==deviceID else{throw RailwayError.accountMismatch}
        let id=UUID().uuidString
        try db.execute(sql:"INSERT INTO railwayNativeCaptureContext VALUES(?,?,?,?)",arguments:[libraryID,deviceID,id,changedAt])
        return id
    }
    func finish(in db:Database,batchID:String)throws{
        guard try LibraryAccess.allows(libraryID,in:db) else{throw RailwayError.accountMismatch}
        let rows=try Row.fetchAll(db,sql:"SELECT payload,deleted,changedAt FROM railwayNativeCaptured WHERE libraryID=? AND deviceID=? AND batchID=? ORDER BY recordName",arguments:[libraryID,deviceID,batchID])
        let mapped=try rows.map{try RailwayNativeRecordMapping.convert(JSONDecoder().decode(SyncRow.self,from:$0["payload"]),deleted:$0["deleted"],changedAt:$0["changedAt"])}
        if !mapped.isEmpty{
            let paths=Set(mapped.flatMap{RailwayNativeRecordMapping.assetPaths($0)})
            let directory=staging.appendingPathComponent(batchID,isDirectory:true)
            if !paths.isEmpty {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
            var assets:[RailwayMigrationAsset]=[]
            var remotePaths:Set<String>?
            for path in paths.sorted(){
                let source=try attachments.validatedFileURL(relativePath:path)
                if !FileManager.default.fileExists(atPath:source.path){
                    if remotePaths==nil {remotePaths=try RailwayNativeRecordMapping.mirroredAssetPaths(in:db,libraryID:libraryID,deviceID:deviceID)}
                    guard remotePaths?.contains(path)==true else{throw RailwayError.corruptFile}
                    continue
                }
                let target=directory.appendingPathComponent(path)
                // Retain immutable bytes even if the user replaces or deletes the
                // original before the device reconnects.
                // Independent file bytes survive in-place edits and replacement.
                try FileManager.default.copyItem(at:source,to:target)
                let digest=try RailwayFileIntegrity.digest(target)
                assets.append(.init(path:path,sha256:digest.sha256,bytes:digest.bytes))
            }
            let package=RailwayMigrationPackage(rows:mapped,assets:assets)
            let batch=RailwayNativePendingBatch(id:batchID,package:package)
            try db.execute(sql:"INSERT INTO railwayNativeRowOutbox VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,batchID,try RailwayJSON.encoder.encode(batch),Date().timeIntervalSince1970])
        }
        try db.execute(sql:"DELETE FROM railwayNativeCaptured WHERE libraryID=? AND deviceID=? AND batchID=?",arguments:[libraryID,deviceID,batchID])
        try db.execute(sql:"DELETE FROM railwayNativeCaptureContext WHERE libraryID=? AND deviceID=? AND batchID=?",arguments:[libraryID,deviceID,batchID])
    }
    func next()throws->RailwayNativePendingBatch?{
        try database.read{db in
            guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
            return try Data.fetchOne(db,sql:"SELECT payload FROM railwayNativeRowOutbox WHERE libraryID=? AND deviceID=? ORDER BY createdAt,batchID LIMIT 1",arguments:[libraryID,deviceID]).map{try JSONDecoder().decode(RailwayNativePendingBatch.self,from:$0)}
        }
    }
    func stagedFile(batchID:String,path:String)throws->URL{
        guard UUID(uuidString:batchID) != nil,AttachmentStore.validRelativePath(path) else{throw RailwayError.invalidParameter}
        return staging.appendingPathComponent(batchID,isDirectory:true).appendingPathComponent(path)
    }
}
actor RailwayNativeRecordSender {
    private let account:RailwayAccountSession
    private let capture:RailwayNativeRecordCapture
    private let destination:any RailwayMigrationDestination
    private let journal:RailwayJournal
    init(account:RailwayAccountSession,capture:RailwayNativeRecordCapture,destination:any RailwayMigrationDestination,journal:RailwayJournal){
        self.account=account;self.capture=capture;self.destination=destination;self.journal=journal
    }
    func drain()async throws{
        let binding=try await account.binding()
        guard binding.libraryID==capture.libraryID,binding.deviceID==capture.deviceID else{throw RailwayError.accountMismatch}
        for _ in 0..<10{
            try Task.checkCancellation()
            guard let batch=try capture.next()else{return}
            let manifest=try batch.package.manifest()
            var receipt=try await destination.status(id:batch.id)
            if receipt?.verified != true{
                try await destination.begin(id:batch.id,libraryID:binding.libraryID,manifest:manifest)
                for start in stride(from:0,to:batch.package.rows.count,by:50){
                    try await destination.stageRows(id:batch.id,rows:Array(batch.package.rows[start..<min(start+50,batch.package.rows.count)]))
                }
                for asset in batch.package.assets{
                    try await destination.stageAsset(id:batch.id,asset:asset,from:capture.stagedFile(batchID:batch.id,path:asset.path))
                }
                receipt=try await destination.verifyAndCommit(id:batch.id,expected:manifest)
            }
            guard let receipt,receipt.migrationID==batch.id,receipt.libraryID==binding.libraryID,receipt.verified else{throw RailwayError.migrationNotVerified}
            try RailwayMigrationGate.validate(expected:manifest,verified:receipt.manifest,pending:receipt.pending)
            try Task.checkCancellation()
            try journal.receiveNativeRecordBatch(batch,receipt:receipt)
        }
    }
}
