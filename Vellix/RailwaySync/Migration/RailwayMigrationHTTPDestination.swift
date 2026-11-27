import Foundation

nonisolated private struct MigrationStatusEnvelope:Codable,Sendable {
    let receipt:RailwayMigrationReceipt?
    let status:String
}
nonisolated private struct MigrationStageResult:Codable,Sendable {
    let status:String?
    let rows:Int?
    let id:String?
}
actor RailwayMigrationHTTPDestination:RailwayMigrationDestination {
    private let account:RailwayAccountSession
    private let transport:RailwayTransport
    private let stagingDirectory:URL
    private let nativeTransactions:Bool
    init(account:RailwayAccountSession,transport:RailwayTransport,stagingDirectory:URL,nativeTransactions:Bool=false){
        self.account=account;self.transport=transport;self.stagingDirectory=stagingDirectory;self.nativeTransactions=nativeTransactions
    }
    private func path(_ id:String,_ action:String?=nil)->[String]{
        ["internal","sync",nativeTransactions ? "records":"migrations",id]+(action.map{[$0]} ?? [])
    }
    func begin(id:String,libraryID:String,manifest:RailwayMigrationManifest)async throws{
        let binding=try await account.binding()
        guard binding.libraryID==libraryID else{throw RailwayError.accountMismatch}
        _ = try await account.request(MigrationStageResult.self,"POST",path(id,"begin"),body:RailwayJSON.from(manifest))
    }
    func stageRows(id:String,rows:[RailwayMigrationRow])async throws{
        // Hash the exact canonical encoded bytes, not a reserialized server JSON object.
        var batch:[RailwayJSON]=[],size=0
        func send(_ values:[RailwayJSON])async throws{
            _ = try await account.request(MigrationStageResult.self,"POST",path(id,"rows"),body:.object(["rows":.array(values)]))
        }
        for row in rows{
            let bytes=try RailwayJSON.encoder.encode(row)
            guard bytes.count<=8*1024*1024 else{throw RailwayError.invalidParameter}
            let encoded=bytes.base64EncodedString()
            if !batch.isEmpty && (size+encoded.utf8.count>14*1024*1024 || batch.count>=50){try await send(batch);batch=[];size=0}
            batch.append(.string(encoded));size+=encoded.utf8.count
        }
        if !batch.isEmpty{try await send(batch)}
    }
    func stageAsset(id:String,asset:RailwayMigrationAsset,from source:URL)async throws{
        try RailwayFileIntegrity.verify(source,sha256:asset.sha256,bytes:asset.bytes)
        try FileManager.default.createDirectory(at:stagingDirectory,withIntermediateDirectories:true)
        let (file,type)=try RailwayFileIntegrity.multipart(source:source,filename:asset.path,mime:"application/octet-stream",directory:stagingDirectory)
        defer{try? FileManager.default.removeItem(at:file)}
        let encoded=try RailwayJSON.encoder.encode(asset).base64EncodedString()
        let response=try await transport.upload(path(id,"assets"),query:[.init(name:"manifest",value:encoded)],token:account.token(),bodyFile:file,contentType:type)
        _ = try JSONDecoder().decode(MigrationStageResult.self,from:response.data)
    }
    func verifyAndCommit(id:String,expected:RailwayMigrationManifest)async throws->RailwayMigrationReceipt{
        try await account.request(RailwayMigrationReceipt.self,"POST",path(id,"commit"),body:RailwayJSON.from(expected))
    }
    func status(id:String)async throws->RailwayMigrationReceipt?{
        do{return try await account.request(MigrationStatusEnvelope.self,"GET",path(id)).receipt}
        catch RailwayError.http(404,"migration_not_found",_){return nil}
    }
}
