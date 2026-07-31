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
        case .impossibleMove(let message):
            return "Move is not allowed: \(message)"
        }
    }
}

final class AppDatabase: @unchecked Sendable {
    private let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try DatabaseMigrator.vellixMigrator.migrate(writer)
    }

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
        return try AppDatabase(queue)
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

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try writer.read(value)
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try writer.write(updates)
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
                table.column("blockNoteJSON", .text).notNull()
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
                table.column("blockNoteJSON", .text).notNull()
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
                table.column("blockNoteJSON", .text).notNull()
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

        return migrator
    }
}
