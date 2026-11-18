import CloudKit
import Foundation
import GRDB
import os

// Temporary, opt-in iPad/iPhone diagnostics. Never log payloads or SQL statements.
nonisolated enum PennedSyncTrace {
    static let documentID: String? = {
        #if DEBUG && os(iOS)
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-PennedSyncTraceDocumentID"), index + 1 < args.count else { return nil }
        return UUID(uuidString: args[index + 1])?.uuidString
        #else
        return nil
        #endif
    }()

    static let recordName = documentID.map {
        SyncRow(table: "documents", values: ["id": .text($0)]).recordName
    }
    private static let logger = Logger(subsystem: "im.lystaria.Vellix", category: "PennedSyncTrace")
    private static let sequence = OSAllocatedUnfairLock(initialState: 0)
    private static let outputQueue = DispatchQueue(label: "im.lystaria.Vellix.PennedSyncTrace", qos: .utility)
    // The debugger can attach after startup; keep one bounded trace per opted-in launch.
    private static let outputFile: FileHandle? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = support.appendingPathComponent("Vellix/PennedSyncTrace.log")
        do {
            try Data().write(to: url, options: .atomic)
            return try FileHandle(forWritingTo: url)
        } catch {
            logger.notice("[PENNED-SYNC-TRACE] trace.fileUnavailable")
            return nil
        }
    }()

    static func token(_ string: String?) -> String {
        string.map { String(SyncRow.digest(Data($0.utf8)).prefix(16)) } ?? "-"
    }

    static func wallUS(_ date: Date?) -> String {
        guard let date, let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded(.towardZero))
        else { return "-" }
        return String(value)
    }

    static func body(_ json: String?) -> String {
        guard let json else { return "blocks=- hash=-" }
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let blocks = (object?["content"] as? [Any]).map { String($0.count) } ?? "?"
        return "blocks=\(blocks) hash=\(token(json))"
    }

    static func row(_ row: SyncRow) -> String {
        let updated = Date.fromDatabaseValue(row.values["updatedAt"]?.databaseValue ?? .null)
        return "rev=\(row.values["revision"]?.integer.map { String($0) } ?? "-")"
            + " updated_us=\(wallUS(updated)) \(body(row.values["tipTapJSON"]?.text))"
    }

    static func record(_ event: String, _ details: @autoclosure () -> String = "") {
        guard documentID != nil else { return }
        let detail = details()
        sequence.withLock { number in
            number += 1
            let wall = wallUS(Date())
            let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
            let pid = ProcessInfo.processInfo.processIdentifier
            let line = "pid=\(pid) seq=\(number) wall_us=\(wall) uptime_us=\(uptime) \(event) \(detail)"
            logger.notice("[PENNED-SYNC-TRACE] \(line, privacy: .public)")
            if number <= 1_500 {
                outputQueue.async {
                    try? outputFile?.write(contentsOf: Data("[PENNED-SYNC-TRACE] \(line)\n".utf8))
                }
            }
        }
    }

    static func isWatched(_ name: String) -> Bool {
        recordName == name
    }

    static func decision(_ decision: String, recordName: String) {
        guard isWatched(recordName) else { return }
        record("sync.decision", decision)
    }

    // Owned by a single writer connection and used only on that writer's queue.
    nonisolated final class DatabaseObserver: TransactionObserver, @unchecked Sendable {
        private let id: String
        private let name: String
        private var origin: String?
        private var labels: Set<String> = []
        private var previous: [String: String]?
        private var phase = "migration"

        init?(inMemory: Bool) {
            guard !inMemory, let id = PennedSyncTrace.documentID, let name = PennedSyncTrace.recordName else { return nil }
            self.id = id
            self.name = name
        }

        func install(in db: Database) {
            capture("db.beforeMigration", in: db, always: true)
            db.add(transactionObserver: self, extent: .databaseLifetime)
        }

        func completedMigration(in db: Database) {
            phase = "unattributed"
            capture("db.afterMigration", in: db, always: true)
        }

        func markOrigin(file: StaticString, line: UInt, function: StaticString) {
            origin = "\(file):\(line):\(function)"
        }

        func observes(eventsOfKind event: DatabaseEventKind) -> Bool {
            switch event.tableName {
            case "documents", "documentSnapshots", "librarySyncItems", "librarySyncInbox",
                 "librarySyncBaselines", "librarySyncState", "libraries", "grdb_migrations":
                return true
            default:
                return false
            }
        }

        func databaseDidChange(with event: DatabaseEvent) {
            labels.insert(event.tableName)
        }

        func databaseDidChange() {
            labels.insert("unspecified")
        }

        func databaseWillCommit() throws {}

        func databaseDidCommit(_ db: Database) {
            defer { resetTransaction() }
            guard !labels.isEmpty else { return }
            capture("db.commit", in: db, always: false)
        }

        func databaseDidRollback(_ db: Database) {
            defer { resetTransaction() }
            if !labels.isEmpty {
                record("db.rollback", "source=\(origin ?? phase) tables=\(labels.sorted().joined(separator: ","))")
            }
        }

        private func resetTransaction() {
            labels.removeAll()
            origin = nil
        }

        private func capture(_ event: String, in db: Database, always: Bool) {
            do {
                let state = try snapshot(in: db)
                let changed = state.keys.sorted().filter { always || state[$0] != previous?[$0] }
                previous = state
                guard !changed.isEmpty else { return }
                let source = origin ?? phase
                let tables = labels.sorted().joined(separator: ",")
                for key in changed {
                    record(event, "source=\(source) migration=\(state["migration"] ?? "-") tables=\(tables) \(key) \(state[key] ?? "-")")
                }
            } catch {
                record("db.traceReadFailed", "event=\(event) errorType=\(type(of: error))")
            }
        }

        private func snapshot(in db: Database) throws -> [String: String] {
            var state = ["live": "-", "outbox": "-", "inbox": "-", "baseline": "-", "snapshot": "-",
                         "checkpoint": "-", "migration": "-"]
            if try db.tableExists("grdb_migrations") {
                state["migration"] = try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") ?? "-"
            }
            if try db.tableExists("documents"), try db.columns(in: "documents").contains(where: { $0.name == "tipTapJSON" }),
               let live = try Row.fetchOne(db, sql: "SELECT revision,tipTapJSON,updatedAt FROM documents WHERE id=?", arguments: [id]) {
                let json: String? = live["tipTapJSON"]
                let revision: Int64 = live["revision"]
                let updated: Date? = live["updatedAt"]
                state["live"] = "rev=\(revision) updated_us=\(wallUS(updated)) \(body(json))"
            }
            if try db.tableExists("documentSnapshots"),
               try db.columns(in: "documentSnapshots").contains(where: { $0.name == "tipTapJSON" }),
               let latest = try Row.fetchOne(db, sql: """
                   SELECT revision,tipTapJSON FROM documentSnapshots WHERE documentID=? ORDER BY revision DESC,createdAt DESC LIMIT 1
                   """, arguments: [id]) {
                let revision: Int64 = latest["revision"]
                let json: String? = latest["tipTapJSON"]
                state["snapshot"] = "rev=\(revision) \(body(json))"
            }
            for (key, table, fields) in [
                ("outbox", "librarySyncItems", ",dirty,deleted,version,mutationID,ackMutation,systemFields"),
                ("inbox", "librarySyncInbox", ",deleted,mutationID,systemFields"),
                ("baseline", "librarySyncBaselines", "")
            ] where try db.tableExists(table) {
                let rows = try Row.fetchAll(db, sql: "SELECT libraryID,payload\(fields) FROM \(table) WHERE recordName=? ORDER BY libraryID",
                                            arguments: [name])
                if !rows.isEmpty {
                    state[key] = rows.map { stored in
                        let payload: Data = stored["payload"]
                        let library: String = stored["libraryID"]
                        let decoded = try? JSONDecoder().decode(SyncRow.self, from: payload)
                        let summary = decoded.map { row($0) } ?? "invalidPayload=true"
                        var result = "library=\(token(library)) \(summary)"
                        if key != "baseline" {
                            let mutation: String? = stored["mutationID"]
                            let deleted: Bool = stored["deleted"]
                            let systemFields: Data? = stored["systemFields"]
                            let server = systemFields.flatMap { $0.isEmpty ? nil : try? LibrarySyncStore.restoredRecord($0) }
                            result += " mutation=\(token(mutation)) deleted=\(deleted)"
                                + " tag=\(token(server?.recordChangeTag)) server_us=\(wallUS(server?.modificationDate))"
                        }
                        if key == "outbox" {
                            let dirty: Bool = stored["dirty"]
                            let version: Int64 = stored["version"]
                            let ack: String? = stored["ackMutation"]
                            result += " dirty=\(dirty) queueVersion=\(version) ack=\(token(ack))"
                        }
                        return result
                    }.joined(separator: " | ")
                }
            }
            if try db.tableExists("librarySyncState"), try db.tableExists("librarySyncItems"),
               try db.tableExists("libraries") {
                let bindings = try Row.fetchAll(db, sql: """
                    SELECT l.id, l.syncEnabled, s.engineState IS NOT NULL AS hasCheckpoint,
                           s.pausedReason IS NOT NULL AS paused
                    FROM libraries l LEFT JOIN librarySyncState s ON s.libraryID=l.id
                    WHERE l.id IN (SELECT libraryID FROM librarySyncItems WHERE recordName=?) ORDER BY l.id
                    """, arguments: [name])
                if !bindings.isEmpty {
                    state["checkpoint"] = bindings.map { binding in
                        let library: String = binding["id"]
                        let enabled: Bool = binding["syncEnabled"]
                        let present: Bool = binding["hasCheckpoint"]
                        let paused: Bool = binding["paused"]
                        return "library=\(token(library)) enabled=\(enabled) present=\(present) paused=\(paused)"
                    }.joined(separator: " | ")
                }
            }
            return state
        }
    }
}
