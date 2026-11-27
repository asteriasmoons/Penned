import Foundation
import GRDB

nonisolated struct RailwayRebindResponse:Codable,Sendable {
    let deviceID:String;let previousDeviceID:String;let snapshotRequired:Bool
}
// The retained local binding is per Library, not the currently signed-in account.
// No old editor handle is reopened. Only the same authenticated owner may adopt it.
nonisolated final class RailwayDeviceRebinding:@unchecked Sendable{
    private let database:AppDatabase
    private let account:RailwayAccountSession
    init(database:AppDatabase,account:RailwayAccountSession){self.database=database;self.account=account}
    func reconcile()async throws{
        let session=try await account.binding()
        let library=database.libraryID
        guard library==session.libraryID,RailwayAccountSession.libraryID(ownerKey:session.ownerKey)==library else{throw RailwayError.accountMismatch}
        let former=try database.read{db->String? in
            guard try LibraryAccess.current(in:db)==library,try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[library])==session.ownerKey else{throw RailwayError.accountMismatch}
            return try String.fetchOne(db,sql:"SELECT deviceID FROM railwayLocalBinding WHERE libraryID=?",arguments:[library])
        }
        if let former,former != session.deviceID{
            let result=try await account.request(RailwayRebindResponse.self,"POST",["internal","sync","device","rebind"],body:.object(["previousDeviceID":.string(former)]))
            guard result.deviceID==session.deviceID,result.previousDeviceID==former,result.snapshotRequired else{throw RailwayError.invalidResponse}
            let current=try await account.binding();guard current.deviceID==session.deviceID,current.libraryID==library else{throw RailwayError.signedOut}
            try database.writeMetadata{db in
                guard try LibraryAccess.current(in:db)==library,try String.fetchOne(db,sql:"SELECT deviceID FROM railwayLocalBinding WHERE libraryID=?",arguments:[library])==former else{throw RailwayError.staleCheckpoint}
                // Keep exact old request bodies, timestamps and mutation IDs: server
                // receipt handoff has already made them replay-safe on the new device.
                for table in ["railwayOutbox","railwayReceipt","railwayTransfer","railwayMirror","railwayRecovery","railwayDeferredApply","railwayNativeRowOutbox","railwayNativeCaptured"]{
                    try db.execute(sql:"UPDATE \(table) SET deviceID=? WHERE libraryID=? AND deviceID=?",arguments:[session.deviceID,library,former])
                }
                try db.execute(sql:"DELETE FROM railwaySnapshotStage WHERE libraryID=? AND deviceID IN (?,?)",arguments:[library,former,session.deviceID])
                try db.execute(sql:"DELETE FROM railwayCheckpoint WHERE libraryID=? AND deviceID IN (?,?)",arguments:[library,former,session.deviceID])
                try db.execute(sql:"INSERT INTO railwayCheckpoint(libraryID,deviceID) VALUES (?,?)",arguments:[library,session.deviceID])
                try db.execute(sql:"UPDATE railwayLocalBinding SET deviceID=? WHERE libraryID=?",arguments:[session.deviceID,library])
            }
        }else if former==nil{
            try database.writeMetadata{db in
                guard try LibraryAccess.current(in:db)==library else{throw RailwayError.accountMismatch}
                try db.execute(sql:"INSERT INTO railwayLocalBinding(libraryID,deviceID) VALUES (?,?)",arguments:[library,session.deviceID])
            }
        }
    }
}
