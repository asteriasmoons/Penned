import Foundation
import GRDB

// The allowed columns and types are generated from the Builder Engine's database
// contract. No wire-provided table/column names enter SQL without this whitelist.
nonisolated struct RailwayTableDefinition:Sendable {
    let keys:[String]
    let types:[String:String]
}
nonisolated enum RailwayGRDBConversion {
    static func databaseValue(_ value:RailwayJSON,type:String)throws->DatabaseValue{
        if value == .null{return .null}
        switch type {
        case "jsonb":return String(decoding:try RailwayJSON.encoder.encode(value),as:UTF8.self).databaseValue
        case "text":guard let text=value.string else{throw RailwayError.invalidResponse};return text.databaseValue
        case "boolean":guard case .bool(let b)=value else{throw RailwayError.invalidResponse};return b.databaseValue
        case "bigint":
            if let n=value.integer{return n.databaseValue}
            if let s=value.string,let n=Int64(s){return n.databaseValue}
            throw RailwayError.invalidResponse
        case "double precision":
            if case .number(let n)=value,n.isFinite{return n.databaseValue}
            if let n=value.integer{return Double(n).databaseValue}
            throw RailwayError.invalidResponse
        case "timestamptz":guard let s=value.string else{throw RailwayError.invalidResponse};return try RailwayJSON.date(s).databaseValue
        case "bytea":
            if let s=value.string{
                if s.hasPrefix("\\\\x"){
                    let hex=Array(s.dropFirst(2));guard hex.count%2==0 else{throw RailwayError.invalidResponse}
                    var bytes=Data()
                    for i in stride(from:0,to:hex.count,by:2){guard let byte=UInt8(String(hex[i...i+1]),radix:16)else{throw RailwayError.invalidResponse};bytes.append(byte)}
                    return bytes.databaseValue
                }
                if let bytes=Data(base64Encoded:s){return bytes.databaseValue}
            }
            if let o=value.object,o["type"]?.string=="Buffer",case .array(let values)?=o["data"]{
                let bytes=try values.map{v->UInt8 in guard let n=v.integer,(0...255).contains(n)else{throw RailwayError.invalidResponse};return UInt8(n)}
                return Data(bytes).databaseValue
            }
            throw RailwayError.invalidResponse
        default:throw RailwayError.unsupportedRecord
        }
    }
    static func wireValue(_ value:DatabaseValue,type:String)throws->RailwayJSON{
        if value.isNull{return .null}
        switch type{
        case "jsonb":guard let s=String.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return try JSONDecoder().decode(RailwayJSON.self,from:Data(s.utf8))
        case "text":guard let s=String.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return .string(s)
        case "boolean":guard let b=Bool.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return .bool(b)
        case "bigint":guard let n=Int64.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return .string(String(n))
        case "double precision":guard let n=Double.fromDatabaseValue(value),n.isFinite else{throw RailwayError.invalidResponse};return .number(n)
        case "timestamptz":guard let d=Date.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return .string(RailwayJSON.timestamp(d))
        case "bytea":guard let d=Data.fromDatabaseValue(value)else{throw RailwayError.invalidResponse};return .string(d.base64EncodedString())
        default:throw RailwayError.unsupportedRecord
        }
    }
    static func quoted(_ value:String)->String{"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
}
nonisolated final class RailwayGRDBRows:RailwayRowApplying,@unchecked Sendable {
    private let deviceID:String
    // Editor protection hook must use the same database connection. Do not call AppDatabase recursively.
    private let editorProtected:@Sendable(Database,Set<String>)throws->Bool
    private static let derived:Set<String>=["documentTasks","documentTaskReferences","documentTagRecords","taggedBlocks","documentTagOccurrences"]
    private static let order=["spaces","folders","templates","documents","documentSnapshots","attachments","documentStyles","collections","collectionFields","collectionViews","collectionEntries","collectionValues","taskCompletions","dailyNoteSettings","calendarEventNotes","librarySpaceDefaults"]
    init(deviceID:String,editorProtected:@escaping @Sendable(Database,Set<String>)throws->Bool){self.deviceID=deviceID;self.editorProtected=editorProtected}
    private func definition(_ name:String)throws->RailwayTableDefinition{
        guard let def=RailwayNativeSchema.tables[name] else{throw RailwayError.unsupportedRecord};return def
    }
    private func predicate(_ keys:[String])->String{keys.map{RailwayGRDBConversion.quoted($0)+"=?"}.joined(separator:" AND ")}
    private func args(_ record:RailwayRecord,_ keys:[String])throws->StatementArguments{
        guard Set(record.record_key.keys)==Set(keys) else{throw RailwayError.invalidResponse}
        return StatementArguments(try keys.map{key in guard let v=record.record_key[key],!v.isEmpty else{throw RailwayError.invalidResponse};return v.databaseValue})
    }
    private func owner(_ resource:String,alias:String)->String?{
        if resource=="librarySpaceDefaults"{return alias+".libraryID"}
        return LibraryAccess.owners[resource]?.replacingOccurrences(of:"$",with:alias)
    }
    private func archive(_ row:Row,resource:String,name:String,in db:Database,libraryID:String)throws{
        let payload=try SyncRow(table:resource,row:row).encoded
        let suffix=SyncRow.digest(payload)
        try db.execute(sql:"INSERT OR IGNORE INTO railwayRecovery VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,name+":"+suffix,payload,Date().timeIntervalSince1970])
    }
    private func ownedCurrent(_ record:RailwayRecord,definition:RailwayTableDefinition,in db:Database,libraryID:String)throws->Row?{
        let table=RailwayGRDBConversion.quoted(record.resource),args=try args(record,definition.keys)
        guard let expression=owner(record.resource,alias:"t") else{throw RailwayError.unsupportedRecord}
        let columns=definition.keys.map{"t."+RailwayGRDBConversion.quoted($0)+"=?"}.joined(separator:" AND ")
        if let existing=try Row.fetchOne(db,sql:"SELECT t.*,(\(expression)) AS railwayOwner FROM \(table) t WHERE \(columns)",arguments:args){
            guard (existing["railwayOwner"] as String?)==libraryID else{throw RailwayError.accountMismatch}
            return try Row.fetchOne(db,sql:"SELECT * FROM \(table) WHERE \(predicate(definition.keys))",arguments:args)
        }
        return nil
    }
    private func upsert(_ record:RailwayRecord,in db:Database,libraryID:String,templateInitial:Bool=false)throws{
        let def=try definition(record.resource)
        let table=RailwayGRDBConversion.quoted(record.resource)
        let current=try ownedCurrent(record,definition:def,in:db,libraryID:libraryID)
        guard let body=record.payload?.object else{throw RailwayError.invalidResponse}
        var values:[String:DatabaseValue]=[:]
        let actual=Set(try db.columns(in:record.resource).map(\.name))
        for (column,type) in def.types where actual.contains(column){
            guard let v=body[column]else{throw RailwayError.invalidResponse}
            values[column]=try RailwayGRDBConversion.databaseValue(v,type:type)
        }
        for key in def.keys{guard values[key]==record.record_key[key]?.databaseValue else{throw RailwayError.invalidResponse}}
        if ["spaces","documentStyles","librarySpaceDefaults"].contains(record.resource),body["libraryID"]?.string != libraryID{throw RailwayError.accountMismatch}
        if record.resource=="templates",templateInitial{values["rootDocumentID"] = .null}
        if record.resource=="documents"{
            if let bodyJSON=String.fromDatabaseValue(values["tipTapJSON"] ?? .null){
                let analysis=try TipTapContentAnalyzer.analyze(bodyJSON)
                values["tipTapJSON"]=analysis.canonicalJSON.databaseValue
                values["plainText"]=analysis.plainText.databaseValue;values["previewText"]=analysis.previewText.databaseValue
                values["wordCount"]=analysis.wordCount.databaseValue;values["characterCount"]=analysis.characterCount.databaseValue
                values["estimatedReadingMinutes"]=analysis.estimatedReadingMinutes.databaseValue
            }
            // Opening a note on this device is local presentation state.
            if let current{values["lastOpenedAt"]=current["lastOpenedAt"] as DatabaseValue}
            if let day=body["dailyNoteDate"]?.string,body["isTrashed"] != .bool(true),let space=body["spaceID"]?.string,let id=record.record_key["id"],
               let duplicate=try Row.fetchOne(db,sql:"SELECT d.* FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE s.libraryID=? AND d.spaceID=? AND d.dailyNoteDate=? AND d.isTrashed=0 AND d.id<>?",arguments:[libraryID,space,day,id]){
                // Retain the existing competing draft privately and put the noncanonical
                // local note in trash rather than create another active Daily Note.
                try archive(duplicate,resource:"documents",name:"daily-note",in:db,libraryID:libraryID)
                try db.execute(sql:"UPDATE documents SET isTrashed=1,trashedAt=?,trashBatchID=? WHERE id=?",arguments:[Date(),UUID().uuidString,duplicate["id"] as String])
            }
        }
        if record.resource=="calendarEventNotes",let space=body["spaceID"]?.string,let event=body["eventKey"]?.string,let id=record.record_key["id"],
           let duplicate=try Row.fetchOne(db,sql:"SELECT c.* FROM calendarEventNotes c JOIN spaces s ON s.id=c.spaceID WHERE s.libraryID=? AND c.spaceID=? AND c.eventKey=? AND c.id<>?",arguments:[libraryID,space,event,id]){
            try archive(duplicate,resource:"calendarEventNotes",name:"calendar-link",in:db,libraryID:libraryID)
            try db.execute(sql:"DELETE FROM calendarEventNotes WHERE id=?",arguments:[duplicate["id"] as String])
        }
        let columns=values.keys.sorted(),q=RailwayGRDBConversion.quoted
        let updates=columns.filter{!def.keys.contains($0)}.map{q($0)+"=excluded."+q($0)}.joined(separator:",")
        let conflict=updates.isEmpty ? "DO NOTHING":"DO UPDATE SET "+updates
        try db.execute(sql:"INSERT INTO \(table)(\(columns.map(q).joined(separator:","))) VALUES (\(columns.map{_ in "?"}.joined(separator:","))) ON CONFLICT(\(def.keys.map(q).joined(separator:","))) \(conflict)",arguments:StatementArguments(columns.map{values[$0]!}))
        // Validate resolved ownership after each write, even for tables whose native guard is indirect.
        guard try ownedCurrent(record,definition:def,in:db,libraryID:libraryID) != nil else{throw RailwayError.accountMismatch}
    }
    func apply(_ records:[RailwayRecord],in db:Database,libraryID:String)throws{
        guard !records.isEmpty else{return}
        guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
        let names=Set(records.compactMap{$0.resource=="documents" ? $0.record_key["id"]:$0.payload?["documentID"]?.string})
        guard try !editorProtected(db,names)else{throw RailwayError.staleCheckpoint}
        var newest:[String:RailwayRecord]=[:]
        for record in records where !Self.derived.contains(record.resource){
            if let prior=newest[record.key.stable],try RailwayCursor(prior.revision)>RailwayCursor(record.revision){continue}
            newest[record.key.stable]=record
        }
        let authored=Array(newest.values)
        for r in authored{_ = try definition(r.resource)}
        let sorted=authored.sorted{(Self.order.firstIndex(of:$0.resource) ?? 99)<(Self.order.firstIndex(of:$1.resource) ?? 99)}
        try db.execute(sql:"PRAGMA defer_foreign_keys=ON; UPDATE librarySyncControl SET remote=1; UPDATE spaceOwnershipOperation SET transferring=1")
        // Native graph validates the final state. The template/root-document cycle is completed after the documents.
        let deletions=sorted.filter(\.isDeleted).reversed()
        for r in deletions{
            let def=try definition(r.resource)
            if let current=try ownedCurrent(r,definition:def,in:db,libraryID:libraryID){
                try archive(current,resource:r.resource,name:"tombstone:"+r.key.stable,in:db,libraryID:libraryID)
                try db.execute(sql:"DELETE FROM \(RailwayGRDBConversion.quoted(r.resource)) WHERE \(predicate(def.keys))",arguments:try args(r,def.keys))
            }
        }
        for r in sorted where !r.isDeleted && r.resource != "taskCompletions"{
            try upsert(r,in:db,libraryID:libraryID,templateInitial:r.resource=="templates")
        }
        for r in sorted where !r.isDeleted && r.resource=="templates"{try upsert(r,in:db,libraryID:libraryID)}
        _ = try DocumentTaskIndex.reconcile(in:db)
        for r in sorted where !r.isDeleted && r.resource=="taskCompletions"{try upsert(r,in:db,libraryID:libraryID)}
        try SpaceOwnership.validate(in:db)
        for id in names{
            if let page=try DocumentRecord.fetchOne(db,key:id){try DocumentRepository.upsertSearchIndex(page,in:db)}
            else{try DocumentRepository.deleteSearchIndex(id:id,in:db)}
        }
        _ = try DocumentTagIndex.reconcile(in:db)
        _ = try DocumentPreviewDescriptorIndex.reconcile(in:db)
        try db.execute(sql:"UPDATE spaceOwnershipOperation SET transferring=0; UPDATE librarySyncControl SET remote=0")
    }
}
