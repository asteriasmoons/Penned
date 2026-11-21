import Foundation
@preconcurrency import EventKit
import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// EventKit objects never leave this actor. Views receive immutable, Sendable snapshots.
actor AppleCalendarService {
    private lazy var store = EKEventStore()

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .allowed
        case .notDetermined, .writeOnly: return .notRequested
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    func requestAccess() async throws -> CalendarAccess {
        _ = try await store.requestFullAccessToEvents()
        return access()
    }

    func events(in range: DateInterval) -> [CalendarEvent] {
        guard access() == .allowed else { return [] }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return CalendarAgenda.uniqueEvents(store.events(matching: predicate).compactMap(snapshot))
    }

    // Resolve by the original calendar and occurrence, never by title or date
    // alone. EventKit can change local identifiers after a calendar sync, so
    // use the external ID only within the same source/calendar.
    func linkedEvent(identity: CalendarEventIdentity, lastKnownStart: Date) -> CalendarEvent? {
        guard access() == .allowed else { return nil }
        let calendar = store.calendars(for: .event).first {
            $0.calendarIdentifier == identity.calendarID &&
            $0.source.sourceIdentifier == identity.sourceID
        }
        guard let calendar else { return nil }
        func matches(_ event: CalendarEvent) -> Bool {
            let actual = event.identity
            guard actual.calendarID == identity.calendarID, actual.sourceID == identity.sourceID else { return false }
            let sameEvent = actual.localID == identity.localID ||
                (identity.externalID != nil && actual.externalID == identity.externalID)
            return sameEvent && actual.occurrenceKey == identity.occurrenceKey
        }
        if identity.occurrenceDate == nil && identity.floatingOccurrenceKey == nil,
           let direct = store.calendarItem(withIdentifier: identity.localID) as? EKEvent,
           let event = snapshot(direct), matches(event) { return event }
        let anchor = identity.occurrenceDate ?? lastKnownStart
        let range = DateInterval(start: anchor.addingTimeInterval(-366 * 86_400),
                                 end: anchor.addingTimeInterval(366 * 86_400))
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: [calendar])
        return store.events(matching: predicate).compactMap(snapshot).first(where: matches)
    }

    private func snapshot(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar,
              event.status != .canceled else { return nil }
        let color = calendar.cgColor?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let parts = color?.components ?? [0.44, 0.31, 0.67, 1]
        let recurring = event.hasRecurrenceRules || event.isDetached
        let occurrenceDate = recurring ? (event.occurrenceDate ?? start) : nil
        // EventKit returns floating occurrences in the default time zone. Persist a
        // civil identity for them, not an absolute timestamp that changes on travel.
        let floatingKey = occurrenceDate.flatMap { date in
            event.isAllDay || event.timeZone == nil
                ? CalendarEventIdentity.floatingKey(for: date, allDay: event.isAllDay, timeZone: .current) : nil
        }
        let identity = CalendarEventIdentity(calendarID: calendar.calendarIdentifier,
            sourceID: calendar.source.sourceIdentifier, localID: event.calendarItemIdentifier,
            externalID: cleaned(event.calendarItemExternalIdentifier),
            occurrenceDate: occurrenceDate, floatingOccurrenceKey: floatingKey)
        let availability: String?
        switch event.availability {
        case .busy: availability = "Busy"
        case .free: availability = "Free"
        case .tentative: availability = "Tentative"
        case .unavailable: availability = "Unavailable"
        default: availability = nil
        }
        let status = event.status == .tentative ? "Tentative" : event.status == .confirmed ? "Confirmed" : nil
        return CalendarEvent(identity: identity, title: cleaned(event.title) ?? "Untitled Event",
            calendarTitle: calendar.title, colorRed: Double(parts[0]), colorGreen: Double(parts.count > 1 ? parts[1] : parts[0]),
            colorBlue: Double(parts.count > 2 ? parts[2] : parts[0]), start: start, end: end, isAllDay: event.isAllDay,
            location: cleaned(event.location), notes: cleaned(event.notes), url: event.url,
            availability: availability, status: status, organizer: cleaned(event.organizer?.name),
            timeZoneID: event.timeZone?.identifier, lastModified: event.lastModifiedDate)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

@MainActor
enum AppleCalendarNavigation {
    static func open(_ event: CalendarEvent) async throws {
        // Calendar has a date-navigation URL, not a public EventKit identifier deep-link API.
        // Open the event's date rather than inventing an undocumented event-ID URL.
        guard let url = URL(string: "calshow:" + String(event.start.timeIntervalSinceReferenceDate)) else { return }
        #if os(iOS)
        let opened = await UIApplication.shared.open(url)
        #elseif os(macOS)
        let opened = NSWorkspace.shared.open(url)
        #else
        let opened = false
        #endif
        if !opened { throw VellixError.impossibleMove("Apple Calendar could not be opened on this device.") }
    }

    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
