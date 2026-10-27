import Foundation
import GRDB
import Testing
@testable import Vellix

// Historical migration fixtures must encode the historical document columns.
private struct PreDailyNoteDocument: PersistableRecord {
    static let databaseTableName = "documents"
    let document: DocumentRecord
    func encode(to container: inout PersistenceContainer) throws {
        for (column, value) in try document.databaseDictionary where column != "dailyNoteDate" { container[column] = value }
    }
}

extension DocumentRecord {
    func insertBeforeDailyNotes(_ db: Database) throws { try PreDailyNoteDocument(document: self).insert(db) }
}

@MainActor
struct DailyNotesTests {
    private struct Fixture {
        let db: AppDatabase
        let documents: DocumentRepository
        let templates: TemplateRepository
        let daily: DailyNoteRepository
        let store: AttachmentStore
        let space: String
        let template: DocumentRecord
    }

    private func components(answered: Bool = false) throws -> String {
        let nodes: [[String: Any]] = TemplateComponentKind.allCases.map { kind in
            let definition = TemplateComponentDefinition(kind: kind)
            let response: Any = answered ? (kind == .singleSelect ? definition.choices[0].id as Any : kind == .multiSelect ? [definition.choices[0].id] as Any : 4 as Any) : NSNull()
            return ["type": "templateComponent", "attrs": ["id": "component-" + kind.rawValue, "definition": definition.object, "response": response]]
        }
        return try TipTapContentAnalyzer.makeDocumentJSON(content: nodes + [["type": "paragraph", "content": [["type": "text", "text": "Permanent text", "marks": [["type": "bold"]]]]]])
    }

    private func fixture() throws -> Fixture {
        let db = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: db), templates = TemplateRepository(database: db)
        let space = try SpaceRepository(database: db).all()[0].id
        documents.spaceID = space; templates.spaceID = space
        let daily = DailyNoteRepository(database: db, templates: templates); daily.spaceID = space
        let root = try templates.create(title: "My Daily Note")
        let saved = try documents.saveEditorJSON(id: root.id, canonicalJSON: components(answered: true))
        try daily.setDefaultTemplate(saved.templateID)
        return Fixture(db: db, documents: documents, templates: templates, daily: daily,
            store: AttachmentStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), space: space, template: saved)
    }

    private func nodes(_ document: DocumentRecord) -> [[String: Any]] {
        (TipTapContentAnalyzer.documentObject(from: document.tipTapJSON)["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "templateComponent" }
    }

    @Test func civilDatesRetainExactDateAndTitleAcrossTravelAndDST() throws {
        let day = try #require(DailyNoteDay(key: "2026-10-16"))
        #expect(day.title == "10-16-2026")
        #expect(day.title(adding: "My Day") == "10-16-2026 My Day")
        #expect(day.suffix(from: "10-16-2026 My Day") == "My Day")
        #expect(DailyNoteDay(key: "2026-02-30") == nil)
        #expect(DailyNoteDay(key: "2026-2-3") == nil)
        for zone in ["America/Chicago", "Pacific/Auckland", "Asia/Tokyo"] {
            let timeZone = try #require(TimeZone(identifier: zone))
            #expect(DailyNoteDay(date: day.date(timeZone: timeZone), timeZone: timeZone) == day)
        }
        let dst = try #require(DailyNoteDay(key: "2026-03-08"))
        #expect(DailyNoteDay(date: dst.date(timeZone: TimeZone(identifier: "America/Chicago")!), timeZone: TimeZone(identifier: "America/Chicago")!) == dst)
    }

    @Test func actualEditorExchangePersistsAllResponsesThroughGRDB() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNED_DAILY_NOTES_EDITOR_EXCHANGE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(DatabaseQueue(path: directory.appendingPathComponent("notes.sqlite").path), isInMemory: true)
        let templates = TemplateRepository(database: database), documents = DocumentRepository(database: database)
        let daily = DailyNoteRepository(database: database, templates: templates)
        let store = AttachmentStore(rootURL: directory.appendingPathComponent("attachments"))
        let day = DailyNoteDay(key: "2026-10-16")!
        let answers = directory.appendingPathComponent("responses.json")
        if FileManager.default.fileExists(atPath: answers.path) {
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: String]
            documents.spaceID = metadata["spaceID"]; templates.spaceID = metadata["spaceID"]; daily.spaceID = metadata["spaceID"]
            let returned = try JSONSerialization.jsonObject(with: Data(contentsOf: answers))
            let saved = try documents.saveEditorJSON(id: metadata["documentID"]!, canonicalJSON: TipTapContentAnalyzer.normalizePayloadToJSON(returned))
            let reloaded = try daily.createOrFind(day: day, attachmentStore: store)
            #expect(reloaded.id == saved.id && reloaded.tipTapJSON == saved.tipTapJSON)
            for node in nodes(reloaded) {
                let attrs = node["attrs"] as! [String: Any], definition = TemplateComponentDefinition.decode(attrs["definition"])!
                switch definition.kind {
                case .rating: #expect((attrs["response"] as? NSNumber)?.intValue == 3)
                case .singleSelect:
                    #expect(definition.choices.first { $0.id == attrs["response"] as? String }?.label == "Difficult")
                case .multiSelect:
                    let selected = attrs["response"] as! [String]
                    #expect(Set(definition.choices.filter { selected.contains($0.id) }.map(\.label)) == ["Creative", "Tired"])
                case .slider: #expect((attrs["response"] as? NSNumber)?.intValue == 70)
                }
            }
            let next = try daily.createOrFind(day: DailyNoteDay(key: "2026-10-17")!, attachmentStore: store)
            #expect(nodes(next).allSatisfy { ($0["attrs"] as? [String: Any])?["response"] is NSNull })
            #expect(try documents.requireDocument(id: saved.id).tipTapJSON == saved.tipTapJSON)
        } else {
            let owner = try SpaceRepository(database: database).all()[0].id
            templates.spaceID = owner; documents.spaceID = owner; daily.spaceID = owner
            let root = try templates.create(title: "Daily Check In")
            let questions: [TemplateComponentKind: String] = [.rating: "How would you rate your day?", .singleSelect: "How was your overall day?", .multiSelect: "Which feelings showed up today?", .slider: "How much energy did you have?"]
            let content: [[String: Any]] = TemplateComponentKind.allCases.map { kind in
                var definition = TemplateComponentDefinition(kind: kind); definition.label = questions[kind]!
                if kind == .multiSelect { definition.choices = ["Happy", "Calm", "Creative", "Tired", "Anxious", "Excited"].map { TemplateComponentChoice(label: $0) } }
                if kind == .slider { definition.minimumLabel = "None"; definition.maximumLabel = "Maximum" }
                return ["type": "templateComponent", "attrs": ["id": UUID().uuidString, "definition": definition.object, "response": NSNull()]]
            }
            _ = try documents.saveEditorJSON(id: root.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: content))
            try daily.setDefaultTemplate(root.templateID)
            let note = try daily.createOrFind(day: day, attachmentStore: store)
            try Data(note.tipTapJSON.utf8).write(to: directory.appendingPathComponent("document.json"))
            try JSONSerialization.data(withJSONObject: ["documentID": note.id, "spaceID": owner]).write(to: directory.appendingPathComponent("metadata.json"))
            #expect(note.dailyNoteDate == "2026-10-16" && nodes(note).count == 4)
        }
    }

    @Test func existingDataMigrationAddsOnlyNullableDateAndSettings() throws {
        let queue = try DatabaseQueue()
        try DatabaseMigrator.vellixMigrator.migrate(queue, upTo: "v17_space_images")
        try queue.write { db in
            let space = try String.fetchOne(db, sql: "SELECT id FROM spaces LIMIT 1")!
            try db.execute(sql: "INSERT INTO documents(id,title,tipTapJSON,spaceID,createdAt,updatedAt) VALUES ('legacy','Legacy',?,?,?,?)", arguments: [TipTapContentAnalyzer.emptyDocumentJSON, space, Date(), Date()])
        }
        let db = try AppDatabase(queue, isInMemory: true)
        let legacy = try #require(try DocumentRepository(database: db).document(id: "legacy"))
        #expect(legacy.title == "Legacy" && legacy.dailyNoteDate == nil)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dailyNoteSettings") } == 0)
        #expect(try db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    }

    @Test func settingsAreSpaceScopedPersistedAndFollowTemplateIdentityNotName() throws {
        let f = try fixture()
        let templateID = try #require(f.template.templateID)
        #expect(try f.daily.defaultTemplate()?.id == templateID)
        try f.templates.rename(id: templateID, title: "Renamed")
        #expect(try f.daily.defaultTemplate()?.title == "Renamed")
        let reloaded = DailyNoteRepository(database: f.db, templates: f.templates); reloaded.spaceID = f.space
        #expect(try reloaded.defaultTemplate()?.id == templateID)
        let secondSpace = try SpaceRepository(database: f.db).create(title: "Other")
        f.daily.spaceID = secondSpace.id
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(throws: (any Error).self) { try f.daily.setDefaultTemplate(templateID) }
        f.daily.spaceID = f.space
        try f.daily.setDefaultTemplate(nil)
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(throws: DailyNoteError.self) { try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: f.store) }
    }

    @Test func dailyCreationIsAtomicIdempotentIndependentAndResetsAnswers() throws {
        let f = try fixture(), day = DailyNoteDay(key: "2026-10-16")!
        let first = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        let same = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        let next = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-17")!, attachmentStore: f.store)
        #expect(first.id == same.id && first.id != next.id)
        #expect(first.title == day.title && first.dailyNoteDate == day.key && first.spaceID == f.space)
        #expect(nodes(first).count == 4)
        #expect(nodes(first).allSatisfy { ($0["attrs"] as? [String: Any])?["response"] is NSNull })
        let firstIDs = Set(nodes(first).compactMap { ($0["attrs"] as? [String: Any])?["id"] as? String })
        let secondIDs = Set(nodes(next).compactMap { ($0["attrs"] as? [String: Any])?["id"] as? String })
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(first.plainText.contains("Permanent text"))
        #expect(first.tipTapJSON.contains("bold"))
        var object = TipTapContentAnalyzer.documentObject(from: first.tipTapJSON)
        var content = object["content"] as! [[String: Any]]
        var attrs = content[0]["attrs"] as! [String: Any]; attrs["response"] = 4; content[0]["attrs"] = attrs
        object["content"] = content
        let answered = try f.documents.saveEditorJSON(id: first.id, canonicalJSON: String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
        #expect(try f.daily.createOrFind(day: day, attachmentStore: f.store).tipTapJSON == answered.tipTapJSON)
        #expect(try f.documents.requireDocument(id: next.id).tipTapJSON == next.tipTapJSON)
        #expect(try f.documents.requireDocument(id: f.template.id).tipTapJSON == f.template.tipTapJSON)
        #expect(try f.documents.updateTitle(id: first.id, title: "My notes").title == "10-16-2026 My notes")
        #expect(try f.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    }

    @Test func ordinaryInstantiationIsGuardedAndReenabledAfterComponentsAreRemoved() throws {
        let f = try fixture(), id = f.template.templateID!
        #expect(try f.templates.dailyNoteOnlyTemplateIDs().contains(id))
        #expect(throws: (any Error).self) { try f.templates.instantiate(id: id, title: "Ordinary", spaceID: f.space, folderID: nil, parentID: nil, attachmentStore: f.store) }
        _ = try f.documents.saveEditorJSON(id: f.template.id, canonicalJSON: TipTapContentAnalyzer.starterDocument(title: "", lines: ["Ordinary text"]))
        #expect(try !f.templates.dailyNoteOnlyTemplateIDs().contains(id))
        #expect(try f.templates.instantiate(id: id, title: "Ordinary", spaceID: f.space, folderID: nil, parentID: nil, attachmentStore: f.store).dailyNoteDate == nil)
    }

    @Test func nestedComponentsAlsoRestrictOrdinaryUseAndAreIndependentInDailyNotes() throws {
        let f = try fixture()
        _ = try f.documents.saveEditorJSON(id: f.template.id, canonicalJSON: TipTapContentAnalyzer.emptyDocumentJSON)
        let child = try f.documents.create(DocumentDraft(title: "Nested", parentDocumentID: f.template.id, tipTapJSON: components()))
        #expect(try f.templates.hasInteractiveComponents(id: f.template.templateID!))
        let note = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: f.store)
        let children = try f.documents.children(of: note.id)
        #expect(children.count == 1 && children[0].id != child.id)
        #expect(nodes(children[0]).count == 4)
        #expect(children[0].templateID == nil && children[0].spaceID == f.space)
    }

    @Test func changingDeletingAndMovingDefaultsNeverMutatesCreatedNotes() throws {
        let f = try fixture(), spaces = SpaceRepository(database: f.db)
        let note = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: f.store)
        let second = try f.templates.create(title: "Other Template")
        try f.daily.setDefaultTemplate(second.templateID)
        let next = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-17")!, attachmentStore: f.store)
        #expect(nodes(next).isEmpty)
        #expect(try f.documents.requireDocument(id: note.id).tipTapJSON == note.tipTapJSON)
        try f.templates.delete(id: second.templateID!, attachmentStore: f.store)
        #expect(try f.daily.defaultTemplate() == nil)
        try f.daily.setDefaultTemplate(f.template.templateID)
        let destination = try spaces.create(title: "Destination")
        try spaces.transfer(.template(f.template.templateID!), from: f.space, to: destination.id, copy: false, store: f.store)
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(try f.documents.requireDocument(id: note.id).tipTapJSON == note.tipTapJSON)
    }

    @Test func unavailableTemplateRootsClearTheDefaultWithoutChangingExistingNotes() throws {
        let f = try fixture(), templateID = f.template.templateID!
        let note = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: f.store)
        try f.db.write { try $0.execute(sql: "UPDATE documents SET isArchived=1 WHERE id=?", arguments: [f.template.id]) }
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(throws: DailyNoteError.self) { try f.daily.setDefaultTemplate(templateID) }
        try f.db.write { try $0.execute(sql: "UPDATE documents SET isArchived=0 WHERE id=?", arguments: [f.template.id]) }
        try f.daily.setDefaultTemplate(templateID)
        _ = try f.documents.trash(id: f.template.id)
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(throws: DailyNoteError.self) { try f.daily.setDefaultTemplate(templateID) }
        _ = try f.documents.restore(id: f.template.id)
        try f.daily.setDefaultTemplate(templateID)
        try f.db.write { try $0.execute(sql: "DELETE FROM documents WHERE id=?", arguments: [f.template.id]) }
        #expect(try f.daily.defaultTemplate() == nil)
        #expect(try f.documents.requireDocument(id: note.id).tipTapJSON == note.tipTapJSON)
        #expect(try f.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    }

    @Test func trashRestorationAndDateConflictsPreserveBothDocuments() throws {
        let f = try fixture(), day = DailyNoteDay(key: "2026-10-16")!
        let first = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        _ = try f.documents.trash(id: first.id)
        #expect(try f.daily.notes(from: day, through: day).isEmpty)
        _ = try f.documents.restore(id: first.id)
        #expect(try f.daily.notes(from: day, through: day)[day.key]?.id == first.id)
        _ = try f.documents.trash(id: first.id)
        let second = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        #expect(second.id != first.id)
        #expect(throws: DailyNoteError.self) { try f.documents.restore(id: first.id) }
        #expect(try f.documents.requireDocument(id: first.id).isTrashed)
        #expect(try f.daily.notes(from: day, through: day)[day.key]?.id == second.id)
        try f.documents.permanentlyDelete(id: second.id, attachmentStore: f.store)
        _ = try f.documents.restore(id: first.id)
        #expect(try f.daily.createOrFind(day: day, attachmentStore: f.store).id == first.id)
    }

    @Test func settingsAndAllResponsesSurviveReopeningTheDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let templates = TemplateRepository(database: database), documents = DocumentRepository(database: database)
        let owner = try SpaceRepository(database: database).all()[0].id
        documents.spaceID = owner; templates.spaceID = owner
        let daily = DailyNoteRepository(database: database, templates: templates); daily.spaceID = owner
        let root = try templates.create(title: "Persisted Template")
        _ = try documents.saveEditorJSON(id: root.id, canonicalJSON: components())
        try daily.setDefaultTemplate(root.templateID)
        let day = DailyNoteDay(key: "2026-10-16")!, store = AttachmentStore.previewStore()
        let note = try daily.createOrFind(day: day, attachmentStore: store)
        var content = TipTapContentAnalyzer.documentObject(from: note.tipTapJSON)["content"] as! [[String: Any]]
        for index in 0..<4 {
            var attrs = content[index]["attrs"] as! [String: Any]
            let definition = TemplateComponentDefinition.decode(attrs["definition"])!
            switch definition.kind {
            case .rating: attrs["response"] = 4
            case .singleSelect: attrs["response"] = definition.choices[2].id
            case .multiSelect: attrs["response"] = [definition.choices[0].id, definition.choices[3].id]
            case .slider: attrs["response"] = 70
            }
            content[index]["attrs"] = attrs
        }
        let saved = try documents.saveEditorJSON(id: note.id, canonicalJSON: TipTapContentAnalyzer.makeDocumentJSON(content: content))
        let reopened = try AppDatabase(DatabaseQueue(path: path.path), isInMemory: true)
        let reloadedTemplates = TemplateRepository(database: reopened)
        let loaded = DailyNoteRepository(database: reopened, templates: reloadedTemplates); loaded.spaceID = owner
        #expect(try loaded.defaultTemplate()?.id == root.templateID)
        #expect(try loaded.createOrFind(day: day, attachmentStore: store).tipTapJSON == saved.tipTapJSON)
        #expect(try loaded.createOrFind(day: day, attachmentStore: store).id == note.id)
    }

    @Test func generationPreservesAssetsCollectionsAndRollsBackFailedAssociation() throws {
        let f = try fixture()
        let repository = CollectionRepository(database: f.db, documents: f.documents)
        let collection = try repository.create(ownerID: f.template.id, name: "Tasks", viewName: "Main", kind: .gallery)
        _ = try repository.addEntry(collectionID: collection.record.id, title: "Make Coffee")
        let asset = try f.store.importData(Data("test asset".utf8), originalFileName: "cover.txt", mimeType: "text/plain", documentID: f.template.id)
        try f.db.write { try asset.insert($0) }
        _ = try f.documents.updateAppearance(id: f.template.id, cover: asset.relativePath, appearance: .defaultForTheme(.neonCode))
        let note = try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-16")!, attachmentStore: f.store)
        let copies = try repository.collectionIDs(forDocument: note.id)
        #expect(copies.count == 1 && copies[0] != collection.record.id)
        #expect(try repository.snapshot(id: copies[0]).entries.first?.title == "Make Coffee")
        #expect(note.cover != asset.relativePath && note.cover != nil)
        #expect(note.appearance == DocumentAppearance.defaultForTheme(.neonCode))
        #expect(try Data(contentsOf: f.store.fileURL(relativePath: note.cover!)) == Data("test asset".utf8))
        let before = try f.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents") }
        let assetsBefore = try f.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachments") }
        try f.db.write { try $0.execute(sql: "CREATE TRIGGER reject_daily_note BEFORE UPDATE OF dailyNoteDate ON documents WHEN NEW.dailyNoteDate IS NOT NULL BEGIN SELECT RAISE(ABORT,'test failure'); END") }
        #expect(throws: (any Error).self) { try f.daily.createOrFind(day: DailyNoteDay(key: "2026-10-17")!, attachmentStore: f.store) }
        #expect(try f.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents") } == before)
        #expect(try f.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachments") } == assetsBefore)
        #expect(try f.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    }

    @Test func dailyNoteSpaceCopiesAreIndependentAndRejectDateCollisions() throws {
        let f = try fixture(), spaces = SpaceRepository(database: f.db), day = DailyNoteDay(key: "2026-10-16")!
        let source = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        let destination = try spaces.create(title: "Destination")
        try spaces.transfer(.document(source.id), from: f.space, to: destination.id, copy: true, store: f.store)
        f.daily.spaceID = destination.id
        let copied = try #require(try f.daily.notes(from: day, through: day)[day.key])
        #expect(copied.id != source.id && copied.dailyNoteDate == source.dailyNoteDate)
        #expect(throws: (any Error).self) { try spaces.transfer(.document(source.id), from: f.space, to: destination.id, copy: false, store: f.store) }
        #expect(try f.documents.requireDocument(id: source.id).spaceID == f.space)
    }

    @Test func calendarAndDateUniquenessAreScopedToActiveSpace() async throws {
        let f = try fixture(), day = DailyNoteDay(key: "2026-10-16")!
        let first = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        let other = try SpaceRepository(database: f.db).create(title: "Other")
        f.templates.spaceID = other.id; f.documents.spaceID = other.id; f.daily.spaceID = other.id
        let root = try f.templates.create(title: "Other Daily Template")
        try f.daily.setDefaultTemplate(root.templateID)
        let second = try f.daily.createOrFind(day: day, attachmentStore: f.store)
        #expect(first.id != second.id)
        let model = CalendarModel(tasks: DocumentTaskRepository(database: f.db), documents: f.documents,
            notes: CalendarEventNoteRepository(database: f.db, documents: f.documents), database: f.db, dailyNotes: f.daily)
        model.select(day.date()); model.activate(); await model.refreshAndWait()
        #expect(model.dailyNote(on: day.date())?.id == second.id)
        #expect(!model.dailyNotes.values.contains { $0.id == first.id })
        model.deactivate()
    }
}

@MainActor
struct CalendarTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        value.firstWeekday = 2
        return value
    }

    @Test func weekHasSevenCalendarDaysAcrossDST() {
        var calendar = utc
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let week = CalendarAgenda.week(containing: date("2026-03-08T14:00:00Z"), calendar: calendar)
        let days = CalendarAgenda.days(in: week, calendar: calendar)
        #expect(days.count == 7)
        #expect(calendar.component(.weekday, from: days[0]) == 2)
        #expect(week.duration == 7 * 86400 - 3600)
    }

    @Test func initialAgendaDayUsesTodayOnlyWithinTheDisplayedLocalWeek() {
        let now = date("2026-03-08T15:00:00Z")
        for firstWeekday in [1, 2, 7] {
            var calendar = utc
            calendar.timeZone = TimeZone(identifier: "America/Chicago")!
            calendar.firstWeekday = firstWeekday
            let week = CalendarAgenda.week(containing: now, calendar: calendar)
            let days = CalendarAgenda.days(in: week, calendar: calendar)
            #expect(CalendarAgenda.initialVisibleDay(in: week, now: now, calendar: calendar) == calendar.startOfDay(for: now))
            #expect(days.count == 7 && days == days.sorted())
            #expect(CalendarAgenda.days(in: week, calendar: calendar) == days)
            for offset in [-7, 7] {
                let otherDate = calendar.date(byAdding: .day, value: offset, to: now)!
                let otherWeek = CalendarAgenda.week(containing: otherDate, calendar: calendar)
                #expect(CalendarAgenda.initialVisibleDay(in: otherWeek, now: now, calendar: calendar) == otherWeek.start)
            }
            #expect(CalendarAgenda.initialVisibleDay(in: week, now: week.end, calendar: calendar) == week.start)
        }
    }

    @Test func reopeningTargetsTodayWithoutOverridingANewExplicitDateRequest() throws {
        let model = try scrollModel()
        let today = model.selectedDate
        let days = model.days
        #expect(model.initialScrollDate(now: today) == today)
        let selected = days.first { $0 != today }!
        model.select(selected)
        #expect(model.initialScrollDate(now: today) == selected)
        model.acknowledgeScrollRequest()
        #expect(model.initialScrollDate(now: today) == today)
        #expect(model.selectedDate == selected && model.days == days)
        let revision = model.selectionRevision
        model.toggleDay(selected); model.expandAll(); model.collapseAll(); model.refresh()
        #expect(model.selectionRevision == revision)
    }

    @Test func weekNavigationTargetsTheFirstCardWithoutChangingTheWeekdaySelection() throws {
        let model = try scrollModel()
        let selected = model.days[3]
        model.select(selected); model.acknowledgeScrollRequest()
        model.navigate(1)
        #expect(model.selectedDate == model.calendar.date(byAdding: .day, value: 7, to: selected))
        #expect(model.scrollTargetDate == model.week.start)
        #expect(model.initialScrollDate(now: selected) == model.week.start)
        #expect(model.days.count == 7 && model.days == model.days.sorted())
        model.acknowledgeScrollRequest()
        #expect(model.initialScrollDate(now: selected) == model.week.start)
        model.navigate(-1)
        #expect(model.selectedDate == selected)
        #expect(model.scrollTargetDate == model.week.start)
    }

    @Test func todayAlwaysIssuesANewSnapAndDayNavigationKeepsItsExistingBehavior() throws {
        let model = try scrollModel()
        model.navigate(1)
        let revision = model.selectionRevision
        model.today()
        #expect(model.selectionRevision == revision + 1)
        #expect(model.calendar.isDateInToday(model.selectedDate))
        #expect(model.scrollTargetDate == model.selectedDate)
        #expect(model.expandedDays.contains(model.selectedDate))
        model.acknowledgeScrollRequest()
        model.today()
        #expect(model.selectionRevision == revision + 2)
        #expect(model.scrollTargetDate == model.selectedDate)
        model.mode = .day
        let selected = model.selectedDate
        model.navigate(1)
        #expect(model.selectedDate == model.calendar.date(byAdding: .day, value: 1, to: selected))
        #expect(model.scrollTargetDate == model.selectedDate)
    }

    private func scrollModel() throws -> CalendarModel {
        let db = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: db)
        return CalendarModel(tasks: DocumentTaskRepository(database: db), documents: documents,
            notes: CalendarEventNoteRepository(database: db, documents: documents), database: db)
    }

    @Test func expansionAndModeSwitchingDoNotCollapseOtherDays() throws {
        let db = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: db)
        let model = CalendarModel(tasks: DocumentTaskRepository(database: db), documents: documents,
            notes: CalendarEventNoteRepository(database: db, documents: documents), database: db)
        let first = model.days[0], second = model.days[1]
        model.collapseAll()
        model.toggleDay(first)
        model.toggleDay(second)
        #expect(model.expandedDays.contains(first) && model.expandedDays.contains(second))
        model.select(second)
        model.mode = .day
        model.mode = .week
        #expect(model.selectedDate == second)
        #expect(model.expandedDays.contains(first) && model.expandedDays.contains(second))
        model.expandAll()
        #expect(model.days.allSatisfy(model.expandedDays.contains))
        model.collapseAll()
        #expect(model.days.allSatisfy { !model.expandedDays.contains($0) })
    }

    @Test func eventDeduplicationPreservesCalendarsAndRecurringOccurrences() {
        let first = event()
        var otherCalendar = first
        otherCalendar.identity.calendarID = "other-calendar"
        var recurring = first
        recurring.identity.occurrenceDate = date("2026-10-14T09:00:00Z")
        #expect(CalendarAgenda.uniqueEvents([first, first, otherCalendar, recurring]).count == 3)
        var edited = first
        edited.start = date("2026-10-15T12:00:00Z")
        #expect(edited.id == first.id, "editing a one-time event's date retains its note identity")
        edited.lastModified = date("2026-10-13T12:00:00Z")
        #expect(CalendarAgenda.uniqueEvents([edited, first]).first?.start == edited.start)
    }

    @Test func allDayAndSpanningEventsUseExclusiveEndDates() {
        var value = event()
        value.isAllDay = true
        value.start = date("2026-10-13T00:00:00Z")
        value.end = date("2026-10-15T00:00:00Z")
        #expect(value.intersects(utc.dateInterval(of: .day, for: date("2026-10-14T12:00:00Z"))!))
        #expect(!value.intersects(utc.dateInterval(of: .day, for: date("2026-10-15T12:00:00Z"))!))
        #expect(value.timeLabel(on: value.start, calendar: utc) == "All Day")
    }

    @Test func floatingOccurrenceIdentitySurvivesTravel() {
        var chicago = event().identity, newYork = event().identity
        chicago.occurrenceDate = date("2026-10-13T17:00:00Z")
        newYork.occurrenceDate = date("2026-10-13T16:00:00Z")
        chicago.floatingOccurrenceKey = CalendarEventIdentity.floatingKey(for: chicago.occurrenceDate!, allDay: false,
            timeZone: TimeZone(identifier: "America/Chicago")!)
        newYork.floatingOccurrenceKey = CalendarEventIdentity.floatingKey(for: newYork.occurrenceDate!, allDay: false,
            timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(chicago.key == newYork.key)
        #expect(CalendarEventIdentity.floatingKey(for: date("2026-10-13T05:00:00Z"), allDay: true,
            timeZone: TimeZone(identifier: "America/Chicago")!) == CalendarEventIdentity.floatingKey(for: date("2026-10-13T04:00:00Z"), allDay: true,
            timeZone: TimeZone(identifier: "America/New_York")!))
    }

    @Test func recurringProjectionDoesNotCreateTasksOrMutateHistory() throws {
        let start = date("2026-10-13T09:00:00Z")
        var metadata = DocumentTaskMetadata()
        metadata.scheduledAt = start.timeIntervalSince1970
        metadata.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let task = DocumentTaskRecord(documentID: "document", rootDocumentID: "document", blockID: "checklist",
            documentTitle: "Document", text: "Task", checked: false, isTemplate: false, isActive: true, metadata: metadata)
        let range = DateInterval(start: date("2026-10-13T00:00:00Z"), end: date("2026-10-17T00:00:00Z"))
        let entries = try CalendarAgenda.taskEntries([task], in: range)
        #expect(entries.count == 4)
        #expect(entries.filter(\.canComplete).count == 4)
        #expect(entries.first?.occurrenceID == metadata.occurrenceID)
        #expect(metadata.history.isEmpty)
        let completed = try metadata.completing(true)
        var updated = task
        updated.metadata = completed.metadata
        let next = try CalendarAgenda.taskEntries([updated], in: range)
        #expect(next.count == 4)
        #expect(next.filter(\.isCompleted).count == 1)
        #expect(next.filter(\.canComplete).count == 3)
        #expect(next.first(where: \.canComplete)?.scheduledDate == date("2026-10-14T09:00:00Z"))
    }

    @Test func completedDatesDoNotAlsoAppearAsPendingProjections() throws {
        let start = date("2026-10-19T09:00:00Z"), selected = date("2026-10-21T09:00:00Z")
        var metadata = DocumentTaskMetadata()
        metadata.scheduledAt = start.timeIntervalSince1970
        metadata.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        metadata = try metadata.completingOccurrence(DocumentTaskMetadata.projectedOccurrenceID(for: selected),
            completed: true, text: "Task").metadata
        let task = DocumentTaskRecord(documentID: "document", rootDocumentID: "document", blockID: "checklist",
            documentTitle: "Document", text: "Task", checked: false, isTemplate: false, isActive: true, metadata: metadata)
        let entries = try CalendarAgenda.taskEntries([task], in: DateInterval(
            start: date("2026-10-19T00:00:00Z"), end: date("2026-10-24T00:00:00Z")))
        #expect(entries.count == 5)
        let selectedEntries = entries.filter { $0.scheduledDate == selected }
        #expect(selectedEntries.count == 1 && selectedEntries[0].isCompleted && !selectedEntries[0].canComplete)
        #expect(entries.first(where: { $0.kind == .current })?.scheduledDate == start)
        #expect(entries.filter(\.canComplete).count == 4)
    }

    @Test func unscheduledTasksAndTemplatesRemainDistinct() throws {
        let task = DocumentTaskRecord(documentID: "document", rootDocumentID: "document", blockID: "checklist",
            documentTitle: "Document", text: "Task", checked: false, isTemplate: false, isActive: true, metadata: DocumentTaskMetadata())
        var template = task
        template.isTemplate = true
        let entries = try CalendarAgenda.taskEntries([task, template], in: CalendarAgenda.week(containing: Date()))
        #expect(entries.count == 1 && entries[0].scheduledDate == nil)
        #expect(entries[0].task.id == task.id)
    }

    @Test func eventNoteCreationIsAtomicIdempotentAndSurvivesReopening() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let documents = DocumentRepository(database: db)
        let notes = CalendarEventNoteRepository(database: db, documents: documents)
        let value = event()
        let first = try notes.createOrFind(for: value)
        #expect(try notes.createOrFind(for: value).id == first.id)
        #expect(try documents.allDocuments().count == 1)
        let reopened = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let loaded = CalendarEventNoteRepository(database: reopened, documents: DocumentRepository(database: reopened))
        #expect(try loaded.notes(for: [value])[value.id]?.id == first.id)
        var moved = value
        moved.identity.calendarID = "moved-calendar"
        #expect(try loaded.notes(for: [moved])[moved.id]?.id == first.id)
        moved.identity.localID = "resynced-local-id"
        #expect(try loaded.createOrFind(for: moved).id == first.id)
        try reopened.write { db in try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [first.id]) }
        #expect(try loaded.notes(for: [moved]).isEmpty)
    }

    @Test func recurringEventNotesAreOccurrenceScopedAndFailedLinksRollBackDocuments() throws {
        let db = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: db)
        let notes = CalendarEventNoteRepository(database: db, documents: documents)
        var first = event(), second = event()
        first.identity.occurrenceDate = date("2026-10-13T09:00:00Z")
        second.identity.occurrenceDate = date("2026-10-14T09:00:00Z")
        #expect(try notes.createOrFind(for: first).id != notes.createOrFind(for: second).id)
        try db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_calendar_note BEFORE INSERT ON calendarEventNotes BEGIN SELECT RAISE(ABORT, 'test rollback'); END;")
        }
        let before = try documents.allDocuments().count
        #expect(throws: (any Error).self) { try notes.createOrFind(for: event()) }
        #expect(try documents.allDocuments().count == before)
    }

    @Test func serverCopiesInDifferentCalendarsDoNotShareNotes() throws {
        let db = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: db)
        let notes = CalendarEventNoteRepository(database: db, documents: documents)
        let first = event()
        var copy = first
        copy.identity.calendarID = "copied-calendar"
        copy.identity.localID = "copied-local-id"
        let originalNote = try notes.createOrFind(for: first)
        let copiedNote = try notes.createOrFind(for: copy)
        #expect(originalNote.id != copiedNote.id)
        #expect(try notes.notes(for: [first, copy]).count == 2)
    }

    private func event() -> CalendarEvent {
        CalendarEvent(identity: CalendarEventIdentity(calendarID: "calendar", sourceID: "source", localID: "local", externalID: "server-id"),
            title: "Event", calendarTitle: "Calendar", colorRed: 0.5, colorGreen: 0.3, colorBlue: 0.8,
            start: date("2026-10-13T09:00:00Z"), end: date("2026-10-13T10:00:00Z"), isAllDay: false)
    }
}
