import Foundation

nonisolated enum TaskRepeatFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekdays, weekly, monthly, yearly

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Every Weekday"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

nonisolated struct TaskRepeatRule: Codable, Equatable, Sendable {
    var frequency: TaskRepeatFrequency
    var interval: Int = 1
    var weekdays: [Int] = [] // Foundation weekdays: Sunday = 1.
    var hour: Int = 9
    var minute: Int = 0
    var timeZoneID: String = TimeZone.current.identifier
    var anchorDay: Int?
    var anchorMonth: Int?
    var anchor: Double

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    var label: String {
        guard interval > 1 else { return frequency.title }
        let unit: String
        switch frequency {
        case .daily, .weekdays: unit = "Days"
        case .weekly: unit = "Weeks"
        case .monthly: unit = "Months"
        case .yearly: unit = "Years"
        }
        return "Every \(interval) \(unit)"
    }

    func validated() throws -> Self {
        guard (1...365).contains(interval), (0...23).contains(hour), (0...59).contains(minute),
              anchor.isFinite, TimeZone(identifier: timeZoneID) != nil,
              (frequency != .weekdays || interval == 1),
              anchorDay.map({ (1...31).contains($0) }) ?? true,
              anchorMonth.map({ (1...12).contains($0) }) ?? true,
              weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw DocumentTaskError.invalidSchedule
        }
        return self
    }

    // Resolve wall-clock time using Calendar's DST policy, not fixed 24-hour durations.
    private func timed(_ day: Date) throws -> Date {
        let start = calendar.startOfDay(for: day)
        guard let date = calendar.nextDate(after: start.addingTimeInterval(-1),
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              calendar.isDate(date, inSameDayAs: day) else { throw DocumentTaskError.invalidSchedule }
        return date
    }

    func first(onOrAfter date: Date) throws -> Date {
        _ = try validated()
        var day = date
        if frequency == .monthly || frequency == .yearly {
            let original = calendar.dateComponents([.month, .day], from: Date(timeIntervalSince1970: anchor))
            var parts = calendar.dateComponents([.year, .month], from: date)
            if frequency == .yearly { parts.month = anchorMonth ?? original.month }
            parts.day = 1
            guard let month = calendar.date(from: parts), let range = calendar.range(of: .day, in: .month, for: month) else {
                throw DocumentTaskError.invalidSchedule
            }
            parts.day = min(anchorDay ?? original.day ?? 1, range.count)
            guard let selected = calendar.date(from: parts) else { throw DocumentTaskError.invalidSchedule }
            day = selected
        }
        let candidate = try timed(day)
        let weekday = calendar.component(.weekday, from: candidate)
        let selectedWeekdays = weekdays.isEmpty ? [calendar.component(.weekday, from: Date(timeIntervalSince1970: anchor))] : weekdays
        let allowed = frequency == .weekdays ? (2...6).contains(weekday)
            : (frequency != .weekly || selectedWeekdays.contains(weekday))
        var activeWeek = true
        if frequency == .weekly,
           let start = calendar.dateInterval(of: .weekOfYear, for: Date(timeIntervalSince1970: anchor))?.start,
           let week = calendar.dateInterval(of: .weekOfYear, for: candidate)?.start {
            activeWeek = ((calendar.dateComponents([.day], from: start, to: week).day ?? 0) / 7) % interval == 0
        }
        if candidate >= date, allowed, activeWeek { return candidate }
        return try next(after: candidate)
    }

    func next(after scheduledDate: Date) throws -> Date {
        _ = try validated()
        let cal = calendar
        let original = Date(timeIntervalSince1970: anchor)
        switch frequency {
        case .daily:
            guard let day = cal.date(byAdding: .day, value: interval, to: scheduledDate) else {
                throw DocumentTaskError.invalidSchedule
            }
            return try timed(day)
        case .weekdays, .weekly:
            let days = frequency == .weekdays ? Array(2...6)
                : (weekdays.isEmpty ? [cal.component(.weekday, from: original)] : weekdays)
            guard let anchorWeek = cal.dateInterval(of: .weekOfYear, for: original)?.start else {
                throw DocumentTaskError.invalidSchedule
            }
            for offset in 1...(interval * 7 + 7) {
                guard let day = cal.date(byAdding: .day, value: offset, to: scheduledDate),
                      days.contains(cal.component(.weekday, from: day)) else { continue }
                if frequency == .weekly {
                    guard let week = cal.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
                    let distance = cal.dateComponents([.day], from: anchorWeek, to: week).day ?? 0
                    if (distance / 7) % interval != 0 { continue }
                }
                return try timed(day)
            }
            throw DocumentTaskError.invalidSchedule
        case .monthly, .yearly:
            let anchorParts = cal.dateComponents([.month, .day], from: original)
            var parts = cal.dateComponents([.year, .month], from: scheduledDate)
            parts.day = 1
            guard let month = cal.date(from: parts),
                  let next = cal.date(byAdding: frequency == .monthly ? .month : .year,
                                      value: interval, to: month) else { throw DocumentTaskError.invalidSchedule }
            parts = cal.dateComponents([.year, .month], from: next)
            if frequency == .yearly { parts.month = anchorMonth ?? anchorParts.month }
            parts.day = 1
            guard let targetMonth = cal.date(from: parts), let range = cal.range(of: .day, in: .month, for: targetMonth) else {
                throw DocumentTaskError.invalidSchedule
            }
            parts.day = min(anchorDay ?? anchorParts.day ?? 1, range.count)
            guard let day = cal.date(from: parts) else { throw DocumentTaskError.invalidSchedule }
            return try timed(day)
        }
    }
}

nonisolated struct TaskCompletedOccurrence: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var scheduledAt: Double?
    var completedAt: Double
}

nonisolated struct DocumentTaskMetadata: Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var occurrenceID: String = UUID().uuidString
    var scheduledAt: Double?
    var reminderEnabled = false
    var recurrence: TaskRepeatRule?
    var history: [TaskCompletedOccurrence] = []

    var notificationID: String { "vellix.task.\(id).\(occurrenceID)" }
    var scheduledDate: Date? { scheduledAt.map(Date.init(timeIntervalSince1970:)) }

    func completing(_ completed: Bool, at date: Date = Date()) throws -> (metadata: Self, checked: Bool) {
        var copy = self
        if !completed {
            if history.contains(where: { $0.id == occurrenceID }) { copy.occurrenceID = UUID().uuidString }
            return (copy, false)
        }
        guard !history.contains(where: { $0.id == occurrenceID }) else { return (copy, recurrence == nil) }
        copy.history.append(TaskCompletedOccurrence(id: occurrenceID, scheduledAt: scheduledAt,
                                                     completedAt: date.timeIntervalSince1970))
        if let recurrence {
            // A repeating occurrence is always anchored, even without a notification.
            guard let scheduledDate else { throw DocumentTaskError.invalidSchedule }
            copy.scheduledAt = try recurrence.next(after: scheduledDate).timeIntervalSince1970
            copy.occurrenceID = UUID().uuidString
            return (copy, false)
        }
        return (copy, true)
    }

    func independent() -> Self {
        var copy = self
        copy.id = UUID().uuidString
        copy.occurrenceID = UUID().uuidString
        copy.history = []
        return copy
    }

    static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let task = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: task.id) != nil, UUID(uuidString: task.occurrenceID) != nil else { return nil }
        return task
    }

    var object: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}

nonisolated struct DocumentTaskContext: Equatable, Identifiable, Sendable {
    var blockID: String
    var checked: Bool
    var metadata: DocumentTaskMetadata?
    var id: String { blockID }

    static func decode(_ payload: [String: Any]) -> Self? {
        guard let id = payload["blockId"] as? String, !id.isEmpty else { return nil }
        return Self(blockID: id, checked: payload["checked"] as? Bool ?? false,
                    metadata: DocumentTaskMetadata.decode(payload["task"]))
    }
}

nonisolated enum DocumentTaskError: LocalizedError {
    case invalidSchedule, missingTask, staleOccurrence
    var errorDescription: String? {
        switch self {
        case .invalidSchedule: return "The task schedule is invalid. Choose a valid repeat interval and time."
        case .missingTask: return "This checklist task no longer exists."
        case .staleOccurrence: return "This task occurrence has already changed. Refresh the task before completing it."
        }
    }
}
