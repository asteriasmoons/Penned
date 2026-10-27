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

    @Test func calendarTapCompletesTheSelectedRepeatWithoutCompletingAnOverdueDate() async throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        defer { environment.calendar.deactivate() }
        let start = date("2026-10-19T09:00:00Z"), selected = date("2026-10-21T09:00:00Z")
        var metadata = DocumentTaskMetadata()
        metadata.scheduledAt = start.timeIntervalSince1970
        metadata.reminderEnabled = true
        metadata.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let source = try environment.documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(metadata)))
        let calendar = environment.calendar
        calendar.select(selected); calendar.activate(); await calendar.refreshAndWait()
        let entry = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.scheduledDate == selected })
        #expect(entry.kind == .projected && entry.canComplete)
        await calendar.complete(entry)
        await calendar.refreshAndWait()
        #expect(calendar.errorMessage == nil)
        var saved = try #require(environment.tasks.tasks(documentID: source.id).first)
        #expect(!saved.checked && saved.metadata.occurrenceID == metadata.occurrenceID)
        #expect(saved.metadata.scheduledDate == start && saved.metadata.reminderEnabled)
        #expect(saved.metadata.history.count == 1 && saved.metadata.history[0].scheduledAt == selected.timeIntervalSince1970)
        #expect(saved.metadata.history[0].taskText == "Rich task text")
        #expect(try environment.tasks.completedOccurrences(taskID: metadata.id).count == 1)
        #expect(calendar.tasks.filter { $0.task.id == metadata.id && $0.scheduledDate == selected }.count == 1)
        #expect(calendar.tasks.first { $0.task.id == metadata.id && $0.scheduledDate == selected }?.isCompleted == true)
        let history = try environment.documents.requireDocument(id: DocumentTaskPages.historyID(metadata.id))
        #expect(history.plainText.contains("Rich task text") && history.plainText.contains("completed on"))

        await calendar.complete(entry)
        #expect(calendar.errorMessage != nil)
        #expect(try environment.tasks.tasks(documentID: source.id).first?.metadata.history.count == 1)
        calendar.errorMessage = nil
        for _ in 0..<2 {
            await calendar.refreshAndWait()
            let current = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.kind == .current })
            await calendar.complete(current)
            #expect(calendar.errorMessage == nil)
        }
        saved = try #require(environment.tasks.tasks(documentID: source.id).first)
        #expect(saved.metadata.scheduledDate == date("2026-10-22T09:00:00Z"))
        #expect(saved.metadata.history.count == 3 && !saved.checked)
        #expect(saved.metadata.history.filter { $0.scheduledAt == selected.timeIntervalSince1970 }.count == 1)
    }

    @Test func projectedCompletionRejectsDuplicateMalformedAndRescheduledOccurrences() throws {
        let start = date("2026-10-19T09:00:00Z"), selected = date("2026-10-21T09:00:00Z")
        var task = DocumentTaskMetadata()
        task.scheduledAt = start.timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, interval: 2, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let occurrenceID = DocumentTaskMetadata.projectedOccurrenceID(for: selected)
        for invalid in [UUID().uuidString, "scheduled:nan", "scheduled:inf",
                        DocumentTaskMetadata.projectedOccurrenceID(for: date("2026-10-18T09:00:00Z")),
                        DocumentTaskMetadata.projectedOccurrenceID(for: date("2026-10-20T09:00:00Z")),
                        DocumentTaskMetadata.projectedOccurrenceID(for: date("2026-10-21T10:00:00Z"))] {
            #expect(throws: DocumentTaskError.self) { try task.completingOccurrence(invalid, completed: true) }
        }
        #expect(throws: DocumentTaskError.self) { try task.completingOccurrence(occurrenceID, completed: false) }
        var rescheduled = task
        rescheduled.recurrence?.interval = 3
        #expect(throws: DocumentTaskError.self) { try rescheduled.completingOccurrence(occurrenceID, completed: true) }
        var noLongerRepeating = task
        noLongerRepeating.recurrence = nil
        #expect(throws: DocumentTaskError.self) { try noLongerRepeating.completingOccurrence(occurrenceID, completed: true) }
        let result = try task.completingOccurrence(occurrenceID, completed: true, text: "Task")
        #expect(throws: DocumentTaskError.self) { try result.metadata.completingOccurrence(occurrenceID, completed: true) }
        #expect(result.metadata.scheduledAt == task.scheduledAt && result.metadata.occurrenceID == task.occurrenceID)
        let advanced = try result.metadata.completing(true)
        #expect(advanced.metadata.scheduledDate == date("2026-10-23T09:00:00Z"))

        var promoted = task
        promoted.scheduledAt = selected.timeIntervalSince1970
        promoted.occurrenceID = UUID().uuidString
        let completed = try promoted.completingOccurrence(occurrenceID, completed: true)
        #expect(completed.metadata.history.count == 1 && completed.metadata.history[0].id == promoted.occurrenceID)
        #expect(completed.metadata.scheduledDate == date("2026-10-23T09:00:00Z"))
    }

    @Test func calendarSkipMatchesDocumentCompletionAndAdvancesTheRepeatOnce() async throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        defer { environment.calendar.deactivate() }
        let start = date("2026-10-19T09:00:00Z")
        var metadata = DocumentTaskMetadata()
        metadata.scheduledAt = start.timeIntervalSince1970
        metadata.reminderEnabled = true
        metadata.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let source = try environment.documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(metadata)))
        let calendar = environment.calendar
        calendar.select(start); calendar.activate(); await calendar.refreshAndWait()
        let entry = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.kind == .current })
        await calendar.complete(entry, skipped: true)
        await calendar.refreshAndWait()
        #expect(calendar.errorMessage == nil)
        let saved = try #require(environment.tasks.tasks(documentID: source.id).first)
        let documentResult = try metadata.completing(true, skipped: true, text: "Rich task text")
        #expect(!saved.checked && saved.metadata.scheduledAt == documentResult.metadata.scheduledAt)
        #expect(saved.metadata.history.count == 1 && saved.metadata.history[0].outcome == .skipped)
        #expect(saved.metadata.history[0].id == metadata.occurrenceID)
        #expect(saved.metadata.history[0].scheduledAt == metadata.scheduledAt)
        #expect(saved.metadata.history[0].taskText == "Rich task text")
        let recorded = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.kind == .completed })
        #expect(recorded.isCompleted && recorded.isSkipped)
        let current = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.kind == .current })
        #expect(!current.isCompleted && !current.isSkipped && current.canComplete)
        #expect(current.scheduledDate == date("2026-10-20T09:00:00Z"))
        let history = try environment.documents.requireDocument(id: DocumentTaskPages.historyID(metadata.id))
        #expect(history.plainText.contains("skipped on") && !history.plainText.contains("completed on"))

        await calendar.complete(entry, skipped: true)
        #expect(calendar.errorMessage != nil)
        #expect(try environment.tasks.tasks(documentID: source.id).first?.metadata.history.count == 1)
        #expect(try environment.tasks.tasks(documentID: source.id).first?.metadata.scheduledAt == saved.metadata.scheduledAt)
    }

    @Test func calendarProjectedSkipRecordsOneSkipWithoutAnExtraCompletion() async throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        defer { environment.calendar.deactivate() }
        let start = date("2026-10-19T09:00:00Z"), selected = date("2026-10-21T09:00:00Z")
        var metadata = DocumentTaskMetadata()
        metadata.scheduledAt = start.timeIntervalSince1970
        metadata.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let source = try environment.documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(metadata)))
        let calendar = environment.calendar
        calendar.select(selected); calendar.activate(); await calendar.refreshAndWait()
        let entry = try #require(calendar.tasks.first { $0.task.id == metadata.id && $0.scheduledDate == selected })
        await calendar.complete(entry, skipped: true)
        await calendar.refreshAndWait()
        #expect(calendar.errorMessage == nil)
        let saved = try #require(environment.tasks.tasks(documentID: source.id).first)
        #expect(!saved.checked && saved.metadata.occurrenceID == metadata.occurrenceID)
        #expect(saved.metadata.scheduledAt == metadata.scheduledAt)
        #expect(saved.metadata.history.count == 1 && saved.metadata.history[0].outcome == .skipped)
        #expect(saved.metadata.history[0].scheduledAt == selected.timeIntervalSince1970)
        let rows = calendar.tasks.filter { $0.task.id == metadata.id && $0.scheduledDate == selected }
        #expect(rows.count == 1 && rows[0].isSkipped && rows[0].isCompleted)
    }

    @Test func calendarNonRepeatingCirclesCompleteSkipAndClearLikeTheDocument() async throws {
        let environment = AppEnvironment(database: try AppDatabase.makeInMemory(), attachmentStore: .previewStore())
        for skipped in [false, true] {
            let metadata = DocumentTaskMetadata()
            let source = try environment.documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(metadata)))
            let original = try #require(environment.tasks.tasks(documentID: source.id).first)
            let entry = CalendarTaskEntry(task: original, occurrenceID: metadata.occurrenceID, kind: .current)
            await environment.calendar.complete(entry, skipped: skipped)
            #expect(environment.calendar.errorMessage == nil)
            let marked = try #require(environment.tasks.tasks(documentID: source.id).first)
            let markedEntry = CalendarTaskEntry(task: marked, occurrenceID: marked.metadata.occurrenceID, kind: .current)
            #expect(markedEntry.isCompleted && markedEntry.isSkipped == skipped)
            #expect(marked.metadata.history.count == 1)
            #expect(marked.metadata.history[0].outcome == (skipped ? .skipped : .completed))
            await environment.calendar.complete(markedEntry)
            #expect(environment.calendar.errorMessage == nil)
            let cleared = try #require(environment.tasks.tasks(documentID: source.id).first)
            #expect(!cleared.checked && !cleared.metadata.isSkipped)
            #expect(cleared.metadata.history.count == 1 && cleared.metadata.occurrenceID != marked.metadata.occurrenceID)
        }
    }

    @Test func selectedCalendarDatesFollowIntervalsMonthEndsAndDST() throws {
        let start = date("2026-10-19T09:00:00Z")
        let daily = TaskRepeatRule(frequency: .daily, interval: 3, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let distant = try #require(daily.calendar.date(byAdding: .day, value: 4500, to: start))
        #expect(try daily.containsOccurrence(distant, after: start))
        #expect(try !daily.containsOccurrence(date("2026-10-21T09:00:00Z"), after: start))
        let weeklyStart = date("2026-10-12T09:00:00Z")
        let weekly = TaskRepeatRule(frequency: .weekly, interval: 2, weekdays: [2, 4], timeZoneID: "UTC", anchor: weeklyStart.timeIntervalSince1970)
        #expect(try weekly.containsOccurrence(date("2026-10-26T09:00:00Z"), after: weeklyStart))
        #expect(try !weekly.containsOccurrence(date("2026-10-19T09:00:00Z"), after: weeklyStart))
        let weekdays = TaskRepeatRule(frequency: .weekdays, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        #expect(try !weekdays.containsOccurrence(date("2026-10-24T09:00:00Z"), after: start))
        let january = date("2026-01-31T09:00:00Z")
        let monthly = TaskRepeatRule(frequency: .monthly, timeZoneID: "UTC", anchor: january.timeIntervalSince1970)
        #expect(try monthly.containsOccurrence(date("2026-02-28T09:00:00Z"), after: january))
        #expect(try !monthly.containsOccurrence(date("2026-03-28T09:00:00Z"), after: january))
        let leap = date("2024-02-29T09:00:00Z")
        let yearly = TaskRepeatRule(frequency: .yearly, timeZoneID: "UTC", anchor: leap.timeIntervalSince1970)
        #expect(try yearly.containsOccurrence(date("2028-02-29T09:00:00Z"), after: leap))
        let beforeDST = date("2026-03-07T15:00:00Z")
        let dst = TaskRepeatRule(frequency: .daily, timeZoneID: "America/Chicago", anchor: beforeDST.timeIntervalSince1970)
        #expect(try dst.containsOccurrence(date("2026-03-08T14:00:00Z"), after: beforeDST))
        #expect(try !dst.containsOccurrence(date("2026-03-08T15:00:00Z"), after: beforeDST))
    }

    @Test func projectedCompletionsPersistThroughDiskReopening() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = date("2026-10-19T09:00:00Z"), selected = date("2026-10-21T09:00:00Z")
        var task = DocumentTaskMetadata()
        task.scheduledAt = start.timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: start.timeIntervalSince1970)
        let database = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let documents = DocumentRepository(database: database)
        let source = try documents.create(DocumentDraft(title: "Tasks", tipTapJSON: json(task)))
        let repository = DocumentTaskRepository(database: database)
        _ = try repository.setCompleted(taskID: task.id, occurrenceID: DocumentTaskMetadata.projectedOccurrenceID(for: selected), completed: true)
        let reopened = try AppDatabase(DatabaseQueue(path: url.path), isInMemory: true)
        let saved = try #require(DocumentTaskRepository(database: reopened).tasks(documentID: source.id).first)
        #expect(saved.metadata.occurrenceID == task.occurrenceID && saved.metadata.scheduledAt == task.scheduledAt)
        #expect(!saved.checked && saved.metadata.history.count == 1)
        #expect(saved.metadata.history[0].scheduledAt == selected.timeIntervalSince1970)
        #expect(try DocumentTaskRepository(database: reopened).completedOccurrences(taskID: task.id).count == 1)
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

    @Test func legacyHistoryDecodesAndSkipsAdvanceExactlyOneScheduledOccurrence() throws {
        let old = try JSONDecoder().decode(TaskCompletedOccurrence.self, from: Data(#"{"id":"legacy","completedAt":100}"#.utf8))
        #expect(old.outcome == .completed && old.taskText == nil)
        var task = DocumentTaskMetadata()
        task.scheduledAt = date("2026-10-20T09:20:00Z").timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, hour: 9, minute: 20, timeZoneID: "UTC", anchor: task.scheduledAt!)
        let result = try task.completing(true, skipped: true, text: "Original task", at: date("2026-10-20T21:20:00Z"))
        #expect(!result.checked)
        #expect(result.metadata.scheduledDate == date("2026-10-21T09:20:00Z"))
        #expect(result.metadata.history.count == 1 && result.metadata.history[0].outcome == .skipped)
        #expect(result.metadata.history[0].taskText == "Original task" && result.metadata.history[0].timeZoneID == "UTC")
        let plain = try DocumentTaskMetadata().completing(true, skipped: true, text: "One-off")
        #expect(plain.checked && plain.metadata.isSkipped)
    }

    @Test func taskPagesAreRealNestedDocumentsAndRecordsUseAMPM() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        var task = DocumentTaskMetadata()
        task.scheduledAt = date("2026-10-20T09:20:00Z").timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, hour: 9, minute: 20, timeZoneID: "UTC", anchor: task.scheduledAt!)
        let source = try documents.create(DocumentDraft(title: "Parent", tipTapJSON: json(task)))
        let detail = try documents.requireDocument(id: DocumentTaskPages.detailID(task.id))
        let history = try documents.requireDocument(id: DocumentTaskPages.historyID(task.id))
        #expect(detail.parentDocumentID == source.id && detail.title == "Rich task text")
        #expect(history.parentDocumentID == detail.id && history.title == "Completed Tasks")
        #expect(detail.spaceID == source.spaceID && history.spaceID == source.spaceID)
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: detail.tipTapJSON).contains(history.id))
        #expect(TipTapContentAnalyzer.pageReferenceIDs(in: source.tipTapJSON).contains(detail.id))
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true)
        let next = try #require(tasks.all().first)
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: next.metadata.occurrenceID, completed: true, skipped: true)
        let savedHistory = try documents.requireDocument(id: history.id)
        #expect(savedHistory.plainText.contains("completed on") && savedHistory.plainText.contains("skipped on"))
        #expect(savedHistory.plainText.contains("AM") || savedHistory.plainText.contains("PM"))
        #expect(try tasks.all().count == 1)
        #expect(try tasks.completedOccurrences(taskID: task.id).count == 2)
        #expect(try tasks.completedOccurrences(taskID: task.id).contains { $0.occurrence.outcome == .skipped })
        let revision = savedHistory.revision
        try documents.markOpened(id: source.id)
        #expect(try documents.requireDocument(id: history.id).revision == revision)
    }

    @Test func historyEditsTitlesNotesAndDeletedEntriesSurviveFurtherCompletions() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        var task = DocumentTaskMetadata()
        task.scheduledAt = date("2026-10-20T09:00:00Z").timeIntervalSince1970
        task.recurrence = TaskRepeatRule(frequency: .daily, timeZoneID: "UTC", anchor: task.scheduledAt!)
        let source = try documents.create(DocumentDraft(title: "Parent", tipTapJSON: json(task)))
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true)
        let historyID = DocumentTaskPages.historyID(task.id), detailID = DocumentTaskPages.detailID(task.id)
        let history = try documents.requireDocument(id: historyID)
        var object = TipTapContentAnalyzer.documentObject(from: history.tipTapJSON)
        // Deleting the entry must not delete the watermark or resurrect the row later.
        object["content"] = [["type": "paragraph", "attrs": ["id": "my-note"], "content": [["type": "text", "text": "My editable notes"]]]]
        _ = try documents.saveEditorJSON(id: historyID, canonicalJSON: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        _ = try documents.updateTitle(id: historyID, title: "My history")
        _ = try documents.updateTitle(id: detailID, title: "My task title")
        let current = try #require(tasks.all().first)
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: current.metadata.occurrenceID, completed: true, skipped: true)
        let saved = try documents.requireDocument(id: historyID)
        #expect(saved.title == "My history" && saved.plainText.contains("My editable notes"))
        #expect(!saved.plainText.contains("completed on") && saved.plainText.contains("skipped on"))
        #expect(try documents.requireDocument(id: detailID).title == "My task title")
        // Undoing the source occurrences retracts generated rows, never the user's note.
        _ = try documents.saveEditorJSON(id: source.id, canonicalJSON: json(task))
        let undone = try documents.requireDocument(id: historyID)
        #expect(undone.plainText.contains("My editable notes") && !undone.plainText.contains("skipped on"))
    }

    @Test func terminalSkipStaysClosedAndCopiesStartWithIndependentEmptyHistoryPages() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        var task = DocumentTaskMetadata()
        task.reminderEnabled = true
        task.scheduledAt = date("2026-10-21T09:00:00Z").timeIntervalSince1970
        let source = try documents.create(DocumentDraft(title: "Parent", tipTapJSON: json(task)))
        _ = try tasks.setCompleted(taskID: task.id, occurrenceID: task.occurrenceID, completed: true, skipped: true)
        let saved = try #require(tasks.all().first)
        #expect(saved.checked && saved.metadata.isSkipped)
        #expect(try tasks.upcoming(from: date("2026-10-20T00:00:00Z")).isEmpty)
        let originalHistoryID = DocumentTaskPages.historyID(task.id)
        let originalHistory = try documents.requireDocument(id: originalHistoryID)
        var object = TipTapContentAnalyzer.documentObject(from: originalHistory.tipTapJSON)
        var body = object["content"] as? [[String: Any]] ?? []
        body.append(["type": "paragraph", "content": [["type": "text", "text": "Copy my notes"]]])
        object["content"] = body
        _ = try documents.saveEditorJSON(id: originalHistoryID, canonicalJSON: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        let authoredChild = try documents.create(DocumentDraft(title: "Task notes page", parentDocumentID: DocumentTaskPages.detailID(task.id)))
        let copied = try documents.duplicate(id: source.id)
        let copiedTask = try #require(tasks.tasks(documentID: copied.id).first)
        #expect(copiedTask.id != task.id && copiedTask.metadata.history.isEmpty)
        let children = try documents.children(of: copied.id)
        #expect(children.count == 1 && children[0].id == DocumentTaskPages.detailID(copiedTask.id))
        let copiedHistory = try documents.requireDocument(id: DocumentTaskPages.historyID(copiedTask.id))
        #expect(copiedHistory.plainText.contains("Copy my notes") && !copiedHistory.plainText.contains("skipped on"))
        let copiedChildren = try documents.children(of: children[0].id)
        #expect(copiedChildren.contains { $0.title == authoredChild.title && $0.id != authoredChild.id })
    }

    @Test func taskHistoryLinksRequestASheetWithoutNavigatingOrChangingHistory() throws {
        let database = try AppDatabase.makeInMemory()
        let documents = DocumentRepository(database: database)
        let tasks = DocumentTaskRepository(database: database)
        let task = DocumentTaskMetadata()
        let source = try documents.create(DocumentDraft(title: "Not the task name", tipTapJSON: json(task)))
        let model = DocumentEditorModel(documentRepository: documents, snapshotRepository: SnapshotRepository(database: database))
        model.prepare(document: source)
        let before = try documents.requireDocument(id: source.id).tipTapJSON
        model.session.onEvent?(.requestOpenPage(documentID: DocumentTaskPages.detailID(task.id)))
        #expect(model.taskHistoryRequest?.task.text == "Rich task text")
        #expect(model.taskHistoryRequest?.id == task.id && model.nestedPageToOpen == nil)
        #expect(try documents.requireDocument(id: source.id).tipTapJSON == before)
        #expect(try tasks.completedOccurrences().isEmpty)

        model.taskHistoryRequest = nil
        let unrelated = try documents.create(DocumentDraft(title: "Other", tipTapJSON: json(DocumentTaskMetadata())))
        let otherTask = try #require(tasks.tasks(documentID: unrelated.id).first)
        model.session.onEvent?(.requestOpenPage(documentID: DocumentTaskPages.detailID(otherTask.id)))
        #expect(model.taskHistoryRequest == nil && model.nestedPageToOpen == nil)

        let child = try documents.create(DocumentDraft(title: "Ordinary nested page", parentDocumentID: source.id))
        model.session.onEvent?(.requestOpenPage(documentID: child.id))
        #expect(model.nestedPageToOpen?.id == child.id && model.taskHistoryRequest == nil)

        let detail = try documents.requireDocument(id: DocumentTaskPages.detailID(task.id))
        let detailModel = DocumentEditorModel(documentRepository: documents, snapshotRepository: SnapshotRepository(database: database))
        detailModel.prepare(document: detail)
        detailModel.session.onEvent?(.requestOpenPage(documentID: DocumentTaskPages.historyID(task.id)))
        #expect(detailModel.taskHistoryRequest?.id == task.id && detailModel.nestedPageToOpen == nil)
    }

    @Test func sheetTimestampsKeepTheirEventZoneAndUseAMPM() throws {
        let occurrence = TaskCompletedOccurrence(id: "event", scheduledAt: nil,
            completedAt: date("2026-10-21T21:14:00Z").timeIntervalSince1970, timeZoneID: "UTC")
        let display = TaskHistoryTimestamp(occurrence: occurrence, locale: Locale(identifier: "en_US"))
        #expect(display.date == "October 21, 2026" && display.weekday == "Wednesday")
        #expect(display.time == "9:14 PM")
        var morning = occurrence
        morning.completedAt = date("2026-10-21T09:14:00Z").timeIntervalSince1970
        #expect(TaskHistoryTimestamp(occurrence: morning).time == "9:14 AM")
        var legacy = occurrence
        legacy.timeZoneID = nil
        #expect(TaskHistoryTimestamp(occurrence: legacy, fallbackTimeZoneID: "America/Chicago").time == "4:14 PM")
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
