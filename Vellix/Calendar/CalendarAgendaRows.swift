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
                    size: CGSize(width: 37, height: 48), cover: document.cover, attachmentStore: environment.attachmentStore)
                    .equatable()
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(.subheadline, design: document.appearance.fontStyle.design).weight(.bold))
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
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(event.calendarColor)
                    .frame(width: 3).frame(minHeight: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(event.timeLabel(on: day)).font(.subheadline).foregroundStyle(.secondary)
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
            .font(.system(.body, design: .rounded)).strikethrough(entry.isCompleted)
            .foregroundStyle(entry.isCompleted ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var scheduledTime: some View {
        if let date = entry.scheduledDate {
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

    var body: some View {
        let events = model.events(on: day)
        let tasks = model.tasks(on: day)
        LazyVStack(alignment: .leading, spacing: 0) {
            if let note = model.dailyNote(on: day) {
                CalendarDocumentPreview(document: note) { environment.openCalendarDocument(note) }
                Divider()
            }
            ForEach(events) { event in
                CalendarEventRow(event: event, day: day) { model.selectedEvent = event }
                if let note = model.eventNotes[event.id], !note.isTrashed {
                    CalendarDocumentPreview(document: note) { environment.openCalendarDocument(note) }
                        .padding(.leading, 15)
                }
                if event.id != events.last?.id || !tasks.isEmpty {
                    Divider().overlay(VellixSurface.controlInk.opacity(0.04))
                }
            }
            ForEach(tasks) { entry in
                CalendarTaskRow(model: model, entry: entry, showsDocumentBadge: true)
                if entry.id != tasks.last?.id {
                    Divider().overlay(VellixSurface.controlInk.opacity(0.04))
                }
            }
            if events.isEmpty && tasks.isEmpty && model.dailyNote(on: day) == nil {
                Text(model.isLoading ? "Loading..." : "Nothing scheduled")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
