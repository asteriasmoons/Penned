import CloudKit
import Foundation
import GRDB

nonisolated struct LibrarySyncItem: Sendable {
    var row: SyncRow
    var deleted: Bool
    var version: Int64
    var mutationID: String
    var systemFields: Data?
}

nonisolated struct LibrarySyncConflict: Identifiable, Sendable {
    var id: String
    var row: SyncRow
    var deleted: Bool
    var reason: String
    var createdAt: Date
}

nonisolated enum LibrarySyncError: LocalizedError {
    case invalidRecord(String), assetMissing(String), zoneRemoved
    case requiresResolution(recordName: String, message: String)
    var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason): return "Sync paused to protect your library: \(reason)"
        case .assetMissing(let path): return "A required attachment is unavailable: \(path). Your changes remain queued."
        case .zoneRemoved: return "This library's CloudKit zone was removed. Local content is safe. Sync is paused; restore the cloud library before resuming."
        case .requiresResolution(_, let message): return message
        }
    }
}

nonisolated final class LibrarySyncStore: @unchecked Sendable {
    let database: AppDatabase
    let libraryID: String
    let ownerKey: String
    let cloudAccountID: String
    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: "PennedLibrary-" + libraryID) }

    init(database: AppDatabase, libraryID: String, ownerKey: String, cloudAccountID: String) {
        self.database = database.scoped(to: "*")
        self.libraryID = libraryID; self.ownerKey = ownerKey; self.cloudAccountID = cloudAccountID
    }

    func requireBinding(in db: Database) throws {
        guard let library = try LibraryRecord.fetchOne(db, key: libraryID), library.ownerKey == ownerKey,
              library.id == LibraryRecord.accountID(ownerKey: ownerKey) else { throw LibraryError.wrongOwner }
        guard library.syncEnabled else { throw LibraryError.syncDisabled }
        guard library.cloudAccountID == cloudAccountID else { throw LibraryError.cloudIdentityChanged }
    }

    func enable(confirmed: Bool) throws {
        guard confirmed, libraryID != LibraryRecord.localID, !cloudAccountID.isEmpty else { throw LibraryError.confirmationRequired }
        try database.write { db in
            guard var library = try LibraryRecord.fetchOne(db, key: libraryID), library.ownerKey == ownerKey,
                  library.id == LibraryRecord.accountID(ownerKey: ownerKey) else { throw LibraryError.wrongOwner }
            if let bound = library.cloudAccountID, bound != cloudAccountID { throw LibraryError.cloudIdentityChanged }
            library.cloudAccountID = cloudAccountID; library.syncEnabled = true
            try library.update(db)
            try db.execute(sql: "INSERT INTO librarySyncState(libraryID,cloudAccountID) VALUES (?,?) ON CONFLICT(libraryID) DO NOTHING", arguments: [libraryID, cloudAccountID])
            try seed(in: db)
        }
    }

    func disable() throws {
        try database.write { db in
            guard let library = try LibraryRecord.fetchOne(db, key: libraryID), library.ownerKey == ownerKey else { throw LibraryError.wrongOwner }
            try db.execute(sql: "UPDATE libraries SET syncEnabled=0 WHERE id=?", arguments: [libraryID])
        }
    }

    func prepareRetry(restoringRemovedZone: Bool = false) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            let reason = try String.fetchOne(db, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [libraryID])
            if reason == LibrarySyncError.zoneRemoved.localizedDescription {
                guard restoringRemovedZone else { throw LibrarySyncError.zoneRemoved }
                try db.execute(sql: "UPDATE librarySyncItems SET systemFields=NULL,dirty=1,ackMutation='' WHERE libraryID=?", arguments: [libraryID])
            }
            try db.execute(sql: "UPDATE librarySyncState SET engineState=NULL,pausedReason=NULL WHERE libraryID=? AND cloudAccountID=?", arguments: [libraryID, cloudAccountID])
        }
    }

    func seed(in db: Database) throws {
        for table in LibrarySyncSchema.tables {
            let owner = LibraryAccess.owners[table]!.replacingOccurrences(of: "$", with: "t")
            for record in try Row.fetchAll(db, sql: "SELECT t.* FROM \(table) t WHERE \(owner)=?", arguments: [libraryID]) {
                let row = SyncRow(table: table, row: record)
                try db.execute(sql: "INSERT INTO librarySyncItems(libraryID,recordName,payload,mutationID) VALUES (?,?,?,?) ON CONFLICT(libraryID,recordName) DO NOTHING",
                               arguments: [libraryID, row.recordName, try row.encoded, UUID().uuidString])
                for path in row.assetPaths {
                    try db.execute(sql: "INSERT OR IGNORE INTO librarySyncAssets(libraryID,relativePath,digest) VALUES (?,?,'')", arguments: [libraryID, path])
                }
            }
        }
    }

    func pending() throws -> [LibrarySyncItem] {
        try database.read { db in
            try requireBinding(in: db)
            return try Row.fetchAll(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND dirty=1 ORDER BY recordName", arguments: [libraryID]).map(Self.item)
        }
    }
    func pendingRecordNames() throws -> [String] {
        try database.read { db in
            try requireBinding(in: db)
            let priority = LibrarySyncSchema.tables.enumerated().map {
                "WHEN recordName LIKE '\($0.element)-%' THEN \($0.offset)"
            }.joined(separator: " ")
            return try String.fetchAll(db, sql: "SELECT recordName FROM librarySyncItems WHERE libraryID=? AND dirty=1 ORDER BY CASE \(priority) ELSE 99 END,recordName", arguments: [libraryID])
        }
    }

    func pending(recordNames: [String]) throws -> [LibrarySyncItem] {
        try database.read { db in
            try requireBinding(in: db)
            guard !recordNames.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: recordNames.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND dirty=1 AND recordName IN (\(placeholders))",
                                       arguments: StatementArguments([libraryID] + recordNames))
            let items = try Dictionary(uniqueKeysWithValues: rows.map { row in (row["recordName"] as String, try Self.item(row)) })
            return recordNames.compactMap { items[$0] }
        }
    }
    func incomingCount() throws -> Int {
        try database.read { db in
            try requireBinding(in: db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySyncInbox WHERE libraryID=?", arguments: [libraryID]) ?? 0
        }
    }
    private static func item(_ row: Row) throws -> LibrarySyncItem {
        let fields: Data? = row["systemFields"]
        return LibrarySyncItem(row: try JSONDecoder().decode(SyncRow.self, from: row["payload"]), deleted: row["deleted"],
                        version: row["version"], mutationID: row["mutationID"], systemFields: fields?.isEmpty == false ? fields : nil)
    }

    func state() throws -> CKSyncEngine.State.Serialization? {
        try database.read { db in
            try requireBinding(in: db)
            if let reason = try String.fetchOne(db, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [libraryID]) { throw LibrarySyncError.invalidRecord(reason) }
            guard let data = try Data.fetchOne(db, sql: "SELECT engineState FROM librarySyncState WHERE libraryID=? AND cloudAccountID=?", arguments: [libraryID, cloudAccountID]) else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
    }
    func saveState(_ state: CKSyncEngine.State.Serialization) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            try db.execute(sql: "UPDATE librarySyncState SET engineState=? WHERE libraryID=? AND cloudAccountID=?", arguments: [try JSONEncoder().encode(state), libraryID, cloudAccountID])
        }
    }
    func pause(_ reason: String) throws {
        try database.writeMetadata { db in
            try db.execute(sql: "UPDATE librarySyncState SET pausedReason=? WHERE libraryID=?", arguments: [reason, libraryID])
        }
    }
    func acknowledge(_ record: CKRecord) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            guard record.recordID.zoneID == zoneID, let mutation = record["mutationID"] as? String else { throw LibraryError.wrongOwner }
            if try isOlderServerRecord(record, in: db) { return }
            try db.execute(sql: "UPDATE librarySyncItems SET systemFields=?,ackMutation=?,dirty=CASE WHEN mutationID=? THEN 0 ELSE dirty END WHERE libraryID=? AND recordName=?",
                           arguments: [try Self.systemFields(record), mutation, mutation, libraryID, record.recordID.recordName])
            if let item = try Row.fetchOne(db, sql: "SELECT payload,deleted,dirty FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, record.recordID.recordName]),
               item["deleted"] as Bool, !(item["dirty"] as Bool) {
                let row = try JSONDecoder().decode(SyncRow.self, from: item["payload"])
                try db.execute(sql: "UPDATE librarySyncItems SET payload=? WHERE libraryID=? AND recordName=?", arguments: [try row.tombstone.encoded, libraryID, record.recordID.recordName])
            }
            try db.execute(sql: "UPDATE librarySyncState SET lastSyncedAt=? WHERE libraryID=?", arguments: [Date(), libraryID])
        }
    }

    static func systemFields(_ record: CKRecord) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        return coder.encodedData
    }
    static func restoredRecord(_ data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder) else { throw LibrarySyncError.invalidRecord("Invalid CloudKit change tag.") }
        return record
    }

    func isOlderServerRecord(_ record: CKRecord, in db: Database) throws -> Bool {
        for table in ["librarySyncItems", "librarySyncInbox"] {
            if let data = try Data.fetchOne(db, sql: "SELECT systemFields FROM \(table) WHERE libraryID=? AND recordName=?", arguments: [libraryID, record.recordID.recordName]), !data.isEmpty,
               let knownDate = try Self.restoredRecord(data).modificationDate {
                guard let receivedDate = record.modificationDate else { return true }
                if knownDate > receivedDate { return true }
            }
        }
        return false
    }

    func conflicts() throws -> [LibrarySyncConflict] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM librarySyncConflicts WHERE libraryID=? ORDER BY createdAt DESC", arguments: [libraryID]).map {
                LibrarySyncConflict(id: $0["id"], row: try JSONDecoder().decode(SyncRow.self, from: $0["payload"]),
                                    deleted: $0["deleted"], reason: $0["reason"], createdAt: $0["createdAt"])
            }
        }
    }
    func archive(_ row: SyncRow, deleted: Bool, reason: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO librarySyncConflicts(id,libraryID,recordName,payload,deleted,reason,createdAt) VALUES (?,?,?,?,?,?,?)",
                       arguments: [UUID().uuidString, libraryID, row.recordName, try row.encoded, deleted, reason, Date()])
    }

    func archiveStagedRevision(recordName: String, reason: String) throws {
        try database.writeMetadata { db in
            guard let pending = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncInbox WHERE libraryID=? AND recordName=?", arguments: [libraryID, recordName]) else { return }
            let payload: Data = pending["payload"]
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM librarySyncConflicts WHERE libraryID=? AND recordName=? AND payload=?)", arguments: [libraryID, recordName, payload]) != true else { return }
            try archive(JSONDecoder().decode(SyncRow.self, from: payload), deleted: pending["deleted"], reason: reason, in: db)
        }
    }
}
