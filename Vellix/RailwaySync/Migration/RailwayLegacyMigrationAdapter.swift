import Foundation
import CryptoKit

// The native workspace supplies its existing editor-save and CloudKit fence
// callbacks when integration is explicitly authorized. Never manipulate the
// currently running native provider from a Builder Engine generation run.
actor RailwayLegacyMigrationAdapter:RailwayLegacyMigrationSource{
    private let reader:RailwayLegacyCapture
    private let attachments:AttachmentStore
    private let staging:URL
    private let freeze:@Sendable(String)async throws->Void
    private let activate:@Sendable(RailwayMigrationReceipt)async throws->Void
    private let unfreeze:@Sendable()async->Void
    private var fencedLibrary:String?
    init(reader:RailwayLegacyCapture,attachments:AttachmentStore,staging:URL,freeze:@escaping @Sendable(String)async throws->Void,activate:@escaping @Sendable(RailwayMigrationReceipt)async throws->Void,unfreeze:@escaping @Sendable()async->Void){
        self.reader=reader;self.attachments=attachments;self.staging=staging;self.freeze=freeze;self.activate=activate;self.unfreeze=unfreeze
    }
    func capture(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage{
        try reader.capture(libraryID:libraryID,ownerKey:ownerKey)
    }
    private func stagedURL(_ path:String)throws->URL{
        guard AttachmentStore.validRelativePath(path) else{throw RailwayError.invalidParameter}
        let name=SHA256.hash(data:Data(path.utf8)).map{String(format:"%02x",$0)}.joined()
        return staging.appendingPathComponent(name)
    }
    func fileURL(path:String)async throws->URL{try stagedURL(path)}
    func beginFinalFence(libraryID:String)async throws{
        guard fencedLibrary==nil else{throw RailwayError.staleCheckpoint}
        try await freeze(libraryID);fencedLibrary=libraryID
    }
    func captureFinal(libraryID:String,ownerKey:String)async throws->RailwayMigrationPackage{
        guard fencedLibrary==libraryID else{throw RailwayError.staleCheckpoint}
        let package=try reader.capture(libraryID:libraryID,ownerKey:ownerKey)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        for asset in package.assets{
            try Task.checkCancellation()
            let source=try attachments.validatedFileURL(relativePath:asset.path),target=try stagedURL(asset.path)
            if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)}
            try FileManager.default.copyItem(at:source,to:target)
            try RailwayFileIntegrity.verify(target,sha256:asset.sha256,bytes:asset.bytes)
        }
        return package
    }
    func activateRailway(receipt:RailwayMigrationReceipt)async throws{
        guard fencedLibrary==receipt.libraryID,receipt.verified,receipt.pending==0,receipt.status=="applied" else{throw RailwayError.migrationNotVerified}
        try await activate(receipt);fencedLibrary=nil
    }
    func releaseFenceKeepingLegacyActive()async{await unfreeze();fencedLibrary=nil}
}
