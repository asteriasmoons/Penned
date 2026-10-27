//
//  AppDatabase.swift
//  Vellix
//

import Foundation
import GRDB

enum VellixError: LocalizedError, Equatable {
    case database(String)
    case documentNotFound(String)
    case invalidEditorJSON(String)
    case editorBridge(String)
    case attachmentImport(String)
    case snapshotRestore(String)
    case search(String)
    case tagging(String)
    case impossibleMove(String)

    var errorDescription: String? {
        switch self {
        case .database(let message):
            return "Database error: \(message)"
        case .documentNotFound(let id):
            return "Document was not found: \(id)"
        case .invalidEditorJSON(let message):
            return "Invalid editor JSON: \(message)"
        case .editorBridge(let message):
            return "Editor bridge error: \(message)"
        case .attachmentImport(let message):
            return "Attachment import failed: \(message)"
        case .snapshotRestore(let message):
            return "Snapshot restore failed: \(message)"
        case .search(let message):
            return "Search failed: \(message)"
        case .tagging(let message): return message
        case .impossibleMove(let message):
            return "Move is not allowed: \(message)"
        }
    }
}

final class AppDatabase: @unchecked Sendable {
    private let writer: any DatabaseWriter
    let isInMemory: Bool
    let libraryID: String
    private let lease = LibraryLease()

    init(_ writer: any DatabaseWriter, isInMemory: Bool = false) throws {
        self.writer = writer
        self.isInMemory = isInMemory
        self.libraryID = LibraryRecord.localID
        try writer.writeWithoutTransaction { LibraryAccess.configure($0, libraryID: "*") }
        let wasEmpty = try writer.read { db in
            for table in ["spaces", "documents", "folders", "templates"] where try db.tableExists(table) {
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) LIMIT 1)") == true { return false }
            }
            return true
        }
        try DatabaseMigrator.vellixMigrator.migrate(writer)
        // Only a known-empty install can identify migration-created scaffolding.
        // Never classify an existing user's Spaces by title or apparent emptiness.
        if wasEmpty {
            try writer.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO bootstrapSpaces SELECT id FROM spaces WHERE libraryID='local'")
            }
        }
    }

    nonisolated private init(sharing database: AppDatabase, libraryID: String) {
        writer = database.writer
        isInMemory = database.isInMemory
        self.libraryID = libraryID
    }

    nonisolated func scoped(to libraryID: String) -> AppDatabase { AppDatabase(sharing: self, libraryID: libraryID) }
    nonisolated func invalidate() { lease.invalidate() }
    nonisolated var isAccessible: Bool { lease.isValid }

    static func makeShared() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        let directory = try applicationSupportDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let databaseURL = directory.appendingPathComponent("Vellix.sqlite")
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    static func makeInMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(configuration: configuration)
        return try AppDatabase(queue, isInMemory: true)
    }

    static func applicationSupportDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return baseURL.appendingPathComponent(
            "Vellix",
            isDirectory: true
        )
    }

    nonisolated func read<T>(_ value: (Database) throws -> T) throws -> T {
        try writer.read { db in
            try lease.check()
            LibraryAccess.configure(db, libraryID: libraryID)
            return try value(db)
        }
    }

    nonisolated func writeMetadata<T>(_ updates: (Database) throws -> T) throws -> T {
        try writer.write { db in
            try lease.check()
            LibraryAccess.configure(db, libraryID: libraryID)
            return try updates(db)
        }
    }

    nonisolated func write<T>(_ updates: (Database) throws -> T) throws -> T {
        var tasksChanged = false
        var tagsChanged = false
        let value = try writer.write { db in
            try lease.check()
            LibraryAccess.configure(db, libraryID: libraryID)
            let value = try updates(db)
            tasksChanged = try DocumentTaskIndex.reconcile(in: db)
            tagsChanged = try DocumentTagIndex.reconcile(in: db)
            return value
        }
        if tasksChanged { NotificationCenter.default.post(name: .vellixTasksChanged, object: self) }
        if tagsChanged { NotificationCenter.default.post(name: .pennedTagsChanged, object: self) }
        NotificationCenter.default.post(name: .pennedCollectionsChanged, object: self)
        return value
    }
}

extension DatabaseMigrator {
    static var vellixMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_local_document_system") { db in
            try db.create(table: "spaces") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("spaceDescription", .text)
                table.column("icon", .text)
                table.column("isArchived", .boolean).notNull().defaults(to: false)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("sortOrder", .double).notNull().defaults(to: 0)
            }

            try db.create(table: "folders") { table in
                table.column("id", .text).primaryKey()
                table.column("spaceID", .text).references("spaces", onDelete: .setNull)
                table.column("parentFolderID", .text).references("folders", onDelete: .setNull)
                table.column("title", .text).notNull()
                table.column("icon", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("sortOrder", .double).notNull().defaults(to: 0)
            }

            try db.create(table: "templates") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("templateDescription", .text).notNull()
                table.column("icon", .text)
                table.column("tipTapJSON", .text).notNull()
                table.column("category", .text).notNull()
                table.column("isBuiltIn", .boolean).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "documents") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("subtitle", .text)
                table.column("icon", .text)
                table.column("cover", .text)
                table.column("appearanceJSON", .text)
                table.column("tipTapJSON", .text).notNull()
                table.column("plainText", .text).notNull().defaults(to: "")
                table.column("previewText", .text).notNull().defaults(to: "")
                table.column("spaceID", .text).references("spaces", onDelete: .setNull)
                table.column("folderID", .text).references("folders", onDelete: .setNull)
                table.column("parentDocumentID", .text).references("documents", onDelete: .setNull)
                table.column("isFavorite", .boolean).notNull().defaults(to: false)
                table.column("isArchived", .boolean).notNull().defaults(to: false)
                table.column("isTrashed", .boolean).notNull().defaults(to: false)
                table.column("trashedAt", .datetime)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("lastOpenedAt", .datetime)
                table.column("revision", .integer).notNull().defaults(to: 1)
                table.column("documentSchemaVersion", .integer).notNull().defaults(to: 1)
                table.column("wordCount", .integer).notNull().defaults(to: 0)
                table.column("characterCount", .integer).notNull().defaults(to: 0)
                table.column("estimatedReadingMinutes", .integer).notNull().defaults(to: 0)
                table.column("sortOrder", .double).notNull().defaults(to: 0)
                table.column("templateOriginID", .text).references("templates", onDelete: .setNull)
                table.check(sql: "parentDocumentID IS NULL OR parentDocumentID <> id")
            }

            try db.create(index: "documents_space_index", on: "documents", columns: ["spaceID"])
            try db.create(index: "documents_folder_index", on: "documents", columns: ["folderID"])
            try db.create(index: "documents_parent_index", on: "documents", columns: ["parentDocumentID"])
            try db.create(index: "documents_recent_index", on: "documents", columns: ["lastOpenedAt"])
            try db.create(index: "documents_trash_index", on: "documents", columns: ["isTrashed"])

            try db.create(table: "documentSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("documentID", .text).notNull().references("documents", onDelete: .cascade)
                table.column("tipTapJSON", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("revision", .integer).notNull()
                table.column("reason", .text).notNull()
                table.column("isAutomatic", .boolean).notNull()
            }

            try db.create(index: "snapshots_document_index", on: "documentSnapshots", columns: ["documentID", "createdAt"])

            try db.create(table: "attachments") { table in
                table.column("id", .text).primaryKey()
                table.column("documentID", .text).notNull().references("documents", onDelete: .cascade)
                table.column("originalFileName", .text).notNull()
                table.column("storedFileName", .text).notNull()
                table.column("relativePath", .text).notNull()
                table.column("mimeType", .text)
                table.column("uti", .text)
                table.column("fileSize", .integer).notNull()
                table.column("thumbnailRelativePath", .text)
                table.column("createdAt", .datetime).notNull()
            }

            try db.create(index: "attachments_document_index", on: "attachments", columns: ["documentID"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE documentSearch USING fts5(
                    documentID UNINDEXED,
                    title,
                    subtitle,
                    content,
                    preview,
                    tokenize='porter unicode61'
                )
                """
            )
        }

        migrator.registerMigration("v2_document_appearance") { db in
            if try !db.columns(in: "documents").contains(where: { $0.name == "appearanceJSON" }) {
                try db.alter(table: "documents") { table in
                    table.add(column: "appearanceJSON", .text)
                }
            }
        }

        migrator.registerMigration("v3_tiptap_editor_storage") { db in
            try renameEditorColumnIfNeeded(in: db, table: "documents")
            try renameEditorColumnIfNeeded(in: db, table: "documentSnapshots")
            try renameEditorColumnIfNeeded(in: db, table: "templates")
        }

        migrator.registerMigration("v4_nested_page_trash_ownership") { db in
            try db.alter(table: "documents") { table in
                table.add(column: "trashBatchID", .text)
            }
        }

        migrator.registerMigration("v5_inline_page_references") { db in
            let parents = try DocumentRecord.fetchAll(db, sql: """
                SELECT * FROM documents WHERE id IN (
                    SELECT parentDocumentID FROM documents WHERE parentDocumentID IS NOT NULL
                    AND isTrashed = 0 AND isArchived = 0
                )
                """)
            for var parent in parents {
                let children = try String.fetchAll(db, sql: """
                    SELECT id FROM documents WHERE parentDocumentID = ? AND isTrashed = 0 AND isArchived = 0
                    ORDER BY sortOrder ASC, createdAt ASC, id ASC
                    """, arguments: [parent.id])
                let placed = TipTapContentAnalyzer.pageReferenceIDs(in: parent.tipTapJSON)
                guard children.contains(where: { !placed.contains($0) }) else { continue }
                // The old header-only implementation did not save positions. Preserve those pages at the end.
                parent.tipTapJSON = try TipTapContentAnalyzer.appendingPageReferences(to: parent.tipTapJSON, documentIDs: children)
                parent.revision += 1
                try db.execute(sql: "UPDATE documents SET tipTapJSON = ?, revision = ? WHERE id = ?",
                               arguments: [parent.tipTapJSON, parent.revision, parent.id])
            }
        }

        migrator.registerMigration("v6_page_card_style") { db in
            try db.alter(table: "documents") { table in
                table.add(column: "cardStyleJSON", .text)
            }
        }

        migrator.registerMigration("v7_folder_icon_colors") { db in
            try db.alter(table: "folders") { table in
                table.add(column: "iconColorHex", .text)
            }
            try db.create(index: "folders_parent_index", on: "folders", columns: ["parentFolderID"])
        }

        migrator.registerMigration("v8_user_templates_only") { _ in
            // Retain this identifier for existing installations, but never remove legacy templates.
        }

        migrator.registerMigration("v9_structured_templates") { db in
            try db.alter(table: "documents") { table in
                table.add(column: "templateID", .text).references("templates", onDelete: .setNull)
            }
            try db.alter(table: "templates") { table in
                table.add(column: "rootDocumentID", .text).references("documents", onDelete: .setNull)
            }
            try db.create(index: "documents_template_index", on: "documents", columns: ["templateID"])
        }

        migrator.registerMigration("v10_document_styles") { db in
            try db.create(table: "documentStyles") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("styleJSON", .text).notNull()
                table.column("fingerprint", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v11_document_tasks") { db in
            try DocumentTaskIndex.install(in: db)
        }

        migrator.registerMigration("v12_calendar_event_notes") { db in
            try CalendarEventNoteRepository.install(in: db)
        }

        migrator.registerMigration("v13_document_collections") { db in
            try CollectionRepository.install(in: db)
        }

        migrator.registerMigration("v14_embedded_collections") { db in
            try CollectionMigration.embedInOwningDocuments(db)
        }

        let plainAppearanceJSON = DocumentAppearance.plain.encodedJSON()!
        migrator.registerMigration("v15_independent_collection_entry_styles") { db in
            try CollectionMigration.removeInheritedEntryStyles(db, defaultAppearanceJSON: plainAppearanceJSON)
        }

        migrator.registerMigration("v16_independent_spaces") { db in
            try SpaceOwnership.install(in: db)
        }

        migrator.registerMigration("v17_space_images") { db in
            try db.alter(table: "spaces") { table in
                table.add(column: "iconImageData", .blob)
            }
        }

        migrator.registerMigration("v18_daily_notes") { db in
            try DailyNoteMigration.install(in: db)
        }

        migrator.registerMigration("v19_document_tags") { db in
            try DocumentTagIndex.install(in: db)
        }

        migrator.registerMigration("v20_account_library_ownership") { db in
            try LibraryOwnership.install(in: db)
        }
        migrator.registerMigration("v21_library_access_guards") { db in
            try LibraryAccess.install(in: db)
        }
        migrator.registerMigration("v22_cloudkit_record_journal") { db in
            try LibrarySyncSchema.install(in: db)
        }
        migrator.registerMigration("v23_bootstrap_space_provenance") { db in
            try SpaceOwnership.installBootstrapTracking(in: db)
        }
        migrator.registerMigration("v24_task_history_pages") { db in
            try db.execute(sql: "INSERT OR IGNORE INTO taskDocumentChanges SELECT id FROM documents")
            _ = try DocumentTaskIndex.reconcile(in: db)
        }
        migrator.registerMigration("v25_publication_queue") { db in
            try db.execute(sql: """
                CREATE TABLE publicationJobs (
                  ownerKey TEXT NOT NULL, libraryID TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE, documentID TEXT NOT NULL,
                  statusJSON TEXT NOT NULL, intent TEXT NOT NULL DEFAULT 'active',
                  dirty INTEGER NOT NULL DEFAULT 1, sequence INTEGER NOT NULL DEFAULT 1,
                  attempts INTEGER NOT NULL DEFAULT 0, retryAt DOUBLE NOT NULL DEFAULT 0,
                  error TEXT, blocked INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(ownerKey,libraryID,documentID)
                );
                """)
            // Include dependencies and imports, not just editor body revisions. These
            // marks commit/roll back with the original save; hashes coalesce no-ops.
            for table in ["documents", "attachments", "spaces", "documentStyles", "collections", "collectionFields", "collectionViews", "collectionEntries", "collectionValues"] {
                for event in ["INSERT", "UPDATE", "DELETE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER publication_dirty_\(table)_\(event) AFTER \(event) ON \(table)
                        BEGIN UPDATE publicationJobs SET dirty=1,sequence=sequence+1,retryAt=0
                        WHERE intent='active' AND (libraryID=penned_library() OR penned_library()='*'); END;
                        """)
                }
            }
        }
        migrator.registerMigration("v26_publication_revocations") { db in
            try db.execute(sql: """
                CREATE TRIGGER publication_trash AFTER UPDATE OF isTrashed,isArchived ON documents
                WHEN NEW.isTrashed=1 OR NEW.isArchived=1
                BEGIN UPDATE publicationJobs SET intent='stop',dirty=1,blocked=0,retryAt=0,sequence=sequence+1
                WHERE documentID=NEW.id AND intent<>'inactive' AND (libraryID=penned_library() OR penned_library()='*'); END;
                CREATE TRIGGER publication_delete AFTER DELETE ON documents
                BEGIN UPDATE publicationJobs SET intent='stop',dirty=1,blocked=0,retryAt=0,sequence=sequence+1
                WHERE documentID=OLD.id AND intent<>'inactive' AND (libraryID=penned_library() OR penned_library()='*'); END;
                UPDATE publicationJobs SET intent='stop',dirty=1,blocked=0,retryAt=0
                WHERE intent='active' AND (NOT EXISTS(SELECT 1 FROM documents WHERE id=documentID)
                  OR documentID IN (SELECT id FROM documents WHERE isTrashed=1 OR isArchived=1));
                """)
        }

        migrator.registerMigration("v27_publication_collection_views") { db in
            try db.execute(sql: """
                UPDATE publicationJobs SET dirty=1,sequence=sequence+1,retryAt=0
                WHERE intent='active' AND blocked=0;
                """)
        }

        migrator.registerMigration("v28_publication_author_avatar") { db in
            try db.execute(sql: "UPDATE publicationJobs SET dirty=1,sequence=sequence+1,retryAt=0 WHERE intent='active' AND blocked=0 AND json_extract(statusJSON,'$.settings.showAuthor')=1")
        }
        migrator.registerMigration("v29_publication_linked_pages") { db in
            try db.execute(sql: "UPDATE publicationJobs SET dirty=1,sequence=sequence+1,retryAt=0 WHERE intent='active' AND blocked=0 AND json_extract(statusJSON,'$.settings.allowFollowLinkedContent')=1")
        }

        return migrator
    }

    private nonisolated static func renameEditorColumnIfNeeded(
        in db: Database,
        table: String
    ) throws {
        let columns = try db.columns(in: table)
        let hasLegacyColumn = columns.contains { $0.name == "blockNoteJSON" }
        let hasTipTapColumn = columns.contains { $0.name == "tipTapJSON" }

        guard hasLegacyColumn, !hasTipTapColumn else {
            return
        }

        try db.execute(sql: "ALTER TABLE \(table) RENAME COLUMN blockNoteJSON TO tipTapJSON")
    }
}
