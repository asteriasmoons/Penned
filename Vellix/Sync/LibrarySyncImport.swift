import Foundation
import GRDB

extension LibrarySyncStore {
    // The inbox survives engine token advances. Missing dependencies remain here for the next batch.
    func applyIncoming(protecting editor: LibrarySyncProtection = .init(),
                       validateEvenIfEmpty: Bool = false) throws -> Set<String> {
        try applyIncomingBatch(protecting: editor, validateEvenIfEmpty: validateEvenIfEmpty).changed
    }

    func applyIncomingBatch(protecting editor: LibrarySyncProtection,
                            validateEvenIfEmpty: Bool) throws -> (changed: Set<String>, consumedRows: Bool, drained: Bool) {
        try Task.checkCancellation()
        return try database.write { db in
            try requireBinding(in: db)
            let protection = try expandProtection(editor, in: db)
            var changed = Set<String>()
            var madeProgress = true
            var consumedRows = false
            try db.execute(sql: "PRAGMA defer_foreign_keys=ON; UPDATE librarySyncControl SET remote=1; UPDATE spaceOwnershipOperation SET transferring=1")
            while madeProgress {
                madeProgress = false
                let inbox = try Row.fetchAll(db, sql: "SELECT * FROM librarySyncInbox WHERE libraryID=? ORDER BY recordName", arguments: [libraryID])
                let incoming = try inbox.compactMap { entry -> (Row, SyncRow)? in
                    let row = try JSONDecoder().decode(SyncRow.self, from: entry["payload"])
                    guard try !affectsProtectedEditor(row, protection: protection, in: db) else {
                        PennedSyncTrace.decision("deferForEditor", recordName: entry["recordName"])
                        return nil
                    }
                    return (entry, row)
                }.sorted {
                    (LibrarySyncSchema.tables.firstIndex(of: $0.1.table) ?? 99) <
                    (LibrarySyncSchema.tables.firstIndex(of: $1.1.table) ?? 99)
                }
                var candidates = incoming.filter { !($0.0["deleted"] as Bool) }.map { $0.1 }
                var priorCount = -1
                while candidates.count != priorCount {
                    priorCount = candidates.count
                    candidates = try candidates.filter {
                        try dependenciesAvailable($0, candidates: candidates, in: db) && relationshipsAvailable($0, candidates: candidates, in: db)
                    }
                }
                let ready = Set(candidates.map(\.recordName))
                var completedTemplates: [SyncRow] = []
                for (incomingRow, row) in incoming where ready.contains(row.recordName) {
                    let fields: Data = incomingRow["systemFields"]
                    if !fields.isEmpty, try isOlderServerRecord(Self.restoredRecord(fields), in: db) {
                        PennedSyncTrace.decision("discardOlderServerRecord", recordName: incomingRow["recordName"])
                        try removeIncoming(incomingRow["recordName"], in: db)
                        madeProgress = true; continue
                    }
                    try validate(row, in: db)
                    if try preserveNewerOwnEdit(incomingRow, in: db) { madeProgress = true; continue }
                    if row.table == "documents", let id = row.values["id"]?.text,
                       try reconcileDocument(row, entry: incomingRow, candidates: candidates, in: db) {
                        changed.insert(id)
                        madeProgress = true
                        continue
                    }
                    if try preserveIncomingInsteadOfOverwritingLocal(with: incomingRow, in: db) {
                        madeProgress = true
                        continue
                    }
                    // Templates point back to their root documents. Complete that cycle after documents exist.
                    var initial = row
                    if initial.table == "templates" { initial.values["rootDocumentID"] = .null; completedTemplates.append(row) }
                    try archiveRemovedDocumentBlocks(row, in: db)
                    PennedSyncTrace.decision("applyIncoming", recordName: incomingRow["recordName"])
                    try upsert(initial, in: db)
                    if row.table == "documents", let id = row.values["id"]?.text { changed.insert(id) }
                    try accept(incomingRow, in: db)
                    madeProgress = true
                }
                for row in completedTemplates { try upsert(row, in: db) }
                _ = try DocumentTaskIndex.reconcile(in: db)
                for (incomingRow, row) in incoming.reversed() where incomingRow["deleted"] as Bool {
                    try validate(row, in: db)
                    guard try deletionIsReady(row, in: db) else { continue }
                    if try preserveNewerOwnEdit(incomingRow, in: db) { madeProgress = true; continue }
                    if try preserveIncomingInsteadOfOverwritingLocal(with: incomingRow, in: db) {
                        madeProgress = true
                        continue
                    }
                    try prepareCascadingDeletion(row, in: db)
                    try delete(row, in: db)
                    if row.table == "documents", let id = row.values["id"]?.text { changed.insert(id) }
                    try accept(incomingRow, in: db)
                    madeProgress = true
                }
                consumedRows = consumedRows || madeProgress
            }
            if !validateEvenIfEmpty && !consumedRows {
                try db.execute(sql: "UPDATE spaceOwnershipOperation SET transferring=0; UPDATE librarySyncControl SET remote=0")
                return (changed, false, try inboxIsEmpty(in: db))
            }
            do { try SpaceOwnership.validate(in: db) }
            catch VellixError.impossibleMove(let reason) {
                throw LibrarySyncError.invalidRecord(reason)
            }
            // Validate the complete graph's library as well as its existing Space invariants.
            for table in LibrarySyncSchema.tables {
                let owner = LibraryAccess.owners[table]!.replacingOccurrences(of: "$", with: "t")
                for row in try Row.fetchAll(db, sql: "SELECT t.* FROM \(table) t WHERE \(owner)=?", arguments: [libraryID]) {
                    let record = SyncRow(table: table, row: row)
                    guard try dependenciesAvailable(record, candidates: [], in: db) else { throw LibrarySyncError.invalidRecord("An imported relationship is incomplete.") }
                }
            }
            for id in changed {
                if let page = try DocumentRecord.fetchOne(db, key: id) { try DocumentRepository.upsertSearchIndex(page, in: db) }
                else { try DocumentRepository.deleteSearchIndex(id: id, in: db) }
            }
            _ = try DocumentTagIndex.reconcile(in: db)
            try db.execute(sql: "UPDATE spaceOwnershipOperation SET transferring=0; UPDATE librarySyncControl SET remote=0")
            return (changed, consumedRows, try inboxIsEmpty(in: db))
        }
    }

    private func inboxIsEmpty(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM librarySyncInbox WHERE libraryID=?)",
                          arguments: [libraryID]) == true
    }

    private func expandProtection(_ editor: LibrarySyncProtection, in db: Database) throws -> LibrarySyncProtection {
        var protection = editor
        for id in editor.documentIDs {
            let ancestors = try Row.fetchAll(db, sql: """
                WITH RECURSIVE parents AS (
                    SELECT id,parentDocumentID,folderID,templateID,templateOriginID,spaceID FROM documents WHERE id=?
                    UNION
                    SELECT d.id,d.parentDocumentID,d.folderID,d.templateID,d.templateOriginID,d.spaceID
                    FROM documents d JOIN parents p ON p.parentDocumentID=d.id
                ) SELECT * FROM parents
                """, arguments: [id])
            for row in ancestors {
                protection.documentIDs.insert(row["id"])
                if let space: String = row["spaceID"] { protection.spaceIDs.insert(space) }
                if let template: String = row["templateID"] { protection.templateIDs.insert(template) }
                if let template: String = row["templateOriginID"] { protection.templateIDs.insert(template) }
                if let folder: String = row["folderID"] {
                    protection.folderIDs.formUnion(try String.fetchAll(db, sql: """
                        WITH RECURSIVE parents AS (
                            SELECT id,parentFolderID FROM folders WHERE id=?
                            UNION
                            SELECT f.id,f.parentFolderID FROM folders f JOIN parents p ON p.parentFolderID=f.id
                        ) SELECT id FROM parents
                        """, arguments: [folder]))
                }
            }
            protection.collectionIDs.formUnion(try String.fetchAll(db, sql: """
                SELECT id FROM collections WHERE documentID=?
                UNION SELECT collectionID FROM collectionEntries WHERE documentID=?
                """, arguments: [id, id]))
            protection.taskIDs.formUnion(try String.fetchAll(db, sql: "SELECT id FROM documentTasks WHERE documentID=?", arguments: [id]))
        }
        return protection
    }

    private func affectsProtectedEditor(_ row: SyncRow, protection: LibrarySyncProtection, in db: Database) throws -> Bool {
        guard !protection.isEmpty else { return false }
        let documents = protection.documentIDs
        func matches(_ key: String, in values: [String: SyncValue] = [:]) -> Bool {
            (values.isEmpty ? row.values : values)[key]?.text.map { documents.contains($0) } == true
        }
        if row.table == "spaces" { return row.values["id"]?.text.map { protection.spaceIDs.contains($0) } == true }
        if row.table == "dailyNoteSettings" { return row.values["spaceID"]?.text.map { protection.spaceIDs.contains($0) } == true }
        if row.table == "folders" { return row.values["id"]?.text.map { protection.folderIDs.contains($0) } == true }
        if row.table == "documents", matches("id") || matches("parentDocumentID") { return true }
        if row.table == "templates", matches("rootDocumentID") || row.values["id"]?.text.map({ protection.templateIDs.contains($0) }) == true { return true }
        if row.table == "documents", let id = row.values["id"]?.text,
           let collection = try String.fetchOne(db, sql: "SELECT collectionID FROM collectionEntries WHERE documentID=?", arguments: [id]),
           protection.collectionIDs.contains(collection) { return true }
        if matches("documentID") { return true }
        if row.table == "attachments", let path = row.values["relativePath"]?.text,
           protection.attachmentPaths.contains(path) { return true }
        if let collection = row.values["collectionID"]?.text, protection.collectionIDs.contains(collection) { return true }
        if row.table == "collections", let id = row.values["id"]?.text, protection.collectionIDs.contains(id) { return true }
        if row.table == "collectionValues", let field = row.values["fieldID"]?.text,
           let collection = try String.fetchOne(db, sql: "SELECT collectionID FROM collectionFields WHERE id=?", arguments: [field]),
           protection.collectionIDs.contains(collection) { return true }
        if row.table == "taskCompletions", let task = row.values["taskID"]?.text, protection.taskIDs.contains(task) { return true }

        // Incoming moves and tombstones can omit the current relationship.
        let keys = LibrarySyncSchema.keys(for: row.table)
        let predicate = keys.map { "\"\($0)\"=?" }.joined(separator: " AND ")
        guard let current = try Row.fetchOne(db, sql: "SELECT * FROM \(row.table) WHERE \(predicate)",
                                            arguments: StatementArguments(keys.map { (row.values[$0] ?? .null).databaseValue })) else { return false }
        let values = SyncRow(table: row.table, row: current).values
        if row.table == "documents" { return matches("parentDocumentID", in: values) }
        if row.table == "templates" { return matches("rootDocumentID", in: values) }
        return matches("documentID", in: values)
            || values["taskID"]?.text.map { protection.taskIDs.contains($0) } == true
            || values["collectionID"]?.text.map { protection.collectionIDs.contains($0) } == true
            || (row.table == "attachments" && values["relativePath"]?.text.map { protection.attachmentPaths.contains($0) } == true)
    }

    private func dependenciesAvailable(_ row: SyncRow, candidates: [SyncRow], in db: Database) throws -> Bool {
        for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(row.table))") {
            let column: String = key["from"], table: String = key["table"], target: String = key["to"]
            guard let value = row.values[column], value != .null else { continue }
            if table == "libraries" {
                guard value.text == libraryID else { throw LibraryError.wrongOwner }
                continue
            }
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \"\(target)\"=?", arguments: [value.databaseValue]) {
                if let expression = LibraryAccess.owners[table] {
                    let owner = expression.replacingOccurrences(of: "$", with: "t")
                    let library = try String.fetchOne(db, sql: "SELECT \(owner) FROM \(table) t WHERE \"\(target)\"=?", arguments: [value.databaseValue])
                    guard library == libraryID else { throw LibraryError.wrongOwner }
                } else if table == "documentTasks" {
                    let documentID: String = existing["documentID"]
                    let document = try SpaceOwnership.document(documentID, scope: nil, in: db)
                    guard try String.fetchOne(db, sql: "SELECT libraryID FROM spaces WHERE id=?", arguments: [document.spaceID]) == libraryID else { throw LibraryError.wrongOwner }
                }
                continue
            }
            guard candidates.contains(where: { $0.table == table && $0.values[target] == value }) else { return false }
        }
        return true
    }

    private func relationshipsAvailable(_ row: SyncRow, candidates: [SyncRow], in db: Database) throws -> Bool {
        func projected(_ table: String, id: String?) throws -> SyncRow? {
            guard let id else { return nil }
            if let candidate = candidates.first(where: { $0.table == table && $0.values["id"]?.text == id }) { return candidate }
            return try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id=?", arguments: [id]).map { SyncRow(table: table, row: $0) }
        }
        guard let space = row.values["spaceID"]?.text else { return true }
        let forward: [(String, String)]
        let reverse: [(String, String)]
        switch row.table {
        case "documents":
            forward = [("documents", "parentDocumentID"), ("folders", "folderID"), ("templates", "templateID")]
            reverse = [("documents", "parentDocumentID"), ("calendarEventNotes", "documentID")]
        case "folders":
            forward = [("folders", "parentFolderID")]
            reverse = [("folders", "parentFolderID"), ("documents", "folderID")]
        case "templates":
            forward = [("documents", "rootDocumentID")]
            reverse = [("documents", "templateID")]
        case "calendarEventNotes":
            forward = [("documents", "documentID")]; reverse = []
        case "dailyNoteSettings":
            forward = [("templates", "templateID")]; reverse = []
        default: return true
        }
        for (table, column) in forward {
            if let related = try projected(table, id: row.values[column]?.text), related.values["spaceID"]?.text != space { return false }
        }
        if let id = row.values["id"]?.text {
            for (table, column) in reverse {
                for current in try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(column)=?", arguments: [id]) {
                    guard let related = try projected(table, id: current["id"]), related.values[column]?.text == id else { continue }
                    if related.values["spaceID"]?.text != space { return false }
                }
            }
        }
        return true
    }

    private func preserveNewerOwnEdit(_ incoming: Row, in db: Database) throws -> Bool {
        guard let current = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, incoming["recordName"] as String]),
              current["dirty"] as Bool, current["ackMutation"] as String == incoming["mutationID"] as String,
              current["mutationID"] as String != incoming["mutationID"] as String else { return false }
        PennedSyncTrace.decision("preserveOwnEditAgainstEcho", recordName: incoming["recordName"])
        try db.execute(sql: "UPDATE librarySyncItems SET systemFields=? WHERE libraryID=? AND recordName=?", arguments: [incoming["systemFields"] as Data, libraryID, incoming["recordName"] as String])
        let name: String = incoming["recordName"]
        if name.hasPrefix("documents-"), !(incoming["deleted"] as Bool) {
            let echoed = try JSONDecoder().decode(SyncRow.self, from: incoming["payload"])
            let baseline = try documentBaseline(for: name, in: db)
            // A server echo may be the first delivery of the acknowledged asset.
            // Do not replace a newer baseline while its repair is still queued.
            if (echoed.values["revision"]?.integer ?? 0) >= (baseline?.values["revision"]?.integer ?? 0) {
                try saveDocumentBaseline(echoed, in: db)
            }
        }
        try removeIncoming(incoming["recordName"], in: db)
        return true
    }

    private func reconcileDocument(_ incoming: SyncRow, entry: Row, candidates: [SyncRow], in db: Database) throws -> Bool {
        let current = try Row.fetchOne(db, sql: "SELECT payload,dirty,deleted FROM librarySyncItems WHERE libraryID=? AND recordName=?",
                                      arguments: [libraryID, incoming.recordName])
        // Do not turn a pending deletion into a live record.
        if let current, current["dirty"] as Bool, current["deleted"] as Bool { return false }

        let baseline = try documentBaseline(for: incoming.recordName, in: db)
        let queued: SyncRow?
        if let current, current["dirty"] as Bool {
            queued = try JSONDecoder().decode(SyncRow.self, from: current["payload"])
        } else {
            queued = nil
        }
        if let baseline, let acknowledgedRevision = baseline.values["revision"]?.integer,
           let incomingRevision = incoming.values["revision"]?.integer, acknowledgedRevision > incomingRevision,
           baseline.values["tipTapJSON"]?.text != nil,
           try dependenciesAvailable(baseline, candidates: candidates, in: db),
           try relationshipsAvailable(baseline, candidates: candidates, in: db) {
            // Only a confirmed cloud copy can repair a server regression. Never
            // put a new tag on the unmerged local draft, regardless of its counter.
            PennedSyncTrace.decision("restoreAcknowledgedDocument", recordName: incoming.recordName)
            try archiveDocumentOnce(incoming, reason: "Older iCloud revision retained; acknowledged document protected", in: db)
            var repair = baseline
            if let queued, queued != baseline {
                try archiveDocumentOnce(queued, reason: "Queued draft retained before repairing a cloud regression", in: db)
                if queued.values["tipTapJSON"] == baseline.values["tipTapJSON"],
                   let merged = try mergeConcurrentDocument(local: queued, remote: baseline, baseline: baseline),
                   try dependenciesAvailable(merged, candidates: candidates, in: db),
                   try relationshipsAvailable(merged, candidates: candidates, in: db) {
                    repair = merged
                }
            }
            try queueReconciledDocument(repair, against: entry, in: db)
            return true
        }
        guard let queued, queued != incoming else { return false }
        if let baseline,
           (queued.values["revision"]?.integer ?? 0) >= (baseline.values["revision"]?.integer ?? 0),
           let merged = try mergeConcurrentDocument(local: queued, remote: incoming, baseline: baseline),
           try dependenciesAvailable(merged, candidates: candidates, in: db),
           try relationshipsAvailable(merged, candidates: candidates, in: db) {
            if merged == incoming { return false }
            PennedSyncTrace.decision("mergeConcurrentDocument", recordName: incoming.recordName)
            try archiveDocumentOnce(queued, reason: "Local revision retained before automatic merge", in: db)
            try archiveDocumentOnce(incoming, reason: "Remote revision retained before automatic merge", in: db)
            try saveDocumentBaseline(incoming, in: db)
            try queueReconciledDocument(merged, against: entry, in: db)
            return true
        }
        PennedSyncTrace.decision("acceptCloudWithoutUnmergedRetry", recordName: incoming.recordName)
        try archiveDocumentOnce(queued, reason: "Unmerged draft retained; current iCloud document accepted", in: db)
        try archiveRemovedDocumentBlocks(incoming, in: db)
        try upsert(incoming, in: db)
        try accept(entry, in: db)
        return true
    }

    private func queueReconciledDocument(_ resolved: SyncRow, against incoming: Row, in db: Database) throws {
        var row = resolved
        let id = row.values["id"]?.text
        let currentRevision = try Int64.fetchOne(db, sql: "SELECT revision FROM documents WHERE id=?", arguments: [id]) ?? 0
        row.values["revision"] = .integer(max(row.values["revision"]?.integer ?? 0, currentRevision + 1))
        try upsert(row, in: db)
        try db.execute(sql: """
            INSERT INTO librarySyncItems(libraryID,recordName,payload,deleted,dirty,systemFields,mutationID,ackMutation)
            VALUES (?,?,?,0,1,?,?,?)
            ON CONFLICT(libraryID,recordName) DO UPDATE SET
              payload=excluded.payload,deleted=0,dirty=1,systemFields=excluded.systemFields,
              version=version+1,mutationID=excluded.mutationID,ackMutation=excluded.ackMutation
            """, arguments: [libraryID, row.recordName, try row.encoded, incoming["systemFields"] as Data,
                              UUID().uuidString, incoming["mutationID"] as String])
        try removeIncoming(row.recordName, in: db)
    }

    private func archiveRemovedDocumentBlocks(_ incoming: SyncRow, in db: Database) throws {
        guard incoming.table == "documents", let id = incoming.values["id"]?.text,
              let remoteJSON = incoming.values["tipTapJSON"]?.text,
              let current = try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE id=?", arguments: [id]) else { return }
        let local = SyncRow(table: "documents", row: current)
        if let localJSON = local.values["tipTapJSON"]?.text, localJSON != remoteJSON,
           Self.removesDocumentBlocks(from: localJSON, to: remoteJSON) {
            try archiveDocumentOnce(local, reason: "Document retained before an incoming revision removed blocks", in: db)
        }
    }

    private static func removesDocumentBlocks(from previous: String, to incoming: String) -> Bool {
        func inventory(_ json: String) -> (ids: Set<String>, count: Int) {
            var ids = Set<String>()
            var count = 0
            func visit(_ node: [String: Any]) {
                if let id = (node["attrs"] as? [String: Any])?["id"] as? String, !id.isEmpty { ids.insert(id) }
                if let type = node["type"] as? String, type != "doc", type != "text", type != "hardBreak" { count += 1 }
                for child in node["content"] as? [[String: Any]] ?? [] { visit(child) }
            }
            visit(TipTapContentAnalyzer.documentObject(from: json))
            return (ids, count)
        }
        let old = inventory(previous), new = inventory(incoming)
        return new.count < old.count || !old.ids.isSubset(of: new.ids)
    }

    // Non-document records and deletions retain their existing conflict policy.
    private func preserveIncomingInsteadOfOverwritingLocal(with incoming: Row, in db: Database) throws -> Bool {
        guard let current = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND recordName=?",
                                             arguments: [libraryID, incoming["recordName"] as String]),
              current["dirty"] as Bool,
              (current["payload"] as Data != incoming["payload"] as Data ||
               current["deleted"] as Bool != incoming["deleted"] as Bool) else { return false }
        let incomingRow = try JSONDecoder().decode(SyncRow.self, from: incoming["payload"] as Data)
        if incomingRow.table == "documents", !(incoming["deleted"] as Bool), !(current["deleted"] as Bool) {
            return false // Live document conflicts are resolved by reconcileDocument.
        }
        PennedSyncTrace.decision("retainUnsyncedLocal", recordName: incoming["recordName"])
        try archive(incomingRow, deleted: incoming["deleted"], reason: "Incoming remote revision retained; unsynced local changes protected", in: db)
        try db.execute(sql: "UPDATE librarySyncItems SET systemFields=? WHERE libraryID=? AND recordName=?",
                       arguments: [incoming["systemFields"] as Data, libraryID, incoming["recordName"] as String])
        try removeIncoming(incoming["recordName"], in: db)
        return true
    }

    private func mergeConcurrentDocument(local: SyncRow, remote: SyncRow, baseline: SyncRow) throws -> SyncRow? {
        guard let baseJSON = baseline.values["tipTapJSON"]?.text,
              let localJSON = local.values["tipTapJSON"]?.text,
              let remoteJSON = remote.values["tipTapJSON"]?.text else { return nil }

        // Non-content document fields are independently merged; conflicting
        // changes to the same field cannot be guessed.
        var values = remote.values
        let computedFields: Set<String> = [
            "tipTapJSON", "plainText", "previewText", "wordCount",
            "characterCount", "estimatedReadingMinutes", "revision",
            "updatedAt", "lastOpenedAt"
        ]
        for (key, localValue) in local.values where !computedFields.contains(key) {
            let baseValue = baseline.values[key] ?? .null
            let remoteValue = remote.values[key] ?? .null
            if localValue == remoteValue || localValue == baseValue { continue }
            guard remoteValue == baseValue else { return nil }
            values[key] = localValue
        }

        guard let mergedJSON = try mergeDocumentBodies(base: baseJSON, local: localJSON, remote: remoteJSON) else { return nil }
        if values == remote.values, mergedJSON == remoteJSON { return remote }
        let mergedAnalysis = try TipTapContentAnalyzer.analyze(mergedJSON)
        values["tipTapJSON"] = .text(mergedAnalysis.canonicalJSON)
        values["plainText"] = .text(mergedAnalysis.plainText)
        values["previewText"] = .text(mergedAnalysis.previewText)
        values["wordCount"] = .integer(Int64(mergedAnalysis.wordCount))
        values["characterCount"] = .integer(Int64(mergedAnalysis.characterCount))
        values["estimatedReadingMinutes"] = .integer(Int64(mergedAnalysis.estimatedReadingMinutes))
        values["revision"] = .integer(max(local.values["revision"]?.integer ?? 0, remote.values["revision"]?.integer ?? 0) + 1)
        return SyncRow(table: "documents", values: values)
    }

    private func mergeDocumentBodies(base: String, local: String, remote: String) throws -> String? {
        func document(_ json: String) throws -> [String: Any]? {
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        }
        func identifier(_ node: [String: Any]) -> String? {
            guard let id = (node["attrs"] as? [String: Any])?["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
        func equal(_ left: Any?, _ right: Any?) -> Bool {
            switch (left, right) {
            case (nil, nil): return true
            case (nil, _), (_, nil): return false
            default:
                guard let a = left, let b = right,
                      let da = try? JSONSerialization.data(withJSONObject: a, options: [.fragmentsAllowed, .sortedKeys]),
                      let db = try? JSONSerialization.data(withJSONObject: b, options: [.fragmentsAllowed, .sortedKeys])
                else { return false }
                return da == db
            }
        }
        func mergeDictionary(base: [String: Any], local: [String: Any],
                             remote: [String: Any]) -> [String: Any]? {
            var result: [String: Any] = [:]
            for key in Set(base.keys).union(local.keys).union(remote.keys) {
                let old = base[key], left = local[key], right = remote[key]
                if equal(left, right) { result[key] = left }
                else if equal(left, old) { result[key] = right }
                else if equal(right, old) { result[key] = left }
                else if let b = old as? [String: Any],
                        let l = left as? [String: Any],
                        let r = right as? [String: Any] {
                    guard let nested = mergeDictionary(base: b, local: l, remote: r) else { return nil }
                    result[key] = nested
                } else { return nil }
            }
            return result
        }
        if local == base || local == remote { return remote }
        if remote == base { return local }
        guard var baseDocument = try document(base), var localDocument = try document(local),
              var remoteDocument = try document(remote) else { return nil }
        if equal(localDocument, baseDocument) || equal(localDocument, remoteDocument) { return remote }
        if equal(remoteDocument, baseDocument) { return local }
        let original = baseDocument.removeValue(forKey: "content") as? [[String: Any]] ?? []
        let ours = localDocument.removeValue(forKey: "content") as? [[String: Any]] ?? []
        let theirs = remoteDocument.removeValue(forKey: "content") as? [[String: Any]] ?? []
        // Stable block IDs are mandatory. Without them a safe alignment is impossible.
        guard original.allSatisfy({ identifier($0) != nil }),
              ours.allSatisfy({ identifier($0) != nil }),
              theirs.allSatisfy({ identifier($0) != nil }) else {
            // No stable block identity: do not attempt a positional merge.
            // It could silently attach task metadata to the wrong block.
            return nil
        }
        let baseIDs = original.compactMap(identifier)
        let ourIDs = ours.compactMap(identifier)
        let theirIDs = theirs.compactMap(identifier)
        guard Set(baseIDs).count == baseIDs.count,
              Set(ourIDs).count == ourIDs.count,
              Set(theirIDs).count == theirIDs.count else { return nil }
        let baseMap = Dictionary(uniqueKeysWithValues: zip(baseIDs, original))
        let ourMap = Dictionary(uniqueKeysWithValues: zip(ourIDs, ours))
        let theirMap = Dictionary(uniqueKeysWithValues: zip(theirIDs, theirs))

        // Reordering existing blocks on both devices needs a dedicated ordering
        // strategy; do not silently choose one device's ordering.
        let retained = Set(baseIDs).intersection(ourIDs).intersection(theirIDs)
        let baseOrder = baseIDs.filter { retained.contains($0) }
        let ourOrder = ourIDs.filter { retained.contains($0) }
        let theirOrder = theirIDs.filter { retained.contains($0) }
        if ourOrder != baseOrder && theirOrder != baseOrder && ourOrder != theirOrder { return nil }

        // A block present in the shared ancestor but missing from exactly one
        // side is ambiguous: it may be an intentional deletion, or the incoming
        // side may be stale/partial and simply never received it. We refuse to
        // guess. Only a block BOTH sides dropped (a mutual, agreed deletion) may
        // be removed; any one-sided disappearance aborts the automatic merge so
        // the cloud body remains live and the unmerged local draft is retained.
        let ourSet = Set(ourIDs), theirSet = Set(theirIDs)
        for id in baseIDs where ourSet.contains(id) != theirSet.contains(id) { return nil }

        // Every block that exists on either side is preserved. A block is dropped
        // only when it is absent from both sides (so it is absent from the union
        // below). Nested structures are merged whole — never flattened.
        var merged: [String: [String: Any]] = [:]
        for id in ourSet.union(theirSet) {
            let base = baseMap[id], ours = ourMap[id], theirs = theirMap[id]
            if let ours, let theirs {
                if equal(ours, theirs) { merged[id] = ours }
                else if equal(ours, base) { merged[id] = theirs }
                else if equal(theirs, base) { merged[id] = ours }
                else if let base, let combined = mergeDictionary(base: base, local: ours, remote: theirs) {
                    merged[id] = combined
                } else { return nil }   // genuine conflict on the same block: preserve both
            } else if let ours {
                merged[id] = ours          // retained or added locally
            } else if let theirs {
                merged[id] = theirs        // retained or added remotely
            }
        }
        // Keep the reordering device's sequence as the spine, then fold in the
        // other device's blocks. Every retained id is placed exactly once.
        var order = ourOrder != baseOrder ? ourIDs : theirIDs
        for id in theirIDs where !order.contains(id) { order.append(id) }
        for id in ourIDs where !order.contains(id) { order.append(id) }
        let mergedContent = order.compactMap { merged[$0] }

        // Defense in depth: the merged document must contain every block present
        // on either device. If ordering or merging would drop anything, refuse
        // the merge and preserve both versions rather than risk silent loss.
        guard Set(mergedContent.compactMap(identifier)) == ourSet.union(theirSet),
              var mergedDocument = mergeDictionary(base: baseDocument, local: localDocument, remote: remoteDocument) else { return nil }
        mergedDocument["content"] = mergedContent
        remoteDocument["content"] = theirs
        if equal(mergedDocument, remoteDocument) { return remote }
        let encoded = try JSONSerialization.data(withJSONObject: mergedDocument, options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self)
    }

    private func documentBaseline(for name: String, in db: Database) throws -> SyncRow? {
        let payload = try Data.fetchOne(db, sql: "SELECT payload FROM librarySyncBaselines WHERE libraryID=? AND recordName=?",
                                        arguments: [libraryID, name])
        return payload.flatMap { try? JSONDecoder().decode(SyncRow.self, from: $0) }
    }

    func saveDocumentBaseline(_ row: SyncRow, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO librarySyncBaselines(libraryID,recordName,payload) VALUES (?,?,?)
            ON CONFLICT(libraryID,recordName) DO UPDATE SET payload=excluded.payload
            """, arguments: [libraryID, row.recordName, try row.encoded])
    }

    func removeDocumentBaseline(_ recordName: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM librarySyncBaselines WHERE libraryID=? AND recordName=?", arguments: [libraryID, recordName])
    }

    private func accept(_ incoming: Row, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO librarySyncItems(libraryID,recordName,payload,deleted,dirty,systemFields,mutationID,ackMutation)
            VALUES (?,?,?,?,0,?,?,?) ON CONFLICT(libraryID,recordName) DO UPDATE SET
              payload=excluded.payload,deleted=excluded.deleted,dirty=0,systemFields=excluded.systemFields,
              mutationID=excluded.mutationID,ackMutation=excluded.ackMutation
            """, arguments: [libraryID, incoming["recordName"] as String, incoming["payload"] as Data,
                              incoming["deleted"] as Bool, incoming["systemFields"] as Data,
                              incoming["mutationID"] as String, incoming["mutationID"] as String])
        try removeIncoming(incoming["recordName"], in: db)
        let name: String = incoming["recordName"]
        if name.hasPrefix("documents-") {
            if incoming["deleted"] as Bool { try removeDocumentBaseline(name, in: db) }
            else { try saveDocumentBaseline(JSONDecoder().decode(SyncRow.self, from: incoming["payload"]), in: db) }
        }
    }
    private func removeIncoming(_ name: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM librarySyncInbox WHERE libraryID=? AND recordName=?", arguments: [libraryID, name])
    }

    private func upsert(_ row: SyncRow, in db: Database) throws {
        let keys = LibrarySyncSchema.keys(for: row.table)
        var values = row.values
        if row.table == "documents" {
            if let day = values["dailyNoteDate"]?.text, values["isTrashed"] != .integer(1),
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM documents WHERE spaceID=? AND dailyNoteDate=? AND isTrashed=0 AND id<>?)", arguments: [values["spaceID"]!.databaseValue, day, values["id"]!.databaseValue]) == true {
                throw LibrarySyncError.requiresResolution(recordName: row.recordName, message: "Two devices created different Daily Notes for the same date. Both copies are retained. Move the existing note to another Space or trash it, then retry sync. The incoming version is in Recovery Revisions.")
            }
            if let json = values["tipTapJSON"]?.text {
                let analysis = try TipTapContentAnalyzer.analyze(json)
                values["plainText"] = .text(analysis.plainText)
                values["previewText"] = .text(analysis.previewText)
                values["wordCount"] = .integer(Int64(analysis.wordCount))
                values["characterCount"] = .integer(Int64(analysis.characterCount))
                values["estimatedReadingMinutes"] = .integer(Int64(analysis.estimatedReadingMinutes))
            }
            let current = try Row.fetchOne(db, sql: "SELECT lastOpenedAt FROM documents WHERE id=?", arguments: [row.values["id"]!.databaseValue])
            values["lastOpenedAt"] = current.map { SyncValue($0["lastOpenedAt"] as DatabaseValue) } ?? .null
        } else if row.table == "calendarEventNotes",
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM calendarEventNotes WHERE spaceID=? AND eventKey=? AND id<>?)", arguments: [values["spaceID"]!.databaseValue, values["eventKey"]!.databaseValue, values["id"]!.databaseValue]) == true {
            throw LibrarySyncError.requiresResolution(recordName: row.recordName, message: "Two devices created notes for the same calendar event. Both documents are retained. Move one note to another Space, then retry sync. The incoming association is in Recovery Revisions.")
        }
        let columns = values.keys.sorted()
        let updates = columns.filter { !keys.contains($0) }.map { "\"\($0)\"=excluded.\"\($0)\"" }.joined(separator: ",")
        try db.execute(sql: "INSERT INTO \(row.table)(\(columns.map { "\"\($0)\"" }.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(keys.joined(separator: ","))) DO UPDATE SET \(updates)", arguments: StatementArguments(columns.map { values[$0]!.databaseValue }))
    }
    private func delete(_ row: SyncRow, in db: Database) throws {
        let keys = LibrarySyncSchema.keys(for: row.table)
        let predicate = keys.map { "\"\($0)\"=?" }.joined(separator: " AND ")
        try db.execute(sql: "DELETE FROM \(row.table) WHERE \(predicate)", arguments: StatementArguments(keys.map { row.values[$0]!.databaseValue }))
    }
    private func deletionIsReady(_ row: SyncRow, in db: Database) throws -> Bool {
        guard let id = row.values["id"]?.text else { return true }
        let checks: [(String, String)]
        switch row.table {
        case "spaces": checks = [("documents", "spaceID"), ("folders", "spaceID"), ("templates", "spaceID")]
        case "documents": checks = [("documents", "parentDocumentID")]
        case "folders": checks = [("folders", "parentFolderID"), ("documents", "folderID")]
        case "templates": checks = [("documents", "templateID")]
        default: checks = []
        }
        for (table, column) in checks {
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(column)=?)", arguments: [id]) == true { return false }
        }
        return true
    }

    private func prepareCascadingDeletion(_ root: SyncRow, in db: Database) throws {
        let keys = LibrarySyncSchema.keys(for: root.table)
        guard let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(root.table) WHERE \(keys.map { "\($0)=?" }.joined(separator: " AND "))", arguments: StatementArguments(keys.map { root.values[$0]!.databaseValue })) else { return }
        var pending = [SyncRow(table: root.table, row: existing)], affected: [String: SyncRow] = [:]
        let tables = LibrarySyncSchema.tables + ["documentTasks"]
        while let parent = pending.popLast() {
            guard affected[parent.recordName] == nil else { continue }
            affected[parent.recordName] = parent
            for table in tables {
                for fk in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") where fk["table"] as String == parent.table && fk["on_delete"] as String == "CASCADE" {
                    let source: String = fk["from"], destination: String = fk["to"]
                    guard let value = parent.values[destination], value != .null else { continue }
                    pending += try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(source)=?", arguments: [value.databaseValue]).map { SyncRow(table: table, row: $0) }
                }
            }
        }
        let authored = affected.values.filter { LibrarySyncSchema.tables.contains($0.table) }
        var hasUnsyncedContent = false
        for row in authored {
            if try Bool.fetchOne(db, sql: "SELECT dirty FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, row.recordName]) == true { hasUnsyncedContent = true }
        }
        for row in authored {
            if hasUnsyncedContent {
                try archive(row, deleted: false, reason: "Content retained before remote deletion of its owning record; restore parents first", in: db)
            }
            try db.execute(sql: "UPDATE librarySyncItems SET payload=?,deleted=1,dirty=0 WHERE libraryID=? AND recordName=?", arguments: [try row.tombstone.encoded, libraryID, row.recordName])
        }
    }

    func recover(conflictID: String) throws {
        try database.write { db in
            guard let conflict = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncConflicts WHERE id=? AND libraryID=?", arguments: [conflictID, libraryID]) else { throw LibraryError.unavailable }
            var row = try JSONDecoder().decode(SyncRow.self, from: conflict["payload"])
            guard !(conflict["deleted"] as Bool) else { throw LibrarySyncError.invalidRecord("Deletion revisions are retained for inspection, not replayed automatically.") }
            try validate(row, in: db)
            guard try dependenciesAvailable(row, candidates: [], in: db) else { throw LibrarySyncError.invalidRecord("Restore this revision's parent Space or document first.") }
            var previousRevision: Int64 = 0
            let keys = LibrarySyncSchema.keys(for: row.table)
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(row.table) WHERE \(keys.map { "\($0)=?" }.joined(separator: " AND "))", arguments: StatementArguments(keys.map { row.values[$0]!.databaseValue })) {
                try archive(SyncRow(table: row.table, row: current), deleted: false, reason: "Version before manual recovery", in: db)
                if row.table == "documents" { previousRevision = current["revision"] }
            }
            if row.table == "documents", let id = row.values["id"]?.text {
                let snapshotRevision = try Int64.fetchOne(db, sql: "SELECT MAX(revision) FROM documentSnapshots WHERE documentID=?", arguments: [id]) ?? 0
                row.values["revision"] = .integer(max(snapshotRevision, previousRevision, row.values["revision"]?.integer ?? 0) + 1)
                row.values["updatedAt"] = SyncValue(Date().databaseValue)
            }
            try upsert(row, in: db)
            try SpaceOwnership.validate(in: db)
            if row.table == "documents", let id = row.values["id"]?.text, let page = try DocumentRecord.fetchOne(db, key: id) { try DocumentRepository.upsertSearchIndex(page, in: db) }
        }
    }
}
