import Foundation
import CryptoKit
import GRDB

nonisolated enum LibraryError: LocalizedError, Equatable {
    case unavailable, confirmationRequired, wrongOwner, staleWorkspace, cloudIdentityChanged, syncDisabled
    var errorDescription: String? {
        switch self {
        case .unavailable: "This library is unavailable. Your saved content has not been removed."
        case .confirmationRequired: "Confirm the account and Spaces before adopting local content."
        case .wrongOwner: "This content belongs to another account library."
        case .staleWorkspace: "This workspace has closed. Reopen the document in its owning library."
        case .cloudIdentityChanged: "This library is bound to a different iCloud account. Sync is paused."
        case .syncDisabled: "Document synchronization is not enabled for this library."
        }
    }
}

nonisolated struct LibraryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "libraries"
    static let localID = "local"
    var id: String
    var ownerKey: String?
    var cloudAccountID: String?
    var syncEnabled: Bool
    var createdAt: Date

    static func accountID(ownerKey: String) -> String {
        "account-" + SHA256.hash(data: Data(ownerKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum LibraryOwnership {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE libraries (
              id TEXT PRIMARY KEY NOT NULL, ownerKey TEXT UNIQUE, cloudAccountID TEXT,
              syncEnabled INTEGER NOT NULL DEFAULT 0 CHECK(syncEnabled IN (0,1)), createdAt DATETIME NOT NULL,
              CHECK(ownerKey IS NOT NULL OR (id='local' AND syncEnabled=0 AND cloudAccountID IS NULL))
            );
            INSERT INTO libraries(id,createdAt) VALUES ('local',CURRENT_TIMESTAMP);
            ALTER TABLE spaces ADD COLUMN libraryID TEXT NOT NULL DEFAULT 'local' REFERENCES libraries(id) ON DELETE RESTRICT;
            ALTER TABLE documentStyles ADD COLUMN libraryID TEXT NOT NULL DEFAULT 'local' REFERENCES libraries(id) ON DELETE RESTRICT;
            CREATE INDEX spaces_library ON spaces(libraryID,isArchived,sortOrder);
            CREATE INDEX styles_library ON documentStyles(libraryID,createdAt);
            CREATE TABLE librarySpaceDefaults (
              libraryID TEXT PRIMARY KEY NOT NULL REFERENCES libraries(id) ON DELETE RESTRICT,
              spaceID TEXT REFERENCES spaces(id) ON DELETE SET NULL
            );
            INSERT INTO librarySpaceDefaults SELECT 'local',spaceID FROM spaceDefaults;
            CREATE TRIGGER library_default_insert BEFORE INSERT ON librarySpaceDefaults
            WHEN NEW.spaceID IS NOT NULL AND NOT EXISTS(SELECT 1 FROM spaces WHERE id=NEW.spaceID AND libraryID=NEW.libraryID)
            BEGIN SELECT RAISE(ABORT,'Default Space must belong to its library'); END;
            CREATE TRIGGER library_default_update BEFORE UPDATE ON librarySpaceDefaults
            WHEN NEW.spaceID IS NOT NULL AND NOT EXISTS(SELECT 1 FROM spaces WHERE id=NEW.spaceID AND libraryID=NEW.libraryID)
            BEGIN SELECT RAISE(ABORT,'Default Space must belong to its library'); END;
            """)
    }
}

final class LibraryRepository: @unchecked Sendable {
    let database: AppDatabase
    init(database: AppDatabase) { self.database = database.scoped(to: "*") }

    func library(id: String) throws -> LibraryRecord? {
        try database.read { try LibraryRecord.fetchOne($0, key: id) }
    }

    @discardableResult
    func accountLibrary(ownerKey: String) throws -> LibraryRecord {
        guard !ownerKey.isEmpty else { throw LibraryError.wrongOwner }
        return try database.write { db in
            let id = LibraryRecord.accountID(ownerKey: ownerKey)
            if let existing = try LibraryRecord.fetchOne(db, key: id) {
                guard existing.ownerKey == ownerKey else { throw LibraryError.wrongOwner }
                return existing
            }
            let record = LibraryRecord(id: id, ownerKey: ownerKey, syncEnabled: false, createdAt: Date())
            try record.insert(db)
            return record
        }
    }

    func adopt(spaceIDs: Set<String>, into libraryID: String, ownerKey: String,
               includeSavedStyles: Bool, confirmed: Bool) throws {
        guard confirmed, !spaceIDs.isEmpty else { throw LibraryError.confirmationRequired }
        try database.write { db in
            try adopt(spaceIDs: spaceIDs, into: libraryID, ownerKey: ownerKey, includeSavedStyles: includeSavedStyles, in: db)
        }
    }

    func hasUnownedLocalContent() throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM spaces WHERE libraryID='local' AND id NOT IN (SELECT spaceID FROM bootstrapSpaces)) OR EXISTS(SELECT 1 FROM documentStyles WHERE libraryID='local')") ?? false
        }
    }

    func claimLocalLibrary(ownerKey: String, preferredSpaceID: String? = nil) throws -> (library: LibraryRecord, selectedSpaceID: String?) {
        let library = try accountLibrary(ownerKey: ownerKey)
        let selectedSpaceID: String? = try database.write { db in
            let ids = Set(try String.fetchAll(db, sql: "SELECT id FROM spaces WHERE libraryID='local' AND id NOT IN (SELECT spaceID FROM bootstrapSpaces)"))
            let hasStyles = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM documentStyles WHERE libraryID='local')") ?? false
            guard !ids.isEmpty || hasStyles else { return nil }
            // An empty signed-out workspace must not displace an account's selected Space.
            let hasContent = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM documents WHERE spaceID IN (SELECT id FROM spaces WHERE libraryID='local'))
                    OR EXISTS(SELECT 1 FROM folders WHERE spaceID IN (SELECT id FROM spaces WHERE libraryID='local'))
                    OR EXISTS(SELECT 1 FROM templates WHERE spaceID IN (SELECT id FROM spaces WHERE libraryID='local'))
                """) ?? false
            let hasAccountSpace = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM spaces WHERE libraryID=? AND isArchived=0)", arguments: [library.id]) ?? false
            let selection = try String.fetchOne(db, sql: """
                SELECT id FROM spaces WHERE libraryID='local' AND isArchived=0 AND id NOT IN (SELECT spaceID FROM bootstrapSpaces)
                ORDER BY CASE WHEN id=? THEN 0
                    WHEN id=(SELECT spaceID FROM librarySpaceDefaults WHERE libraryID='local') THEN 1 ELSE 2 END,
                    sortOrder,createdAt,id LIMIT 1
                """, arguments: [preferredSpaceID])
            try adopt(spaceIDs: ids, into: library.id, ownerKey: ownerKey, includeSavedStyles: true, in: db)
            return hasContent || !hasAccountSpace ? selection : nil
        }
        return (library, selectedSpaceID)
    }

    private func adopt(spaceIDs: Set<String>, into libraryID: String, ownerKey: String,
                       includeSavedStyles: Bool, in db: Database) throws {
        guard let library = try LibraryRecord.fetchOne(db, key: libraryID), library.ownerKey == ownerKey,
              library.id != LibraryRecord.localID else { throw LibraryError.wrongOwner }
        for id in spaceIDs {
            guard let space = try SpaceRecord.fetchOne(db, key: id), space.libraryID == LibraryRecord.localID else {
                throw LibraryError.wrongOwner
            }
        }
        let localDefault = try String.fetchOne(db, sql: "SELECT spaceID FROM librarySpaceDefaults WHERE libraryID='local'")
        for id in spaceIDs {
            try db.execute(sql: "UPDATE librarySpaceDefaults SET spaceID=NULL WHERE spaceID=?", arguments: [id])
            try db.execute(sql: "UPDATE spaceDefaults SET spaceID=NULL WHERE spaceID=?", arguments: [id])
            try db.execute(sql: "UPDATE spaces SET libraryID=? WHERE id=?", arguments: [libraryID, id])
        }
        if let localDefault, spaceIDs.contains(localDefault),
           try String.fetchOne(db, sql: "SELECT spaceID FROM librarySpaceDefaults WHERE libraryID=?", arguments: [libraryID]) == nil {
            try db.execute(sql: "INSERT INTO librarySpaceDefaults(libraryID,spaceID) VALUES (?,?) ON CONFLICT(libraryID) DO UPDATE SET spaceID=excluded.spaceID", arguments: [libraryID, localDefault])
        }
        if includeSavedStyles {
            try db.execute(sql: "UPDATE documentStyles SET libraryID=? WHERE libraryID='local'", arguments: [libraryID])
        }
        if library.syncEnabled, let cloudID = library.cloudAccountID {
            try LibrarySyncStore(database: database, libraryID: libraryID, ownerKey: ownerKey, cloudAccountID: cloudID).seed(in: db)
        }
        try SpaceOwnership.validate(in: db)
    }
}
