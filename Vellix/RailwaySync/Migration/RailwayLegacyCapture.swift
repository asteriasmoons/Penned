import Foundation
import GRDB
import CloudKit

// Read-only source capture. Never modifies a native row, CloudKit token, or file.
nonisolated final class RailwayLegacyCapture:@unchecked Sendable {
    private let database:AppDatabase
    private let attachments:AttachmentStore
    private static let derived:Set<String>=["documentTasks","documentTaskReferences","documentTagRecords","taggedBlocks","documentTagOccurrences"]
    init(database:AppDatabase,attachments:AttachmentStore){self.database=database;self.attachments=attachments}
    private func ownerExpression(_ table:String)->String?{
        table=="librarySpaceDefaults" ? "t.libraryID":LibraryAccess.owners[table]?.replacingOccurrences(of:"$",with:"t")
    }
    private func dates(_ row:[String:RailwayJSON])->String{
        // Never pretend capture time is the original edit time for an old record.
        for key in ["updatedAt","createdAt","trashedAt"]{if let value=row[key]?.string,(try? RailwayJSON.date(value)) != nil{return value}}
        return "1970-01-01T00:00:00.000Z"
    }
    private func collectPaths(_ value:RailwayJSON,_ paths:inout Set<String>){
        if let object=value.object{
            for (key,item) in object{
                if ["relativePath","previewPath","imagePath","thumbnailRelativePath","cover"].contains(key),let path=item.string,!path.isEmpty{paths.insert(path)}
                else{collectPaths(item,&paths)}
            }
        }else if case .array(let items)=value{for item in items{collectPaths(item,&paths)}}
    }
    func capture(libraryID:String,ownerKey:String)throws->RailwayMigrationPackage{
        guard database.libraryID==libraryID,RailwayAccountSession.libraryID(ownerKey:ownerKey)==libraryID else{throw RailwayError.accountMismatch}
        let captured=try database.read{db->([RailwayMigrationRow],Set<String>) in
            guard try LibraryAccess.current(in:db)==libraryID,
                  try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[libraryID])==ownerKey else{throw RailwayError.accountMismatch}
            var rows:[String:RailwayMigrationRow]=[:],paths=Set<String>()
            for table in RailwayNativeSchema.tables.keys.sorted() where table != "libraries" && !Self.derived.contains(table){
                guard let definition=RailwayNativeSchema.tables[table],let owner=ownerExpression(table),try db.tableExists(table)else{throw RailwayError.unsupportedRecord}
                let source=try Row.fetchAll(db,sql:"SELECT t.* FROM \(RailwayGRDBConversion.quoted(table)) t WHERE \(owner)=?",arguments:[libraryID])
                for record in source{
                    var values:[String:RailwayJSON]=[:]
                    for (column,type) in definition.types{
                        guard record.hasColumn(column)else{throw RailwayError.unsupportedRecord}
                        values[column]=try RailwayGRDBConversion.wireValue(record[column] as DatabaseValue,type:type)
                    }
                    let keys=try Dictionary(uniqueKeysWithValues:definition.keys.map{key in guard let value=values[key]?.string else{throw RailwayError.invalidResponse};return(key,value)})
                    let payload=RailwayJSON.object(values)
                    let row=RailwayMigrationRow(resource:table,key:keys,changedAt:dates(values),deleted:false,payload:payload)
                    rows[row.name]=row
                    paths.formUnion(RailwayNativeRecordMapping.assetPaths(row))
                }
            }
            // CloudKit transport state is excluded from the migrated payload. Its
            // retained deletion identities and timestamps are used only to avoid
            // resurrecting data when an old device migrates after another device.
            for entry in try Row.fetchAll(db,sql:"SELECT payload,systemFields FROM librarySyncItems WHERE libraryID=? AND deleted=1",arguments:[libraryID]){
                let native=try JSONDecoder().decode(SyncRow.self,from:entry["payload"])
                guard let definition=RailwayNativeSchema.tables[native.table],!Self.derived.contains(native.table)else{continue}
                let keys=try Dictionary(uniqueKeysWithValues:definition.keys.map{key in guard let value=native.values[key]?.text else{throw RailwayError.invalidResponse};return(key,value)})
                var timestamp="1970-01-01T00:00:00.000Z"
                if let fields:Data=entry["systemFields"],let coder=try? NSKeyedUnarchiver(forReadingFrom:fields){
                    coder.requiresSecureCoding=true
                    if let record=CKRecord(coder:coder),let date=record.modificationDate{timestamp=RailwayJSON.timestamp(date)}
                    coder.finishDecoding()
                }
                let row=RailwayMigrationRow(resource:native.table,key:keys,changedAt:timestamp,deleted:true,payload:nil)
                if rows[row.name]==nil{rows[row.name]=row}
            }
            return(Array(rows.values).sorted{$0.name<$1.name},paths)
        }
        var manifest:[RailwayMigrationAsset]=[]
        for path in captured.1.sorted(){
            try Task.checkCancellation()
            let url=try attachments.validatedFileURL(relativePath:path)
            let digest=try RailwayFileIntegrity.digest(url)
            manifest.append(.init(path:path,sha256:digest.sha256,bytes:digest.bytes))
        }
        return .init(rows:captured.0,assets:manifest)
    }
}
