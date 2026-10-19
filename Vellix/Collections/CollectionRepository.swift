import Foundation
import GRDB

final class CollectionRepository {
    let database: AppDatabase
    private let documents: DocumentRepository
    init(database: AppDatabase, documents: DocumentRepository) {
        self.database = database
        self.documents = documents
    }

    nonisolated static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE collections (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
                activeViewID TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE TABLE collectionFields (
                id TEXT PRIMARY KEY NOT NULL,
                collectionID TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                name TEXT NOT NULL, kind TEXT NOT NULL, configurationJSON TEXT NOT NULL,
                position INTEGER NOT NULL
            );
            CREATE INDEX collectionFields_owner ON collectionFields(collectionID, position);
            CREATE TABLE collectionViews (
                id TEXT PRIMARY KEY NOT NULL,
                collectionID TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                name TEXT NOT NULL, kind TEXT NOT NULL, configurationJSON TEXT NOT NULL,
                position INTEGER NOT NULL
            );
            CREATE INDEX collectionViews_owner ON collectionViews(collectionID, position);
            CREATE TABLE collectionEntries (
                documentID TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                collectionID TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                position INTEGER NOT NULL
            );
            CREATE INDEX collectionEntries_owner ON collectionEntries(collectionID, position);
            CREATE TABLE collectionValues (
                documentID TEXT NOT NULL REFERENCES collectionEntries(documentID) ON DELETE CASCADE,
                fieldID TEXT NOT NULL REFERENCES collectionFields(id) ON DELETE CASCADE,
                valueJSON TEXT NOT NULL,
                PRIMARY KEY (documentID, fieldID)
            );
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

    func create(ownerID: String, name: String, viewName: String, kind: CollectionViewKind) throws -> CollectionSnapshot {
        let id = try database.write { db in
            let owner = try documents.requireDocumentInDatabase(ownerID, db: db)
            guard !owner.isTrashed, !owner.isArchived else { throw VellixError.impossibleMove("Restore this page before adding a collection.") }
            guard let name = name.trimmedNonEmpty else { throw VellixError.impossibleMove("Enter a collection name.") }
            let view = CollectionViewRecord(collectionID: UUID().uuidString, name: viewName.trimmedNonEmpty ?? "Main", kind: kind)
            let record = CollectionRecord(id: view.collectionID, documentID: owner.id, name: name, activeViewID: view.id)
            try record.insert(db)
            try view.insert(db)
            return record.id
        }
        return try snapshot(id: id)
    }

    static func blockJSON(collectionID: String, documentID: String) throws -> String {
        try TipTapContentAnalyzer.makeDocumentJSON(content: [["type": "collection", "attrs": [
            "id": UUID().uuidString, "collectionID": collectionID, "documentID": documentID
        ]]])
    }

    func collectionID(forEntry documentID: String) throws -> String? {
        try database.read { db in
            _ = try SpaceOwnership.document(documentID, scope: documents.spaceID, in: db)
            return try String.fetchOne(db, sql: """
            SELECT e.collectionID FROM collectionEntries e JOIN documents d ON d.id = e.documentID
            JOIN collections c ON c.id = e.collectionID JOIN documents p ON p.id = c.documentID
            WHERE e.documentID = ? AND d.isTrashed = 0 AND p.isTrashed = 0
                AND d.isArchived = 0 AND p.isArchived = 0
            """, arguments: [documentID]) }
    }

    func collectionIDs(forDocument documentID: String) throws -> [String] {
        try database.read { db in
            let owner = try SpaceOwnership.document(documentID, scope: documents.spaceID, in: db)
            let json = try String.fetchOne(db, sql: "SELECT tipTapJSON FROM documents WHERE id = ?", arguments: [documentID]) ?? "{}"
            let referencedIDs = TipTapContentAnalyzer.collectionIDs(in: json).sorted()
            let references = referencedIDs.isEmpty ? "" : " OR c.id IN (\(Array(repeating: "?", count: referencedIDs.count).joined(separator: ",")))"
            return try String.fetchAll(db, sql: """
                SELECT c.id FROM collections c JOIN documents d ON c.documentID = d.id
                WHERE (d.id = ?\(references))
                    AND d.spaceID = ? AND d.isTrashed = 0 AND d.isArchived = 0 ORDER BY c.createdAt, c.id
                """, arguments: StatementArguments([documentID] + referencedIDs + [owner.spaceID!]))
        }
    }

    func snapshot(id: String) throws -> CollectionSnapshot {
        try database.read { db in
            let record = try Self.requireCollection(id, in: db)
            _ = try SpaceOwnership.document(record.documentID, scope: documents.spaceID, in: db)
            let fields = try CollectionField.fetchAll(db, sql: "SELECT * FROM collectionFields WHERE collectionID = ? ORDER BY position, id", arguments: [id])
            let views = try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ? ORDER BY position, id", arguments: [id])
            // Agenda projections do not load any rich-text document bodies.
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, d.title, d.cover, d.appearanceJSON, e.position
                FROM collectionEntries e JOIN documents d ON e.documentID = d.id
                JOIN collections c ON c.id = e.collectionID
                WHERE e.collectionID = ? AND d.parentDocumentID = c.documentID
                    AND d.isTrashed = 0 AND d.isArchived = 0 ORDER BY e.position, d.id
                """, arguments: [id])
            let values = try Row.fetchAll(db, sql: """
                SELECT v.documentID, v.fieldID, v.valueJSON FROM collectionValues v
                JOIN collectionFields f ON f.id = v.fieldID WHERE f.collectionID = ?
                """, arguments: [id])
            var byDocument: [String: [String: CollectionValue]] = [:]
            for row in values {
                let json: String = row["valueJSON"]
                let value = try JSONDecoder().decode(CollectionValue.self, from: Data(json.utf8))
                byDocument[row["documentID"], default: [:]][row["fieldID"]] = value
            }
            let entries = rows.map { row -> CollectionEntrySummary in
                let documentID: String = row["id"]
                return CollectionEntrySummary(id: documentID, title: row["title"], cover: row["cover"],
                    appearance: .decode(row["appearanceJSON"]),
                    position: row["position"], values: byDocument[documentID] ?? [:])
            }
            return CollectionSnapshot(record: record, name: record.name, fields: fields, views: views, entries: entries)
        }
    }

    func addEntry(collectionID: String, title: String, kanbanViewID: String? = nil, columnID: String? = nil) throws -> DocumentRecord {
        try database.write { db in
            try checkScope(collectionID, in: db)
            guard (kanbanViewID == nil) == (columnID == nil) else { throw VellixError.impossibleMove("Choose both a board and its column.") }
            guard title.trimmedNonEmpty != nil else { throw VellixError.impossibleMove("Enter an entry title.") }
            let collection = try Self.requireCollection(collectionID, in: db)
            let container = try documents.requireDocumentInDatabase(collection.documentID, db: db)
            let entry = try documents.create(DocumentDraft(title: title, spaceID: container.spaceID, folderID: container.folderID,
                parentDocumentID: container.id), in: db)
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM collectionEntries WHERE collectionID = ?", arguments: [collectionID]) ?? 0
            try db.execute(sql: "INSERT INTO collectionEntries (documentID, collectionID, position) VALUES (?, ?, ?)", arguments: [entry.id, collectionID, position])
            if let kanbanViewID, let columnID {
                try Self.updateKanban(collectionID: collectionID, viewID: kanbanViewID, in: db) { config in
                    guard config.kanbanColumns.contains(where: { $0.id == columnID }) else { throw VellixError.impossibleMove("This column no longer exists.") }
                    config.kanbanAssignments[entry.id] = columnID
                    config.kanbanEntryOrder[columnID, default: []].append(entry.id)
                }
            }
            return entry
        }
    }

    func rename(collectionID: String, name: String) throws {
        guard let name = name.trimmedNonEmpty else { throw VellixError.impossibleMove("Enter a collection name.") }
        try database.write { db in
            try checkScope(collectionID, in: db)
            _ = try Self.requireCollection(collectionID, in: db)
            try db.execute(sql: "UPDATE collections SET name = ? WHERE id = ?", arguments: [name, collectionID])
        }
    }

    func saveValue(collectionID: String, documentID: String, fieldID: String, value: CollectionValue) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            guard try String.fetchOne(db, sql: "SELECT collectionID FROM collectionEntries WHERE documentID = ?", arguments: [documentID]) == collectionID,
                  let field = try CollectionField.fetchOne(db, key: fieldID), field.collectionID == collectionID else {
                throw VellixError.impossibleMove("This field does not belong to this collection entry.")
            }
            var normalized = value
            let validOptions = Set(field.configuration.options.map(\.id))
            guard Set(value.optionIDs).isSubset(of: validOptions) else { throw VellixError.impossibleMove("An option was removed. Choose an available value.") }
            normalized.optionIDs = Array(Set(value.optionIDs)).sorted()
            if field.kind == .select { normalized.optionIDs = Array(normalized.optionIDs.prefix(1)) }
            if field.kind != .checkbox { normalized.checked = nil }
            if field.kind != .select && field.kind != .multiSelect { normalized.optionIDs = [] }
            if field.kind == .select || field.kind == .multiSelect || field.kind == .checkbox { normalized.text = "" }
            if !normalized.isEmpty {
                if field.kind == .email {
                    guard normalized.text.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else {
                        throw VellixError.impossibleMove("Enter a valid email address.")
                    }
                } else if let message = normalized.applying(to: field.configuration).validationMessage {
                    throw VellixError.impossibleMove(message)
                }
                if field.kind == .date && normalized.applying(to: field.configuration).civilDate == nil {
                    throw VellixError.impossibleMove("Choose a valid date.")
                }
            }
            if normalized.isEmpty {
                try db.execute(sql: "DELETE FROM collectionValues WHERE documentID = ? AND fieldID = ?", arguments: [documentID, fieldID])
            } else {
                let json = String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!
                try db.execute(sql: "INSERT INTO collectionValues VALUES (?, ?, ?) ON CONFLICT(documentID, fieldID) DO UPDATE SET valueJSON = excluded.valueJSON",
                    arguments: [documentID, fieldID, json])
            }
        }
    }

    func saveField(_ proposed: CollectionField, allowClearingValues: Bool = false) throws {
        try database.write { db in
            try checkScope(proposed.collectionID, in: db)
            _ = try Self.requireCollection(proposed.collectionID, in: db)
            var field = proposed
            guard let name = field.name.trimmedNonEmpty else { throw VellixError.impossibleMove("Enter a field name.") }
            field.name = name
            var configuration = field.configuration
            configuration.value = ""; configuration.checked = false; configuration.selectedOptionIDs = []
            if let message = configuration.validationMessage { throw VellixError.impossibleMove(message) }
            guard Set(configuration.options.map(\.id)).count == configuration.options.count else { throw VellixError.impossibleMove("Options must have unique identifiers.") }
            let original = try CollectionField.fetchOne(db, key: field.id)
            guard original == nil || original?.collectionID == field.collectionID else { throw VellixError.impossibleMove("This field belongs to another collection.") }
            let values = try Row.fetchAll(db, sql: "SELECT documentID, valueJSON FROM collectionValues WHERE fieldID = ?", arguments: [field.id])
            let valid = Set(configuration.options.map(\.id))
            let views = try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ?", arguments: [field.collectionID])
            for var view in views {
                var config = view.configuration
                let affected = config.filters.contains { filter in
                    filter.fieldID == field.id && (original?.kind != field.kind || !Set(filter.value.optionIDs).isSubset(of: valid))
                }
                if affected {
                    guard allowClearingValues else { throw CollectionIntegrityError.confirmationRequired }
                    config.filters.removeAll { filter in
                        filter.fieldID == field.id && (original?.kind != field.kind || !Set(filter.value.optionIDs).isSubset(of: valid))
                    }
                    view.configuration = config
                    try view.update(db)
                }
            }
            for row in values {
                let json: String = row["valueJSON"]
                var value = try JSONDecoder().decode(CollectionValue.self, from: Data(json.utf8))
                let incompatible = original?.kind != field.kind
                let removed = !Set(value.optionIDs).isSubset(of: valid)
                guard !incompatible && !removed || allowClearingValues else {
                    throw CollectionIntegrityError.confirmationRequired
                }
                if incompatible { value = CollectionValue() }
                else { value.optionIDs.removeAll { !valid.contains($0) } }
                try db.execute(sql: "UPDATE collectionValues SET valueJSON = ? WHERE documentID = ? AND fieldID = ?",
                    arguments: [String(data: try JSONEncoder().encode(value), encoding: .utf8)!, row["documentID"] as String, field.id])
            }
            field.configuration = configuration
            if original == nil {
                field.position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM collectionFields WHERE collectionID = ?", arguments: [field.collectionID]) ?? 0
            }
            try field.save(db)
            if original == nil {
                for var view in try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ?", arguments: [field.collectionID]) {
                    var config = view.configuration
                    config.visibleFieldIDs.append(field.id)
                    view.configuration = config
                    try view.update(db)
                }
            }
        }
    }

    func deleteField(_ field: CollectionField) throws {
        try database.write { db in
            try checkScope(field.collectionID, in: db)
            guard try CollectionField.fetchOne(db, key: field.id)?.collectionID == field.collectionID else { return }
            try db.execute(sql: "DELETE FROM collectionFields WHERE id = ?", arguments: [field.id])
            for var view in try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ?", arguments: [field.collectionID]) {
                var config = view.configuration
                config.visibleFieldIDs.removeAll { $0 == field.id }
                config.filters.removeAll { $0.fieldID == field.id }
                config.sorts.removeAll { $0.fieldID == field.id }
                view.configuration = config
                try view.update(db)
            }
        }
    }

    @discardableResult func addView(collectionID: String, name: String, kind: CollectionViewKind, duplicateID: String? = nil) throws -> CollectionViewRecord {
        try database.write { db in
            try checkScope(collectionID, in: db)
            _ = try Self.requireCollection(collectionID, in: db)
            var view = CollectionViewRecord(collectionID: collectionID, name: name.trimmedNonEmpty ?? kind.title, kind: kind)
            view.position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM collectionViews WHERE collectionID = ?", arguments: [collectionID]) ?? 0
            if let duplicateID {
                guard let original = try CollectionViewRecord.fetchOne(db, key: duplicateID), original.collectionID == collectionID else {
                    throw VellixError.impossibleMove("The view no longer exists.")
                }
                view.configurationJSON = original.configurationJSON
            } else {
                var config = view.configuration
                config.visibleFieldIDs = try String.fetchAll(db, sql: "SELECT id FROM collectionFields WHERE collectionID = ? ORDER BY position", arguments: [collectionID])
                view.configuration = config
            }
            try view.insert(db)
            try db.execute(sql: "UPDATE collections SET activeViewID = ? WHERE id = ?", arguments: [view.id, collectionID])
            return view
        }
    }

    func saveView(_ view: CollectionViewRecord) throws {
        try database.write { db in
            try checkScope(view.collectionID, in: db)
            guard let original = try CollectionViewRecord.fetchOne(db, key: view.id), original.collectionID == view.collectionID,
                  view.name.trimmedNonEmpty != nil else { throw VellixError.impossibleMove("Enter a view name.") }
            let fields = Set(try String.fetchAll(db, sql: "SELECT id FROM collectionFields WHERE collectionID = ?", arguments: [view.collectionID]))
            var saved = view
            var config = view.configuration
            // Board mutations have their own transactional commands; settings must not overwrite them from an older sheet snapshot.
            config.kanbanColumns = original.configuration.kanbanColumns
            config.kanbanAssignments = original.configuration.kanbanAssignments
            config.kanbanEntryOrder = original.configuration.kanbanEntryOrder
            guard Set(config.visibleFieldIDs).isSubset(of: fields), Set(config.visibleFieldIDs).count == config.visibleFieldIDs.count,
                  (config.filters.map(\.fieldID) + config.sorts.map(\.fieldID)).allSatisfy({ $0 == CollectionViewConfiguration.titleFieldID || fields.contains($0) }),
                  (1...3).contains(config.galleryColumns) else { throw VellixError.impossibleMove("A field changed. Reopen the view settings.") }
            for filter in config.filters {
                let field = try CollectionField.fetchOne(db, key: filter.fieldID)
                let kind = field?.kind ?? .text
                guard kind.operators.contains(filter.operation),
                      Set(filter.value.optionIDs).isSubset(of: Set(field?.configuration.options.map(\.id) ?? [])) else {
                    throw VellixError.impossibleMove("A filter option changed. Reopen the filter before saving.")
                }
                if let field, let message = field.filterValidation(filter) { throw VellixError.impossibleMove(message) }
            }
            saved.configuration = config
            try saved.update(db)
        }
    }

    func selectView(collectionID: String, viewID: String) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            guard try CollectionViewRecord.fetchOne(db, key: viewID)?.collectionID == collectionID else { throw VellixError.impossibleMove("This view no longer exists.") }
            try db.execute(sql: "UPDATE collections SET activeViewID = ? WHERE id = ?", arguments: [viewID, collectionID])
        }
    }

    func deleteView(collectionID: String, viewID: String) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            let views = try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ? ORDER BY position", arguments: [collectionID])
            guard views.count > 1 else { throw VellixError.impossibleMove("Add a replacement view before deleting the last view.") }
            guard views.contains(where: { $0.id == viewID }) else { return }
            try db.execute(sql: "DELETE FROM collectionViews WHERE id = ?", arguments: [viewID])
            try db.execute(sql: "UPDATE collections SET activeViewID = ? WHERE id = ? AND activeViewID = ?",
                arguments: [views.first { $0.id != viewID }!.id, collectionID, viewID])
        }
    }

    func reorder(collectionID: String, table: String, ids: [String]) throws {
        guard ["collectionViews", "collectionFields", "collectionEntries"].contains(table) else { return }
        try database.write { db in
            try checkScope(collectionID, in: db)
            let key = table == "collectionEntries" ? "documentID" : "id"
            let visible = table == "collectionEntries" ? " AND documentID IN (SELECT id FROM documents WHERE isTrashed = 0 AND isArchived = 0)" : ""
            let originals = try String.fetchAll(db, sql: "SELECT \(key) FROM \(table) WHERE collectionID = ?\(visible)", arguments: [collectionID])
            guard Set(ids) == Set(originals), ids.count == originals.count else { throw VellixError.impossibleMove("The list changed. Reopen it before reordering.") }
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE \(table) SET position = ? WHERE \(key) = ? AND collectionID = ?", arguments: [position, id, collectionID])
            }
        }
    }

    private static func requireCollection(_ id: String, in db: Database) throws -> CollectionRecord {
        guard let record = try CollectionRecord.fetchOne(db, key: id),
              try Bool.fetchOne(db, sql: "SELECT isTrashed = 0 AND isArchived = 0 FROM documents WHERE id = ?", arguments: [record.documentID]) == true else {
            throw VellixError.impossibleMove("This collection is no longer available. Restore its page from Trash.")
        }
        _ = try SpaceOwnership.document(record.documentID, scope: nil, in: db)
        return record
    }

    private func checkScope(_ id: String, in db: Database) throws {
        let owner = try Self.requireCollection(id, in: db)
        _ = try SpaceOwnership.document(owner.documentID, scope: documents.spaceID, in: db)
    }

    private static func updateKanban(collectionID: String, viewID: String, in db: Database,
        mutation: (inout CollectionViewConfiguration) throws -> Void) throws {
        _ = try requireCollection(collectionID, in: db)
        guard var view = try CollectionViewRecord.fetchOne(db, key: viewID),
              view.collectionID == collectionID, view.kind == .kanban else {
            throw VellixError.impossibleMove("This board no longer exists.")
        }
        var config = view.configuration
        let members = Set(try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries WHERE collectionID = ?", arguments: [collectionID]))
        config.kanbanAssignments = config.kanbanAssignments.filter { members.contains($0.key) }
        config.kanbanEntryOrder = config.kanbanEntryOrder.mapValues { $0.filter { members.contains($0) } }
        try mutation(&config)
        let columnIDs = Set(config.kanbanColumns.map(\.id))
        guard !columnIDs.isEmpty, columnIDs.count == config.kanbanColumns.count,
              config.kanbanColumns.allSatisfy({ !$0.id.isEmpty && $0.name.trimmedNonEmpty != nil && $0.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }),
              Set(config.kanbanAssignments.keys).isSubset(of: members),
              Set(config.kanbanAssignments.values).isSubset(of: columnIDs) else {
            throw VellixError.impossibleMove("The board changed. Reopen its columns before saving.")
        }
        config.kanbanEntryOrder = config.kanbanEntryOrder.filter { columnIDs.contains($0.key) }
        for (columnID, order) in config.kanbanEntryOrder {
            guard Set(order).count == order.count, order.allSatisfy({ members.contains($0) && config.kanbanColumnID(for: $0) == columnID }) else {
                throw VellixError.impossibleMove("The entry order changed. Reopen the board.")
            }
        }
        view.configuration = config
        try view.update(db)
    }

    @discardableResult func addKanbanColumn(collectionID: String, viewID: String, name: String, color: String) throws -> CollectionKanbanColumn {
        let column = CollectionKanbanColumn(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color)
        try database.write { db in
            try checkScope(collectionID, in: db)
            try Self.updateKanban(collectionID: collectionID, viewID: viewID, in: db) { $0.kanbanColumns.append(column) }
        }
        return column
    }

    func updateKanbanColumn(collectionID: String, viewID: String, columnID: String,
        name: String? = nil, color: String? = nil, collapsed: Bool? = nil) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            try Self.updateKanban(collectionID: collectionID, viewID: viewID, in: db) { config in
                guard let index = config.kanbanColumns.firstIndex(where: { $0.id == columnID }) else { throw VellixError.impossibleMove("This column no longer exists.") }
                if let name { config.kanbanColumns[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let color { config.kanbanColumns[index].color = color }
                if let collapsed { config.kanbanColumns[index].collapsed = collapsed }
            }
        }
    }

    func reorderKanbanColumns(collectionID: String, viewID: String, ids: [String]) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            try Self.updateKanban(collectionID: collectionID, viewID: viewID, in: db) { config in
                guard Set(ids) == Set(config.kanbanColumns.map(\.id)), ids.count == config.kanbanColumns.count else { throw VellixError.impossibleMove("The column list changed. Reopen it before reordering.") }
                // Materialize the implicit default before changing the first column.
                let entries = try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries WHERE collectionID = ?", arguments: [collectionID])
                for id in entries where config.kanbanAssignments[id] == nil { config.kanbanAssignments[id] = config.kanbanColumns.first!.id }
                let columns = Dictionary(uniqueKeysWithValues: config.kanbanColumns.map { ($0.id, $0) })
                config.kanbanColumns = ids.compactMap { columns[$0] }
            }
        }
    }

    func deleteKanbanColumn(collectionID: String, viewID: String, columnID: String, destinationID: String) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            try Self.updateKanban(collectionID: collectionID, viewID: viewID, in: db) { config in
                guard columnID != destinationID, config.kanbanColumns.count > 1,
                      config.kanbanColumns.contains(where: { $0.id == columnID }),
                      config.kanbanColumns.contains(where: { $0.id == destinationID }) else {
                    throw VellixError.impossibleMove("Keep at least one column and choose where its entries should move.")
                }
                let entries = try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries WHERE collectionID = ? ORDER BY position, documentID", arguments: [collectionID])
                for id in entries {
                    let previous = config.kanbanColumnID(for: id)
                    config.kanbanAssignments[id] = previous == columnID ? destinationID : previous
                }
                let moved = config.kanbanEntryOrder.removeValue(forKey: columnID) ?? []
                config.kanbanEntryOrder[destinationID, default: []].append(contentsOf: moved)
                config.kanbanColumns.removeAll { $0.id == columnID }
            }
        }
    }

    func moveKanbanEntry(collectionID: String, viewID: String, documentID: String, columnID: String, beforeID: String? = nil) throws {
        try database.write { db in
            try checkScope(collectionID, in: db)
            try Self.updateKanban(collectionID: collectionID, viewID: viewID, in: db) { config in
                let members = try String.fetchAll(db, sql: "SELECT e.documentID FROM collectionEntries e JOIN documents d ON d.id = e.documentID WHERE e.collectionID = ? AND d.isTrashed = 0 AND d.isArchived = 0 ORDER BY e.position, e.documentID", arguments: [collectionID])
                guard members.contains(documentID), config.kanbanColumns.contains(where: { $0.id == columnID }) else { throw VellixError.impossibleMove("This entry or column is no longer available.") }
                if let beforeID {
                    guard beforeID != documentID, members.contains(beforeID), config.kanbanColumnID(for: beforeID) == columnID,
                          config.sorts.isEmpty else { throw VellixError.impossibleMove("Clear the board's sorting rules before manually reordering entries.") }
                }
                for key in Array(config.kanbanEntryOrder.keys) { config.kanbanEntryOrder[key]?.removeAll { $0 == documentID } }
                let current = config.kanbanEntryOrder[columnID] ?? []
                var order = current + members.filter { $0 != documentID && !current.contains($0) && config.kanbanColumnID(for: $0) == columnID }
                config.kanbanAssignments[documentID] = columnID
                if let beforeID, let index = order.firstIndex(of: beforeID) { order.insert(documentID, at: index) }
                else { order.append(documentID) }
                config.kanbanEntryOrder[columnID] = order
            }
        }
    }

    // Called inside the existing document/template tree-copy transaction.
    @discardableResult static func copyCollections(documentIDs: [String: String], in db: Database) throws -> [String: String] {
        var collections: [String: String] = [:]
        var fields: [String: String] = [:]
        for source in try CollectionRecord.fetchAll(db) where documentIDs[source.documentID] != nil {
            var copy = source
            copy.id = UUID().uuidString
            copy.documentID = documentIDs[source.documentID]!
            copy.createdAt = Date()
            collections[source.id] = copy.id
            let originalViews = try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ? ORDER BY position", arguments: [source.id])
            let viewIDs = Dictionary(uniqueKeysWithValues: originalViews.map { ($0.id, UUID().uuidString) })
            copy.activeViewID = viewIDs[source.activeViewID] ?? viewIDs.values.sorted().first ?? UUID().uuidString
            try copy.insert(db)
            for original in try CollectionField.fetchAll(db, sql: "SELECT * FROM collectionFields WHERE collectionID = ?", arguments: [source.id]) {
                var field = original
                field.id = UUID().uuidString; field.collectionID = copy.id
                fields[original.id] = field.id
                try field.insert(db)
            }
            for original in originalViews {
                var view = original
                view.id = viewIDs[original.id]!; view.collectionID = copy.id
                var config = original.configuration
                config.visibleFieldIDs = config.visibleFieldIDs.compactMap { fields[$0] }
                for i in config.filters.indices { config.filters[i].fieldID = fields[config.filters[i].fieldID] ?? config.filters[i].fieldID }
                for i in config.sorts.indices { config.sorts[i].fieldID = fields[config.sorts[i].fieldID] ?? config.sorts[i].fieldID }
                config.kanbanAssignments = Dictionary(uniqueKeysWithValues: config.kanbanAssignments.compactMap { key, value in
                    documentIDs[key].map { ($0, value) }
                })
                config.kanbanEntryOrder = config.kanbanEntryOrder.mapValues { $0.compactMap { documentIDs[$0] } }
                view.configuration = config
                try view.insert(db)
            }
        }
        for (sourceID, copyID) in documentIDs {
            guard let membership = try Row.fetchOne(db, sql: "SELECT collectionID, position FROM collectionEntries WHERE documentID = ?", arguments: [sourceID]) else { continue }
            let originalID: String = membership["collectionID"]
            let collectionID = collections[originalID] ?? originalID
            guard let collection = try CollectionRecord.fetchOne(db, key: collectionID),
                  try String.fetchOne(db, sql: "SELECT parentDocumentID FROM documents WHERE id = ?", arguments: [copyID]) == collection.documentID else { continue }
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM collectionEntries WHERE collectionID = ?", arguments: [collectionID]) ?? 0
            try db.execute(sql: "INSERT INTO collectionEntries VALUES (?, ?, ?)", arguments: [copyID, collectionID, position])
            for value in try Row.fetchAll(db, sql: "SELECT fieldID, valueJSON FROM collectionValues WHERE documentID = ?", arguments: [sourceID]) {
                let fieldID: String = value["fieldID"]
                try db.execute(sql: "INSERT INTO collectionValues VALUES (?, ?, ?)",
                    arguments: [copyID, fields[fieldID] ?? fieldID, value["valueJSON"] as String])
            }
            if collections[originalID] == nil {
                // Duplicating an entry (not its containing page) keeps its placement in existing boards.
                for var view in try CollectionViewRecord.fetchAll(db, sql: "SELECT * FROM collectionViews WHERE collectionID = ? AND kind = 'kanban'", arguments: [collectionID]) {
                    var config = view.configuration
                    guard let columnID = config.kanbanColumnID(for: sourceID) else { continue }
                    config.kanbanAssignments[copyID] = columnID
                    let members = try String.fetchAll(db, sql: "SELECT documentID FROM collectionEntries WHERE collectionID = ? ORDER BY position, documentID", arguments: [collectionID])
                    var order = config.kanbanEntryOrder[columnID] ?? []
                    order += members.filter { $0 != copyID && !order.contains($0) && config.kanbanColumnID(for: $0) == columnID }
                    if let index = order.firstIndex(of: sourceID) { order.insert(copyID, at: index + 1) } else { order.append(copyID) }
                    config.kanbanEntryOrder[columnID] = order
                    view.configuration = config; try view.update(db)
                }
            }
        }
        try remapCollectionReferences(documentIDs: documentIDs, collectionIDs: collections, in: db)
        return collections
    }

    static func remapCollectionReferences(documentIDs: [String: String], collectionIDs: [String: String], in db: Database) throws {
        for copyID in documentIDs.values {
            guard var document = try DocumentRecord.fetchOne(db, key: copyID) else { continue }
            func remap(_ node: [String: Any]) -> [String: Any] {
                var result = node
                if node["type"] as? String == "collection", var attrs = node["attrs"] as? [String: Any],
                   let oldID = attrs["collectionID"] as? String, let newID = collectionIDs[oldID] {
                    attrs["collectionID"] = newID
                    if let oldDocument = attrs["documentID"] as? String { attrs["documentID"] = documentIDs[oldDocument] ?? oldDocument }
                    result["attrs"] = attrs
                }
                if let content = node["content"] as? [[String: Any]] { result["content"] = content.map(remap) }
                return result
            }
            document.tipTapJSON = try TipTapContentAnalyzer.normalizePayloadToJSON(remap(TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)))
            try document.update(db)
            try DocumentRepository.upsertSearchIndex(document, in: db)
            for var snapshot in try DocumentSnapshotRecord.fetchAll(db, sql: "SELECT * FROM documentSnapshots WHERE documentID=?", arguments: [copyID]) {
                snapshot.tipTapJSON = try TipTapContentAnalyzer.normalizePayloadToJSON(remap(TipTapContentAnalyzer.documentObject(from: snapshot.tipTapJSON)))
                try snapshot.update(db)
            }
        }
    }
}

extension DocumentRepository {
    func requireDocumentInDatabase(_ id: String, db: Database) throws -> DocumentRecord {
        try SpaceOwnership.document(id, scope: spaceID, in: db)
    }
}
