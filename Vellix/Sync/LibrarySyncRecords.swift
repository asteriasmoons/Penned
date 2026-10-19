import CloudKit
import Foundation
import GRDB

extension LibrarySyncStore {
    func makeRecord(_ item: LibrarySyncItem, attachments: AttachmentStore) throws -> CKRecord {
        let id = CKRecord.ID(recordName: item.row.recordName, zoneID: zoneID)
        let record = try item.systemFields.map(Self.restoredRecord) ?? CKRecord(recordType: "PennedLibraryRecord", recordID: id)
        guard record.recordID == id else { throw LibraryError.wrongOwner }
        let wireRow = item.deleted ? item.row.tombstone : item.row
        let payload = try wireRow.encoded
        record["formatVersion"] = 1 as NSNumber
        record["libraryID"] = libraryID
        record["deleted"] = item.deleted as NSNumber
        record["mutationID"] = item.mutationID
        record["payload"] = CKAsset(fileURL: try stage(payload, attachments: attachments))
        let paths = wireRow.assetPaths.sorted()
        var hashes: [String] = [], assets: [CKAsset] = []
        for path in paths {
            try Task.checkCancellation()
            let url = try attachments.validatedFileURL(relativePath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LibrarySyncError.assetMissing(path) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SyncRow.digest(data)
            hashes.append(digest)
            assets.append(CKAsset(fileURL: try stage(data, attachments: attachments, digest: digest)))
            try track(path: path, digest: digest)
        }
        record["filePaths"] = paths.isEmpty ? nil : paths as CKRecordValue
        record["fileHashes"] = hashes.isEmpty ? nil : hashes as CKRecordValue
        record["files"] = assets.isEmpty ? nil : assets as CKRecordValue
        return record
    }

    private func stage(_ data: Data, attachments: AttachmentStore, digest: String? = nil) throws -> URL {
        let directory = attachments.syncDirectory.appendingPathComponent(libraryID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = digest ?? SyncRow.digest(data)
        let url = directory.appendingPathComponent(digest)
        if let existing = try? Data(contentsOf: url, options: .mappedIfSafe), SyncRow.digest(existing) == digest { return url }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func track(path: String, digest: String) throws {
        try database.writeMetadata { db in
            try requireBinding(in: db)
            if let existing = try String.fetchOne(db, sql: "SELECT digest FROM librarySyncAssets WHERE libraryID=? AND relativePath=?", arguments: [libraryID, path]),
               !existing.isEmpty, existing != digest { throw LibrarySyncError.invalidRecord("An immutable attachment changed unexpectedly: \(path)") }
            try db.execute(sql: "INSERT INTO librarySyncAssets(libraryID,relativePath,digest) VALUES (?,?,?) ON CONFLICT(libraryID,relativePath) DO UPDATE SET digest=excluded.digest", arguments: [libraryID, path, digest])
        }
    }

    func stageIncoming(_ record: CKRecord, attachments: AttachmentStore) throws {
        guard record.recordID.zoneID == zoneID, record.recordType == "PennedLibraryRecord",
              record["libraryID"] as? String == libraryID,
              (record["formatVersion"] as? NSNumber)?.intValue == 1,
              let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
              let deleted = record["deleted"] as? NSNumber,
              let mutation = record["mutationID"] as? String else { throw LibrarySyncError.invalidRecord("Unknown record format or library.") }
        if try database.read({ try isOlderServerRecord(record, in: $0) }) { return }
        let data = try Data(contentsOf: url)
        let row = try JSONDecoder().decode(SyncRow.self, from: data)
        guard row.recordName == record.recordID.recordName, LibrarySyncSchema.tables.contains(row.table) else { throw LibrarySyncError.invalidRecord("Record identity mismatch.") }
        let paths = record["filePaths"] as? [String] ?? []
        let hashes = record["fileHashes"] as? [String] ?? []
        let files = record["files"] as? [CKAsset] ?? []
        guard paths == row.assetPaths.sorted(), paths.count == files.count, paths.count == hashes.count else { throw LibrarySyncError.invalidRecord("Incomplete attachment manifest.") }
        // CKAsset download URLs are temporary: preserve and validate every byte before acknowledging the event.
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            let destination = try attachments.validatedFileURL(relativePath: path)
            guard let source = files[index].fileURL else { throw LibrarySyncError.assetMissing(path) }
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            guard SyncRow.digest(bytes) == hashes[index] else { throw LibrarySyncError.invalidRecord("Attachment checksum mismatch.") }
            _ = try stage(bytes, attachments: attachments, digest: hashes[index])
            if FileManager.default.fileExists(atPath: destination.path) {
                guard SyncRow.digest(try Data(contentsOf: destination, options: .mappedIfSafe)) == hashes[index] else {
                    throw LibrarySyncError.invalidRecord("A downloaded attachment conflicts with an existing file. Both copies have been retained.")
                }
            } else { try bytes.write(to: destination, options: .atomic) }
            try track(path: path, digest: hashes[index])
        }
        try database.writeMetadata { db in
            try requireBinding(in: db)
            if try isOlderServerRecord(record, in: db) { return }
            try validate(row, in: db)
            try db.execute(sql: """
                INSERT INTO librarySyncInbox(libraryID,recordName,payload,deleted,systemFields,mutationID) VALUES (?,?,?,?,?,?)
                ON CONFLICT(libraryID,recordName) DO UPDATE SET payload=excluded.payload,deleted=excluded.deleted,
                  systemFields=excluded.systemFields,mutationID=excluded.mutationID
                """, arguments: [libraryID, row.recordName, data, deleted.boolValue, try Self.systemFields(record), mutation])
        }
    }

    func stagePhysicalDeletion(_ id: CKRecord.ID) throws {
        guard id.zoneID == zoneID else { throw LibraryError.wrongOwner }
        try database.writeMetadata { db in
            try requireBinding(in: db)
            guard let item = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, id.recordName]) else { return }
            let row = try JSONDecoder().decode(SyncRow.self, from: item["payload"])
            try db.execute(sql: """
                INSERT INTO librarySyncInbox(libraryID,recordName,payload,deleted,systemFields,mutationID) VALUES (?,?,?,1,?,'physical-delete')
                ON CONFLICT(libraryID,recordName) DO UPDATE SET deleted=1,systemFields=excluded.systemFields,mutationID=excluded.mutationID
                """, arguments: [libraryID, id.recordName, try row.tombstone.encoded, Data()])
        }
    }

    func validate(_ row: SyncRow, in db: Database) throws {
        guard LibrarySyncSchema.tables.contains(row.table) else { throw LibrarySyncError.invalidRecord("Unknown authored table.") }
        let columns = Set(try db.columns(in: row.table).map(\.name))
        guard Set(row.values.keys) == columns,
              LibrarySyncSchema.keys(for: row.table).allSatisfy({ row.values[$0]?.text?.isEmpty == false }) else {
            throw LibrarySyncError.invalidRecord("Record columns or primary keys are invalid.")
        }
        if let library = row.values["libraryID"]?.text, library != libraryID { throw LibraryError.wrongOwner }
        if ["documents", "templates", "documentSnapshots"].contains(row.table), let json = row.values["tipTapJSON"]?.text {
            _ = try TipTapContentAnalyzer.analyze(json)
        }
        let keys = LibrarySyncSchema.keys(for: row.table)
        let predicate = keys.map { "\"\($0)\"=?" }.joined(separator: " AND ")
        let owner = LibraryAccess.owners[row.table]!.replacingOccurrences(of: "$", with: "t")
        if let existing = try String.fetchOne(db, sql: "SELECT \(owner) FROM \(row.table) t WHERE \(predicate)", arguments: StatementArguments(keys.map { row.values[$0]!.databaseValue })), existing != libraryID {
            throw LibraryError.wrongOwner
        }
    }
}
