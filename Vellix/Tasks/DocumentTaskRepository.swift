import Foundation
import GRDB

extension Notification.Name {
    static let vellixTasksChanged = Notification.Name("Vellix.TasksChanged")
}

nonisolated struct DocumentTaskRecord: Identifiable, Sendable {
    var id: String { metadata.id }
    var documentID: String
    var rootDocumentID: String
    var parentDocumentID: String?
    var blockID: String
    var documentTitle: String
    var text: String
    var checked: Bool
    var isTemplate: Bool
    var isActive: Bool
    var metadata: DocumentTaskMetadata
}

nonisolated struct DocumentTaskOccurrence: Identifiable, Sendable {
    var id: String { occurrence.id }
    var taskID: String
    var documentID: String
    var blockID: String
    var occurrence: TaskCompletedOccurrence
}

// This is an index of document JSON, never an independently editable copy of task content.
nonisolated enum DocumentTaskIndex {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE documentTasks (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                blockID TEXT NOT NULL,
                metadataJSON TEXT NOT NULL,
                checked INTEGER NOT NULL,
                scheduledAt DOUBLE,
                recurring INTEGER NOT NULL,
                UNIQUE(documentID, blockID)
            );
            CREATE INDEX documentTasks_schedule ON documentTasks(scheduledAt);
            CREATE TABLE taskCompletions (
                id TEXT PRIMARY KEY NOT NULL,
                taskID TEXT NOT NULL REFERENCES documentTasks(id) ON DELETE CASCADE,
                scheduledAt DOUBLE,
                completedAt DOUBLE NOT NULL
            );
            CREATE INDEX taskCompletions_date ON taskCompletions(completedAt);
            CREATE TABLE taskDocumentChanges (documentID TEXT PRIMARY KEY NOT NULL);
            CREATE TRIGGER tasks_document_insert AFTER INSERT ON documents BEGIN
                INSERT OR IGNORE INTO taskDocumentChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER tasks_document_update AFTER UPDATE OF tipTapJSON, title, parentDocumentID, templateID, isTrashed, isArchived ON documents BEGIN
                INSERT OR IGNORE INTO taskDocumentChanges VALUES (NEW.id);
            END;
            CREATE TRIGGER tasks_document_delete AFTER DELETE ON documents BEGIN
                INSERT OR IGNORE INTO taskDocumentChanges VALUES (OLD.id);
            END;
            INSERT INTO taskDocumentChanges SELECT id FROM documents;
            """)
        _ = try reconcile(in: db)
    }

    @discardableResult
    static func reconcile(in db: Database) throws -> Bool {
        let documentIDs = try String.fetchAll(db, sql: "SELECT documentID FROM taskDocumentChanges")
        guard !documentIDs.isEmpty else { return false }
        try db.execute(sql: "DELETE FROM taskDocumentChanges")
        var changed = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for id in documentIDs {
            let oldIDs = try String.fetchAll(db, sql: "SELECT id FROM documentTasks WHERE documentID = ?", arguments: [id])
            guard let document = try DocumentRecord.fetchOne(db, key: id) else {
                // The foreign key has already removed the task and its occurrence index.
                changed = true
                continue
            }
            let tasks = try contexts(in: document.tipTapJSON)
            changed = changed || !tasks.isEmpty || !oldIDs.isEmpty
            let current = Set(tasks.compactMap { $0.metadata?.id })
            for old in oldIDs where !current.contains(old) {
                try db.execute(sql: "DELETE FROM documentTasks WHERE id = ? AND documentID = ?", arguments: [old, id])
            }
            for context in tasks {
                guard let task = context.metadata else { continue }
                let json = String(decoding: try encoder.encode(task), as: UTF8.self)
                if let old = try Row.fetchOne(db, sql: "SELECT * FROM documentTasks WHERE id = ?", arguments: [task.id]),
                   old["documentID"] as String == id, old["blockID"] as String == context.blockID,
                   old["metadataJSON"] as String == json, old["checked"] as Bool == context.checked { continue }
                try db.execute(sql: """
                    INSERT INTO documentTasks(id, documentID, blockID, metadataJSON, checked, scheduledAt, recurring)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET documentID = excluded.documentID, blockID = excluded.blockID,
                        metadataJSON = excluded.metadataJSON, checked = excluded.checked,
                        scheduledAt = excluded.scheduledAt, recurring = excluded.recurring
                    """, arguments: [task.id, id, context.blockID, json, context.checked, task.scheduledAt, task.recurrence != nil])
                try db.execute(sql: "DELETE FROM taskCompletions WHERE taskID = ?", arguments: [task.id])
                for completion in task.history {
                    try db.execute(sql: "INSERT OR IGNORE INTO taskCompletions VALUES (?, ?, ?, ?)",
                                   arguments: [completion.id, task.id, completion.scheduledAt, completion.completedAt])
                }
            }
        }
        // Even an ancestor with no tasks can change eligibility of every nested task.
        return changed || !documentIDs.isEmpty
    }

    static func contexts(in json: String) throws -> [DocumentTaskContext] {
        var result: [DocumentTaskContext] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "taskItem", let attrs = node["attrs"] as? [String: Any],
               let id = attrs["id"] as? String, let task = DocumentTaskMetadata.decode(attrs["trackedTask"]) {
                result.append(DocumentTaskContext(blockID: id, checked: attrs["checked"] as? Bool ?? false, metadata: task))
            }
            for child in node["content"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(TipTapContentAnalyzer.documentObject(from: json))
        return result
    }

    static func texts(in json: String) -> [String: String] {
        func contentText(_ node: [String: Any]) -> String {
            if node["type"] as? String == "taskList" { return "" }
            if let text = node["text"] as? String { return text }
            return (node["content"] as? [[String: Any]] ?? []).map(contentText).joined(separator: " ")
        }
        var result: [String: String] = [:]
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "taskItem", let id = (node["attrs"] as? [String: Any])?["id"] as? String {
                result[id] = contentText(node).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for child in node["content"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(TipTapContentAnalyzer.documentObject(from: json))
        return result
    }

    static func updating(_ json: String, blockID: String, metadata: DocumentTaskMetadata, checked: Bool) throws -> String {
        var found = false
        func walk(_ node: [String: Any]) -> [String: Any] {
            var copy = node
            if node["type"] as? String == "taskItem", var attrs = node["attrs"] as? [String: Any],
               attrs["id"] as? String == blockID {
                attrs["trackedTask"] = metadata.object
                attrs["checked"] = checked
                attrs["crossed"] = false
                copy["attrs"] = attrs
                found = true
            }
            if let children = node["content"] as? [[String: Any]] { copy["content"] = children.map(walk) }
            return copy
        }
        let value = walk(TipTapContentAnalyzer.documentObject(from: json))
        guard found else { throw DocumentTaskError.missingTask }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

final class DocumentTaskRepository: @unchecked Sendable {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func all(includeTemplates: Bool = false, includeInactive: Bool = false) throws -> [DocumentTaskRecord] {
        try database.read { db in
            let documents = try DocumentRecord.fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            var textCache: [String: [String: String]] = [:]
            return try Row.fetchAll(db, sql: "SELECT * FROM documentTasks ORDER BY scheduledAt IS NULL, scheduledAt, id").compactMap { row in
                let sourceID: String = row["documentID"]
                guard let document = byID[sourceID], let json = (row["metadataJSON"] as String).data(using: .utf8) else { return nil }
                let metadata = try JSONDecoder().decode(DocumentTaskMetadata.self, from: json)
                var active = !document.isTrashed && !document.isArchived
                var template = document.templateID != nil
                var parent = document.parentDocumentID
                var rootID = document.id
                var seen: Set<String> = [document.id]
                while let id = parent, seen.insert(id).inserted, let ancestor = byID[id] {
                    active = active && !ancestor.isTrashed && !ancestor.isArchived
                    template = template || ancestor.templateID != nil
                    rootID = ancestor.id
                    parent = ancestor.parentDocumentID
                }
                guard (includeTemplates || !template), (includeInactive || active) else { return nil }
                let blockID: String = row["blockID"]
                if textCache[sourceID] == nil { textCache[sourceID] = DocumentTaskIndex.texts(in: document.tipTapJSON) }
                return DocumentTaskRecord(documentID: sourceID, rootDocumentID: rootID, parentDocumentID: document.parentDocumentID,
                    blockID: blockID, documentTitle: document.title,
                    text: textCache[sourceID]?[blockID] ?? "",
                    checked: row["checked"], isTemplate: template, isActive: active, metadata: metadata)
            }
        }
    }

    func tasks(documentID: String, includingNestedPages: Bool = false) throws -> [DocumentTaskRecord] {
        var ids: Set<String> = [documentID]
        if includingNestedPages {
            let docs = try database.read { try DocumentRecord.fetchAll($0) }
            var count = 0
            while count != ids.count {
                count = ids.count
                for doc in docs where doc.parentDocumentID.map(ids.contains) == true { ids.insert(doc.id) }
            }
        }
        return try all(includeTemplates: true).filter { ids.contains($0.documentID) }
    }

    func scheduled(on day: Date, calendar: Calendar = .current) throws -> [DocumentTaskRecord] {
        try all().filter { !$0.checked && $0.metadata.scheduledDate.map { calendar.isDate($0, inSameDayAs: day) } == true }
    }

    func upcoming(from date: Date = Date()) throws -> [DocumentTaskRecord] {
        try all().filter { !$0.checked && ($0.metadata.scheduledDate.map { $0 >= date } ?? false) }
    }

    func recurring() throws -> [DocumentTaskRecord] { try all().filter { $0.metadata.recurrence != nil } }
    func reminders() throws -> [DocumentTaskRecord] { try all().filter { $0.metadata.reminderEnabled } }

    func completedOccurrences(taskID: String? = nil) throws -> [DocumentTaskOccurrence] {
        try database.read { db in
            let arguments = StatementArguments(taskID.map { [$0] } ?? [])
            let rows = try Row.fetchAll(db, sql: taskID == nil
                ? "SELECT taskCompletions.*, documentID, blockID FROM taskCompletions JOIN documentTasks ON taskID = documentTasks.id ORDER BY completedAt DESC"
                : "SELECT taskCompletions.*, documentID, blockID FROM taskCompletions JOIN documentTasks ON taskID = documentTasks.id WHERE taskID = ? ORDER BY completedAt DESC",
                arguments: arguments)
            return rows.map { DocumentTaskOccurrence(taskID: $0["taskID"], documentID: $0["documentID"], blockID: $0["blockID"],
                occurrence: TaskCompletedOccurrence(id: $0["id"], scheduledAt: $0["scheduledAt"], completedAt: $0["completedAt"])) }
        }
    }

    @discardableResult
    func setCompleted(taskID: String, occurrenceID: String, completed: Bool) throws -> DocumentRecord {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM documentTasks WHERE id = ?", arguments: [taskID]),
                  var document = try DocumentRecord.fetchOne(db, key: row["documentID"] as String) else { throw DocumentTaskError.missingTask }
            let metadata = try JSONDecoder().decode(DocumentTaskMetadata.self, from: Data((row["metadataJSON"] as String).utf8))
            guard metadata.occurrenceID == occurrenceID else { throw DocumentTaskError.staleOccurrence }
            let result = try metadata.completing(completed)
            document.tipTapJSON = try DocumentTaskIndex.updating(document.tipTapJSON, blockID: row["blockID"], metadata: result.metadata, checked: result.checked)
            document.updatedAt = Date()
            document.revision += 1
            try document.update(db)
            try DocumentRepository.upsertSearchIndex(document, in: db)
            return document
        }
    }
}
