import Foundation
import GRDB

// A repository scope is assigned centrally by AppEnvironment. Nil is reserved for
// migration, transfer, and background maintenance repositories, never library UI.
nonisolated enum SpaceOwnership {
    static func defaultSpace(in db: Database) throws -> String {
        if try db.tableExists("libraries") {
            let library = try LibraryAccess.current(in: db)
            guard library != "*" else { throw LibraryError.unavailable }
            if let id = try String.fetchOne(db, sql: "SELECT d.spaceID FROM librarySpaceDefaults d JOIN spaces s ON s.id=d.spaceID WHERE d.libraryID=? AND s.libraryID=? AND s.isArchived=0", arguments: [library, library]) { return id }
            if let id = try String.fetchOne(db, sql: "SELECT id FROM spaces WHERE libraryID=? AND isArchived=0 ORDER BY sortOrder,createdAt,id LIMIT 1", arguments: [library]) { return id }
            let stableID = "personal-\(library)"
            let hasStableSpace = try SpaceRecord.exists(db, key: stableID)
            var space = SpaceRecord(id: library == LibraryRecord.localID || hasStableSpace ? UUID().uuidString : stableID, title: "Personal", icon: "spaces")
            space.libraryID = library
            try space.insert(db)
            if try db.tableExists("bootstrapSpaces") {
                try db.execute(sql: "INSERT INTO bootstrapSpaces(spaceID) VALUES (?)", arguments: [space.id])
            }
            try db.execute(sql: "INSERT INTO librarySpaceDefaults(libraryID,spaceID) VALUES (?,?) ON CONFLICT(libraryID) DO UPDATE SET spaceID=excluded.spaceID", arguments: [library, space.id])
            return space.id
        }
        if try db.tableExists("spaceDefaults"), let id = try String.fetchOne(db, sql: "SELECT d.spaceID FROM spaceDefaults d JOIN spaces s ON s.id=d.spaceID WHERE s.isArchived=0 LIMIT 1") { return id }
        if let id = try String.fetchOne(db, sql: "SELECT id FROM spaces WHERE isArchived = 0 ORDER BY sortOrder, createdAt, id LIMIT 1") { return id }
        let id = UUID().uuidString
        try db.execute(sql: "INSERT INTO spaces (id,title,icon,isArchived,createdAt,updatedAt,sortOrder) VALUES (?, 'Personal', 'spaces', 0, ?, ?, 0)", arguments: [id, Date(), Date()])
        return id
    }

    static func installBootstrapTracking(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE bootstrapSpaces (
                spaceID TEXT PRIMARY KEY NOT NULL REFERENCES spaces(id) ON DELETE CASCADE
            );
            CREATE TRIGGER bootstrap_space_edited AFTER UPDATE OF title,spaceDescription,icon,iconImageData,isArchived,sortOrder ON spaces
            WHEN NEW.title IS NOT OLD.title OR NEW.spaceDescription IS NOT OLD.spaceDescription
              OR NEW.icon IS NOT OLD.icon OR NEW.iconImageData IS NOT OLD.iconImageData
              OR NEW.isArchived IS NOT OLD.isArchived OR NEW.sortOrder IS NOT OLD.sortOrder
            BEGIN DELETE FROM bootstrapSpaces WHERE spaceID=NEW.id; END;
            """)
        for table in ["documents", "folders", "templates", "dailyNoteSettings"] {
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER bootstrap_\(table)_\(event) AFTER \(event) ON \(table)
                    BEGIN DELETE FROM bootstrapSpaces WHERE spaceID=NEW.spaceID; END;
                    """)
            }
        }
    }

    static func requireSpace(_ id: String, in db: Database, includingArchived: Bool = false) throws {
        guard let space = try SpaceRecord.fetchOne(db, key: id), includingArchived || !space.isArchived else {
            throw VellixError.impossibleMove("This Space is unavailable. Restore it before using its content.")
        }
        if try db.tableExists("libraries") { try LibraryAccess.requireSpace(id, in: db) }
    }

    static func document(_ id: String, scope: String?, in db: Database) throws -> DocumentRecord {
        guard let document = try DocumentRecord.fetchOne(db, key: id), scope == nil || document.spaceID == scope else {
            throw VellixError.documentNotFound(id)
        }
        if try db.tableExists("libraries") { try LibraryAccess.requireSpace(document.spaceID, in: db) }
        return document
    }

    static func validate(in db: Database) throws {
        let invalid = try Int.fetchOne(db, sql: """
            SELECT
              (SELECT COUNT(*) FROM documents d WHERE d.spaceID IS NULL
                OR NOT EXISTS(SELECT 1 FROM spaces s WHERE s.id=d.spaceID)
                OR EXISTS(SELECT 1 FROM documents p WHERE p.id=d.parentDocumentID AND p.spaceID IS NOT d.spaceID)
                OR EXISTS(SELECT 1 FROM folders f WHERE f.id=d.folderID AND f.spaceID IS NOT d.spaceID)
                OR EXISTS(SELECT 1 FROM templates t WHERE t.id=d.templateID AND t.spaceID IS NOT d.spaceID))
              + (SELECT COUNT(*) FROM folders f WHERE f.spaceID IS NULL
                OR NOT EXISTS(SELECT 1 FROM spaces s WHERE s.id=f.spaceID)
                OR EXISTS(SELECT 1 FROM folders p WHERE p.id=f.parentFolderID AND p.spaceID IS NOT f.spaceID))
              + (SELECT COUNT(*) FROM templates t WHERE t.spaceID IS NULL
                OR NOT EXISTS(SELECT 1 FROM spaces s WHERE s.id=t.spaceID)
                OR EXISTS(SELECT 1 FROM documents d WHERE d.id=t.rootDocumentID AND (d.spaceID IS NOT t.spaceID OR d.templateID IS NOT t.id)))
              + (SELECT COUNT(*) FROM collectionEntries e JOIN collections c ON c.id=e.collectionID
                JOIN documents d ON d.id=e.documentID WHERE d.parentDocumentID IS NOT c.documentID)
              + (SELECT COUNT(*) FROM calendarEventNotes n JOIN documents d ON d.id=n.documentID WHERE n.spaceID IS NOT d.spaceID)
            """) ?? 0
        guard invalid == 0 else { throw VellixError.impossibleMove("The operation would separate content from its owning Space.") }
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw VellixError.database("Space ownership failed foreign-key validation.") }
    }

    static func changingOwnership<T>(in db: Database, _ body: () throws -> T) throws -> T {
        try db.execute(sql: "UPDATE spaceOwnershipOperation SET transferring=1")
        let result = try body()
        try validate(in: db)
        try db.execute(sql: "UPDATE spaceOwnershipOperation SET transferring=0")
        return result
    }

    static func install(in db: Database) throws {
        try db.alter(table: "templates") { $0.add(column: "spaceID", .text).references("spaces", onDelete: .restrict) }
        let unowned = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM documents WHERE spaceID IS NULL) OR EXISTS(SELECT 1 FROM folders WHERE spaceID IS NULL) OR EXISTS(SELECT 1 FROM templates WHERE spaceID IS NULL)") ?? false
        let fallback: String
        if unowned {
            let personal = SpaceRecord(title: "Personal", icon: "spaces")
            // Keep migration writes independent of columns added to SpaceRecord later.
            try db.execute(sql: "INSERT INTO spaces (id,title,icon,isArchived,createdAt,updatedAt,sortOrder) VALUES (?,?,?,0,?,?,0)",
                arguments: [personal.id, personal.title, personal.icon, personal.createdAt, personal.updatedAt])
            fallback = personal.id
        } else { fallback = try defaultSpace(in: db) }
        let validSpaces = Set(try String.fetchAll(db, sql: "SELECT id FROM spaces"))
        try db.execute(sql: "UPDATE documents SET parentDocumentID=(SELECT c.documentID FROM collections c JOIN collectionEntries e ON e.collectionID=c.id WHERE e.documentID=documents.id) WHERE id IN (SELECT documentID FROM collectionEntries)")
        // Resolve folder parents before children. Cycles are detached, never deleted.
        var pending = try FolderRecord.fetchAll(db)
        var done = Set<String>()
        while !pending.isEmpty {
            let index = pending.firstIndex { $0.parentFolderID == nil || done.contains($0.parentFolderID!) } ?? 0
            var folder = pending.remove(at: index)
            if let parent = folder.parentFolderID, !done.contains(parent) { folder.parentFolderID = nil }
            if let parent = folder.parentFolderID { folder.spaceID = try FolderRecord.fetchOne(db, key: parent)?.spaceID }
            if folder.spaceID.map(validSpaces.contains) != true { folder.spaceID = fallback }
            try folder.update(db); done.insert(folder.id)
        }
        for var template in try TemplateRecord.fetchAll(db) {
            template.spaceID = try template.rootDocumentID.flatMap { try DocumentRecord.fetchOne(db, key: $0)?.spaceID } ?? fallback
            if template.spaceID.map(validSpaces.contains) != true { template.spaceID = fallback }
            try template.update(db)
        }
        var pages = try DocumentRecord.fetchAll(db)
        done = []
        while !pages.isEmpty {
            let index = pages.firstIndex { $0.parentDocumentID == nil || done.contains($0.parentDocumentID!) } ?? 0
            var page = pages.remove(at: index)
            if let parent = page.parentDocumentID, !done.contains(parent) { page.parentDocumentID = nil }
            if let template = page.templateID { page.spaceID = try TemplateRecord.fetchOne(db, key: template)?.spaceID }
            else if let parent = page.parentDocumentID { page.spaceID = try DocumentRecord.fetchOne(db, key: parent)?.spaceID }
            else if let folder = page.folderID { page.spaceID = try FolderRecord.fetchOne(db, key: folder)?.spaceID }
            if page.spaceID.map(validSpaces.contains) != true { page.spaceID = fallback }
            if let folder = page.folderID, try FolderRecord.fetchOne(db, key: folder)?.spaceID != page.spaceID { page.folderID = nil }
            try page.update(db); done.insert(page.id)
        }
        try db.execute(sql: """
            CREATE TABLE spaceOwnershipOperation (transferring INTEGER NOT NULL);
            INSERT INTO spaceOwnershipOperation VALUES (0);
            CREATE TABLE spaceDefaults (id INTEGER PRIMARY KEY CHECK(id=1), spaceID TEXT REFERENCES spaces(id) ON DELETE SET NULL);
            CREATE TABLE attachmentCleanup (relativePath TEXT PRIMARY KEY NOT NULL);
            CREATE INDEX folders_space_order ON folders(spaceID, parentFolderID, sortOrder);
            CREATE INDEX templates_space_order ON templates(spaceID, title);
            CREATE INDEX documents_space_library ON documents(spaceID, parentDocumentID, templateID, isTrashed, updatedAt);
            DROP TRIGGER tasks_document_update;
            CREATE TRIGGER tasks_document_update AFTER UPDATE OF tipTapJSON,title,parentDocumentID,templateID,isTrashed,isArchived,spaceID ON documents BEGIN
                INSERT OR IGNORE INTO taskDocumentChanges VALUES (NEW.id);
            END;
            CREATE TABLE calendarEventNotes_spaces (
                id TEXT PRIMARY KEY NOT NULL, eventKey TEXT NOT NULL,
                documentID TEXT NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
                spaceID TEXT NOT NULL REFERENCES spaces(id) ON DELETE RESTRICT,
                calendarID TEXT NOT NULL, sourceID TEXT NOT NULL, localID TEXT NOT NULL,
                externalID TEXT, occurrenceKey TEXT NOT NULL, createdAt DATETIME NOT NULL,
                UNIQUE(spaceID,eventKey)
            );
            INSERT INTO calendarEventNotes_spaces SELECT n.id,n.eventKey,n.documentID,d.spaceID,n.calendarID,n.sourceID,n.localID,n.externalID,n.occurrenceKey,n.createdAt
                FROM calendarEventNotes n JOIN documents d ON d.id=n.documentID;
            DROP TABLE calendarEventNotes;
            ALTER TABLE calendarEventNotes_spaces RENAME TO calendarEventNotes;
            CREATE INDEX calendarEventNotes_local ON calendarEventNotes(spaceID,localID,occurrenceKey);
            CREATE INDEX calendarEventNotes_external ON calendarEventNotes(spaceID,externalID,occurrenceKey);
            """)
        try db.execute(sql: "INSERT INTO spaceDefaults VALUES (1,?)", arguments: [fallback])
        for table in ["documents", "folders", "templates"] {
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_space_required_\(event) BEFORE \(event) ON \(table)
                    WHEN NEW.spaceID IS NULL OR NOT EXISTS(SELECT 1 FROM spaces WHERE id=NEW.spaceID)
                    BEGIN SELECT RAISE(ABORT,'Every item requires a Space'); END;
                    """)
            }
        }
        let conditions = [
            "documents": "EXISTS(SELECT 1 FROM documents p WHERE p.id=NEW.parentDocumentID AND p.spaceID IS NOT NEW.spaceID) OR EXISTS(SELECT 1 FROM folders f WHERE f.id=NEW.folderID AND f.spaceID IS NOT NEW.spaceID) OR EXISTS(SELECT 1 FROM templates t WHERE t.id=NEW.templateID AND t.spaceID IS NOT NEW.spaceID) OR EXISTS(SELECT 1 FROM documents c WHERE c.parentDocumentID=NEW.id AND c.spaceID IS NOT NEW.spaceID)",
            "folders": "EXISTS(SELECT 1 FROM folders p WHERE p.id=NEW.parentFolderID AND p.spaceID IS NOT NEW.spaceID) OR EXISTS(SELECT 1 FROM folders c WHERE c.parentFolderID=NEW.id AND c.spaceID IS NOT NEW.spaceID) OR EXISTS(SELECT 1 FROM documents d WHERE d.folderID=NEW.id AND d.spaceID IS NOT NEW.spaceID)",
            "templates": "EXISTS(SELECT 1 FROM documents d WHERE d.templateID=NEW.id AND d.spaceID IS NOT NEW.spaceID)"
        ]
        for (table, condition) in conditions {
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_space_relationship_\(event) BEFORE \(event) ON \(table)
                    WHEN (SELECT transferring FROM spaceOwnershipOperation)=0 AND (\(condition))
                    BEGIN SELECT RAISE(ABORT,'Related content must share its Space'); END;
                    """)
            }
        }
        try db.execute(sql: """
            CREATE TRIGGER spaces_delete_owned BEFORE DELETE ON spaces
            WHEN EXISTS(SELECT 1 FROM documents WHERE spaceID=OLD.id) OR EXISTS(SELECT 1 FROM folders WHERE spaceID=OLD.id) OR EXISTS(SELECT 1 FROM templates WHERE spaceID=OLD.id)
            BEGIN SELECT RAISE(ABORT,'Delete Space contents transactionally first'); END;
            CREATE TRIGGER calendarNotes_space_insert BEFORE INSERT ON calendarEventNotes
            WHEN NEW.spaceID IS NOT (SELECT spaceID FROM documents WHERE id=NEW.documentID)
            BEGIN SELECT RAISE(ABORT,'Event notes must share their document Space'); END;
            CREATE TRIGGER calendarNotes_space_update BEFORE UPDATE ON calendarEventNotes
            WHEN (SELECT transferring FROM spaceOwnershipOperation)=0 AND NEW.spaceID IS NOT (SELECT spaceID FROM documents WHERE id=NEW.documentID)
            BEGIN SELECT RAISE(ABORT,'Event notes must share their document Space'); END;
            """)
        for event in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER collectionEntries_space_\(event) BEFORE \(event) ON collectionEntries
                WHEN (SELECT transferring FROM spaceOwnershipOperation)=0 AND EXISTS(
                    SELECT 1 FROM collections c JOIN documents d ON d.id=NEW.documentID
                    JOIN documents p ON p.id=c.documentID WHERE c.id=NEW.collectionID
                    AND (d.parentDocumentID IS NOT c.documentID OR d.spaceID IS NOT p.spaceID))
                BEGIN SELECT RAISE(ABORT,'Collection entries require their owning document and Space'); END;
                """)
        }
        try validate(in: db)
    }
}
