import Foundation
import GRDB

extension Notification.Name {
    static let pennedTagsChanged = Notification.Name("Penned.TagsChanged")
}

nonisolated enum TagName {
    static func clean(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#", with: "", options: .regularExpression)
            .precomposedStringWithCanonicalMapping
        guard !value.isEmpty, value.unicodeScalars.count <= 80,
              value.range(of: #"^[\p{L}\p{M}\p{N}_-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func normalized(_ input: String) -> String? {
        clean(input)?.uppercased(with: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
}

nonisolated struct DocumentTag: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "documentTagRecords"
    var id: String
    var spaceID: String
    var name: String
    var normalizedName: String
    var createdAt: Date
}

nonisolated struct TagTextRun: Codable, Hashable, Sendable {
    var text: String
    var tagName: String?
}

nonisolated struct TaggedBlock: Identifiable, Hashable, Sendable {
    var id: String { documentID + ":" + blockID }
    var documentID: String
    var rootDocumentID: String
    var blockID: String
    var ordinal: Int
    var runs: [TagTextRun]
    var tagIDs: Set<String>
    var occurrenceIDs: [String: String]
    var breadcrumbs: [String]
    var text: String { runs.map(\.text).joined() }
}

nonisolated struct TaggedDocument: Identifiable, Sendable {
    var id: String { document.id }
    var document: DocumentRecord
    var blocks: [TaggedBlock]
}

nonisolated struct TagBrowserSnapshot: Sendable {
    var tags: [DocumentTag] = []
    var documentCounts: [String: Int] = [:]
    var documents: [TaggedDocument] = []
}

nonisolated struct TagNavigationTarget: Identifiable, Equatable, Sendable {
    var id = UUID()
    var documentID: String
    var blockID: String
    var occurrenceID: String?
}

nonisolated struct InlineTagRequest: Identifiable, Equatable, Sendable {
    var id: String { token }
    var token: String
    var action: String
    var name: String

    static func decode(_ payload: [String: Any]) -> Self? {
        guard let token = payload["token"] as? String, !token.isEmpty,
              let action = payload["action"] as? String, ["menu", "commit"].contains(action),
              let name = payload["name"] as? String, TagName.clean(name) != nil else { return nil }
        return Self(token: token, action: action, name: name)
    }
}

// Derived exclusively from structured inlineTag nodes, in the document's save transaction.
nonisolated enum DocumentTagIndex {
    struct Block {
        var id: String
        var ordinal: Int
        var runs: [TagTextRun]
        var occurrences: [(id: String, name: String)]
    }

    static func blocks(in json: String) -> [Block] {
        var result: [Block] = []
        var ordinal = 0
        func runs(_ node: [String: Any], occurrences: inout [(id: String, name: String)]) -> [TagTextRun] {
            let type = node["type"] as? String ?? ""
            if type == "text" { return [TagTextRun(text: node["text"] as? String ?? "")] }
            if type == "hardBreak" { return [TagTextRun(text: "\n")] }
            if type == "inlineTag", let attrs = node["attrs"] as? [String: Any],
               let id = attrs["id"] as? String, let name = TagName.clean(attrs["name"] as? String ?? "") {
                occurrences.append((id, name))
                return [TagTextRun(text: "#" + name, tagName: TagName.normalized(name))]
            }
            return (node["content"] as? [[String: Any]] ?? []).flatMap { runs($0, occurrences: &occurrences) }
        }
        func walk(_ node: [String: Any]) {
            if ["paragraph", "heading", "codeBlock"].contains(node["type"] as? String ?? ""),
               let id = (node["attrs"] as? [String: Any])?["id"] as? String {
                var occurrences: [(id: String, name: String)] = []
                let text = runs(node, occurrences: &occurrences)
                if !occurrences.isEmpty { result.append(Block(id: id, ordinal: ordinal, runs: text, occurrences: occurrences)) }
                ordinal += 1
                return
            }
            for child in node["content"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(TipTapContentAnalyzer.documentObject(from: json))
        return result
    }

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE documentTagRecords (
                id TEXT PRIMARY KEY NOT NULL,
                spaceID TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL, normalizedName TEXT NOT NULL, createdAt DATETIME NOT NULL,
                UNIQUE(spaceID, normalizedName)
            );
            CREATE TABLE taggedBlocks (
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                blockID TEXT NOT NULL, ordinal INTEGER NOT NULL, runsJSON TEXT NOT NULL,
                PRIMARY KEY(documentID, blockID)
            );
            CREATE TABLE documentTagOccurrences (
                documentID TEXT NOT NULL, blockID TEXT NOT NULL, occurrenceID TEXT NOT NULL,
                tagID TEXT NOT NULL REFERENCES documentTagRecords(id) ON DELETE CASCADE,
                PRIMARY KEY(documentID, occurrenceID),
                FOREIGN KEY(documentID, blockID) REFERENCES taggedBlocks(documentID, blockID) ON DELETE CASCADE
            );
            CREATE INDEX tagOccurrences_lookup ON documentTagOccurrences(tagID, documentID, blockID);
            CREATE INDEX tagBlocks_order ON taggedBlocks(documentID, ordinal);
            CREATE TABLE tagDocumentChanges (documentID TEXT PRIMARY KEY NOT NULL);
            CREATE TRIGGER tags_document_insert AFTER INSERT ON documents BEGIN
                INSERT OR IGNORE INTO tagDocumentChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER tags_document_update AFTER UPDATE OF tipTapJSON,title,parentDocumentID,templateID,isTrashed,isArchived,spaceID ON documents BEGIN
                INSERT OR IGNORE INTO tagDocumentChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER tags_document_delete AFTER DELETE ON documents BEGIN
                INSERT OR IGNORE INTO tagDocumentChanges VALUES (OLD.id);
            END;
            INSERT INTO tagDocumentChanges SELECT id FROM documents;
            """)
        _ = try reconcile(in: db)
    }

    static func resolve(name: String, spaceID: String, in db: Database) throws -> DocumentTag {
        guard let name = TagName.clean(name), let normalized = TagName.normalized(name) else {
            throw VellixError.tagging("Use a tag name with letters, numbers, hyphens, or underscores (up to 80 characters).")
        }
        try db.execute(sql: "INSERT OR IGNORE INTO documentTagRecords VALUES (?, ?, ?, ?, ?)",
            arguments: [UUID().uuidString, spaceID, name, normalized, Date()])
        guard let tag = try DocumentTag.fetchOne(db, sql: "SELECT * FROM documentTagRecords WHERE spaceID=? AND normalizedName=?",
            arguments: [spaceID, normalized]) else { throw VellixError.database("The tag could not be created.") }
        return tag
    }

    @discardableResult static func reconcile(in db: Database) throws -> Bool {
        let ids = try String.fetchAll(db, sql: "SELECT documentID FROM tagDocumentChanges")
        guard !ids.isEmpty else { return false }
        try db.execute(sql: "DELETE FROM tagDocumentChanges")
        for id in ids {
            try db.execute(sql: "DELETE FROM taggedBlocks WHERE documentID=?", arguments: [id])
            guard let doc = try DocumentRecord.fetchOne(db, key: id), let space = doc.spaceID else { continue }
            for block in blocks(in: doc.tipTapJSON) {
                let text = String(decoding: try JSONEncoder().encode(block.runs), as: UTF8.self)
                try db.execute(sql: "INSERT INTO taggedBlocks VALUES (?, ?, ?, ?)", arguments: [id, block.id, block.ordinal, text])
                for occurrence in block.occurrences {
                    let tag = try resolve(name: occurrence.name, spaceID: space, in: db)
                    try db.execute(sql: "INSERT INTO documentTagOccurrences VALUES (?, ?, ?, ?)",
                        arguments: [id, block.id, occurrence.id, tag.id])
                }
            }
        }
        return true
    }
}

final class DocumentTagRepository: @unchecked Sendable {
    private let database: AppDatabase
    var spaceID: String?
    init(database: AppDatabase) { self.database = database }

    func resolve(_ name: String) throws -> DocumentTag {
        try database.write { db in
            let space = try spaceID ?? SpaceOwnership.defaultSpace(in: db)
            try SpaceOwnership.requireSpace(space, in: db)
            return try DocumentTagIndex.resolve(name: name, spaceID: space, in: db)
        }
    }

    func catalogue() throws -> [DocumentTag] {
        try database.read { db in
            try DocumentTag.fetchAll(db, sql: "SELECT t.* FROM documentTagRecords t JOIN spaces s ON s.id=t.spaceID WHERE \(LibraryAccess.spaces("t.spaceID")) AND s.isArchived=0 AND (? IS NULL OR t.spaceID=?) ORDER BY t.normalizedName,t.id", arguments: [spaceID, spaceID])
        }
    }

    func snapshot(selected: Set<String> = [], query: String = "", titleOnly: Bool = false) throws -> TagBrowserSnapshot {
        try database.read { db in
            let tags = try DocumentTag.fetchAll(db, sql: "SELECT t.* FROM documentTagRecords t JOIN spaces s ON s.id=t.spaceID WHERE \(LibraryAccess.spaces("t.spaceID")) AND s.isArchived=0 AND (? IS NULL OR t.spaceID=?) ORDER BY t.normalizedName,t.id", arguments: [spaceID, spaceID])
            let pages = try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE \(LibraryAccess.spaces("d.spaceID")) AND s.isArchived=0 AND (? IS NULL OR d.spaceID=?)", arguments: [spaceID, spaceID])
            let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
            func path(_ doc: DocumentRecord) -> [DocumentRecord]? {
                var path = [doc], seen: Set<String> = [doc.id], next = doc.parentDocumentID
                while let id = next {
                    guard seen.insert(id).inserted, let parent = byID[id], parent.spaceID == doc.spaceID else { return nil }
                    path.insert(parent, at: 0); next = parent.parentDocumentID
                }
                return path.allSatisfy { !$0.isTrashed && !$0.isArchived && $0.templateID == nil } ? path : nil
            }
            // Traverse nested pages at their actual page-reference position, not creation time.
            let childrenByParent = Dictionary(grouping: pages.filter { $0.parentDocumentID != nil }, by: { $0.parentDocumentID! })
            var pageOrder: [String: Int] = [:], order = 0
            func visit(_ doc: DocumentRecord) {
                guard pageOrder[doc.id] == nil else { return }
                pageOrder[doc.id] = order; order += 1
                let children = (childrenByParent[doc.id] ?? []).sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
                let refs = TipTapContentAnalyzer.orderedPageReferenceIDs(in: doc.tipTapJSON)
                for id in refs { if let child = children.first(where: { $0.id == id }) { visit(child) } }
                for child in children { visit(child) }
            }
            for root in pages.filter({ $0.parentDocumentID == nil }).sorted(by: { $0.id < $1.id }) { visit(root) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.*,o.tagID,o.occurrenceID FROM taggedBlocks b
                JOIN documentTagOccurrences o ON o.documentID=b.documentID AND o.blockID=b.blockID
                JOIN documents d ON d.id=b.documentID WHERE (? IS NULL OR d.spaceID=?)
                ORDER BY b.documentID,b.ordinal,o.occurrenceID
                """, arguments: [spaceID, spaceID])
            var indexed: [String: TaggedBlock] = [:]
            for row in rows {
                let source: String = row["documentID"], block: String = row["blockID"]
                guard let doc = byID[source], let chain = path(doc), let root = chain.first else { continue }
                let key = source + ":" + block, tag: String = row["tagID"], occurrence: String = row["occurrenceID"]
                if indexed[key] == nil {
                    let runs = try JSONDecoder().decode([TagTextRun].self, from: Data((row["runsJSON"] as String).utf8))
                    indexed[key] = TaggedBlock(documentID: source, rootDocumentID: root.id, blockID: block,
                        ordinal: row["ordinal"], runs: runs, tagIDs: [], occurrenceIDs: [:], breadcrumbs: chain.map(\.title))
                }
                indexed[key]?.tagIDs.insert(tag)
                if indexed[key]?.occurrenceIDs[tag] == nil { indexed[key]?.occurrenceIDs[tag] = occurrence }
            }
            let grouped = Dictionary(grouping: indexed.values, by: \.rootDocumentID)
            var counts: [String: Int] = [:]
            for blocks in grouped.values {
                let tagIDs = blocks.reduce(into: Set<String>()) { $0.formUnion($1.tagIDs) }
                for id in tagIDs { counts[id, default: 0] += 1 }
            }
            let searchIDs = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
                : try DocumentSearchService.matchingDocumentIDs(query, titleOnly: titleOnly, spaceID: spaceID, in: db)
            var documents: [TaggedDocument] = []
            for (rootID, allBlocks) in grouped {
                guard let root = byID[rootID], selected.isSubset(of: allBlocks.reduce(into: Set<String>()) { $0.formUnion($1.tagIDs) }) else { continue }
                if let searchIDs, !searchIDs.contains(rootID), !allBlocks.contains(where: { searchIDs.contains($0.documentID) }) { continue }
                let blocks = allBlocks.filter { selected.isEmpty || !$0.tagIDs.isDisjoint(with: selected) }.sorted {
                    if $0.documentID == $1.documentID { return $0.ordinal < $1.ordinal }
                    return (pageOrder[$0.documentID] ?? 0) < (pageOrder[$1.documentID] ?? 0)
                }
                documents.append(TaggedDocument(document: root, blocks: blocks))
            }
            documents.sort { $0.document.updatedAt == $1.document.updatedAt ? $0.id < $1.id : $0.document.updatedAt > $1.document.updatedAt }
            return TagBrowserSnapshot(tags: tags, documentCounts: counts, documents: documents)
        }
    }

    func targetIsAvailable(_ target: TagNavigationTarget) throws -> Bool {
        try database.read { db in
            var doc = try SpaceOwnership.document(target.documentID, scope: spaceID, in: db)
            let blocks = DocumentTagIndex.blocks(in: doc.tipTapJSON)
            guard blocks.contains(where: { $0.id == target.blockID && (target.occurrenceID == nil || $0.occurrences.contains { $0.id == target.occurrenceID }) }) else { return false }
            var seen: Set<String> = []
            while true {
                guard !doc.isTrashed, !doc.isArchived, doc.templateID == nil, seen.insert(doc.id).inserted else { return false }
                guard let parent = doc.parentDocumentID else { return true }
                doc = try SpaceOwnership.document(parent, scope: spaceID, in: db)
            }
        }
    }
}
