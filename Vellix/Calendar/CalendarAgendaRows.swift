import SwiftUI

enum CalendarStyle {
    static let accent = VellixSurface.lilac
}

extension CalendarEvent {
    var calendarColor: Color { Color(red: colorRed, green: colorGreen, blue: colorBlue) }
}

struct CalendarDocumentPreview: View {
    @EnvironmentObject private var environment: AppEnvironment
    let document: DocumentRecord
    var showsExcerpt = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                NestedPageThumbnail(json: document.tipTapJSON, title: document.title, appearance: document.appearance,
                    size: CGSize(width: 37, height: 48), cover: document.cover, attachmentStore: environment.attachmentStore, document: document, previews: environment.documentPreviews)
                    .equatable()
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(document.appearance.fontStyle.font(.subheadline, weight: .bold))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if showsExcerpt, !document.plainText.isEmpty {
                        Text(document.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(document.title)")
        .accessibilityIdentifier("calendar-document-\(document.id)")
    }
}

struct CalendarEventRow: View {
    let event: CalendarEvent
    let day: Date
    var showsTime = true
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(event.calendarColor)
                    .frame(width: 3).frame(minHeight: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if showsTime {
                        Text(event.timeLabel(on: day)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title), \(event.timeLabel(on: day)), \(event.calendarTitle)")
        .accessibilityIdentifier("calendar-event-\(event.id)")
    }
}

struct CalendarTaskRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: CalendarModel
    let entry: CalendarTaskEntry
    var showsDocumentBadge = false
    var emphasizesTitle = false
    var showsScheduledTime = true
    private var isCompleting: Bool { entry.canComplete && model.completingTasks.contains(entry.task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                TaskCompletionCircle(isChecked: entry.isCompleted, isSkipped: entry.isSkipped,
                    isEnabled: entry.canComplete && !isCompleting,
                    alignment: .top) { skipped in
                    Task { await model.complete(entry, skipped: skipped) }
                }
                .frame(width: showsDocumentBadge ? 19 : 44, height: 44, alignment: .top)
                .padding(.top, 2)
                .accessibilityHint(entry.kind == .projected ? "Completes this scheduled occurrence without changing earlier unfinished occurrences." : "")
                .accessibilityIdentifier("calendar-task-completion-\(entry.id)")
                .help("Click to complete; double-click to skip")
                taskDetails.frame(maxWidth: .infinity, alignment: .leading)
                if entry.task.metadata.reminderEnabled {
                    LibraryIcon(name: "clockwavy", size: 17).foregroundStyle(CalendarStyle.accent)
                        .padding(.top, 3).accessibilityLabel("Reminder attached")
                }
            }
            if !showsDocumentBadge, let document = model.documents[entry.task.documentID] {
                CalendarDocumentPreview(document: document) { environment.openCalendarDocument(document) }
                    .padding(.leading, 50)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("calendar-task-\(entry.id)")
    }

    private var taskTitle: some View {
        Text(entry.task.text.isEmpty ? "Untitled Task" : entry.task.text)
            .font(.system(.body, design: .rounded).weight(emphasizesTitle ? .bold : .regular))
            .strikethrough(entry.isCompleted)
            .foregroundStyle(entry.isCompleted ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var scheduledTime: some View {
        if showsScheduledTime, let date = entry.scheduledDate {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var taskDetails: some View {
        if !showsDocumentBadge {
            VStack(alignment: .leading, spacing: 5) { taskTitle; scheduledTime }
        } else {
            calendarTaskDetails
        }
    }

    @ViewBuilder private var calendarTaskDetails: some View {
        if let document = model.documents[entry.task.documentID] {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: model.mode == .week ? .firstTextBaseline : .lastTextBaseline, spacing: 10) {
                    taskTextAndTime.fixedSize(horizontal: true, vertical: true)
                    documentBadge(document).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    taskTextAndTime
                    documentBadge(document)
                }
            }
        } else {
            taskTextAndTime
        }
    }

    private var taskTextAndTime: some View {
        VStack(alignment: .leading, spacing: 4) {
            taskTitle
            scheduledTime
        }
    }

    private func documentBadge(_ document: DocumentRecord) -> some View {
        Button { environment.openCalendarDocument(document, returnToCalendar: true) } label: {
            HStack(spacing: 6) {
                LibraryIcon(name: "linedpages", size: 16).foregroundStyle(CalendarStyle.accent)
                Text(document.title).font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink).lineLimit(1)
                LibraryIcon(name: "chevright", size: 10).foregroundStyle(CalendarStyle.accent)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(VellixSurface.subtleFill, in: Capsule())
            .overlay { Capsule().strokeBorder(VellixSurface.hairline, lineWidth: 1) }
            .frame(minHeight: 44, alignment: .topLeading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(document.title)")
        .accessibilityIdentifier("calendar-task-document-\(entry.id)-\(document.id)")
    }
}

struct CalendarDayAgenda: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: CalendarModel
    let day: Date
    var showsTimeline = false
    @State private var expandedAllDayDates: Set<String> = []
    @ScaledMetric(relativeTo: .caption) private var timelineTimeWidth: CGFloat = 56

    var body: some View {
        let items = orderedItems
        LazyVStack(alignment: .leading, spacing: 0) {
            if let note = model.dailyNote(on: day) {
                CalendarDocumentPreview(document: note) { environment.openCalendarDocument(note) }
                Divider()
            }
            if showsTimeline {
                let allDay = items.filter(\.isAllDay)
                let tasks = items.filter(\.isTask)
                let events = items.filter { !$0.isAllDay && !$0.isTask }
                if !allDay.isEmpty { allDaySection(allDay) }
                if !events.isEmpty { timelineSection("Events", items: events) }
                if !tasks.isEmpty { timelineSection("Tasks", items: tasks) }
            } else {
                ForEach(items) { item in agendaItem(item) }
            }
            if items.isEmpty && model.dailyNote(on: day) == nil {
                Text(model.isLoading ? "Loading..." : "Nothing scheduled")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).background(.black)
    }

    // Presentation only: retain the real event/task records and their actions.
    // Week retains its flat agenda. Day groups these same records by kind,
    // keeping chronological order within All Day, timed Events, and Tasks.
    private var orderedItems: [CalendarAgendaItem] {
        let items = model.events(on: day).map(CalendarAgendaItem.event) +
            model.tasks(on: day).map(CalendarAgendaItem.task)
        return items.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    @ViewBuilder private func allDaySection(_ items: [CalendarAgendaItem]) -> some View {
        let dateKey = DailyNoteDay(date: day).key
        let expanded = expandedAllDayDates.contains(dateKey)
        let visible = expanded ? items : Array(items.prefix(2))
        if items.count > 2 {
            Button {
                if expandedAllDayDates.contains(dateKey) { expandedAllDayDates.remove(dateKey) }
                else { expandedAllDayDates.insert(dateKey) }
            } label: {
                HStack(spacing: 10) {
                    sectionHeading("All Day", count: items.count)
                    if !expanded {
                        Text("2 of \(items.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    LibraryIcon(name: expanded ? "chevup" : "chevdown", size: 14)
                        .foregroundStyle(CalendarStyle.accent)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse all-day events" : "Expand all-day events")
            .accessibilityValue("Showing \(visible.count) of \(items.count)")
            .accessibilityIdentifier("calendar-all-day-disclosure")
        } else {
            sectionHeading("All Day", count: items.count).frame(minHeight: 44)
        }
        ForEach(visible) { item in
            timelineItem(item, first: item.id == visible.first?.id, last: item.id == visible.last?.id, time: nil)
        }
    }

    @ViewBuilder private func timelineSection(_ title: String, items: [CalendarAgendaItem]) -> some View {
        sectionHeading(title, count: items.count).frame(minHeight: 44).padding(.top, 12)
        ForEach(items) { item in
            timelineItem(item, first: item.id == items.first?.id, last: item.id == items.last?.id,
                time: timelineTime(item))
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(.headline, design: .rounded).weight(.bold))
            Text("\(count)").font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func timelineItem(_ item: CalendarAgendaItem, first: Bool, last: Bool, time: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time ?? "All Day").font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: timelineTimeWidth, alignment: .trailing).padding(.top, 12)
            agendaItem(item)
                .padding(.leading, 26)
                .overlay(alignment: .leading) {
                    CalendarTimelineRail(first: first, last: last).frame(width: 18)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineTime(_ item: CalendarAgendaItem) -> String {
        switch item {
        case .event(let event):
            // Ongoing events enter this day's timeline at midnight; retain the
            // full continuation/end-time label in the actionable event row.
            return max(event.start, model.calendar.startOfDay(for: day))
                .formatted(date: .omitted, time: .shortened)
        case .task(let entry):
            return entry.agendaDate?.formatted(date: .omitted, time: .shortened) ?? "No time"
        }
    }

    @ViewBuilder private func agendaItem(_ item: CalendarAgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .event(let event):
                CalendarEventRow(event: event, day: day, showsTime: !showsTimeline || !event.isAllDay) {
                    model.selectedEvent = event
                }
                if let note = model.eventNotes[event.id], !note.isTrashed {
                    CalendarDocumentPreview(document: note) { environment.openCalendarDocument(note) }
                        .padding(.leading, 15)
                }
            case .task(let entry):
                CalendarTaskRow(model: model, entry: entry, showsDocumentBadge: true,
                    emphasizesTitle: showsTimeline, showsScheduledTime: !showsTimeline)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
        }
    }
}

private enum CalendarAgendaItem: Identifiable {
    case event(CalendarEvent)
    case task(CalendarTaskEntry)

    var id: String {
        switch self {
        case .event(let event): "event:" + event.id
        case .task(let entry): "task:" + entry.id
        }
    }

    var date: Date {
        switch self {
        case .event(let event): event.start
        case .task(let entry): entry.agendaDate ?? .distantFuture
        }
    }

    var isAllDay: Bool {
        if case .event(let event) = self { return event.isAllDay }
        return false
    }

    var isTask: Bool {
        if case .task = self { return true }
        return false
    }
}

private struct CalendarTimelineRail: View {
    let first: Bool
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(first ? .clear : Color.white.opacity(0.3)).frame(height: 24)
            Rectangle().fill(last ? .clear : Color.white.opacity(0.3))
        }
        .frame(width: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Circle().fill(CalendarStyle.accent.opacity(0.85))
                .overlay { Circle().strokeBorder(Color(red: 0.87, green: 0.65, blue: 1), lineWidth: 1.5) }
                .frame(width: 11, height: 11).padding(.top, 18.5)
                .shadow(color: CalendarStyle.accent.opacity(0.35), radius: 2)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
