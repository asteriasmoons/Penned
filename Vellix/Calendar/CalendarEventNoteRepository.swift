import Foundation
import GRDB

extension Notification.Name {
    static let pennedCalendarNotesChanged = Notification.Name("Penned.CalendarNotesChanged")
}

final class CalendarEventNoteRepository: @unchecked Sendable {
    private let database: AppDatabase
    private let documents: DocumentRepository

    init(database: AppDatabase, documents: DocumentRepository) {
        self.database = database
        self.documents = documents
    }

    nonisolated static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE calendarEventNotes (
                id TEXT PRIMARY KEY NOT NULL,
                eventKey TEXT NOT NULL UNIQUE,
                documentID TEXT NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
                calendarID TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                localID TEXT NOT NULL,
                externalID TEXT,
                occurrenceKey TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE INDEX calendarEventNotes_local ON calendarEventNotes(localID, occurrenceKey);
            CREATE INDEX calendarEventNotes_external ON calendarEventNotes(externalID, occurrenceKey);
            """)
    }

    func notes(for events: [CalendarEvent]) throws -> [String: DocumentRecord] {
        try database.write { db in
            var result: [String: DocumentRecord] = [:]
            for event in events {
                if let link = try matchingLink(event.identity, in: db),
                   let document = try DocumentRecord.fetchOne(db, key: link["documentID"] as String) {
                    if link["eventKey"] as String != event.id || link["localID"] as String != event.identity.localID {
                        try updateIdentity(event.identity, linkID: link["id"], in: db)
                    }
                    result[event.id] = document
                }
            }
            return result
        }
    }

    @discardableResult
    func createOrFind(for event: CalendarEvent) throws -> DocumentRecord {
        let document = try database.write { db in
            if let link = try matchingLink(event.identity, in: db),
               let document = try DocumentRecord.fetchOne(db, key: link["documentID"] as String) {
                try updateIdentity(event.identity, linkID: link["id"], in: db)
                return document
            }
            let document = try documents.create(DocumentDraft(title: event.title), in: db)
            let identity = event.identity
            try db.execute(sql: """
                INSERT INTO calendarEventNotes
                (id, eventKey, documentID, calendarID, sourceID, localID, externalID, occurrenceKey, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, identity.key, document.id, identity.calendarID,
                    identity.sourceID, identity.localID, identity.externalID, identity.occurrenceKey, Date()])
            return document
        }
        NotificationCenter.default.post(name: .pennedCalendarNotesChanged, object: database)
        return document
    }

    private func matchingLink(_ identity: CalendarEventIdentity, in db: Database) throws -> Row? {
        if let exact = try Row.fetchOne(db, sql: "SELECT * FROM calendarEventNotes WHERE eventKey = ?", arguments: [identity.key]) { return exact }
        // Local IDs survive calendar moves. Require a unique match; never merge two notes.
        let local = try Row.fetchAll(db, sql: "SELECT * FROM calendarEventNotes WHERE localID = ? AND occurrenceKey = ?",
                                    arguments: [identity.localID, identity.occurrenceKey])
        if local.count == 1 { return local[0] }
        guard let externalID = identity.externalID else { return nil }
        let external = try Row.fetchAll(db, sql: """
            SELECT * FROM calendarEventNotes WHERE externalID = ? AND calendarID = ?
            AND sourceID = ? AND occurrenceKey = ?
            """, arguments: [externalID, identity.calendarID, identity.sourceID, identity.occurrenceKey])
        return external.count == 1 ? external[0] : nil
    }

    private func updateIdentity(_ identity: CalendarEventIdentity, linkID: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE calendarEventNotes SET eventKey = ?, calendarID = ?, sourceID = ?, localID = ?, externalID = ?, occurrenceKey = ? WHERE id = ?
            """, arguments: [identity.key, identity.calendarID, identity.sourceID, identity.localID,
                identity.externalID, identity.occurrenceKey, linkID])
    }
}
