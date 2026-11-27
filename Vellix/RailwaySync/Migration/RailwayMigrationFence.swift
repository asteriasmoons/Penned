import Foundation
import GRDB

// A durable single-writer fence for the shared SQLite file. SQL triggers
// also cover writes from root handles, other windows, and metadata paths.
nonisolated enum RailwayMigrationFence {
    static func install(in db:Database)throws {
        try db.execute(sql:"CREATE TABLE railwayMigrationFence(slot INTEGER PRIMARY KEY CHECK(slot=1),libraryID TEXT NOT NULL,attemptID TEXT NOT NULL)")
        try refreshTriggers(in:db)
    }
    static func refreshTriggers(in db:Database)throws {
        for table in RailwayNativeRecordMapping.authored+["libraries"] {
            let quoted=RailwayGRDBConversion.quoted(table)
            for event in ["INSERT","UPDATE","DELETE"] {
                try db.execute(sql:"DROP TRIGGER IF EXISTS railway_fence_\(table)_\(event)")
                try db.execute(sql:"CREATE TRIGGER railway_fence_\(table)_\(event) BEFORE \(event) ON \(quoted) WHEN EXISTS(SELECT 1 FROM railwayMigrationFence) BEGIN SELECT RAISE(ABORT,'Penned Cloud library upgrade is protecting this library'); END")
            }
        }
    }
    static func owner(in db:Database)throws->String? {
        try String.fetchOne(db,sql:"SELECT libraryID FROM railwayMigrationFence WHERE slot=1")
    }
    static func held(database:AppDatabase)throws->Bool {
        try database.read { db in
            guard let owner=try owner(in:db) else{return false}
            guard owner==database.libraryID else{throw RailwayError.accountMismatch}
            return true
        }
    }
    static func acquire(database:AppDatabase,ownerKey:String)throws {
        try database.writeMetadata { db in
            let id=database.libraryID
            guard try LibraryAccess.current(in:db)==id,
                  try String.fetchOne(db,sql:"SELECT ownerKey FROM libraries WHERE id=?",arguments:[id])==ownerKey,
                  let bytes=try Data.fetchOne(db,sql:"SELECT payload FROM railwayMigrationState WHERE libraryID=?",arguments:[id]) else{throw RailwayError.accountMismatch}
            let state=try JSONDecoder().decode(RailwayMigrationState.self,from:bytes)
            guard state.ownerKey==ownerKey,state.libraryID==id,state.phase != .cutover else{throw RailwayError.migrationNotVerified}
            if let existing=try Row.fetchOne(db,sql:"SELECT libraryID,attemptID FROM railwayMigrationFence WHERE slot=1"){
                guard existing["libraryID"] as String==id,existing["attemptID"] as String==state.migrationID else{throw RailwayError.accountMismatch}
                return
            }
            // A previously bound cloud library must have completed its last
            // CloudKit pass with no outstanding local or incoming changes.
            let library=try LibraryRecord.fetchOne(db,key:id)
            if library?.cloudAccountID != nil {
                guard library?.syncEnabled==true,
                      try Int.fetchOne(db,sql:"SELECT count(*) FROM librarySyncItems WHERE libraryID=? AND dirty=1",arguments:[id])==0,
                      try Int.fetchOne(db,sql:"SELECT count(*) FROM librarySyncInbox WHERE libraryID=?",arguments:[id])==0,
                      try String.fetchOne(db,sql:"SELECT pausedReason FROM librarySyncState WHERE libraryID=?",arguments:[id])==nil else{throw RailwayError.staleCheckpoint}
            }
            try db.execute(sql:"INSERT INTO railwayMigrationFence VALUES(1,?,?)",arguments:[id,state.migrationID])
        }
    }
    static func require(_ state:RailwayMigrationState,in db:Database)throws {
        guard let row=try Row.fetchOne(db,sql:"SELECT libraryID,attemptID FROM railwayMigrationFence WHERE slot=1"),
              row["libraryID"] as String==state.libraryID,row["attemptID"] as String==state.migrationID else{throw RailwayError.migrationNotVerified}
    }
}
