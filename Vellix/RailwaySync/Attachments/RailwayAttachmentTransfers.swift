import Foundation
import CryptoKit
import GRDB

nonisolated public struct RailwayAsset:Codable,Equatable,Sendable {public let path:String;public let sha256:String;public let bytes:String;public let contentType:String?}
nonisolated public struct RailwayAssetPage:Codable,Sendable {public let data:[RailwayAsset];public let nextAfter:String;public let hasMore:Bool}
nonisolated public struct RailwayTransferAck:Codable,Sendable {public let id:String;public let status:String}
nonisolated struct RailwayTransferJob:Codable,Sendable {
    let id:String
    let direction:String
    let path:String
    let expectedSHA:String
    let byteCount:Int64
    let filename:String?
    let mimeType:String?
    let spaceID:String?
    let documentID:String?
    let attachmentID:String?
    let replacementBase:String?
    let changedAt:String
    let dependsOn:[String]?
}
nonisolated final class RailwayTransferStore:@unchecked Sendable{
    let database:AppDatabase;let libraryID:String;let deviceID:String
    init(database:AppDatabase,libraryID:String,deviceID:String)throws{
        guard database.libraryID==libraryID,libraryID != "*",libraryID != "local" else{throw RailwayError.accountMismatch}
        self.database=database;self.libraryID=libraryID;self.deviceID=deviceID
    }
    func enqueue(_ job:RailwayTransferJob)throws{
        try database.writeMetadata{db in
            guard try LibraryAccess.current(in:db)==libraryID else{throw RailwayError.accountMismatch}
            let bytes=try RailwayJSON.encoder.encode(job)
            if let old=try Data.fetchOne(db,sql:"SELECT payload FROM railwayTransfer WHERE libraryID=? AND deviceID=? AND transferID=?",arguments:[libraryID,deviceID,job.id]){
                guard old==bytes else{throw RailwayError.invalidParameter};return
            }
            try db.execute(sql:"INSERT INTO railwayTransfer VALUES(?,?,?,?,?)",arguments:[libraryID,deviceID,job.id,bytes,"pending"])
        }
    }
    func pending()throws->[RailwayTransferJob]{
        try database.read{db in try Data.fetchAll(db,sql:"SELECT payload FROM railwayTransfer WHERE libraryID=? AND deviceID=? AND status<>'completed' ORDER BY rowid",arguments:[libraryID,deviceID]).map{try JSONDecoder().decode(RailwayTransferJob.self,from:$0)}}
    }
    func prerequisitesReady(_ job:RailwayTransferJob)throws->Bool{
        try database.read{db in
            for dep in job.dependsOn ?? []{
                guard let bytes=try Data.fetchOne(db,sql:"SELECT payload FROM railwayReceipt WHERE libraryID=? AND deviceID=? AND mutationID=?",arguments:[libraryID,deviceID,dep])else{return false}
                let outcome=try JSONDecoder().decode(RailwayOutcome.self,from:bytes)
                if outcome.status != "applied"{return false}
            }
            return true
        }
    }
    func complete(_ id:String)throws{try database.writeMetadata{db in try db.execute(sql:"UPDATE railwayTransfer SET status='completed' WHERE libraryID=? AND deviceID=? AND transferID=?",arguments:[libraryID,deviceID,id])}}
    func pin(_ path:String)throws{try database.writeMetadata{db in try db.execute(sql:"INSERT OR IGNORE INTO railwayPinnedAsset VALUES(?,?)",arguments:[libraryID,path])}}
    func unpin(_ path:String)throws{try database.writeMetadata{db in try db.execute(sql:"DELETE FROM railwayPinnedAsset WHERE libraryID=? AND path=?",arguments:[libraryID,path])}}
}
actor RailwayAttachmentTransfers {
    private let account:RailwayAccountSession
    private let transport:RailwayTransport
    private let store:RailwayTransferStore
    private let fileURL:@Sendable(String)throws->URL
    private let stagingDirectory:URL
    private var active=false
    init(account:RailwayAccountSession,transport:RailwayTransport,store:RailwayTransferStore,stagingDirectory:URL,fileURL:@escaping @Sendable(String)throws->URL){
        self.account=account;self.transport=transport;self.store=store;self.stagingDirectory=stagingDirectory;self.fileURL=fileURL
    }
    func manifest(after:String="")async throws->RailwayAssetPage{
        try await account.request(RailwayAssetPage.self,"GET",["internal","sync","assets"],query:[.init(name:"after",value:after),.init(name:"limit",value:"200")])
    }
    func scheduleReferencedAssets()async throws{
        let paths=try store.database.read{db in
            try RailwayNativeRecordMapping.mirroredAssetPaths(in:db,libraryID:store.libraryID,deviceID:store.deviceID)
        }
        guard !paths.isEmpty else{return}
        var after=""
        while true{
            try Task.checkCancellation()
            let page=try await manifest(after:after)
            for asset in page.data where paths.contains(asset.path){
                let url=try fileURL(asset.path)
                if let bytes=Int64(asset.bytes),(try? RailwayFileIntegrity.verify(url,sha256:asset.sha256,bytes:bytes)) != nil{continue}
                try scheduleDownload(asset)
            }
            if !page.hasMore{return}
            guard page.nextAfter != after else{throw RailwayError.invalidResponse};after=page.nextAfter
        }
    }
    func scheduleDownload(_ asset:RailwayAsset,pinned:Bool=false)throws{
        guard let bytes=Int64(asset.bytes),bytes>=0 else{throw RailwayError.invalidResponse}
        if pinned{try store.pin(asset.path)}
        if try store.pending().contains(where:{$0.direction=="download" && $0.path==asset.path && $0.expectedSHA==asset.sha256}){return}
        try store.enqueue(.init(id:UUID().uuidString,direction:"download",path:asset.path,expectedSHA:asset.sha256,byteCount:bytes,filename:nil,mimeType:asset.contentType,spaceID:nil,documentID:nil,attachmentID:nil,replacementBase:nil,changedAt:RailwayJSON.timestamp(),dependsOn:nil))
    }
    func scheduleUpload(path:String,spaceID:String,documentID:String,attachmentID:String,filename:String,mime:String?,replacementBase:String?=nil,changedAt:String=RailwayJSON.timestamp(),dependsOn:[String]=[],transferID:String=UUID().uuidString)throws->String{
        let value=try RailwayFileIntegrity.digest(fileURL(path))
        try store.enqueue(.init(id:transferID,direction:"upload",path:path,expectedSHA:value.sha256,byteCount:value.bytes,filename:filename,mimeType:mime,spaceID:spaceID,documentID:documentID,attachmentID:attachmentID,replacementBase:replacementBase,changedAt:changedAt,dependsOn:dependsOn))
        return transferID
    }
    func drain(network:RailwayNetworkState,preferences:RailwaySyncPreferences)async throws{
        guard !active else{return};active=true;defer{active=false}
        let binding=try await account.binding()
        guard binding.libraryID==store.libraryID,binding.deviceID==store.deviceID else{throw RailwayError.accountMismatch}
        for job in try store.pending(){
            try Task.checkCancellation()
            guard network.assetAllowed(preferences,upload:job.direction=="upload",large:job.byteCount>=5*1024*1024),try store.prerequisitesReady(job) else{continue}
            try FileManager.default.createDirectory(at:stagingDirectory,withIntermediateDirectories:true)
            if job.direction=="download"{try await download(job)}else{try await upload(job)}
            try Task.checkCancellation()
            let current=try await account.binding();guard current.deviceID==binding.deviceID else{throw RailwayError.signedOut}
            try store.complete(job.id)
        }
    }
    private func download(_ job:RailwayTransferJob)async throws{
        let destination=try fileURL(job.path)
        let stage=stagingDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:stage)}
        // Always establish a server transfer receipt, even if bytes are already cached.
        let q=[URLQueryItem(name:"transferID",value:job.id),.init(name:"path",value:job.path),.init(name:"sha256",value:job.expectedSHA)]
        let token=try await account.token()
        let response=try await transport.download(["internal","sync","assets","content"],query:q,token:token,staging:stage)
        guard response.headers["penned-sha256"]==job.expectedSHA else{throw RailwayError.corruptFile}
        try RailwayFileIntegrity.verify(stage,sha256:job.expectedSHA,bytes:job.byteCount)
        if FileManager.default.fileExists(atPath:destination.path){
            // Immutable path collision: never overwrite locally retained bytes.
            try RailwayFileIntegrity.verify(destination,sha256:job.expectedSHA,bytes:job.byteCount)
        }else{
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.moveItem(at:stage,to:destination)
        }
        _ = try await account.request(RailwayTransferAck.self,"POST",["internal","sync","assets",job.id,"ack"],body:.object(["sha256":.string(job.expectedSHA)]))
    }
    private func upload(_ job:RailwayTransferJob)async throws{
        guard let space=job.spaceID,let doc=job.documentID,let attachment=job.attachmentID,let filename=job.filename else{throw RailwayError.invalidParameter}
        let source=try fileURL(job.path)
        try RailwayFileIntegrity.verify(source,sha256:job.expectedSHA,bytes:job.byteCount)
        let (stage,type)=try RailwayFileIntegrity.multipart(source:source,filename:filename,mime:job.mimeType,directory:stagingDirectory)
        defer{try? FileManager.default.removeItem(at:stage)}
        var query=[URLQueryItem(name:"transferID",value:job.id),.init(name:"attachmentID",value:attachment),.init(name:"relativePath",value:job.path),.init(name:"changedAt",value:job.changedAt)]
        if let base=job.replacementBase{query.append(.init(name:"replacementBase",value:base))}
        let result=try await transport.upload(["internal","sync","spaces",space,"documents",doc,"attachments"],query:query,token:account.token(),bodyFile:stage,contentType:type)
        let body=try JSONDecoder().decode(RailwayEnvelope<RailwayJSON>.self,from:result.data)
        guard body.data["id"]?.string==attachment else{throw RailwayError.invalidResponse}
        // Superseded files stay on-device; server has archived the bytes before issuing the terminal receipt.
    }
}
