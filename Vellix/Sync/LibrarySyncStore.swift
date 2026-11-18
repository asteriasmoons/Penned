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
    case paused(String)
    case requiresResolution(recordName: String, message: String)
    var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason): return "Sync paused to protect your library: \(reason)"
        case .assetMissing(let path): return "A required attachment is unavailable: \(path). Your changes remain queued."
        case .zoneRemoved: return "This library's CloudKit zone was removed. Local content is safe. Sync is paused; restore the cloud library before resuming."
        case .paused(let reason): return reason
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
        try Task.checkCancellation()
        try database.write { db in
            guard var library = try LibraryRecord.fetchOne(db, key: libraryID), library.ownerKey == ownerKey,
                  library.id == LibraryRecord.accountID(ownerKey: ownerKey) else { throw LibraryError.wrongOwner }
            if let bound = library.cloudAccountID, bound != cloudAccountID { throw LibraryError.cloudIdentityChanged }
            library.cloudAccountID = cloudAccountID; library.syncEnabled = true
            try library.update(db)
            try db.execute(sql: "INSERT INTO librarySyncState(libraryID,cloudAccountID) VALUES (?,?) ON CONFLICT(libraryID) DO NOTHING", arguments: [libraryID, cloudAccountID])
            try seed(in: db)
            try Task.checkCancellation()
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

    private static var legacyOwnershipPause: String {
        VellixError.impossibleMove(SpaceOwnership.relationshipViolation).localizedDescription
    }

    func needsLegacyOwnershipRecovery() throws -> Bool {
        try database.read { db in
            try requireBinding(in: db)
            let reason = try String.fetchOne(db, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [libraryID])
            return reason == Self.legacyOwnershipPause
        }
    }

    func finishLegacyOwnershipRecovery() throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            // Re-fetch after a previously failed import without touching either queue.
            try db.execute(sql: """
                UPDATE librarySyncState SET engineState=NULL,pausedReason=NULL
                WHERE libraryID=? AND cloudAccountID=? AND pausedReason=?
                """, arguments: [libraryID, cloudAccountID, Self.legacyOwnershipPause])
        }
    }

    func seed(in db: Database) throws {
        for table in LibrarySyncSchema.tables {
            try Task.checkCancellation()
            let owner = LibraryAccess.owners[table]!.replacingOccurrences(of: "$", with: "t")
            let records = try Row.fetchCursor(db, sql: "SELECT t.* FROM \(table) t WHERE \(owner)=?", arguments: [libraryID])
            while let record = try records.next() {
                try Task.checkCancellation()
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
    private static let stagedConflictFilter = """
        AND NOT EXISTS (
            SELECT 1 FROM librarySyncInbox AS incoming
            WHERE incoming.libraryID = librarySyncItems.libraryID
              AND incoming.recordName = librarySyncItems.recordName
              AND incoming.mutationID <> COALESCE(librarySyncItems.ackMutation, '')
        )
        """

    func hasLocalWork() async throws -> Bool {
        try await database.readAsync { [self] db in
            try requireBinding(in: db)
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM librarySyncInbox WHERE libraryID=?)
                    OR EXISTS(SELECT 1 FROM librarySyncItems WHERE libraryID=? AND dirty=1 \(Self.stagedConflictFilter))
                """, arguments: [libraryID, libraryID]) == true
        }
    }

    func pendingRecordNames(excludingStagedConflicts: Bool = false) throws -> [String] {
        try database.read { try pendingRecordNames(excludingStagedConflicts: excludingStagedConflicts, in: $0) }
    }

    func sendableRecordNames() async throws -> [String] {
        try await database.readAsync { [self] in try pendingRecordNames(excludingStagedConflicts: true, in: $0) }
    }

    private func pendingRecordNames(excludingStagedConflicts: Bool, in db: Database) throws -> [String] {
        try requireBinding(in: db)
        let priority = LibrarySyncSchema.tables.enumerated().map {
            "WHEN recordName LIKE '\($0.element)-%' THEN \($0.offset)"
        }.joined(separator: " ")
        // Keep the local edit queued while a competing server revision awaits import. Own echoes do not block uploads.
        let conflictFilter = excludingStagedConflicts ? Self.stagedConflictFilter : ""
        return try String.fetchAll(db, sql: """
            SELECT recordName FROM librarySyncItems WHERE libraryID=? AND dirty=1 \(conflictFilter)
            ORDER BY CASE \(priority) ELSE 99 END,recordName
            """, arguments: [libraryID])
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
    func hasIncomingChanges() async throws -> Bool {
        try await database.readAsync { [self] db in
            try requireBinding(in: db)
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM librarySyncInbox WHERE libraryID=?)",
                                     arguments: [libraryID]) == true
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
            if let reason = try String.fetchOne(db, sql: "SELECT pausedReason FROM librarySyncState WHERE libraryID=?", arguments: [libraryID]) { throw LibrarySyncError.paused(reason) }
            guard let data = try Data.fetchOne(db, sql: "SELECT engineState FROM librarySyncState WHERE libraryID=? AND cloudAccountID=?", arguments: [libraryID, cloudAccountID]) else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
    }
    func saveState(_ state: CKSyncEngine.State.Serialization) throws {
        let data = try JSONEncoder().encode(state)
        try database.writeMetadata { db in
            try requireBinding(in: db)
            try db.execute(sql: "UPDATE librarySyncState SET engineState=? WHERE libraryID=? AND cloudAccountID=?", arguments: [data, libraryID, cloudAccountID])
        }
    }
    func pause(_ reason: String) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            try db.execute(sql: "UPDATE librarySyncState SET pausedReason=? WHERE libraryID=? AND cloudAccountID=?",
                           arguments: [reason, libraryID, cloudAccountID])
        }
    }
    func acknowledge(_ record: CKRecord) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            guard record.recordID.zoneID == zoneID, let mutation = record["mutationID"] as? String else { throw LibraryError.wrongOwner }
            if PennedSyncTrace.isWatched(record.recordID.recordName) {
                PennedSyncTrace.record("cloud.acknowledgment", "mutation=\(PennedSyncTrace.token(mutation)) tag=\(PennedSyncTrace.token(record.recordChangeTag)) server_us=\(PennedSyncTrace.wallUS(record.modificationDate))")
            }
            if try isOlderServerRecord(record, in: db) { return }
            try db.execute(sql: "UPDATE librarySyncItems SET systemFields=?,ackMutation=?,dirty=CASE WHEN mutationID=? THEN 0 ELSE dirty END WHERE libraryID=? AND recordName=?",
                           arguments: [try Self.systemFields(record), mutation, mutation, libraryID, record.recordID.recordName])
            if let item = try Row.fetchOne(db, sql: "SELECT payload,deleted,dirty FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, record.recordID.recordName]),
               item["deleted"] as Bool, !(item["dirty"] as Bool) {
                let row = try JSONDecoder().decode(SyncRow.self, from: item["payload"])
                try db.execute(sql: "UPDATE librarySyncItems SET payload=? WHERE libraryID=? AND recordName=?", arguments: [try row.tombstone.encoded, libraryID, record.recordID.recordName])
            }
            if record.recordID.recordName.hasPrefix("documents-") {
                if (record["deleted"] as? NSNumber)?.boolValue == true {
                    try removeDocumentBaseline(record.recordID.recordName, in: db)
                } else {
                    // The journal may already contain the next edit. Only trust a
                    // matching mutation or the exact payload CloudKit acknowledged.
                    let queuedPayload = try Data.fetchOne(db, sql: """
                        SELECT payload FROM librarySyncItems
                        WHERE libraryID=? AND recordName=? AND mutationID=? AND deleted=0
                        """, arguments: [libraryID, record.recordID.recordName, mutation])
                    let acknowledgedURL = (record["payload"] as? CKAsset)?.fileURL
                    let payload = queuedPayload ?? acknowledgedURL.flatMap { try? Data(contentsOf: $0) }
                    if let payload, let row = try? JSONDecoder().decode(SyncRow.self, from: payload),
                       row.table == "documents", row.recordName == record.recordID.recordName,
                       row.values["tipTapJSON"]?.text != nil {
                        try saveDocumentBaseline(row, in: db)
                    }
                }
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

    func archiveDocumentOnce(_ row: SyncRow, reason: String, in db: Database) throws {
        let payload = try row.encoded
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM librarySyncConflicts WHERE libraryID=? AND recordName=? AND payload=? AND deleted=0)
            """, arguments: [libraryID, row.recordName, payload]) != true else { return }
        try archive(row, deleted: false, reason: reason, in: db)
    }

    func quarantineStaleUploads(_ items: [LibrarySyncItem]) throws -> Set<String> {
        let documents = items.filter { $0.row.table == "documents" && !$0.deleted }
        guard !documents.isEmpty else { return [] }
        return try database.writeMetadata { db in
            try requireBinding(in: db)
            var blocked = Set<String>()
            for item in documents {
                try Task.checkCancellation()
                let row = item.row
                guard let id = row.values["id"]?.text, let revision = row.values["revision"]?.integer else { continue }
                let currentRevision = try Int64.fetchOne(db, sql: "SELECT revision FROM documents WHERE id=?", arguments: [id]) ?? 0
                let baselineRevision = try Int64.fetchOne(db, sql: """
                    SELECT json_extract(CAST(payload AS TEXT),'$.values.revision.integer._0')
                    FROM librarySyncBaselines WHERE libraryID=? AND recordName=?
                    """, arguments: [libraryID, row.recordName]) ?? 0
                // A snapshot can be from a discarded branch, not from the live document's ancestry.
                guard revision < max(currentRevision, baselineRevision) else { continue }
                if PennedSyncTrace.isWatched(row.recordName) {
                    PennedSyncTrace.record("cloud.staleUploadBlocked",
                        "queuedRev=\(revision) currentRev=\(currentRevision) baselineRev=\(baselineRevision) mutation=\(PennedSyncTrace.token(item.mutationID))")
                }
                blocked.insert(row.recordName)
                guard try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM librarySyncItems WHERE libraryID=? AND recordName=? AND mutationID=? AND dirty=1)
                    """, arguments: [libraryID, row.recordName, item.mutationID]) == true else { continue }
                try archiveDocumentOnce(row, reason: "Older queued revision withheld from iCloud", in: db)
                try db.execute(sql: "UPDATE librarySyncItems SET dirty=0 WHERE libraryID=? AND recordName=? AND mutationID=?",
                               arguments: [libraryID, row.recordName, item.mutationID])
            }
            return blocked
        }
    }

    func currentUploadMutations(recordNames: [String]) throws -> [String: String] {
        guard !recordNames.isEmpty else { return [:] }
        return try database.read { db in
            try requireBinding(in: db)
            let placeholders = recordNames.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT recordName,mutationID FROM librarySyncItems
                WHERE libraryID=? AND dirty=1 AND recordName IN (\(placeholders)) \(Self.stagedConflictFilter)
                """, arguments: StatementArguments([libraryID] + recordNames))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["recordName"] as String, $0["mutationID"] as String) })
        }
    }

    func archiveStagedRevision(recordName: String, reason: String) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            guard let pending = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncInbox WHERE libraryID=? AND recordName=?", arguments: [libraryID, recordName]) else { return }
            let payload: Data = pending["payload"]
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM librarySyncConflicts WHERE libraryID=? AND recordName=? AND payload=?)", arguments: [libraryID, recordName, payload]) != true else { return }
            try archive(JSONDecoder().decode(SyncRow.self, from: payload), deleted: pending["deleted"], reason: reason, in: db)
        }
    }
}
