import Combine
import Foundation
import EventKit

@MainActor
final class CalendarModel: ObservableObject {
    @Published var mode: CalendarAgendaMode = .week
    @Published private(set) var selectedDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var selectionRevision = 0
    private(set) var scrollTargetDate: Date?
    private var appliedSelectionRevision = 0
    @Published private(set) var expandedDays: Set<Date> = [Calendar.current.startOfDay(for: Date())]
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var tasks: [CalendarTaskEntry] = []
    @Published private(set) var documents: [String: DocumentRecord] = [:]
    @Published private(set) var eventNotes: [String: DocumentRecord] = [:]
    @Published private(set) var dailyNotes: [String: DocumentRecord] = [:]
    @Published private(set) var access: CalendarAccess = .notRequested
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var completingTasks: Set<String> = []
    @Published var selectedEvent: CalendarEvent?
    @Published var errorMessage: String?
    private let apple = AppleCalendarService()
    private let taskRepository: DocumentTaskRepository
    private let documentRepository: DocumentRepository
    private let noteRepository: CalendarEventNoteRepository
    private let dailyNoteRepository: DailyNoteRepository
    private let enabled: Bool
    private var observers: [NSObjectProtocol] = []
    private var loading: Task<Void, Never>?
    private var generation = 0
    private var isVisible = false
    var completeTask: ((String, String, Bool) async throws -> Void)?

    init(tasks: DocumentTaskRepository, documents: DocumentRepository, notes: CalendarEventNoteRepository, database: AppDatabase, dailyNotes: DailyNoteRepository? = nil) {
        taskRepository = tasks
        documentRepository = documents
        noteRepository = notes
        dailyNoteRepository = dailyNotes ?? DailyNoteRepository(database: database, templates: TemplateRepository(database: database))
        enabled = !database.isInMemory
        for name in [Notification.Name.vellixTasksChanged, .pennedCalendarNotesChanged, .EKEventStoreChanged,
                     .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            let object: Any? = (name == .vellixTasksChanged || name == .pennedCalendarNotesChanged) ? database : nil
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        loading?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var calendar: Calendar { .autoupdatingCurrent }
    var week: DateInterval { CalendarAgenda.week(containing: selectedDate, calendar: calendar) }
    var days: [Date] { CalendarAgenda.days(in: week, calendar: calendar) }
    var unscheduledTasks: [CalendarTaskEntry] { tasks.filter { $0.kind == .current && $0.scheduledDate == nil } }

    func initialScrollDate(now: Date = Date()) -> Date {
        // A date opened from a Daily Note takes precedence over the normal opening position.
        if selectionRevision > appliedSelectionRevision, let scrollTargetDate { return scrollTargetDate }
        return CalendarAgenda.initialVisibleDay(in: week, now: now, calendar: calendar)
    }

    func acknowledgeScrollRequest() { appliedSelectionRevision = selectionRevision }

    func select(_ date: Date) {
        updateSelection(date, scrollToWeekStart: false)
    }

    private func updateSelection(_ date: Date, scrollToWeekStart: Bool) {
        let oldWeek = week
        selectedDate = calendar.startOfDay(for: date)
        expandedDays.insert(selectedDate)
        scrollTargetDate = scrollToWeekStart ? week.start : selectedDate
        selectionRevision += 1
        if week != oldWeek { refresh() }
    }

    func navigate(_ direction: Int) {
        if let date = calendar.date(byAdding: .day, value: direction * (mode == .week ? 7 : 1), to: selectedDate) {
            updateSelection(date, scrollToWeekStart: mode == .week)
        }
    }

    func today() { select(Date()) }
    func activate() { isVisible = true; refresh() }
    func deactivate() {
        isVisible = false
        generation += 1
        loading?.cancel()
        loading = nil
        isLoading = false
    }
    func spaceDidChange() {
        generation += 1
        loading?.cancel(); loading = nil
        tasks = []; documents = [:]; eventNotes = [:]; dailyNotes = [:]; selectedEvent = nil
        completingTasks = []; errorMessage = nil; isLoading = false
        refresh()
    }
    func toggleDay(_ date: Date) {
        if expandedDays.contains(date) { expandedDays.remove(date) } else { expandedDays.insert(date) }
    }
    func expandAll() { expandedDays.formUnion(days) }
    func collapseAll() { expandedDays.subtract(days) }

    func events(on date: Date) -> [CalendarEvent] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        return events.filter { $0.intersects(day) }
    }

    func tasks(on date: Date) -> [CalendarTaskEntry] {
        tasks.filter { $0.agendaDate.map { calendar.isDate($0, inSameDayAs: date) } == true }
    }

    func dailyNote(on date: Date) -> DocumentRecord? { dailyNotes[DailyNoteDay(date: date).key] }

    func refresh() {
        guard isVisible else { return }
        generation += 1
        let expected = generation
        let range = week
        let taskRepository = taskRepository, documentRepository = documentRepository, noteRepository = noteRepository
        loading?.cancel()
        isLoading = true
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let access = self.enabled ? await self.apple.access() : .unavailable
                let events = access == .allowed ? await self.apple.events(in: range) : []
                guard !Task.isCancelled, self.generation == expected else { return }
                // The existing repositories are main-actor isolated by project convention.
                // EventKit's synchronous fetch runs separately in AppleCalendarService.
                let entries = try CalendarAgenda.taskEntries(taskRepository.all(), in: range)
                let ids = Set(entries.map { $0.task.documentID })
                var documents: [String: DocumentRecord] = [:]
                for id in ids { if let document = try documentRepository.document(id: id) { documents[id] = document } }
                let notes = try noteRepository.notes(for: events)
                let dailyNotes = try dailyNoteRepository.notes(from: DailyNoteDay(date: range.start), through: DailyNoteDay(date: self.days.last ?? range.start))
                guard !Task.isCancelled, self.generation == expected else { return }
                self.access = access
                self.events = events
                self.tasks = entries
                self.documents = documents
                self.eventNotes = notes
                self.dailyNotes = dailyNotes
                if access != .allowed { self.selectedEvent = nil }
                else if let selected = self.selectedEvent,
                   let updated = events.first(where: { $0.id == selected.id || $0.identity.localID == selected.identity.localID && $0.identity.occurrenceKey == selected.identity.occurrenceKey }) {
                    self.selectedEvent = updated
                }
                self.isLoading = false
                self.loading = nil
            } catch {
                guard !Task.isCancelled, self.generation == expected else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.loading = nil
            }
        }
    }

    func refreshAndWait() async {
        refresh()
        while let loading { await loading.value }
    }

    func requestAccess() async {
        guard enabled, !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do { access = try await apple.requestAccess(); refresh() }
        catch { errorMessage = error.localizedDescription; access = await apple.access() }
    }

    func complete(_ entry: CalendarTaskEntry) async {
        guard entry.canComplete, !completingTasks.contains(entry.task.id), let completeTask else { return }
        completingTasks.insert(entry.task.id)
        defer { completingTasks.remove(entry.task.id) }
        do { try await completeTask(entry.task.id, entry.occurrenceID, !entry.isCompleted); refresh() }
        catch { errorMessage = error.localizedDescription; refresh() }
    }
}
