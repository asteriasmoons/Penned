import Foundation
import CryptoKit

nonisolated enum CalendarAgendaMode: String, CaseIterable, Identifiable, Sendable {
    case week = "Week", day = "Day"
    var id: String { rawValue }
}

nonisolated enum CalendarAccess: Sendable {
    case notRequested, allowed, denied, restricted, unavailable
}

nonisolated struct CalendarEventIdentity: Codable, Hashable, Sendable {
    var calendarID: String
    var sourceID: String
    var localID: String
    var externalID: String?
    var occurrenceDate: Date?
    var floatingOccurrenceKey: String?

    var occurrenceKey: String { floatingOccurrenceKey ?? occurrenceDate.map { String($0.timeIntervalSince1970) } ?? "single" }

    static func floatingKey(for date: Date, allDay: Bool, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        if allDay { return "floating-day:" + day }
        return "floating-time:\(day)T\(parts.hour ?? 0):\(parts.minute ?? 0):\(parts.second ?? 0)"
    }
    var key: String {
        // Server IDs are calendar-scoped: shared/imported copies in different calendars
        // must not accidentally share a note. Original dates distinguish recurring instances.
        let components = [sourceID, calendarID, externalID == nil ? "local" : "external", externalID ?? localID, occurrenceKey]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct CalendarEvent: Identifiable, Equatable, Sendable {
    var identity: CalendarEventIdentity
    var title: String
    var calendarTitle: String
    var colorRed: Double
    var colorGreen: Double
    var colorBlue: Double
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var availability: String?
    var status: String?
    var organizer: String?
    var timeZoneID: String?
    var lastModified: Date?
    var id: String { identity.key }

    func intersects(_ interval: DateInterval) -> Bool {
        start < interval.end && max(end, start.addingTimeInterval(1)) > interval.start
    }

    func timeLabel(on day: Date, calendar: Calendar = .current) -> String {
        if isAllDay { return "All Day" }
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return "" }
        let startsBefore = start < interval.start
        let endsAfter = end >= interval.end
        if startsBefore && endsAfter { return "Continues all day" }
        if startsBefore { return "Until " + end.formatted(date: .omitted, time: .shortened) }
        if endsAfter { return start.formatted(date: .omitted, time: .shortened) + " - continues" }
        return start.formatted(date: .omitted, time: .shortened) + " - " + end.formatted(date: .omitted, time: .shortened)
    }
}

nonisolated struct CalendarTaskEntry: Identifiable, Sendable {
    enum Kind: Sendable { case current, projected, completed }
    var task: DocumentTaskRecord
    var occurrenceID: String
    var scheduledDate: Date?
    var completedDate: Date?
    var kind: Kind
    var id: String { task.id + ":" + occurrenceID }
    var agendaDate: Date? { scheduledDate ?? completedDate }
    var isCompleted: Bool { kind == .completed || (kind == .current && task.checked) }
    var canComplete: Bool { kind == .current }
}

nonisolated enum CalendarAgenda {
    static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86400)
    }

    static func days(in week: DateInterval, calendar: Calendar = .current) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    static func initialVisibleDay(in week: DateInterval, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return today >= week.start && today < week.end ? today : week.start
    }

    static func uniqueEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var unique: [String: CalendarEvent] = [:]
        for event in events {
            if let old = unique[event.id] {
                let modified = event.lastModified ?? .distantPast, previous = old.lastModified ?? .distantPast
                if modified < previous || (modified == previous && event.start > old.start) { continue }
            }
            unique[event.id] = event
        }
        return unique.values.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    static func taskEntries(_ tasks: [DocumentTaskRecord], in range: DateInterval) throws -> [CalendarTaskEntry] {
        var entries: [CalendarTaskEntry] = []
        for task in tasks where task.isActive && !task.isTemplate {
            let metadata = task.metadata
            let current = metadata.scheduledDate
            if current.map({ $0 >= range.start && $0 < range.end }) ?? true {
                entries.append(CalendarTaskEntry(task: task, occurrenceID: metadata.occurrenceID,
                    scheduledDate: current, kind: .current))
            }
            for completed in metadata.history where completed.id != metadata.occurrenceID {
                let scheduled = completed.scheduledAt.map(Date.init(timeIntervalSince1970:))
                let completedDate = Date(timeIntervalSince1970: completed.completedAt)
                let date = scheduled ?? completedDate
                if date >= range.start && date < range.end {
                    entries.append(CalendarTaskEntry(task: task, occurrenceID: completed.id,
                        scheduledDate: scheduled, completedDate: completedDate, kind: .completed))
                }
            }
            guard !task.checked, let rule = metadata.recurrence, let current else { continue }
            var next = try rule.next(after: current)
            // Seek distant daily/weekly schedules without walking every intervening day.
            if next < range.start {
                switch rule.frequency {
                case .daily:
                    let distance = rule.calendar.dateComponents([.day], from: next, to: range.start).day ?? 0
                    let steps = max(0, distance / rule.interval - 1)
                    if let day = rule.calendar.date(byAdding: .day, value: steps * rule.interval, to: next) {
                        next = try rule.first(onOrAfter: rule.calendar.startOfDay(for: day))
                    }
                case .weekdays, .weekly: next = try rule.first(onOrAfter: range.start)
                case .monthly, .yearly: break
                }
            }
            while next < range.end {
                if next >= range.start {
                    entries.append(CalendarTaskEntry(task: task,
                        occurrenceID: "scheduled:" + String(next.timeIntervalSince1970), scheduledDate: next, kind: .projected))
                }
                let following = try rule.next(after: next)
                guard following > next else { throw DocumentTaskError.invalidSchedule }
                next = following
            }
        }
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.id).inserted }.sorted {
            if $0.agendaDate != $1.agendaDate { return ($0.agendaDate ?? .distantFuture) < ($1.agendaDate ?? .distantFuture) }
            return $0.id < $1.id
        }
    }
}
