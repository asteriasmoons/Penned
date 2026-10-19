import Foundation
import GRDB

// A civil Gregorian date, not an instant. Travel never changes a note's assigned day.
nonisolated struct DailyNoteDay: Hashable, Codable, Comparable, Identifiable {
    let key: String
    var id: String { key }

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              key == String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.month, from: date) == parts[1], calendar.component(.day, from: date) == parts[2] else { return nil }
        self.key = key
    }

    var title: String { "\(key.suffix(5))-\(key.prefix(4))" }
    func title(adding text: String) -> String {
        let suffix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? title : title + " " + suffix
    }
    func suffix(from text: String) -> String {
        if text == title { return "" }
        return text.hasPrefix(title + " ") ? String(text.dropFirst(title.count + 1)) : text
    }
    func date(timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = key.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }
}

enum DailyNoteError: LocalizedError {
    case chooseTemplate, unavailableTemplate, duplicateDate, spaceChanged
    var errorDescription: String? {
        switch self {
        case .chooseTemplate: "Choose a Daily Note template for this Space first."
        case .unavailableTemplate: "This template is no longer available in this Space. Choose another Daily Note template."
        case .duplicateDate: "This Space already has a Daily Note for that date. Neither note was replaced."
        case .spaceChanged: "The selected Space changed. Open the Daily Note from its Space."
        }
    }
}

nonisolated enum DailyNoteMigration {
    static func install(in db: Database) throws {
        try db.alter(table: "documents") { $0.add(column: "dailyNoteDate", .text) }
        try db.execute(sql: """
            CREATE UNIQUE INDEX daily_note_day_per_space ON documents(spaceID, dailyNoteDate)
            WHERE dailyNoteDate IS NOT NULL AND isTrashed = 0;
            CREATE TABLE dailyNoteSettings (
                spaceID TEXT PRIMARY KEY NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                templateID TEXT REFERENCES templates(id) ON DELETE SET NULL
            );
            CREATE TRIGGER daily_note_settings_insert BEFORE INSERT ON dailyNoteSettings
            WHEN NEW.templateID IS NOT NULL AND NOT EXISTS
                (SELECT 1 FROM templates WHERE id=NEW.templateID AND spaceID=NEW.spaceID)
            BEGIN SELECT RAISE(ABORT, 'Daily Note template must belong to this Space'); END;
            CREATE TRIGGER daily_note_settings_update BEFORE UPDATE ON dailyNoteSettings
            WHEN NEW.templateID IS NOT NULL AND NOT EXISTS
                (SELECT 1 FROM templates WHERE id=NEW.templateID AND spaceID=NEW.spaceID)
            BEGIN SELECT RAISE(ABORT, 'Daily Note template must belong to this Space'); END;
            CREATE TRIGGER daily_note_template_moved AFTER UPDATE OF spaceID ON templates
            BEGIN UPDATE dailyNoteSettings SET templateID=NULL WHERE templateID=NEW.id AND spaceID<>NEW.spaceID; END;
            CREATE TRIGGER daily_note_template_unavailable AFTER UPDATE OF isTrashed,isArchived ON documents
            WHEN NEW.isTrashed=1 OR NEW.isArchived=1
            BEGIN UPDATE dailyNoteSettings SET templateID=NULL WHERE templateID IN
                (SELECT id FROM templates WHERE rootDocumentID=NEW.id); END;
            CREATE TRIGGER daily_note_template_root_deleted BEFORE DELETE ON documents
            BEGIN UPDATE dailyNoteSettings SET templateID=NULL WHERE templateID IN
                (SELECT id FROM templates WHERE rootDocumentID=OLD.id); END;
            CREATE TRIGGER daily_note_valid_insert BEFORE INSERT ON documents
            WHEN NEW.dailyNoteDate IS NOT NULL AND (NEW.templateID IS NOT NULL OR NEW.parentDocumentID IS NOT NULL
                OR length(NEW.dailyNoteDate)<>10 OR NEW.dailyNoteDate NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')
            BEGIN SELECT RAISE(ABORT, 'Invalid Daily Note ownership or date'); END;
            CREATE TRIGGER daily_note_valid_update BEFORE UPDATE OF dailyNoteDate,templateID,parentDocumentID ON documents
            WHEN NEW.dailyNoteDate IS NOT NULL AND (NEW.templateID IS NOT NULL OR NEW.parentDocumentID IS NOT NULL
                OR length(NEW.dailyNoteDate)<>10 OR NEW.dailyNoteDate NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')
            BEGIN SELECT RAISE(ABORT, 'Invalid Daily Note ownership or date'); END;
            """)
    }
}

final class DailyNoteRepository: @unchecked Sendable {
    private let database: AppDatabase
    private let templates: TemplateRepository
    var spaceID: String?

    init(database: AppDatabase, templates: TemplateRepository) {
        self.database = database
        self.templates = templates
    }

    func defaultTemplate() throws -> TemplateRecord? {
        try database.read { db in
            guard let spaceID else { return nil }
            try LibraryAccess.requireSpace(spaceID, in: db)
            return try TemplateRecord.fetchOne(db, sql: """
                SELECT t.* FROM dailyNoteSettings s JOIN templates t ON t.id=s.templateID AND t.spaceID=s.spaceID
                JOIN spaces p ON p.id=s.spaceID AND p.isArchived=0 WHERE s.spaceID=?
                    AND (t.rootDocumentID IS NULL OR EXISTS(SELECT 1 FROM documents d
                        WHERE d.id=t.rootDocumentID AND d.templateID=t.id AND d.spaceID=t.spaceID AND d.isTrashed=0 AND d.isArchived=0))
                """, arguments: [spaceID])
        }
    }

    func setDefaultTemplate(_ id: String?) throws {
        try database.write { db in
            guard let spaceID else { throw DailyNoteError.spaceChanged }
            try SpaceOwnership.requireSpace(spaceID, in: db)
            if let id {
                guard let template = try TemplateRecord.fetchOne(db, key: id), template.spaceID == spaceID else {
                    throw DailyNoteError.unavailableTemplate
                }
                if let rootID = template.rootDocumentID {
                    guard let root = try DocumentRecord.fetchOne(db, key: rootID), root.templateID == id,
                          root.spaceID == spaceID, !root.isTrashed, !root.isArchived else { throw DailyNoteError.unavailableTemplate }
                }
            }
            try db.execute(sql: "INSERT INTO dailyNoteSettings(spaceID,templateID) VALUES (?,?) ON CONFLICT(spaceID) DO UPDATE SET templateID=excluded.templateID", arguments: [spaceID, id])
        }
    }

    func notes(from start: DailyNoteDay, through end: DailyNoteDay) throws -> [String: DocumentRecord] {
        try database.read { db in
            guard let spaceID else { return [:] }
            try LibraryAccess.requireSpace(spaceID, in: db)
            let notes = try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE spaceID=? AND dailyNoteDate>=? AND dailyNoteDate<=? AND isTrashed=0 AND isArchived=0 AND templateID IS NULL", arguments: [spaceID, start.key, end.key])
            return Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.dailyNoteDate.map { ($0, note) } })
        }
    }

    func createOrFind(day: DailyNoteDay, attachmentStore: AttachmentStore) throws -> DocumentRecord {
        var paths: [String] = []
        do {
            return try database.write { db in
                guard let spaceID else { throw DailyNoteError.spaceChanged }
                try SpaceOwnership.requireSpace(spaceID, in: db)
                if let note = try DocumentRecord.fetchOne(db, sql: "SELECT * FROM documents WHERE spaceID=? AND dailyNoteDate=? AND isTrashed=0", arguments: [spaceID, day.key]) { return note }
                guard let template = try TemplateRecord.fetchOne(db, sql: "SELECT t.* FROM dailyNoteSettings s JOIN templates t ON t.id=s.templateID AND t.spaceID=s.spaceID WHERE s.spaceID=?", arguments: [spaceID]) else {
                    throw DailyNoteError.chooseTemplate
                }
                if let id = template.rootDocumentID {
                    guard let root = try DocumentRecord.fetchOne(db, key: id), root.templateID == template.id,
                          root.spaceID == spaceID, !root.isTrashed, !root.isArchived else { throw DailyNoteError.unavailableTemplate }
                }
                let root = try templates.materialize(template, store: attachmentStore, paths: &paths, in: db)
                var note = try templates.cloneTree(sourceID: root.id, title: day.title, templateID: nil, originID: template.id,
                    spaceID: spaceID, folderID: nil, parentID: nil, store: attachmentStore, paths: &paths, in: db,
                    resetsComponentResponses: true)
                note.dailyNoteDate = day.key
                try note.update(db)
                try DocumentRepository.upsertSearchIndex(note, in: db)
                return note
            }
        } catch {
            for path in paths { try? attachmentStore.removeFile(relativePath: path) }
            throw error
        }
    }
}
