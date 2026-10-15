//
//  DocumentRepositories.swift
//  Vellix
//

import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

struct DocumentDraft {
    var title: String
    var subtitle: String?
    var spaceID: String?
    var folderID: String?
    var parentDocumentID: String?
    var templateOriginID: String?
    var cover: String?
    var appearanceJSON: String?
    var cardStyleJSON: String?
    var tipTapJSON: String

    init(
        title: String = "Untitled",
        subtitle: String? = nil,
        spaceID: String? = nil,
        folderID: String? = nil,
        parentDocumentID: String? = nil,
        templateOriginID: String? = nil,
        cover: String? = nil,
        appearanceJSON: String? = nil,
        cardStyleJSON: String? = nil,
        tipTapJSON: String = TipTapContentAnalyzer.emptyDocumentJSON
    ) {
        self.title = title
        self.subtitle = subtitle
        self.spaceID = spaceID
        self.folderID = folderID
        self.parentDocumentID = parentDocumentID
        self.templateOriginID = templateOriginID
        self.cover = cover
        self.appearanceJSON = appearanceJSON
        self.cardStyleJSON = cardStyleJSON
        self.tipTapJSON = tipTapJSON
    }
}

final class DocumentRepository: @unchecked Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func create(_ draft: DocumentDraft) throws -> DocumentRecord {
        try database.write { try create(draft, in: $0) }
    }

    // Shared by document creation and atomic event-note/document association writes.
    func create(_ draft: DocumentDraft, in db: Database) throws -> DocumentRecord {
        if let parentID = draft.parentDocumentID {
            let parent = try DocumentRecord.fetchOne(db, key: parentID)
                ?? { throw VellixError.documentNotFound(parentID) }()
            guard !parent.isTrashed && !parent.isArchived else {
                throw VellixError.impossibleMove("Restore the parent page before adding nested pages.")
            }
        }

        let analysis = try TipTapContentAnalyzer.analyze(draft.tipTapJSON)
        let record = DocumentRecord(
            title: draft.title.trimmedNonEmpty ?? "Untitled",
            subtitle: draft.subtitle?.trimmedNonEmpty,
            cover: draft.cover,
            appearanceJSON: draft.appearanceJSON,
            cardStyleJSON: draft.cardStyleJSON,
            tipTapJSON: analysis.canonicalJSON,
            plainText: analysis.plainText,
            previewText: analysis.previewText,
            spaceID: draft.spaceID,
            folderID: draft.folderID,
            parentDocumentID: draft.parentDocumentID,
            lastOpenedAt: Date(),
            wordCount: analysis.wordCount,
            characterCount: analysis.characterCount,
            estimatedReadingMinutes: analysis.estimatedReadingMinutes,
            templateOriginID: draft.templateOriginID,
            templateID: try draft.parentDocumentID.flatMap { try DocumentRecord.fetchOne(db, key: $0)?.templateID }
        )

        try record.insert(db)
        try Self.upsertSearchIndex(record, in: db)
        return record
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

    func savePageCard(parentID: String, documentID: String?, style: PageCardStyle,
                      imageData: Data?, attachmentStore: AttachmentStore) throws -> DocumentRecord {
        var importedPath: String?
        do {
            return try database.write { db in
                let parent = try DocumentRecord.fetchOne(db, key: parentID)
                    ?? { throw VellixError.documentNotFound(parentID) }()
                guard !parent.isTrashed && !parent.isArchived else {
                    throw VellixError.impossibleMove("Restore the parent page before editing cards.")
                }
                var record: DocumentRecord
                if let documentID {
                    record = try DocumentRecord.fetchOne(db, key: documentID)
                        ?? { throw VellixError.documentNotFound(documentID) }()
                    guard record.parentDocumentID == parentID, !record.isTrashed, !record.isArchived else {
                        throw VellixError.impossibleMove("This page is no longer available in this document.")
                    }
                } else {
                    record = DocumentRecord(title: "Untitled", spaceID: parent.spaceID,
                                            folderID: parent.folderID, parentDocumentID: parent.id, templateID: parent.templateID)
                    try record.insert(db)
                }
                var savedStyle = style
                if savedStyle.backdrop == .photo, savedStyle.remotePhoto == nil, let imageData {
                    guard CardImageLoader.image(data: imageData) != nil,
                          let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                          let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else {
                        throw VellixError.impossibleMove("Choose a supported image smaller than 20 MB.")
                    }
                    let attachment = try attachmentStore.importData(imageData,
                        originalFileName: "Card Background.\(type.preferredFilenameExtension ?? "jpg")",
                        mimeType: type.preferredMIMEType, documentID: record.id)
                    importedPath = attachment.relativePath
                    try attachment.insert(db)
                    savedStyle.imagePath = attachment.relativePath
                }
                if savedStyle.remotePhoto != nil { savedStyle.imagePath = nil }
                record.cardStyleJSON = savedStyle.encodedJSON()
                record.updatedAt = Date()
                try record.update(db)
                try Self.upsertSearchIndex(record, in: db)
                return record
            }
        } catch {
            if let importedPath { try? attachmentStore.removeFile(relativePath: importedPath) }
            throw error
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
                ? "SELECT * FROM documents WHERE parentDocumentID IS NULL AND templateID IS NULL ORDER BY updatedAt DESC"
                : "SELECT * FROM documents WHERE parentDocumentID IS NULL AND templateID IS NULL AND isTrashed = 0 AND isArchived = 0 ORDER BY updatedAt DESC"
            return try DocumentRecord.fetchAll(db, sql: sql)
        }
    }

    // Editor ownership includes nested pages even though library lists do not.
    func editorDocuments(excludingCollectionEntries: Bool = false) throws -> [DocumentRecord] {
        try database.read { db in
            let condition = excludingCollectionEntries ? " WHERE id NOT IN (SELECT documentID FROM collectionEntries)" : ""
            return try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents\(condition) ORDER BY createdAt ASC")
        }
    }

    func existingDocumentIDs() throws -> Set<String> {
        try database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM documents")) }
    }

    func effectiveAppearance(for document: DocumentRecord) throws -> DocumentAppearance {
        document.appearance
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
                    WHERE parentDocumentID IS NULL AND templateID IS NULL AND isTrashed = 0 AND isArchived = 0
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
                    WHERE parentDocumentID IS NULL AND templateID IS NULL AND isFavorite = 1 AND isTrashed = 0 AND isArchived = 0
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
                    SELECT d.* FROM documents d
                    WHERE d.templateID IS NULL AND d.isTrashed = 1 AND NOT EXISTS (
                        SELECT 1 FROM documents p WHERE p.id = d.parentDocumentID AND p.isTrashed = 1
                    )
                    ORDER BY d.trashedAt DESC
                    """
            )
        }
    }

    func children(of documentID: String, includingCollectionEntries: Bool = true) throws -> [DocumentRecord] {
        try database.read { db in
            let condition = includingCollectionEntries ? "" : " AND id NOT IN (SELECT documentID FROM collectionEntries)"
            return try DocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE parentDocumentID = ? AND isTrashed = 0 AND isArchived = 0\(condition)
                    ORDER BY sortOrder ASC, createdAt ASC, id ASC
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
                    WHERE parentDocumentID IS NULL AND templateID IS NULL AND spaceID = ? AND isTrashed = 0 AND isArchived = 0
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
                    WHERE parentDocumentID IS NULL AND templateID IS NULL AND folderID = ? AND isTrashed = 0 AND isArchived = 0
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
            let analysis = try TipTapContentAnalyzer.analyze(canonicalJSON)

            guard analysis.canonicalJSON != record.tipTapJSON else {
                return record
            }

            record.tipTapJSON = analysis.canonicalJSON
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

    func duplicate(id: String, attachmentStore: AttachmentStore? = nil) throws -> DocumentRecord {
        var copiedPaths: [String] = []
        do { return try database.write { db in
            let source = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            var duplicate = source
            duplicate.id = UUID().uuidString
            duplicate.title = "\(source.title) Copy"
            duplicate.isFavorite = false
            duplicate.isTrashed = false
            duplicate.trashedAt = nil
            duplicate.trashBatchID = nil
            duplicate.createdAt = Date()
            duplicate.updatedAt = Date()
            duplicate.lastOpenedAt = Date()
            duplicate.revision = 1
            try duplicate.insert(db)
            try Self.copyCardBackground(from: source, to: &duplicate, store: attachmentStore, paths: &copiedPaths, in: db)
            try Self.copyCover(from: source, to: &duplicate, store: attachmentStore, paths: &copiedPaths, in: db)
            try Self.upsertSearchIndex(duplicate, in: db)
            var allIDs = [source.id: duplicate.id]
            let pageIDs = try Self.duplicateChildren(of: source.id, under: duplicate.id, store: attachmentStore, paths: &copiedPaths, documentIDs: &allIDs, in: db)
            duplicate.tipTapJSON = try StructuredTemplateContent.independentTasks(
                TipTapContentAnalyzer.remappingPageReferences(in: duplicate.tipTapJSON, documentIDs: pageIDs))
            try duplicate.update(db)
            try CollectionRepository.copyCollections(documentIDs: allIDs, in: db)
            return try DocumentRecord.fetchOne(db, key: duplicate.id)!
        } } catch {
            for path in copiedPaths { try? attachmentStore?.removeFile(relativePath: path) }
            throw error
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
            if record.parentDocumentID != parentDocumentID,
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM collectionEntries WHERE documentID = ?)", arguments: [id]) == true {
                throw VellixError.impossibleMove("Collection entries stay inside their collection. Use entry actions to reorder or delete them.")
            }
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
            let record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            let timestamp = Date()
            let trashBatchID = UUID().uuidString
            for var descendant in try Self.subtree(id: id, in: db) where !descendant.isTrashed {
                descendant.isTrashed = true
                descendant.trashedAt = timestamp
                descendant.trashBatchID = trashBatchID
                descendant.updatedAt = timestamp
                try descendant.update(db)
                try Self.deleteSearchIndex(id: descendant.id, in: db)
            }
            return try DocumentRecord.fetchOne(db, key: record.id)!
        }
    }

    func restore(id: String) throws -> DocumentRecord {
        try database.write { db in
            let record = try DocumentRecord.fetchOne(db, key: id)
                ?? { throw VellixError.documentNotFound(id) }()
            if let parentID = record.parentDocumentID,
               try DocumentRecord.fetchOne(db, key: parentID)?.isTrashed == true {
                throw VellixError.impossibleMove("Restore this page's parent first.")
            }
            for var descendant in try Self.subtree(id: id, in: db)
                where descendant.id == id || (descendant.isTrashed && record.trashBatchID != nil && descendant.trashBatchID == record.trashBatchID) {
                descendant.isTrashed = false
                descendant.trashedAt = nil
                descendant.trashBatchID = nil
                descendant.updatedAt = Date()
                try descendant.update(db)
                try Self.upsertSearchIndex(descendant, in: db)
            }
            return try DocumentRecord.fetchOne(db, key: id)!
        }
    }

    func permanentlyDelete(id: String, attachmentStore: AttachmentStore? = nil) throws {
        try database.write { db in
            // Resolve ownership before deletion; never promote nested pages into All Pages.
            let descendants = try Self.subtree(id: id, in: db)
            for descendant in descendants {
                let attachments = try AttachmentRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM attachments WHERE documentID = ?",
                    arguments: [descendant.id]
                )
                for attachment in attachments {
                    try attachmentStore?.removeFile(relativePath: attachment.relativePath)
                }
                try Self.deleteSearchIndex(id: descendant.id, in: db)
                try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [descendant.id])
            }
        }
    }

    private static func subtree(id: String, in db: Database) throws -> [DocumentRecord] {
        try DocumentRecord.fetchAll(db, sql: """
            WITH RECURSIVE owned(id) AS (
                SELECT id FROM documents WHERE id = ?
                UNION SELECT d.id FROM documents d JOIN owned p ON d.parentDocumentID = p.id
            )
            SELECT d.* FROM documents d JOIN owned ON owned.id = d.id
            """, arguments: [id])
    }

    private static func copyCardBackground(from source: DocumentRecord, to copy: inout DocumentRecord,
                                          store: AttachmentStore?, paths: inout [String], in db: Database) throws {
        guard var style = source.cardStyle, let path = style.imagePath else { return }
        guard let store else { throw VellixError.impossibleMove("The card image store is unavailable.") }
        let attachment = try store.importFile(at: store.fileURL(relativePath: path), documentID: copy.id)
        paths.append(attachment.relativePath)
        try attachment.insert(db)
        style.imagePath = attachment.relativePath
        copy.cardStyleJSON = style.encodedJSON()
        try copy.update(db)
    }

    private static func copyCover(from source: DocumentRecord, to copy: inout DocumentRecord,
                                  store: AttachmentStore?, paths: inout [String], in db: Database) throws {
        guard let path = source.cover else { return }
        guard let store else { throw VellixError.impossibleMove("The cover image store is unavailable.") }
        let asset = try store.importFile(at: store.fileURL(relativePath: path), documentID: copy.id)
        paths.append(asset.relativePath)
        try asset.insert(db)
        copy.cover = asset.relativePath
        try copy.update(db)
    }

    private static func duplicateChildren(of sourceID: String, under parentID: String, store: AttachmentStore?, paths: inout [String], documentIDs: inout [String: String], in db: Database) throws -> [String: String] {
        let children = try DocumentRecord.fetchAll(db, sql: """
            SELECT * FROM documents WHERE parentDocumentID = ? AND isTrashed = 0 AND isArchived = 0
            ORDER BY sortOrder ASC, createdAt ASC
            """, arguments: [sourceID])
        var pageIDs: [String: String] = [:]
        for child in children {
            var copy = child
            copy.id = UUID().uuidString
            pageIDs[child.id] = copy.id
            documentIDs[child.id] = copy.id
            copy.parentDocumentID = parentID
            copy.isFavorite = false
            copy.trashBatchID = nil
            copy.createdAt = Date()
            copy.updatedAt = Date()
            copy.lastOpenedAt = nil
            copy.revision = 1
            try copy.insert(db)
            try copyCardBackground(from: child, to: &copy, store: store, paths: &paths, in: db)
            try copyCover(from: child, to: &copy, store: store, paths: &paths, in: db)
            try upsertSearchIndex(copy, in: db)
            let descendantIDs = try duplicateChildren(of: child.id, under: copy.id, store: store, paths: &paths, documentIDs: &documentIDs, in: db)
            copy.tipTapJSON = try StructuredTemplateContent.independentTasks(
                TipTapContentAnalyzer.remappingPageReferences(in: copy.tipTapJSON, documentIDs: descendantIDs))
            try copy.update(db)
        }
        return pageIDs
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

        let parent = try DocumentRecord.fetchOne(db, key: parentID)
            ?? { throw VellixError.documentNotFound(parentID) }()
        guard !parent.isTrashed && !parent.isArchived else {
            throw VellixError.impossibleMove("Restore the parent page before moving pages into it.")
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
        if record.templateID != nil {
            try db.execute(sql: "UPDATE templates SET title = ?, icon = ?, tipTapJSON = ?, updatedAt = ? WHERE rootDocumentID = ?",
                arguments: [record.title, record.icon, record.tipTapJSON, record.updatedAt, record.id])
        }
        guard record.templateID == nil, !record.isTrashed && !record.isArchived else {
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

    func create(title: String, spaceID: String? = nil, parentFolderID: String? = nil,
                icon: String = "linesfolderfill", iconColorHex: String? = nil) throws -> FolderRecord {
        try database.write { db in
            let parent = try parentFolderID.map { try Self.requireFolder($0, in: db) }
            let record = FolderRecord(
                spaceID: parent == nil ? spaceID : parent?.spaceID,
                parentFolderID: parentFolderID,
                title: title.trimmedNonEmpty ?? "New Folder",
                icon: icon,
                iconColorHex: iconColorHex
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

    func update(id: String, title: String, icon: String, iconColorHex: String?) throws -> FolderRecord {
        try database.write { db in
            var record = try Self.requireFolder(id, in: db)
            record.title = title.trimmedNonEmpty ?? "Folder"
            record.icon = icon
            record.iconColorHex = iconColorHex
            record.updatedAt = Date()
            try record.update(db)
            return record
        }
    }

    // Folders and pages move together in one transaction; page ownership is never detached.
    func move(documentIDs: Set<String>, folderIDs: Set<String>, to destinationID: String?) throws {
        try database.write { db in
            let destination = try destinationID.map { try Self.requireFolder($0, in: db) }
            let all = try FolderRecord.fetchAll(db)
            let hierarchy = FolderHierarchy(folders: all)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            for id in folderIDs { _ = try Self.requireFolder(id, in: db) }
            var cursor = destinationID
            var visited: Set<String> = []
            while let id = cursor {
                guard visited.insert(id).inserted, !folderIDs.contains(id), let folder = byID[id] else {
                    throw VellixError.impossibleMove("A folder cannot be moved inside itself or one of its child folders.")
                }
                cursor = folder.parentFolderID
            }

            let pages = try documentIDs.map { id -> DocumentRecord in
                guard let page = try DocumentRecord.fetchOne(db, key: id) else { throw VellixError.documentNotFound(id) }
                guard page.parentDocumentID == nil, !page.isTrashed, !page.isArchived else {
                    throw VellixError.impossibleMove("Only library pages can be moved between folders. Nested pages stay inside their parent page.")
                }
                return page
            }
            let movingTree = hierarchy.descendants(including: folderIDs)
            let roots = folderIDs.filter { id in
                !hierarchy.path(to: id).dropLast().contains { folderIDs.contains($0.id) }
            }
            let now = Date()
            for id in roots {
                var folder = try Self.requireFolder(id, in: db)
                folder.parentFolderID = destinationID
                folder.updatedAt = now
                try folder.update(db)
            }
            if let destination {
                for id in movingTree {
                    try db.execute(sql: "UPDATE folders SET spaceID = ?, updatedAt = ? WHERE id = ?",
                        arguments: [destination.spaceID, now, id])
                    try db.execute(sql: """
                        WITH RECURSIVE subtree(id) AS (
                            SELECT id FROM documents WHERE folderID = ? AND parentDocumentID IS NULL
                            UNION SELECT d.id FROM documents d JOIN subtree s ON d.parentDocumentID = s.id
                        )
                        UPDATE documents SET folderID = ?, spaceID = ?, updatedAt = ?
                        WHERE id IN (SELECT id FROM subtree)
                        """, arguments: [id, id, destination.spaceID, now])
                }
            }
            for page in pages where !movingTree.contains(page.folderID ?? "") {
                let targetSpace = destination == nil ? page.spaceID : destination?.spaceID
                try db.execute(sql: """
                    WITH RECURSIVE subtree(id) AS (
                        SELECT id FROM documents WHERE id = ?
                        UNION SELECT d.id FROM documents d JOIN subtree s ON d.parentDocumentID = s.id
                    )
                    UPDATE documents SET folderID = ?, spaceID = ?, updatedAt = ?
                    WHERE id IN (SELECT id FROM subtree)
                    """, arguments: [page.id, destinationID, targetSpace, now])
            }
        }
    }

    private static func requireFolder(_ id: String, in db: Database) throws -> FolderRecord {
        guard let folder = try FolderRecord.fetchOne(db, key: id) else {
            throw VellixError.impossibleMove("This folder no longer exists.")
        }
        return folder
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
                sql: "SELECT * FROM templates ORDER BY category ASC, title ASC"
            )
        }
    }

    func create(title: String = "Untitled Template") throws -> DocumentRecord {
        try database.write { db in
            var template = TemplateRecord(title: title, templateDescription: "", tipTapJSON: TipTapContentAnalyzer.emptyDocumentJSON,
                category: "Mine", isBuiltIn: false)
            try template.insert(db)
            let document = DocumentRecord(title: title, templateID: template.id)
            try document.insert(db)
            template.rootDocumentID = document.id
            try template.update(db)
            return document
        }
    }

    func saveUserTemplate(from document: DocumentRecord, title: String, attachmentStore: AttachmentStore? = nil) throws -> TemplateRecord {
        var copiedPaths: [String] = []
        do {
            return try database.write { db in
                var template = TemplateRecord(title: title.trimmedNonEmpty ?? document.title, templateDescription: "",
                    icon: document.icon, tipTapJSON: document.tipTapJSON, category: "Mine", isBuiltIn: false)
                try template.insert(db)
                let root = try cloneTree(sourceID: document.id, title: template.title, templateID: template.id,
                    originID: nil, spaceID: nil, folderID: nil, parentID: nil, store: attachmentStore, paths: &copiedPaths, in: db)
                template.rootDocumentID = root.id
                template.tipTapJSON = root.tipTapJSON
                try template.update(db)
                return template
            }
        } catch {
            for path in copiedPaths { try? attachmentStore?.removeFile(relativePath: path) }
            throw error
        }
    }

    func editingDocument(id: String, attachmentStore: AttachmentStore? = nil) throws -> DocumentRecord {
        var paths: [String] = []
        do {
            return try database.write { db in
                let template = try requireTemplate(id, in: db)
                guard !template.isBuiltIn else { throw VellixError.impossibleMove("Duplicate this template before editing it.") }
                return try materialize(template, store: attachmentStore, paths: &paths, in: db)
            }
        } catch {
            for path in paths { try? attachmentStore?.removeFile(relativePath: path) }
            throw error
        }
    }

    func instantiate(id: String, title: String, spaceID: String?, folderID: String?, parentID: String?,
                     attachmentStore: AttachmentStore) throws -> DocumentRecord {
        var copiedPaths: [String] = []
        do {
            return try database.write { db in
                let template = try requireTemplate(id, in: db)
                let root = try materialize(template, store: attachmentStore, paths: &copiedPaths, in: db)
                if let parentID {
                    guard let parent = try DocumentRecord.fetchOne(db, key: parentID), !parent.isTrashed,
                          !parent.isArchived, parent.templateID == nil else {
                        throw VellixError.impossibleMove("Choose an available document for this template.")
                    }
                }
                return try cloneTree(sourceID: root.id, title: title, templateID: nil, originID: id,
                    spaceID: spaceID, folderID: folderID, parentID: parentID,
                    store: attachmentStore, paths: &copiedPaths, in: db)
            }
        } catch {
            for path in copiedPaths { try? attachmentStore.removeFile(relativePath: path) }
            throw error
        }
    }

    func duplicate(id: String, attachmentStore: AttachmentStore) throws -> TemplateRecord {
        var paths: [String] = []
        let document: DocumentRecord
        do {
            document = try database.write { db in
                try materialize(requireTemplate(id, in: db), store: attachmentStore, paths: &paths, in: db)
            }
        } catch {
            for path in paths { try? attachmentStore.removeFile(relativePath: path) }
            throw error
        }
        return try saveUserTemplate(from: document, title: document.title + " Copy", attachmentStore: attachmentStore)
    }

    func rename(id: String, title: String) throws {
        try database.write { db in
            let template = try requireTemplate(id, in: db)
            guard !template.isBuiltIn else { return }
            let name = title.trimmedNonEmpty ?? "Template"
            try db.execute(
                sql: "UPDATE templates SET title = ?, updatedAt = ? WHERE id = ? AND isBuiltIn = 0",
                arguments: [name, Date(), id]
            )
            if let rootID = template.rootDocumentID {
                try db.execute(sql: "UPDATE documents SET title = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), rootID])
            }
        }
    }

    func delete(id: String, attachmentStore: AttachmentStore? = nil) throws {
        let paths: [String] = try database.write { db in
            guard !(try requireTemplate(id, in: db)).isBuiltIn else { return [] }
            let paths = try String.fetchAll(db, sql: "SELECT relativePath FROM attachments WHERE documentID IN (SELECT id FROM documents WHERE templateID = ?)", arguments: [id])
            try db.execute(sql: "UPDATE documents SET templateOriginID = NULL WHERE templateOriginID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM documentSearch WHERE documentID IN (SELECT id FROM documents WHERE templateID = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM documents WHERE templateID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM templates WHERE id = ? AND isBuiltIn = 0", arguments: [id])
            return paths
        }
        for path in paths { try? attachmentStore?.removeFile(relativePath: path) }
    }

    private func requireTemplate(_ id: String, in db: Database) throws -> TemplateRecord {
        guard let record = try TemplateRecord.fetchOne(db, key: id) else {
            throw VellixError.impossibleMove("This template no longer exists.")
        }
        return record
    }

    private func materialize(_ template: TemplateRecord, store: AttachmentStore?, paths: inout [String], in db: Database) throws -> DocumentRecord {
        if let id = template.rootDocumentID, let document = try DocumentRecord.fetchOne(db, key: id) { return document }
        let analysis = try TipTapContentAnalyzer.analyze(StructuredTemplateContent.independentTasks(template.tipTapJSON))
        var root = DocumentRecord(title: template.title, icon: template.icon, tipTapJSON: analysis.canonicalJSON,
            plainText: analysis.plainText, previewText: analysis.previewText, templateID: template.id)
        try root.insert(db)
        var pageIDs: [String: String] = [:]
        for pageID in TipTapContentAnalyzer.pageReferenceIDs(in: root.tipTapJSON) {
            guard let source = try DocumentRecord.fetchOne(db, key: pageID) else {
                throw VellixError.impossibleMove("A nested page used by this legacy template is missing.")
            }
            let child = try cloneTree(sourceID: source.id, title: source.title, templateID: template.id,
                originID: nil, spaceID: nil, folderID: nil, parentID: root.id, store: store, paths: &paths, in: db)
            pageIDs[pageID] = child.id
        }
        root.tipTapJSON = try TipTapContentAnalyzer.remappingPageReferences(in: root.tipTapJSON, documentIDs: pageIDs)
        try root.update(db)
        try db.execute(sql: "UPDATE templates SET rootDocumentID = ? WHERE id = ?", arguments: [root.id, template.id])
        return root
    }

    private func cloneTree(sourceID: String, title: String, templateID: String?, originID: String?,
                           spaceID: String?, folderID: String?, parentID: String?, store: AttachmentStore?,
                           paths: inout [String], in db: Database) throws -> DocumentRecord {
        let sources = try DocumentRecord.fetchAll(db, sql: """
            WITH RECURSIVE owned(id) AS (
                SELECT id FROM documents WHERE id = ?
                UNION SELECT d.id FROM documents d JOIN owned p ON d.parentDocumentID = p.id
                    WHERE d.isTrashed = 0 AND d.isArchived = 0
            ) SELECT d.* FROM documents d JOIN owned ON d.id = owned.id
            """, arguments: [sourceID])
        guard sources.contains(where: { $0.id == sourceID }) else { throw VellixError.documentNotFound(sourceID) }
        let ids = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, UUID().uuidString) })
        var copies: [String: DocumentRecord] = [:]
        // Insert parents before children so every write also works with immediate FK checks.
        var remaining = sources
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { $0.id == sourceID || copies[$0.parentDocumentID ?? ""] != nil }) else {
                throw VellixError.impossibleMove("The template contains a circular page relationship.")
            }
            let source = remaining.remove(at: index)
            var copy = source
            copy.id = ids[source.id]!
            copy.parentDocumentID = source.id == sourceID ? parentID : ids[source.parentDocumentID ?? ""]
            copy.title = source.id == sourceID ? (title.trimmedNonEmpty ?? source.title) : source.title
            copy.spaceID = spaceID
            copy.folderID = folderID
            copy.templateID = templateID
            copy.templateOriginID = originID
            copy.isFavorite = false
            copy.isArchived = false
            copy.isTrashed = false
            copy.trashedAt = nil
            copy.trashBatchID = nil
            copy.createdAt = Date()
            copy.updatedAt = Date()
            copy.lastOpenedAt = nil
            copy.revision = 1
            try copy.insert(db)
            copies[source.id] = copy
        }
        for source in sources {
            var copy = copies[source.id]!
            var fileMap: [String: String] = [:]
            let assets = try AttachmentRecord.fetchAll(db, sql: "SELECT * FROM attachments WHERE documentID = ?", arguments: [source.id])
            if !assets.isEmpty, store == nil { throw VellixError.impossibleMove("The template attachment store is unavailable.") }
            for asset in assets {
                guard let store else { continue }
                let assetCopy = try store.importFile(at: store.fileURL(relativePath: asset.relativePath), documentID: copy.id)
                paths.append(assetCopy.relativePath)
                try assetCopy.insert(db)
                fileMap[asset.relativePath] = assetCopy.relativePath
            }
            copy.cover = copy.cover.map { fileMap[$0] ?? $0 }
            copy.appearanceJSON = try StructuredTemplateContent.replacingPaths(copy.appearanceJSON, paths: fileMap)
            copy.cardStyleJSON = try StructuredTemplateContent.replacingPaths(copy.cardStyleJSON, paths: fileMap)
            let analysis = try TipTapContentAnalyzer.analyze(StructuredTemplateContent.independent(source.tipTapJSON, pages: ids, paths: fileMap))
            copy.tipTapJSON = analysis.canonicalJSON
            copy.plainText = analysis.plainText
            copy.previewText = analysis.previewText
            copy.wordCount = analysis.wordCount
            copy.characterCount = analysis.characterCount
            copy.estimatedReadingMinutes = analysis.estimatedReadingMinutes
            try copy.update(db)
            try DocumentRepository.upsertSearchIndex(copy, in: db)
            copies[source.id] = copy
        }
        try CollectionRepository.copyCollections(documentIDs: ids, in: db)
        return try DocumentRecord.fetchOne(db, key: copies[sourceID]!.id)!
    }
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
                tipTapJSON: document.tipTapJSON,
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
            let analysis = try TipTapContentAnalyzer.analyze(snapshot.tipTapJSON)

            let currentSnapshot = DocumentSnapshotRecord(
                documentID: document.id,
                tipTapJSON: document.tipTapJSON,
                revision: document.revision,
                reason: .recovery,
                isAutomatic: false
            )
            try currentSnapshot.insert(db)

            document.tipTapJSON = analysis.canonicalJSON
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
