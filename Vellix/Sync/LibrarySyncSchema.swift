import CryptoKit
import Foundation
import GRDB

nonisolated enum SyncValue: Codable, Equatable, Sendable {
    case null, text(String), integer(Int64), real(Double), blob(Data)
    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .string(let value): self = .text(value)
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .real(value)
        case .blob(let value): self = .blob(value)
        }
    }
    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .text(let value): return value.databaseValue
        case .integer(let value): return value.databaseValue
        case .real(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        }
    }
    var text: String? { if case .text(let value) = self { return value }; return nil }
}

nonisolated struct SyncRow: Codable, Equatable, Sendable {
    var table: String
    var values: [String: SyncValue]
    var recordName: String {
        let keys = LibrarySyncSchema.keys(for: table).map { values[$0] ?? .null }
        let data = (try? Self.encoder.encode(keys)) ?? Data()
        return table + "-" + Self.digest(data)
    }
    var encoded: Data { get throws { try Self.encoder.encode(self) } }
    var tombstone: SyncRow {
        let retained = Set(LibrarySyncSchema.keys(for: table) + ["libraryID"])
        return SyncRow(table: table, values: values.mapValues { _ in .null }.merging(values.filter { retained.contains($0.key) }) { _, value in value })
    }
    static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(table: String, row: Row) { self.table = table; values = Dictionary(uniqueKeysWithValues: row.map { ($0.0, SyncValue($0.1)) }) }
    init(table: String, values: [String: SyncValue]) { self.table = table; self.values = values }

    var assetPaths: [String] {
        if table == "attachments" { return [values["relativePath"]?.text, values["thumbnailRelativePath"]?.text].compactMap { $0 } }
        guard table == "documentStyles", let json = values["styleJSON"]?.text,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        let appearance = object["appearance"] as? [String: Any]
        return Array(Set([object["cover"] as? String,
            (appearance?["editorBackground"] as? [String: Any])?["imagePath"] as? String,
            (appearance?["innerPageBackground"] as? [String: Any])?["imagePath"] as? String].compactMap { $0 }))
    }
}

nonisolated enum LibrarySyncSchema {
    static let tables = ["spaces", "folders", "templates", "documents", "documentSnapshots", "attachments",
        "documentStyles", "collections", "collectionFields", "collectionViews", "collectionEntries",
        "collectionValues", "taskCompletions", "dailyNoteSettings", "calendarEventNotes"]
    static func keys(for table: String) -> [String] {
        switch table {
        case "collectionEntries": return ["documentID"]
        case "collectionValues": return ["documentID", "fieldID"]
        case "dailyNoteSettings": return ["spaceID"]
        default: return ["id"]
        }
    }
    static func configure(_ db: Database) {
        db.add(function: DatabaseFunction("penned_sync_row", argumentCount: nil, pure: true) { arguments -> Data? in
            guard let first = arguments.first, let table = String.fromDatabaseValue(first), tables.contains(table), arguments.count % 2 == 1 else { return nil }
            var values: [String: SyncValue] = [:]
            for index in stride(from: 1, to: arguments.count, by: 2) {
                guard let key = String.fromDatabaseValue(arguments[index]) else { return nil }
                values[key] = SyncValue(arguments[index + 1])
            }
            return try SyncRow(table: table, values: values).encoded
        })
        db.add(function: DatabaseFunction("penned_sync_name", argumentCount: 1, pure: true) { arguments -> String? in
            guard let data = Data.fromDatabaseValue(arguments[0]) else { return nil }
            return try JSONDecoder().decode(SyncRow.self, from: data).recordName
        })
        db.add(function: DatabaseFunction("penned_sync_assets", argumentCount: 1, pure: true) { arguments -> String? in
            guard let data = Data.fromDatabaseValue(arguments[0]) else { return nil }
            let paths = try JSONDecoder().decode(SyncRow.self, from: data).assetPaths
            return String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        })
    }

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE librarySyncControl (remote INTEGER NOT NULL DEFAULT 0);
            INSERT INTO librarySyncControl VALUES (0);
            CREATE TABLE librarySyncItems (
              libraryID TEXT NOT NULL REFERENCES libraries(id), recordName TEXT NOT NULL,
              payload BLOB NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
              version INTEGER NOT NULL DEFAULT 1, dirty INTEGER NOT NULL DEFAULT 1,
              systemFields BLOB, mutationID TEXT NOT NULL DEFAULT '',ackMutation TEXT NOT NULL DEFAULT '',
              PRIMARY KEY(libraryID,recordName)
            );
            CREATE INDEX sync_dirty ON librarySyncItems(libraryID,dirty);
            CREATE TABLE librarySyncState (
              libraryID TEXT PRIMARY KEY NOT NULL REFERENCES libraries(id), cloudAccountID TEXT NOT NULL,
              engineState BLOB, pausedReason TEXT, lastSyncedAt DATETIME
            );
            CREATE TABLE librarySyncInbox (
              libraryID TEXT NOT NULL,recordName TEXT NOT NULL,payload BLOB NOT NULL,
              deleted INTEGER NOT NULL,systemFields BLOB NOT NULL,mutationID TEXT NOT NULL,
              PRIMARY KEY(libraryID,recordName)
            );
            CREATE TABLE librarySyncConflicts (
              id TEXT PRIMARY KEY NOT NULL,libraryID TEXT NOT NULL,recordName TEXT NOT NULL,
              payload BLOB NOT NULL,deleted INTEGER NOT NULL,reason TEXT NOT NULL,createdAt DATETIME NOT NULL
            );
            CREATE TABLE librarySyncAssets (
              libraryID TEXT NOT NULL,relativePath TEXT NOT NULL,digest TEXT NOT NULL,
              PRIMARY KEY(libraryID,relativePath)
            );
            """)
        for table in tables {
            let columns = try db.columns(in: table).map(\.name)
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let row = event == "DELETE" ? "OLD" : "NEW"
                let fields = columns.map { "'\($0)',\(row).\"\($0)\"" }.joined(separator: ",")
                let payload = "penned_sync_row('\(table)',\(fields))"
                let name = "penned_sync_name(\(payload))"
                let owner = LibraryAccess.owners[table]!.replacingOccurrences(of: "$", with: row)
                let library = "COALESCE(\(owner),(SELECT libraryID FROM librarySyncItems WHERE recordName=\(name) LIMIT 1))"
                let changed: String
                if event == "UPDATE" {
                    // Opening a document alone is device-local, not an authored edit.
                    changed = " AND (" + columns.filter { $0 != "lastOpenedAt" }.map { "OLD.\"\($0)\" IS NOT NEW.\"\($0)\"" }.joined(separator: " OR ") + ")"
                } else { changed = "" }
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(table)_\(event) AFTER \(event) ON \(table)
                    WHEN (SELECT remote FROM librarySyncControl)=0 AND \(library)<>'local'\(changed)
                    BEGIN
                      INSERT INTO librarySyncItems(libraryID,recordName,payload,deleted,mutationID)
                      VALUES (\(library),\(name),\(payload),\(event == "DELETE" ? 1 : 0),lower(hex(randomblob(16))))
                      ON CONFLICT(libraryID,recordName) DO UPDATE SET payload=excluded.payload,
                        deleted=excluded.deleted,version=version+1,dirty=1,mutationID=excluded.mutationID;
                      INSERT OR IGNORE INTO librarySyncAssets(libraryID,relativePath,digest)
                        SELECT \(library),value,'' FROM json_each(penned_sync_assets(\(payload)));
                    END;
                    """)
            }
        }
    }
}
