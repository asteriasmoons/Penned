import Foundation
import GRDB

enum SpaceContent: Hashable {
    case document(String), folder(String), template(String)
}

enum SpaceSheet: Identifiable {
    case edit(SpaceRecord?)
    case transfer(SpaceContent, Bool)
    var id: String {
        switch self {
        case .edit(let space): return "edit-" + (space?.id ?? "new")
        case .transfer(let content, let copy): return "transfer-\(content)-\(copy)"
        }
    }
}

extension SpaceRepository {
    func space(id: String) throws -> SpaceRecord? {
        try database.read { try SpaceRecord.fetchOne($0, sql: "SELECT * FROM spaces WHERE id=? AND (libraryID=penned_library() OR penned_library()='*')", arguments: [id]) }
    }

    func includingArchived() throws -> [SpaceRecord] {
        try database.read { try SpaceRecord.fetchAll($0, sql: "SELECT * FROM spaces WHERE libraryID=penned_library() OR penned_library()='*' ORDER BY isArchived, sortOrder, createdAt, id") }
    }

    func save(_ space: SpaceRecord) throws {
        guard space.title.trimmedNonEmpty != nil else { throw VellixError.impossibleMove("Enter a Space name.") }
        try database.write { db in
            var saved = space
            saved.title = space.title.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.updatedAt = Date()
            try saved.update(db)
        }
    }

    func restore(id: String) throws {
        try database.write { try $0.execute(sql: "UPDATE spaces SET isArchived=0,updatedAt=? WHERE id=?", arguments: [Date(), id]) }
    }

    func fallback(preferred: String?) throws -> String {
        try database.write { db in
            if let preferred, let space = try SpaceRecord.fetchOne(db, key: preferred), !space.isArchived,
               try LibraryAccess.allows(space.libraryID, in: db) { return space.id }
            return try SpaceOwnership.defaultSpace(in: db)
        }
    }

    func existingFallback(preferred: String?) throws -> String? {
        try database.read { db in
            if let preferred, let space = try SpaceRecord.fetchOne(db, key: preferred), !space.isArchived,
               try LibraryAccess.allows(space.libraryID, in: db) { return space.id }
            return try String.fetchOne(db, sql: """
                SELECT s.id FROM spaces s LEFT JOIN librarySpaceDefaults d ON d.spaceID=s.id AND d.libraryID=s.libraryID
                WHERE s.libraryID=penned_library() AND s.isArchived=0
                ORDER BY CASE WHEN d.spaceID IS NOT NULL THEN 0 ELSE 1 END,s.sortOrder,s.createdAt,s.id LIMIT 1
                """)
        }
    }

    func owningSpace(documentID: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT d.spaceID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE \(LibraryAccess.spaces("d.spaceID")) AND d.id=? AND s.isArchived=0 AND d.isTrashed=0 AND d.isArchived=0", arguments: [documentID]) }
    }

    func contentCount(id: String) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents WHERE \(LibraryAccess.spaces()) AND spaceID=? AND parentDocumentID IS NULL AND templateID IS NULL AND isTrashed=0 AND isArchived=0", arguments: [id]) ?? 0 }
    }

    func transfer(_ item: SpaceContent, from source: String, to destination: String, copy: Bool, store: AttachmentStore) throws {
        guard source != destination else { throw VellixError.impossibleMove("Choose a different Space.") }
        var paths: [String] = []
        do {
            try database.write { db in
                try SpaceOwnership.requireSpace(source, in: db)
                try SpaceOwnership.requireSpace(destination, in: db)
                try SpaceOwnership.changingOwnership(in: db) {
                    let folders: [FolderRecord]
                    let roots: [DocumentRecord]
                    var template: TemplateRecord?
                    switch item {
                    case .document(let id):
                        let document = try SpaceOwnership.document(id, scope: source, in: db)
                        guard document.parentDocumentID == nil, document.templateID == nil else { throw VellixError.impossibleMove("Transfer the containing page or template to keep nested content together.") }
                        folders = []; roots = [document]
                    case .folder(let id):
                        guard let folder = try FolderRecord.fetchOne(db, key: id), folder.spaceID == source else { throw VellixError.impossibleMove("This folder is outside the current Space.") }
                        folders = try FolderRecord.fetchAll(db, sql: "WITH RECURSIVE owned(id) AS (SELECT id FROM folders WHERE id=? UNION SELECT f.id FROM folders f JOIN owned p ON f.parentFolderID=p.id) SELECT * FROM folders WHERE id IN (SELECT id FROM owned)", arguments: [id])
                        let folderIDs = Set(folders.map(\.id))
                        roots = try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE spaceID=? AND parentDocumentID IS NULL AND templateID IS NULL", arguments: [source]).filter { folderIDs.contains($0.folderID ?? "") }
                    case .template(let id):
                        guard let found = try TemplateRecord.fetchOne(db, key: id), found.spaceID == source else { throw VellixError.impossibleMove("This template is outside the current Space.") }
                        template = found; folders = []
                        let root = try TemplateRepository(database: database).materialize(found, store: store, paths: &paths, in: db)
                        template?.rootDocumentID = root.id
                        roots = [root]
                    }
                    let rootIDs = Set(roots.map(\.id))
                    let allPages = try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE spaceID=?", arguments: [source])
                    var documentIDs = rootIDs
                    var previous = -1
                    while previous != documentIDs.count {
                        previous = documentIDs.count
                        for page in allPages where page.parentDocumentID.map(documentIDs.contains) == true { documentIDs.insert(page.id) }
                    }
                    if copy {
                        let identities = Dictionary(uniqueKeysWithValues: documentIDs.map { ($0, UUID().uuidString) })
                        let folderIDs = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, UUID().uuidString) })
                        var remaining = folders
                        var inserted = Set<String>()
                        while !remaining.isEmpty {
                            guard let index = remaining.firstIndex(where: { $0.parentFolderID == nil || folderIDs[$0.parentFolderID!] == nil || inserted.contains($0.parentFolderID!) }) else { throw VellixError.impossibleMove("This folder hierarchy contains a cycle.") }
                            let original = remaining.remove(at: index)
                            var folder = original
                            folder.id = folderIDs[original.id]!
                            folder.parentFolderID = original.parentFolderID.flatMap { folderIDs[$0] }
                            folder.spaceID = destination; folder.createdAt = Date(); folder.updatedAt = Date()
                            try folder.insert(db); inserted.insert(original.id)
                        }
                        var copiedTemplate: TemplateRecord?
                        if var value = template {
                            value.id = UUID().uuidString; value.spaceID = destination
                            value.rootDocumentID = nil; value.isBuiltIn = false; value.createdAt = Date(); value.updatedAt = Date()
                            try value.insert(db); copiedTemplate = value
                        }
                        let copier = TemplateRepository(database: database)
                        var collectionIDs: [String: String] = [:]
                        var fileMap: [String: String] = [:]
                        for root in roots {
                            let page = try copier.cloneTree(sourceID: root.id, title: root.title,
                                templateID: copiedTemplate?.id, originID: nil, spaceID: destination,
                                folderID: root.folderID.flatMap { folderIDs[$0] }, parentID: nil,
                                store: store, paths: &paths, in: db, includeInactive: true, identities: identities,
                                folderIdentities: folderIDs,
                                collectionsCopied: { collectionIDs.merge($0) { _, new in new } },
                                attachmentsCopied: { fileMap.merge($0) { _, new in new } })
                            if var value = copiedTemplate {
                                value.rootDocumentID = page.id; value.tipTapJSON = page.tipTapJSON
                                try value.update(db); copiedTemplate = value
                            }
                        }
                        try CollectionRepository.remapCollectionReferences(documentIDs: identities, collectionIDs: collectionIDs, in: db)
                        try preserveReferencedAssets(identities, sourceSpace: source, fileMap: &fileMap, store: store, paths: &paths, in: db)
                        try copyEventNotes(identities, destination: destination, in: db)
                    } else {
                        for var folder in folders {
                            folder.spaceID = destination
                            if folder.id == { if case .folder(let id) = item { return id }; return "" }() { folder.parentFolderID = nil }
                            try folder.update(db)
                        }
                        if var template { template.spaceID = destination; try template.update(db) }
                        for id in documentIDs {
                            var page = try SpaceOwnership.document(id, scope: source, in: db)
                            page.spaceID = destination
                            if folders.isEmpty { page.folderID = nil }
                            page.updatedAt = Date()
                            try page.update(db)
                            try moveEventNote(id, destination: destination, in: db)
                        }
                        var fileMap: [String: String] = [:]
                        try preserveReferencedAssets(Dictionary(uniqueKeysWithValues: documentIDs.map { ($0, $0) }), sourceSpace: source,
                            fileMap: &fileMap, store: store, paths: &paths, in: db)
                    }
                    // References outside a transferred tree remain stored but resolve only
                    // within their owner's Space. No source content is erased to hide a link.
                    for id in documentIDs where !copy {
                        try db.execute(sql: "UPDATE documents SET templateOriginID=NULL WHERE id=? AND templateOriginID IN (SELECT id FROM templates WHERE spaceID<>documents.spaceID)", arguments: [id])
                    }
                    if let template, !copy {
                        try db.execute(sql: "UPDATE documents SET templateOriginID=NULL WHERE templateOriginID=? AND spaceID<>?", arguments: [template.id, destination])
                    }
                }
            }
        } catch {
            for path in paths { try? store.removeFile(relativePath: path) }
            throw error
        }
    }

    private func moveEventNote(_ id: String, destination: String, in db: Database) throws {
        // Reject collisions rather than merge or discard either independently authored note.
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM calendarEventNotes a JOIN calendarEventNotes b ON a.eventKey=b.eventKey WHERE a.documentID=? AND b.spaceID=?)", arguments: [id, destination]) == true {
            throw VellixError.impossibleMove("The destination already has a note for this calendar event. Neither note was moved or merged.")
        }
        try db.execute(sql: "UPDATE calendarEventNotes SET spaceID=? WHERE documentID=?", arguments: [destination, id])
    }

    private func preserveReferencedAssets(_ identities: [String: String], sourceSpace: String, fileMap: inout [String: String],
        store: AttachmentStore, paths: inout [String], in db: Database) throws {
        func strings(_ value: Any) -> Set<String> {
            if let value = value as? String { return [value] }
            if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(strings($1)) } }
            if let object = value as? [String: Any] { return object.values.reduce(into: Set<String>()) { $0.formUnion(strings($1)) } }
            return []
        }
        // Blocks moved between pages can still use a file owned by another page.
        // Copy that file before separating Spaces; never transfer its other owner.
        for destination in identities.values.sorted() {
            let document = try SpaceOwnership.document(destination, scope: nil, in: db)
            let snapshots = try DocumentSnapshotRecord.fetchAll(db, sql: "SELECT * FROM documentSnapshots WHERE documentID=?", arguments: [destination])
            var references = Set([document.cover].compactMap { $0 })
            for json in [document.tipTapJSON, document.appearanceJSON, document.cardStyleJSON].compactMap({ $0 }) + snapshots.map(\.tipTapJSON) {
                references.formUnion(strings(try JSONSerialization.jsonObject(with: Data(json.utf8))))
            }
            let unresolved = Array(references.filter { fileMap[$0] == nil }).sorted()
            for start in stride(from: 0, to: unresolved.count, by: 400) {
                let chunk = Array(unresolved[start..<min(start + 400, unresolved.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let assets = try AttachmentRecord.fetchAll(db, sql: "SELECT a.* FROM attachments a JOIN documents d ON d.id=a.documentID WHERE d.spaceID=? AND a.relativePath IN (\(marks))", arguments: StatementArguments([sourceSpace] + chunk))
                for asset in assets where identities[asset.documentID] == nil && fileMap[asset.relativePath] == nil {
                    let copied = try store.copy(asset, documentID: destination)
                    paths.append(contentsOf: copied.storedPaths); try copied.insert(db)
                    fileMap[asset.relativePath] = copied.relativePath
                    fileMap[asset.id] = copied.id
                    if let old = asset.thumbnailRelativePath, let new = copied.thumbnailRelativePath { fileMap[old] = new }
                }
            }
        }
        for destination in identities.values {
            var document = try SpaceOwnership.document(destination, scope: nil, in: db)
            document.cover = document.cover.map { fileMap[$0] ?? $0 }
            document.appearanceJSON = try StructuredTemplateContent.replacingPaths(document.appearanceJSON, paths: fileMap)
            document.cardStyleJSON = try StructuredTemplateContent.replacingPaths(document.cardStyleJSON, paths: fileMap)
            document.tipTapJSON = try StructuredTemplateContent.replacingPaths(document.tipTapJSON, paths: fileMap)!
            try document.update(db); try DocumentRepository.upsertSearchIndex(document, in: db)
            for var snapshot in try DocumentSnapshotRecord.fetchAll(db, sql: "SELECT * FROM documentSnapshots WHERE documentID=?", arguments: [destination]) {
                snapshot.tipTapJSON = try StructuredTemplateContent.replacingPaths(snapshot.tipTapJSON, paths: fileMap)!
                try snapshot.update(db)
            }
        }
    }

    private func copyEventNotes(_ identities: [String: String], destination: String, in db: Database) throws {
        for (original, copy) in identities {
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM calendarEventNotes WHERE documentID=?", arguments: [original]) else { continue }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM calendarEventNotes WHERE spaceID=? AND eventKey=?)", arguments: [destination, row["eventKey"] as String]) != true else {
                throw VellixError.impossibleMove("The destination already has a note for this calendar event. The original is unchanged.")
            }
            try db.execute(sql: "INSERT INTO calendarEventNotes (id,eventKey,documentID,spaceID,calendarID,sourceID,localID,externalID,occurrenceKey,createdAt) VALUES (?,?,?,?,?,?,?,?,?,?)",
                arguments: [UUID().uuidString, row["eventKey"] as String, copy, destination, row["calendarID"] as String, row["sourceID"] as String, row["localID"] as String, row["externalID"] as String?, row["occurrenceKey"] as String, Date()])
        }
    }

    func delete(id: String, store: AttachmentStore) throws -> Set<String> {
        let removed = try database.write { db in
            try SpaceOwnership.requireSpace(id, in: db, includingArchived: true)
            return try SpaceOwnership.changingOwnership(in: db) {
                let ids = Set(try String.fetchAll(db, sql: "SELECT id FROM documents WHERE spaceID=?", arguments: [id]))
                try db.execute(sql: "INSERT OR IGNORE INTO attachmentCleanup SELECT relativePath FROM attachments WHERE documentID IN (SELECT id FROM documents WHERE spaceID=?)", arguments: [id])
                try db.execute(sql: "INSERT OR IGNORE INTO attachmentCleanup SELECT thumbnailRelativePath FROM attachments WHERE thumbnailRelativePath IS NOT NULL AND documentID IN (SELECT id FROM documents WHERE spaceID=?)", arguments: [id])
                try db.execute(sql: "DELETE FROM documentSearch WHERE documentID IN (SELECT id FROM documents WHERE spaceID=?)", arguments: [id])
                try db.execute(sql: "UPDATE templates SET rootDocumentID=NULL WHERE spaceID=?", arguments: [id])
                try db.execute(sql: "DELETE FROM collections WHERE documentID IN (SELECT id FROM documents WHERE spaceID=?)", arguments: [id])
                try db.execute(sql: "DELETE FROM documents WHERE spaceID=?", arguments: [id])
                try db.execute(sql: "DELETE FROM templates WHERE spaceID=?", arguments: [id])
                try db.execute(sql: "DELETE FROM folders WHERE spaceID=?", arguments: [id])
                try db.execute(sql: "DELETE FROM spaces WHERE id=?", arguments: [id])
                return ids
            }
        }
        try? drainAttachmentCleanup(store: store)
        return removed
    }

    func drainAttachmentCleanup(store: AttachmentStore) throws {
        let paths = try database.read { try String.fetchAll($0, sql: "SELECT relativePath FROM attachmentCleanup") }
        for path in paths {
            guard path == (path as NSString).lastPathComponent, path != ".", path != ".." else {
                throw VellixError.attachmentImport("An unsafe attachment cleanup path was retained for recovery.")
            }
            // Never remove a path still owned by a surviving document or a global style.
            let referenced = try database.read { db in
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM librarySyncAssets WHERE relativePath=?)", arguments: [path]) == true { return true }
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachments WHERE relativePath=? OR thumbnailRelativePath=?)", arguments: [path, path]) == true { return true }
                for style in try SavedDocumentStyle.fetchAll(db) {
                    if try style.definition().imagePaths.contains(path) { return true }
                }
                return false
            }
            if !referenced { try store.removeFile(relativePath: path) }
            try database.write { try $0.execute(sql: "DELETE FROM attachmentCleanup WHERE relativePath=?", arguments: [path]) }
        }
    }
}
