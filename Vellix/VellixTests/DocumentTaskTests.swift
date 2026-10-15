import Foundation
import GRDB
import Testing
@testable import Vellix

@MainActor
struct DocumentTaskTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func recurrenceUsesScheduledDateAndPreservesCalendarAnchors() throws {
        let january = date("2026-01-31T09:00:00Z")
        let monthly = TaskRepeatRule(frequency: .monthly, timeZoneID: "UTC", anchor: january.timeIntervalSince1970)
        let february = try monthly.next(after: january)
        #expect(february == date("2026-02-28T09:00:00Z"))
        #expect(try monthly.next(after: february) == date("2026-03-31T09:00:00Z"))
        let leap = date("2024-02-29T09:00:00Z")
        let yearly = TaskRepeatRule(frequency: .yearly, timeZoneID: "UTC", anchor: leap.timeIntervalSince1970)
        #expect(try yearly.next(after: leap) == date("2025-02-28T09:00:00Z"))
        #expect(try yearly.next(after: date("2027-02-28T09:00:00Z")) == date("2028-02-29T09:00:00Z"))
        var task = DocumentTaskMetadata()
        task.scheduledAt = january.timeIntervalSince1970
        task.recurrence = monthly
        let result = try task.completing(true, at: date("2026-04-10T20:00:00Z"))
        #expect(result.checked == false)
        #expect(result.metadata.scheduledDate == february)
        #expect(result.metadata.history.first?.scheduledAt == january.timeIntervalSince1970)
        #expect(result.metadata.history.first?.completedAt == date("2026-04-10T20:00:00Z").timeIntervalSince1970)
        #expect(result.metadata.occurrenceID != task.occurrenceID)
    }

    @Test func weekdaysCustomIntervalsAndDSTUseCalendarDays() throws {
        let friday = date("2026-10-16T09:00:00Z")
        let weekdays = TaskRepeatRule(frequency: .weekdays, timeZoneID: "UTC", anchor: friday.timeIntervalSince1970)
        #expect(try weekdays.next(after: friday) == date("2026-10-19T09:00:00Z"))
        let monday = date("2026-10-12T09:00:00Z")
        let weekly = TaskRepeatRule(frequency: .weekly, interval: 2, weekdays: [2, 4], timeZoneID: "UTC", anchor: monday.timeIntervalSince1970)
        #expect(try weekly.next(after: monday) == date("2026-10-14T09:00:00Z"))
        #expect(try weekly.next(after: date("2026-10-14T09:00:00Z")) == date("2026-10-26T09:00:00Z"))
        let beforeDST = date("2026-03-07T15:00:00Z") // Chicago 9 AM.
        let daily = TaskRepeatRule(frequency: .daily, timeZoneID: "America/Chicago", anchor: beforeDST.timeIntervalSince1970)
        #expect(try daily.next(after: beforeDST) == date("2026-03-08T14:00:00Z"))
        let everyThree = TaskRepeatRule(frequency: .daily, interval: 3, timeZoneID: "UTC", anchor: monday.timeIntervalSince1970)
        #expect(try everyThree.next(after: monday) == date("2026-10-15T09:00:00Z"))
        let monthly = TaskRepeatRule(frequency: .monthly, timeZoneID: "UTC", anchorDay: 31, anchor: monday.timeIntervalSince1970)
        #expect(try monthly.first(onOrAfter: monday) == date("2026-10-31T09:00:00Z"))
        let yearly = TaskRepeatRule(frequency: .yearly, timeZoneID: "UTC", anchorDay: 25, anchorMonth: 12, anchor: monday.timeIntervalSince1970)
        #expect(try yearly.first(onOrAfter: monday) == date("2026-12-25T09:00:00Z"))
    }

    @Test func tasksSurviveDiskReopeningAndRemainOnTheSameBlock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var task = DocumentTaskMetadata()
        task.reminderEnabled = true
        task.scheduledAt = date("2027-01-01T09:00:00Z").timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: task.scheduledAt!)
        let database = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let documents = DocumentRepository(database: database)
        let record = try documents.create(DocumentDraft(title: "Document", tipTapJSON: json(task)))
        let repository = DocumentTaskRepository(database: database)
        #expect(try repository.all().count == 1)
        _ = try repository.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true)
        let reopened = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let index = DocumentTaskRepository(database: reopened)
        let saved = try #require(index.all().first)
        #expect(saved.documentID == record.id && saved.blockID == "checklist")
        #expect(saved.text == "Rich task text")
        #expect(saved.checked == false && saved.metadata.history.count == 1)
        #expect(saved.metadata.scheduledDate == date("2027-01-02T09:00:00Z"))
        #expect(try index.completedOccurrences(taskID: task.id).first?.documentID == record.id)
        #expect(throws: DocumentTaskError.self) {
            try repository.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true)
        }
    }

    @Test func templatesCopiesNestedPagesAndDeletionDoNotShareTasks() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let templates = TemplateRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        var task = DocumentTaskMetadata()
        task.reminderEnabled = true
        task.scheduledAt = date("2027-02-01T09:00:00Z").timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .weekly, timeZoneID: "UTC", anchor: task.scheduledAt!)
        let parent = try documents.create(DocumentDraft(title: "Parent"))
        let child = try documents.create(DocumentDraft(title: "Nested", parentDocumentID: parent.id, tipTapJSON: json(task)))
        #expect(try tasks.tasks(documentID: parent.id, includingNestedPages: true).count == 1)
        let template = try templates.saveUserTemplate(from: parent, title: "Task Template")
        let root = try templates.editingDocument(id: template.id)
        let templateTasks = try tasks.tasks(documentID: root.id, includingNestedPages: true)
        #expect(templateTasks.count == 1 && templateTasks[0].isTemplate)
        #expect(templateTasks.first?.id != task.id)
        #expect(try tasks.all().count == 1)
        let copy = try documents.duplicate(id: child.id)
        #expect(try tasks.tasks(documentID: copy.id).first?.id != task.id)
        _ = try documents.trash(id: parent.id)
        #expect(try tasks.all().isEmpty)
        _ = try documents.restore(id: parent.id)
        #expect(try tasks.all().count == 2)
        try documents.permanentlyDelete(id: child.id)
        #expect(try tasks.all(includeTemplates: true, includeInactive: true).allSatisfy { $0.documentID != child.id })
        let instance = try templates.instantiate(id: template.id, title: "New Document", spaceID: nil, folderID: nil, parentID: nil,
                                                 attachmentStore: .previewStore())
        let instantiatedTasks = try tasks.tasks(documentID: instance.id, includingNestedPages: true)
        #expect(instantiatedTasks.count == 1 && !instantiatedTasks[0].isTemplate)
        #expect(instantiatedTasks[0].id != templateTasks[0].id)
        #expect(instantiatedTasks[0].metadata.notificationID != templateTasks[0].metadata.notificationID)
        #expect(instantiatedTasks[0].metadata.recurrence == task.recurrence)
        #expect(instantiatedTasks[0].metadata.reminderEnabled && instantiatedTasks[0].metadata.history.isEmpty)
    }

    @Test func conversionBackAndChecklistDeletionRemoveTaskIndices() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        let task = DocumentTaskMetadata()
        let document = try documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(task)))
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true)
        #expect(try tasks.completedOccurrences().count == 1)
        _ = try documents.saveEditorJSON(id: document.id, canonicalJSON: json(nil))
        #expect(try tasks.all().isEmpty)
        #expect(try tasks.completedOccurrences().isEmpty)
        #expect(try documents.requireDocument(id: document.id).plainText.contains("Rich task text"))
    }

    private func json(_ task: DocumentTaskMetadata?) throws -> String {
        let attrs: [String: Any] = ["id": "checklist", "checked": false, "trackedTask": task.map { $0.object as Any } ?? NSNull()]
        let text: [String: Any] = ["type": "text", "text": "Rich task text", "marks": [["type": "bold"]]]
        let paragraph: [String: Any] = ["type": "paragraph", "attrs": ["id": "text"], "content": [text]]
        let item: [String: Any] = ["type": "taskItem", "attrs": attrs, "content": [paragraph]]
        let list: [String: Any] = ["type": "taskList", "attrs": ["id": "list"], "content": [item]]
        let object: [String: Any] = ["type": "doc", "content": [list]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
