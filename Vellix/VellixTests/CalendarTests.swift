import Foundation
import GRDB
import Testing
@testable import Vellix

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
        #expect(entries.filter(\.canComplete).count == 1)
        #expect(entries.first?.occurrenceID == metadata.occurrenceID)
        #expect(metadata.history.isEmpty)
        let completed = try metadata.completing(true)
        var updated = task
        updated.metadata = completed.metadata
        let next = try CalendarAgenda.taskEntries([updated], in: range)
        #expect(next.count == 4)
        #expect(next.filter(\.isCompleted).count == 1)
        #expect(next.first(where: \.canComplete)?.scheduledDate == date("2026-10-14T09:00:00Z"))
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
