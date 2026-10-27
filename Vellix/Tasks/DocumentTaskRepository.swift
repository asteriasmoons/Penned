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
        _ = try reconcile(in: db, projectsPages: false)
    }

    @discardableResult
    static func reconcile(in db: Database, projectsPages: Bool = true) throws -> Bool {
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
        if projectsPages {
            var sources = Set(documentIDs)
            for id in documentIDs {
                if let taskID = DocumentTaskPages.taskID(for: id),
                   let source = try String.fetchOne(db, sql: "SELECT documentID FROM documentTasks WHERE id=?", arguments: [taskID]) {
                    sources.insert(source)
                }
            }
            for id in sources { try DocumentTaskPages.reconcile(sourceID: id, in: db) }
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
            if node["type"] as? String == "inlineTag", let name = (node["attrs"] as? [String: Any])?["name"] as? String { return "#" + name }
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

// Stable page identities make this an idempotent projection of the source task,
// including after undo, sync, relaunch, or moving a task to another document.
nonisolated enum DocumentTaskPages {
    static func detailID(_ taskID: String) -> String { "vellix-task-page:" + taskID }
    static func historyID(_ taskID: String) -> String { "vellix-task-history:" + taskID }
    static func taskID(for documentID: String) -> String? {
        for prefix in ["vellix-task-page:", "vellix-task-history:"] where documentID.hasPrefix(prefix) {
            let id = String(documentID.dropFirst(prefix.count))
            if UUID(uuidString: id) != nil { return id }
        }
        return nil
    }
    static func isManaged(_ documentID: String) -> Bool { taskID(for: documentID) != nil }
    static func isDetail(_ documentID: String) -> Bool { documentID.hasPrefix("vellix-task-page:") && isManaged(documentID) }

    static func reconcile(sourceID: String, in db: Database) throws {
        guard let source = try DocumentRecord.fetchOne(db, key: sourceID) else { return }
        let texts = DocumentTaskIndex.texts(in: source.tipTapJSON)
        for context in try DocumentTaskIndex.contexts(in: source.tipTapJSON) {
            guard let task = context.metadata else { continue }
            let text = texts[context.blockID]?.trimmedNonEmpty ?? "Untitled Task"
            let detail = detailID(task.id), history = historyID(task.id)
            let reference: [String: Any] = ["type": "pageReference", "attrs": ["id": task.id + "-history-link", "documentID": history]]
            try save(id: detail, title: text, parentID: source.id, content: [reference], task: task, taskText: text, source: source, in: db)
            try save(id: history, title: "Completed Tasks", parentID: detail,
                     content: historyContent(task, fallbackText: text), task: task, taskText: text, source: source, in: db)
            // Their initial content contains no tracked tasks. Authored additions
            // are indexed on the page's own subsequent save.
            try db.execute(sql: "DELETE FROM taskDocumentChanges WHERE documentID IN (?, ?)", arguments: [detail, history])
        }
    }

    static func historyContent(_ task: DocumentTaskMetadata, fallbackText: String) -> [[String: Any]] {
        guard !task.history.isEmpty else { return [["type": "paragraph", "attrs": ["id": task.id + "-empty-history"]]] }
        let items: [[String: Any]] = task.history.sorted { $0.completedAt > $1.completedAt }.map { occurrence in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = occurrence.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? task.recurrence?.calendar.timeZone ?? .current
            formatter.dateFormat = "MMM d"
            let scheduled = Date(timeIntervalSince1970: occurrence.scheduledAt ?? occurrence.completedAt)
            let day = formatter.string(from: scheduled)
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
            let timestamp = formatter.string(from: Date(timeIntervalSince1970: occurrence.completedAt))
            let text = "\(day) \(occurrence.taskText ?? fallbackText) (\(occurrence.outcome.rawValue) on \(timestamp))"
            return ["type": "taskItem", "attrs": ["id": occurrence.id, "checked": true, "crossed": occurrence.outcome == .skipped],
                    "content": [["type": "paragraph", "attrs": ["id": occurrence.id + "-text"],
                                 "content": [["type": "text", "text": text, "marks": [["type": "strike"]]]]]]]
        }
        return [["type": "taskList", "attrs": ["id": task.id + "-occurrences-" + (task.history.first?.id ?? "empty")], "content": items]]
    }

    static func removingOccurrences(_ content: [[String: Any]], ids: Set<String>) -> [[String: Any]] {
        func retract(_ node: [String: Any]) -> [String: Any]? {
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            if let id = attrs["id"] as? String, ids.contains(id) { return nil }
            var copy = node
            if let children = node["content"] as? [[String: Any]] {
                var kept = children.compactMap(retract)
                let type = node["type"] as? String ?? ""
                if kept.isEmpty && ["taskList", "bulletList", "orderedList"].contains(type) { return nil }
                if kept.isEmpty && ["blockquote", "callout", "plainCallout", "toggleItem", "taskItem", "listItem", "tableCell", "tableHeader"].contains(type) {
                    kept = [["type": "paragraph", "attrs": ["id": (attrs["id"] as? String ?? "history") + "-empty"]]]
                }
                copy["content"] = kept
            }
            return copy
        }
        return content.compactMap(retract)
    }

    private static func save(id: String, title: String, parentID: String, content: [[String: Any]], task: DocumentTaskMetadata, taskText: String, source: DocumentRecord, in db: Database) throws {
        let old = try DocumentRecord.fetchOne(db, key: id)
        let oldObject = old.map { TipTapContentAnalyzer.documentObject(from: $0.tipTapJSON) }
        let projection = (oldObject?["attrs"] as? [String: Any])?["taskHistoryProjection"] as? [String: Any] ?? [:]
        let priorIDs = Set(projection["occurrences"] as? [String] ?? [])
        let currentIDs = Set(task.history.map(\.id))
        var body = oldObject?["content"] as? [[String: Any]] ?? content
        if old != nil && !isDetail(id) {
            // A projection watermark distinguishes an intentionally edited/deleted
            // entry from an occurrence that has not been recorded yet.
            let removed = priorIDs.subtracting(currentIDs)
            body = removingOccurrences(body, ids: removed)
            var additions = task
            additions.history = task.history.filter { !priorIDs.contains($0.id) }
            if !additions.history.isEmpty { body.append(contentsOf: historyContent(additions, fallbackText: taskText)) }
        }
        if body.isEmpty { body = [["type": "paragraph", "attrs": ["id": task.id + "-empty-history"]]] }
        let attributes: [String: Any] = ["taskHistoryProjection": ["taskID": task.id,
            "sourceTitle": isDetail(id) ? title : (projection["sourceTitle"] as? String ?? title),
            "occurrences": currentIDs.sorted()]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "doc", "attrs": attributes, "content": body], options: [.sortedKeys]), as: UTF8.self)
        let analysis = try TipTapContentAnalyzer.analyze(json)
        var appearance = source.appearance
        appearance.showsCover = false
        let style = appearance.encodedJSON()
        let savedTitle = old.map { isDetail(id) && $0.title == (projection["sourceTitle"] as? String) ? title : $0.title } ?? title
        if let old, old.title == savedTitle, old.tipTapJSON == analysis.canonicalJSON, old.parentDocumentID == parentID,
           old.spaceID == source.spaceID, old.folderID == source.folderID, old.templateID == source.templateID { return }
        var record = old ?? DocumentRecord(id: id, title: title, createdAt: source.createdAt)
        record.title = savedTitle; record.parentDocumentID = parentID
        record.spaceID = source.spaceID; record.folderID = source.folderID; record.templateID = source.templateID
        if old == nil { record.appearanceJSON = style }
        record.tipTapJSON = analysis.canonicalJSON
        record.plainText = analysis.plainText; record.previewText = analysis.previewText
        record.wordCount = analysis.wordCount; record.characterCount = analysis.characterCount
        record.estimatedReadingMinutes = analysis.estimatedReadingMinutes
        if old == nil {
            record.isTrashed = source.isTrashed; record.isArchived = source.isArchived
            record.trashedAt = source.trashedAt; record.trashBatchID = source.trashBatchID
        }
        record.updatedAt = max(old?.updatedAt ?? source.updatedAt, source.updatedAt)
        if old != nil { record.revision += 1 }
        try record.save(db)
        try DocumentRepository.upsertSearchIndex(record, in: db)
    }
}

final class DocumentTaskRepository: @unchecked Sendable {
    private let database: AppDatabase
    var spaceID: String?
    init(database: AppDatabase) { self.database = database }

    func all(includeTemplates: Bool = false, includeInactive: Bool = false) throws -> [DocumentTaskRecord] {
        try database.read { db in
            let documents = try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE \(LibraryAccess.spaces("d.spaceID")) AND s.isArchived=0 AND (? IS NULL OR d.spaceID=?)", arguments: [spaceID, spaceID])
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
        _ = try database.read { try SpaceOwnership.document(documentID, scope: spaceID, in: $0) }
        var ids: Set<String> = [documentID]
        if includingNestedPages {
            let docs = try database.read { try DocumentRecord.fetchAll($0, sql: "SELECT * FROM documents WHERE \(LibraryAccess.spaces()) AND (? IS NULL OR spaceID=?)", arguments: [spaceID, spaceID]) }
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
            var values: [DatabaseValueConvertible?] = [spaceID, spaceID]
            if let taskID { values.append(taskID) }
            let arguments = StatementArguments(values)
            let rows = try Row.fetchAll(db, sql: taskID == nil
                ? "SELECT taskCompletions.*, documentTasks.documentID, blockID, metadataJSON FROM taskCompletions JOIN documentTasks ON taskID=documentTasks.id JOIN documents d ON d.id=documentTasks.documentID WHERE \(LibraryAccess.spaces("d.spaceID")) AND (? IS NULL OR d.spaceID=?) ORDER BY completedAt DESC"
                : "SELECT taskCompletions.*, documentTasks.documentID, blockID, metadataJSON FROM taskCompletions JOIN documentTasks ON taskID=documentTasks.id JOIN documents d ON d.id=documentTasks.documentID WHERE \(LibraryAccess.spaces("d.spaceID")) AND (? IS NULL OR d.spaceID=?) AND taskID=? ORDER BY completedAt DESC",
                arguments: arguments)
            return try rows.map { row in
                let metadata = try JSONDecoder().decode(DocumentTaskMetadata.self, from: Data((row["metadataJSON"] as String).utf8))
                let id: String = row["id"]
                let occurrence = metadata.history.first { $0.id == id }
                    ?? TaskCompletedOccurrence(id: id, scheduledAt: row["scheduledAt"], completedAt: row["completedAt"])
                return DocumentTaskOccurrence(taskID: row["taskID"], documentID: row["documentID"], blockID: row["blockID"], occurrence: occurrence)
            }
        }
    }

    @discardableResult
    func setCompleted(taskID: String, occurrenceID: String, completed: Bool, skipped: Bool = false) throws -> DocumentRecord {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM documentTasks WHERE id = ?", arguments: [taskID]),
                  var document = try DocumentRecord.fetchOne(db, key: row["documentID"] as String) else { throw DocumentTaskError.missingTask }
            _ = try SpaceOwnership.document(document.id, scope: spaceID, in: db)
            let metadata = try JSONDecoder().decode(DocumentTaskMetadata.self, from: Data((row["metadataJSON"] as String).utf8))
            guard metadata.occurrenceID == occurrenceID || !(row["checked"] as Bool) else { throw DocumentTaskError.staleOccurrence }
            let result = try metadata.completingOccurrence(occurrenceID, completed: completed, skipped: skipped,
                text: DocumentTaskIndex.texts(in: document.tipTapJSON)[row["blockID"] as String])
            document.tipTapJSON = try DocumentTaskIndex.updating(document.tipTapJSON, blockID: row["blockID"], metadata: result.metadata, checked: result.checked)
            document.updatedAt = Date()
            document.revision += 1
            try document.update(db)
            try DocumentRepository.upsertSearchIndex(document, in: db)
            return document
        }
    }
}
