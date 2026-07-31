//
//  DocumentRepositories.swift
//  Vellix
//

import Foundation
import GRDB

struct DocumentDraft {
    var title: String
    var subtitle: String?
    var spaceID: String?
    var folderID: String?
    var parentDocumentID: String?
    var templateOriginID: String?
    var cover: String?
    var appearanceJSON: String?
    var blockNoteJSON: String

    init(
        title: String = "Untitled",
        subtitle: String? = nil,
        spaceID: String? = nil,
        folderID: String? = nil,
        parentDocumentID: String? = nil,
        templateOriginID: String? = nil,
        cover: String? = nil,
        appearanceJSON: String? = nil,
        blockNoteJSON: String = BlockNoteContentAnalyzer.emptyDocumentJSON
    ) {
        self.title = title
        self.subtitle = subtitle
        self.spaceID = spaceID
        self.folderID = folderID
        self.parentDocumentID = parentDocumentID
        self.templateOriginID = templateOriginID
        self.cover = cover
        self.appearanceJSON = appearanceJSON
        self.blockNoteJSON = blockNoteJSON
    }
}

final class DocumentRepository: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func create(_ draft: DocumentDraft) throws -> DocumentRecord {
        try database.write { db in
            if let parentID = draft.parentDocumentID {
                _ = try DocumentRecord.fetchOne(db, key: parentID)
                    ?? { throw VellixError.documentNotFound(parentID) }()
            }

            let analysis = try BlockNoteContentAnalyzer.analyze(draft.blockNoteJSON)
            let record = DocumentRecord(
                title: draft.title.trimmedNonEmpty ?? "Untitled",
                subtitle: draft.subtitle?.trimmedNonEmpty,
                cover: draft.cover,
                appearanceJSON: draft.appearanceJSON,
                blockNoteJSON: analysis.canonicalJSON,
                plainText: analysis.plainText,
                previewText: analysis.previewText,
                spaceID: draft.spaceID,
                folderID: draft.folderID,
                parentDocumentID: draft.parentDocumentID,
                lastOpenedAt: Date(),
                wordCount: analysis.wordCount,
                characterCount: analysis.characterCount,
                estimatedReadingMinutes: analysis.estimatedReadingMinutes,
                templateOriginID: draft.templateOriginID
            )

            try record.insert(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func updateAppearance(
        id: String,
        cover: String?,
        appearance: DocumentAppearance
    ) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.cover = cover
            record.appearanceJSON = appearance.encodedJSON()
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func updateIcon(id: String, icon: String?) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.icon = icon?.trimmedNonEmpty
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func allDocuments(includeTrashed: Bool = false) throws -> [DocumentRecord] {
        try database.read { db in
            let sql = includeTrashed
                ? "SELECT * FROM documents ORDER BY updatedAt DESC"
                : "SELECT * FROM documents WHERE isTrashed = 0 AND isArchived = 0 ORDER BY updatedAt DESC"
            return try DocumentRecord.fetchAll(db, sql: sql)
        }
    }

    func document(id: String) throws -> DocumentRecord? {
        try database.read { db in
            try DocumentRecord.fetchOne(db, key: id)
        }
    }

    func requireDocument(id: String) throws -> DocumentRecord {
        guard let document = try document(id: id) else {
            throw VellixError.documentNotFound(id)
        }

        return document
    }

    func recent(limit: Int = 12) throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE isTrashed = 0 AND isArchived = 0
                    ORDER BY COALESCE(lastOpenedAt, updatedAt) DESC, updatedAt DESC, rowid DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func favorites() throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE isFavorite = 1 AND isTrashed = 0 AND isArchived = 0
                    ORDER BY updatedAt DESC
                    """
            )
        }
    }

    func trashed() throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE isTrashed = 1
                    ORDER BY trashedAt DESC
                    """
            )
        }
    }

    func children(of documentID: String) throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE parentDocumentID = ? AND isTrashed = 0
                    ORDER BY sortOrder ASC, updatedAt DESC
                    """,
                arguments: [documentID]
            )
        }
    }

    func documents(inSpace spaceID: String) throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE spaceID = ? AND isTrashed = 0
                    ORDER BY sortOrder ASC, updatedAt DESC
                    """,
                arguments: [spaceID]
            )
        }
    }

    func documents(inFolder folderID: String) throws -> [DocumentRecord] {
        try database.read { db in
            try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE folderID = ? AND isTrashed = 0
                    ORDER BY sortOrder ASC, updatedAt DESC
                    """,
                arguments: [folderID]
            )
        }
    }

    func updateTitle(id: String, title: String) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.title = title.trimmedNonEmpty ?? "Untitled"
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func markOpened(id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE documents SET lastOpenedAt = ? WHERE id = ?",
                arguments: [Date().addingTimeInterval(0.001), id]
            )
        }
    }

    func saveEditorJSON(id: String, canonicalJSON: String) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            let analysis = try BlockNoteContentAnalyzer.analyze(canonicalJSON)

            guard analysis.canonicalJSON != record.blockNoteJSON else {
                return record
            }

            record.blockNoteJSON = analysis.canonicalJSON
            record.plainText = analysis.plainText
            record.previewText = analysis.previewText
            record.wordCount = analysis.wordCount
            record.characterCount = analysis.characterCount
            record.estimatedReadingMinutes = analysis.estimatedReadingMinutes
            record.revision += 1
            record.updatedAt = Date()

            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func setFavorite(id: String, isFavorite: Bool) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.isFavorite = isFavorite
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func duplicate(id: String) throws -> DocumentRecord {
        try database.write { db in
            let source = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            var duplicate = source
            duplicate.id = UUID().uuidString
            duplicate.title = "\(source.title) Copy"
            duplicate.isFavorite = false
            duplicate.isTrashed = false
            duplicate.trashedAt = nil
            duplicate.createdAt = Date()
            duplicate.updatedAt = Date()
            duplicate.lastOpenedAt = Date()
            duplicate.revision = 1
            try duplicate.insert(db)
            try Self.upsertSearchIndex(duplicate, in: db)
            return duplicate
        }
    }

    func move(
        id: String,
        spaceID: String?,
        folderID: String?,
        parentDocumentID: String?
    ) throws -> DocumentRecord {
        try database.write { db in
            if let parentDocumentID {
                try Self.validateParent(parentID: parentDocumentID, childID: id, in: db)
            }

            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.spaceID = spaceID
            record.folderID = folderID
            record.parentDocumentID = parentDocumentID
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func trash(id: String) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.isTrashed = true
            record.trashedAt = Date()
            record.updatedAt = Date()
            try record.update(db)
            try Self.deleteSearchIndex(id: id, in: db)
            return record
        }
    }

    func restore(id: String) throws -> DocumentRecord {
        try database.write { db in
            var record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            record.isTrashed = false
            record.trashedAt = nil
            record.updatedAt = Date()
            try record.update(db)
            try Self.upsertSearchIndex(record, in: db)
            return record
        }
    }

    func permanentlyDelete(id: String, attachmentStore: AttachmentStore? = nil) throws {
        try database.write { db in
            let attachments = try AttachmentRecord.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE documentID = ?",
                arguments: [id]
            )
            for attachment in attachments {
                try attachmentStore?.removeFile(relativePath: attachment.relativePath)
            }
            try Self.deleteSearchIndex(id: id, in: db)
            try db.execute(
                sql: "UPDATE documents SET parentDocumentID = NULL WHERE parentDocumentID = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
        }
    }

    func breadcrumbParents(for id: String) throws -> [DocumentRecord] {
        try database.read { db in
            var result: [DocumentRecord] = []
            var seen: Set<String> = [id]
            var current = try DocumentRecord.fetchOne(db, key: id)

            while let parentID = current?.parentDocumentID, !seen.contains(parentID) {
                seen.insert(parentID)
                guard let parent = try DocumentRecord.fetchOne(db, key: parentID) else {
                    break
                }
                result.insert(parent, at: 0)
                current = parent
            }

            return result
        }
    }

    private static func validateParent(parentID: String, childID: String, in db: Database) throws {
        guard parentID != childID else {
            throw VellixError.impossibleMove("A document cannot be moved under itself.")
        }

        var currentID: String? = parentID
        var seen: Set<String> = [childID]
        while let id = currentID {
            if seen.contains(id) {
                throw VellixError.impossibleMove("That move would create a nested document cycle.")
            }
            seen.insert(id)
            currentID = try String.fetchOne(
                db,
                sql: "SELECT parentDocumentID FROM documents WHERE id = ?",
                arguments: [id]
            )
        }
    }

    static func upsertSearchIndex(_ record: DocumentRecord, in db: Database) throws {
        try deleteSearchIndex(id: record.id, in: db)
        guard !record.isTrashed && !record.isArchived else {
            return
        }

        try db.execute(
            sql: """
                INSERT INTO documentSearch(documentID, title, subtitle, content, preview)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                record.id,
                record.title,
                record.subtitle ?? "",
                record.plainText,
                record.previewText
            ]
        )
    }

    static func deleteSearchIndex(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM documentSearch WHERE documentID = ?", arguments: [id])
    }
}

final class SpaceRepository: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func all() throws -> [SpaceRecord] {
        try database.read { db in
            try SpaceRecord.fetchAll(
                db,
                sql: "SELECT * FROM spaces WHERE isArchived = 0 ORDER BY sortOrder ASC, updatedAt DESC"
            )
        }
    }

    func create(title: String, description: String? = nil) throws -> SpaceRecord {
        try database.write { db in
            let record = SpaceRecord(
                title: title.trimmedNonEmpty ?? "New Space",
                spaceDescription: description,
                icon: "rectangle.stack"
            )
            try record.insert(db)
            return record
        }
    }

    func rename(id: String, title: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE spaces SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title.trimmedNonEmpty ?? "Space", Date(), id]
            )
        }
    }

    func archive(id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE spaces SET isArchived = 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
}

final class FolderRepository: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func all() throws -> [FolderRecord] {
        try database.read { db in
            try FolderRecord.fetchAll(
                db,
                sql: "SELECT * FROM folders ORDER BY sortOrder ASC, updatedAt DESC"
            )
        }
    }

    func create(title: String, spaceID: String? = nil, parentFolderID: String? = nil) throws -> FolderRecord {
        try database.write { db in
            let record = FolderRecord(
                spaceID: spaceID,
                parentFolderID: parentFolderID,
                title: title.trimmedNonEmpty ?? "New Folder",
                icon: "folder"
            )
            try record.insert(db)
            return record
        }
    }

    func rename(id: String, title: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE folders SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title.trimmedNonEmpty ?? "Folder", Date(), id]
            )
        }
    }
}

final class TemplateRepository: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func all() throws -> [TemplateRecord] {
        try database.read { db in
            try TemplateRecord.fetchAll(
                db,
                sql: "SELECT * FROM templates ORDER BY isBuiltIn DESC, category ASC, title ASC"
            )
        }
    }

    func seedBuiltIns() throws {
        try database.write { db in
            for template in Self.builtInTemplates {
                if try TemplateRecord.fetchOne(db, key: template.id) == nil {
                    let copy = template
                    try copy.insert(db)
                }
            }
        }
    }

    func saveUserTemplate(from document: DocumentRecord, title: String) throws -> TemplateRecord {
        try database.write { db in
            let template = TemplateRecord(
                title: title.trimmedNonEmpty ?? document.title,
                templateDescription: "Saved from \(document.title)",
                icon: document.icon,
                blockNoteJSON: document.blockNoteJSON,
                category: "Mine",
                isBuiltIn: false
            )
            try template.insert(db)
            return template
        }
    }

    func rename(id: String, title: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE templates SET title = ?, updatedAt = ? WHERE id = ? AND isBuiltIn = 0",
                arguments: [title.trimmedNonEmpty ?? "Template", Date(), id]
            )
        }
    }

    func delete(id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM templates WHERE id = ? AND isBuiltIn = 0", arguments: [id])
        }
    }

    static let builtInTemplates: [TemplateRecord] = [
        TemplateRecord(
            id: "built-in.blank",
            title: "Blank Document",
            templateDescription: "A clean page for anything.",
            icon: "doc",
            blockNoteJSON: BlockNoteContentAnalyzer.emptyDocumentJSON,
            category: "Starter",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.daily-note",
            title: "Daily Note",
            templateDescription: "A quiet structure for the day.",
            icon: "calendar",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Daily Note", lines: ["Today", "Focus", "Notes"]),
            category: "Planning",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.project-plan",
            title: "Project Plan",
            templateDescription: "Goals, milestones, and open questions.",
            icon: "checklist",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Project Plan", lines: ["Overview", "Milestones", "Risks"]),
            category: "Planning",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.meeting-notes",
            title: "Meeting Notes",
            templateDescription: "Agenda, decisions, and follow-ups.",
            icon: "person.2",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Meeting Notes", lines: ["Agenda", "Decisions", "Follow-ups"]),
            category: "Work",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.brainstorm",
            title: "Brainstorm",
            templateDescription: "Room for loose ideas and clusters.",
            icon: "sparkles",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Brainstorm", lines: ["Ideas", "Connections", "Next"]),
            category: "Creative",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.journal",
            title: "Journal Entry",
            templateDescription: "A reflective personal entry.",
            icon: "book.closed",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Journal Entry", lines: ["What happened", "What I noticed", "What matters"]),
            category: "Personal",
            isBuiltIn: true
        ),
        TemplateRecord(
            id: "built-in.reading-notes",
            title: "Reading Notes",
            templateDescription: "Capture quotes, thoughts, and references.",
            icon: "books.vertical",
            blockNoteJSON: BlockNoteContentAnalyzer.starterDocument(title: "Reading Notes", lines: ["Source", "Notes", "Key ideas"]),
            category: "Research",
            isBuiltIn: true
        )
    ]
}

final class SnapshotRepository: @unchecked Sendable {
    private let database: AppDatabase
    private let automaticLimit: Int

    init(database: AppDatabase, automaticLimit: Int = 20) {
        self.database = database
        self.automaticLimit = automaticLimit
    }

    func create(document: DocumentRecord, reason: SnapshotReason) throws -> DocumentSnapshotRecord {
        try database.write { db in
            let snapshot = DocumentSnapshotRecord(
                documentID: document.id,
                blockNoteJSON: document.blockNoteJSON,
                revision: document.revision,
                reason: reason,
                isAutomatic: reason == .automatic
            )
            try snapshot.insert(db)
            if reason == .automatic {
                try Self.pruneAutomatic(documentID: document.id, limit: automaticLimit, in: db)
            }
            return snapshot
        }
    }

    func history(documentID: String) throws -> [DocumentSnapshotRecord] {
        try database.read { db in
            try DocumentSnapshotRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documentSnapshots
                    WHERE documentID = ?
                    ORDER BY createdAt DESC
                    """,
                arguments: [documentID]
            )
        }
    }

    func restore(snapshotID: String) throws -> DocumentRecord {
        try database.write { db in
            let snapshot = try DocumentSnapshotRecord.fetchOne(db, key: snapshotID)
                ?? { throw VellixError.snapshotRestore("Snapshot was not found.") }()
            var document = try DocumentRecord.fetchOne(db, key: snapshot.documentID)
                ?? { throw VellixError.documentNotFound(snapshot.documentID) }()
            let analysis = try BlockNoteContentAnalyzer.analyze(snapshot.blockNoteJSON)

            let currentSnapshot = DocumentSnapshotRecord(
                documentID: document.id,
                blockNoteJSON: document.blockNoteJSON,
                revision: document.revision,
                reason: .recovery,
                isAutomatic: false
            )
            try currentSnapshot.insert(db)

            document.blockNoteJSON = analysis.canonicalJSON
            document.plainText = analysis.plainText
            document.previewText = analysis.previewText
            document.wordCount = analysis.wordCount
            document.characterCount = analysis.characterCount
            document.estimatedReadingMinutes = analysis.estimatedReadingMinutes
            document.revision += 1
            document.updatedAt = Date()
            try document.update(db)
            try DocumentRepository.upsertSearchIndex(document, in: db)
            return document
        }
    }

    func delete(snapshotID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM documentSnapshots WHERE id = ?", arguments: [snapshotID])
        }
    }

    private static func pruneAutomatic(documentID: String, limit: Int, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM documentSnapshots
                WHERE id IN (
                    SELECT id FROM documentSnapshots
                    WHERE documentID = ? AND isAutomatic = 1
                    ORDER BY createdAt DESC
                    LIMIT -1 OFFSET ?
                )
                """,
            arguments: [documentID, limit]
        )
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
