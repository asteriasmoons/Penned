import Foundation
import GRDB

// A closed editor keeps its original database handle, never the next account's scope.
nonisolated final class LibraryLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func check() throws { if !isValid { throw LibraryError.staleWorkspace } }
}

nonisolated enum LibraryAccess {
    static func configure(_ db: Database, libraryID: String) {
        db.add(function: DatabaseFunction("penned_library", argumentCount: 0, pure: false) { _ in libraryID })
        LibrarySyncSchema.configure(db)
    }
    static func current(in db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT penned_library()") ?? LibraryRecord.localID
    }
    static func allows(_ libraryID: String, in db: Database) throws -> Bool {
        let current = try current(in: db)
        return current == "*" || libraryID == current
    }
    static func requireSpace(_ id: String?, in db: Database) throws {
        guard let id, let library = try String.fetchOne(db, sql: "SELECT libraryID FROM spaces WHERE id=?", arguments: [id]),
              try allows(library, in: db) else { throw LibraryError.wrongOwner }
    }
    static func spaces(_ column: String = "spaceID") -> String {
        "\(column) IN (SELECT id FROM spaces WHERE libraryID=penned_library() OR penned_library()='*')"
    }

    // Expressions also define the authored graph used by record-level synchronization.
    static let owners: [String: String] = [
        "spaces": "$.libraryID", "documentStyles": "$.libraryID",
        "documents": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "folders": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "templates": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "dailyNoteSettings": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "documentTagRecords": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "calendarEventNotes": "(SELECT libraryID FROM spaces WHERE id=$.spaceID)",
        "attachments": "(SELECT s.libraryID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE d.id=$.documentID)",
        "documentSnapshots": "(SELECT s.libraryID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE d.id=$.documentID)",
        "collections": "(SELECT s.libraryID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE d.id=$.documentID)",
        "collectionFields": "(SELECT s.libraryID FROM collections c JOIN documents d ON d.id=c.documentID JOIN spaces s ON s.id=d.spaceID WHERE c.id=$.collectionID)",
        "collectionViews": "(SELECT s.libraryID FROM collections c JOIN documents d ON d.id=c.documentID JOIN spaces s ON s.id=d.spaceID WHERE c.id=$.collectionID)",
        "collectionEntries": "(SELECT s.libraryID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE d.id=$.documentID)",
        "collectionValues": "(SELECT s.libraryID FROM documents d JOIN spaces s ON s.id=d.spaceID WHERE d.id=$.documentID)",
        "taskCompletions": "(SELECT s.libraryID FROM documentTasks t JOIN documents d ON d.id=t.documentID JOIN spaces s ON s.id=d.spaceID WHERE t.id=$.taskID)"
    ]

    static func install(in db: Database) throws {
        for (table, expression) in owners {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let rows = event == "UPDATE" ? ["OLD", "NEW"] : [event == "DELETE" ? "OLD" : "NEW"]
                let conditions: String = rows.map { row -> String in
                    let owner = expression.replacingOccurrences(of: "$", with: row)
                    // Cascading children can run after their owning parent has been deleted.
                    return event == "DELETE" ? "(\(owner) IS NOT NULL AND \(owner)<>penned_library())"
                        : "COALESCE(\(owner),'')<>penned_library()"
                }.joined(separator: " OR ")
                try db.execute(sql: """
                    CREATE TRIGGER library_guard_\(table)_\(event) BEFORE \(event) ON \(table)
                    WHEN penned_library()<>'*' AND (\(conditions))
                    BEGIN SELECT RAISE(ABORT,'Content belongs to another library'); END;
                    """)
            }
        }
    }
}
