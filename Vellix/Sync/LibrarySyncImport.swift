import Foundation
import GRDB

extension LibrarySyncStore {
    // The inbox survives engine token advances. Missing dependencies remain here for the next batch.
    func applyIncoming() throws -> Set<String> {
        try database.write { db in
            try requireBinding(in: db)
            var changed = Set<String>()
            var madeProgress = true
            try db.execute(sql: "PRAGMA defer_foreign_keys=ON; UPDATE librarySyncControl SET remote=1; UPDATE spaceOwnershipOperation SET transferring=1")
            while madeProgress {
                madeProgress = false
                let incoming = try Row.fetchAll(db, sql: "SELECT * FROM librarySyncInbox WHERE libraryID=? ORDER BY recordName", arguments: [libraryID])
                var candidates = try incoming.filter { !($0["deleted"] as Bool) }.map { try JSONDecoder().decode(SyncRow.self, from: $0["payload"]) }
                var priorCount = -1
                while candidates.count != priorCount {
                    priorCount = candidates.count
                    candidates = try candidates.filter {
                        try dependenciesAvailable($0, candidates: candidates, in: db) && relationshipsAvailable($0, candidates: candidates, in: db)
                    }
                }
                let ready = Set(candidates.map(\.recordName))
                let sorted = incoming.sorted { left, right in
                    let lhs = try? JSONDecoder().decode(SyncRow.self, from: left["payload"])
                    let rhs = try? JSONDecoder().decode(SyncRow.self, from: right["payload"])
                    return (LibrarySyncSchema.tables.firstIndex(of: lhs?.table ?? "") ?? 99) < (LibrarySyncSchema.tables.firstIndex(of: rhs?.table ?? "") ?? 99)
                }
                var completedTemplates: [SyncRow] = []
                for incomingRow in sorted where ready.contains(incomingRow["recordName"]) {
                    let fields: Data = incomingRow["systemFields"]
                    if !fields.isEmpty, try isOlderServerRecord(Self.restoredRecord(fields), in: db) {
                        try removeIncoming(incomingRow["recordName"], in: db)
                        madeProgress = true; continue
                    }
                    let row = try JSONDecoder().decode(SyncRow.self, from: incomingRow["payload"])
                    try validate(row, in: db)
                    if try preserveNewerOwnEdit(incomingRow, in: db) { madeProgress = true; continue }
                    try preserveConflict(with: incomingRow, in: db)
                    // Templates point back to their root documents. Complete that cycle after documents exist.
                    var initial = row
                    if initial.table == "templates" { initial.values["rootDocumentID"] = .null; completedTemplates.append(row) }
                    try upsert(initial, in: db)
                    if row.table == "documents", let id = row.values["id"]?.text { changed.insert(id) }
                    try accept(incomingRow, in: db)
                    madeProgress = true
                }
                for row in completedTemplates { try upsert(row, in: db) }
                _ = try DocumentTaskIndex.reconcile(in: db)
                for incomingRow in sorted.reversed() where incomingRow["deleted"] as Bool {
                    let row = try JSONDecoder().decode(SyncRow.self, from: incomingRow["payload"])
                    try validate(row, in: db)
                    guard try deletionIsReady(row, in: db) else { continue }
                    if try preserveNewerOwnEdit(incomingRow, in: db) { madeProgress = true; continue }
                    try preserveConflict(with: incomingRow, in: db)
                    try prepareCascadingDeletion(row, in: db)
                    try delete(row, in: db)
                    if row.table == "documents", let id = row.values["id"]?.text { changed.insert(id) }
                    try accept(incomingRow, in: db)
                    madeProgress = true
                }
            }
            try SpaceOwnership.validate(in: db)
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
            return changed
        }
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
        try db.execute(sql: "UPDATE librarySyncItems SET systemFields=? WHERE libraryID=? AND recordName=?", arguments: [incoming["systemFields"] as Data, libraryID, incoming["recordName"] as String])
        try removeIncoming(incoming["recordName"], in: db)
        return true
    }

    private func preserveConflict(with incoming: Row, in db: Database) throws {
        guard let current = try Row.fetchOne(db, sql: "SELECT * FROM librarySyncItems WHERE libraryID=? AND recordName=?", arguments: [libraryID, incoming["recordName"] as String]),
              current["dirty"] as Bool,
              current["payload"] as Data != incoming["payload"] as Data || current["deleted"] as Bool != incoming["deleted"] as Bool else { return }
        let row = try JSONDecoder().decode(SyncRow.self, from: current["payload"])
        try archive(row, deleted: current["deleted"], reason: "Concurrent remote revision; local version retained", in: db)
        if row.table == "documents", let id = row.values["id"]?.text,
           let page = try DocumentRecord.fetchOne(db, key: id) {
            try DocumentSnapshotRecord(documentID: id, tipTapJSON: page.tipTapJSON, revision: page.revision,
                                       reason: .recovery, isAutomatic: false).insert(db)
        }
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
            let row = try JSONDecoder().decode(SyncRow.self, from: conflict["payload"])
            guard !(conflict["deleted"] as Bool) else { throw LibrarySyncError.invalidRecord("Deletion revisions are retained for inspection, not replayed automatically.") }
            try validate(row, in: db)
            guard try dependenciesAvailable(row, candidates: [], in: db) else { throw LibrarySyncError.invalidRecord("Restore this revision's parent Space or document first.") }
            let keys = LibrarySyncSchema.keys(for: row.table)
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(row.table) WHERE \(keys.map { "\($0)=?" }.joined(separator: " AND "))", arguments: StatementArguments(keys.map { row.values[$0]!.databaseValue })) {
                try archive(SyncRow(table: row.table, row: current), deleted: false, reason: "Version before manual recovery", in: db)
            }
            try upsert(row, in: db)
            try SpaceOwnership.validate(in: db)
            if row.table == "documents", let id = row.values["id"]?.text, let page = try DocumentRecord.fetchOne(db, key: id) { try DocumentRepository.upsertSearchIndex(page, in: db) }
        }
    }
}
