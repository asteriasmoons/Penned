import Foundation
import GRDB

enum CollectionMigration {
    nonisolated static func removeInheritedEntryStyles(_ db: Database, defaultAppearanceJSON: String) throws {
        let plain = try JSONSerialization.jsonObject(with: Data(defaultAppearanceJSON.utf8)) as! [String: Any]
        let coverKeys = ["showsCover", "coverPhoto", "coverThemeID"]
        func pageStyle(_ appearance: [String: Any]) -> NSDictionary {
            var style = appearance
            for key in coverKeys { style.removeValue(forKey: key) }
            return style as NSDictionary
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.id, d.appearanceJSON AS entryAppearance, p.appearanceJSON AS parentAppearance
            FROM collectionEntries e JOIN documents d ON d.id = e.documentID
            JOIN collections c ON c.id = e.collectionID JOIN documents p ON p.id = c.documentID
            WHERE d.appearanceJSON IS NOT NULL
            """)
        for row in rows {
            let entryJSON: String = row["entryAppearance"]
            let parentJSON: String = row["parentAppearance"] ?? defaultAppearanceJSON
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(entryJSON.utf8))) as? [String: Any],
                  let parent = (try? JSONSerialization.jsonObject(with: Data(parentJSON.utf8))) as? [String: Any],
                  pageStyle(entry).isEqual(pageStyle(parent)), !pageStyle(entry).isEqual(pageStyle(plain)) else { continue }
            var independent = plain
            for key in coverKeys { if let value = entry[key] { independent[key] = value } }
            independent["showsCover"] = entry["showsCover"] ?? (entry["themeID"] != nil)
            if independent["coverThemeID"] == nil, let theme = entry["themeID"] { independent["coverThemeID"] = theme }
            let json = String(data: try JSONSerialization.data(withJSONObject: independent, options: [.sortedKeys]), encoding: .utf8)!
            try db.execute(sql: "UPDATE documents SET appearanceJSON = ?, updatedAt = ? WHERE id = ?", arguments: [json, Date(), row["id"] as String])
        }
    }

    nonisolated static func embedInOwningDocuments(_ db: Database) throws {
        let records = try Row.fetchAll(db, sql: """
            SELECT c.*, d.title, d.parentDocumentID, d.tipTapJSON FROM collections c
            JOIN documents d ON d.id = c.documentID
            """)
        let parents = Dictionary(uniqueKeysWithValues: records.compactMap { row -> (String, String)? in
            guard let parent: String = row["parentDocumentID"] else { return nil }
            return (row["documentID"], parent)
        })
        let generatedDocuments = Set(records.compactMap { row -> String? in
            let documentID: String = row["documentID"], id: String = row["id"], json: String = row["tipTapJSON"]
            guard parents[documentID] != nil else { return nil }
            let content = TipTapContentAnalyzer.documentObject(from: json)["content"] as? [[String: Any]] ?? []
            let generatedOnly = content.allSatisfy { node in
                if node["type"] as? String == "paragraph" { return (node["content"] as? [Any] ?? []).isEmpty }
                return node["type"] as? String == "collection" && (node["attrs"] as? [String: Any])?["collectionID"] as? String == id
            }
            return generatedOnly ? documentID : nil
        })
        func owner(of documentID: String) -> String {
            var current = parents[documentID] ?? documentID, visited = Set<String>()
            while generatedDocuments.contains(current), let parent = parents[current], visited.insert(current).inserted { current = parent }
            return current
        }
        let owners = Dictionary(uniqueKeysWithValues: records.map { ($0["id"] as String, owner(of: $0["documentID"])) })
        // GRDB runs this migration with deferred foreign-key checks, preserving dependent rows during replacement.
        try db.execute(sql: """
            DROP TRIGGER collectionEntries_parent;
            DROP TRIGGER collectionValues_valid_owner;
            CREATE TABLE collections_replacement (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                name TEXT NOT NULL, activeViewID TEXT NOT NULL, createdAt DATETIME NOT NULL
            );
            ALTER TABLE collectionFields ADD COLUMN icon TEXT NOT NULL DEFAULT '';
            """)
        for row in records {
            let id: String = row["id"]
            try db.execute(sql: "INSERT INTO collections_replacement VALUES (?, ?, ?, ?, ?)",
                arguments: [id, owners[id]!, row["title"] as String, row["activeViewID"] as String, row["createdAt"] as Date])
        }
        try db.execute(sql: "DROP TABLE collections; ALTER TABLE collections_replacement RENAME TO collections; CREATE INDEX collections_owner ON collections(documentID);")
        for row in records {
            let oldID: String = row["documentID"], id: String = row["id"]
            guard let newOwner = owners[id], oldID != newOwner else { continue }
            if generatedDocuments.contains(oldID) {
                try db.execute(sql: "UPDATE documents SET parentDocumentID = ? WHERE parentDocumentID = ?", arguments: [newOwner, oldID])
            } else {
                try db.execute(sql: "UPDATE documents SET parentDocumentID = ? WHERE parentDocumentID = ? AND id IN (SELECT documentID FROM collectionEntries WHERE collectionID = ?)",
                    arguments: [newOwner, oldID, id])
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, tipTapJSON FROM documents") {
            let documentID: String = row["id"], json: String = row["tipTapJSON"]
            guard json.contains("\"collection\"") || parents.keys.contains(where: { json.contains($0) }) else { continue }
            let original = TipTapContentAnalyzer.documentObject(from: json)
            let ownIDs = Set(records.filter { ($0["documentID"] as String) == documentID && owners[$0["id"] as String] != documentID }.map { $0["id"] as String })
            func update(_ node: [String: Any]) -> [String: Any]? {
                var result = node
                if node["type"] as? String == "collection", var attrs = node["attrs"] as? [String: Any], let id = attrs["collectionID"] as? String {
                    if ownIDs.contains(id) { return nil }
                    if let owner = owners[id] { attrs["documentID"] = owner; result["attrs"] = attrs }
                } else if node["type"] as? String == "pageReference", var attrs = node["attrs"] as? [String: Any], let id = attrs["documentID"] as? String, generatedDocuments.contains(id) {
                    attrs["documentID"] = owner(of: id); result["attrs"] = attrs
                }
                if let children = node["content"] as? [[String: Any]] { result["content"] = children.compactMap(update) }
                return result
            }
            let updated = update(original) ?? ["type": "doc", "content": []]
            let nextJSON = try TipTapContentAnalyzer.normalizePayloadToJSON(updated)
            if nextJSON != json { try db.execute(sql: "UPDATE documents SET tipTapJSON = ? WHERE id = ?", arguments: [nextJSON, documentID]) }
            // Retire only generated wrappers into recoverable Trash; authored text and all entry data stay intact.
            if generatedDocuments.contains(documentID) {
                try db.execute(sql: "UPDATE documents SET isTrashed = 1, trashedAt = ?, trashBatchID = ? WHERE id = ? AND isTrashed = 0",
                    arguments: [Date(), UUID().uuidString, documentID])
            }
        }
        try db.execute(sql: """
            CREATE TRIGGER collectionValues_valid_owner BEFORE INSERT ON collectionValues
            WHEN (SELECT collectionID FROM collectionEntries WHERE documentID = NEW.documentID)
                <> (SELECT collectionID FROM collectionFields WHERE id = NEW.fieldID)
            BEGIN SELECT RAISE(ABORT, 'Collection field and entry must have the same owner'); END;
            CREATE TRIGGER collectionEntries_parent BEFORE UPDATE OF parentDocumentID ON documents
            WHEN NEW.parentDocumentID IS NOT OLD.parentDocumentID AND EXISTS (
                SELECT 1 FROM collectionEntries e JOIN collections c ON c.id = e.collectionID
                JOIN documents parent ON parent.id = c.documentID
                WHERE e.documentID = NEW.id AND NEW.parentDocumentID IS NOT c.documentID
            )
            BEGIN SELECT RAISE(ABORT, 'Collection entries must remain inside their collection'); END;
            """)
    }
}
