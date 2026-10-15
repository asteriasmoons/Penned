import SwiftUI

enum CalendarStyle {
    static let accent = Color(vellixHex: "#B59AD9")
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
    private var isCompleting: Bool { entry.canComplete && model.completingTasks.contains(entry.task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Button { Task { await model.complete(entry) } } label: {
                    ZStack {
                        Circle().stroke(entry.isCompleted ? CalendarStyle.accent : .secondary, lineWidth: 2)
                        if isCompleting { ProgressView().controlSize(.mini) }
                        else if entry.isCompleted {
                            LibraryIcon(name: "checkwavy", size: 19).foregroundStyle(CalendarStyle.accent)
                        }
                    }.frame(width: 23, height: 23).frame(width: 44, height: 44, alignment: .top)
                        .padding(.top, 2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.canComplete || isCompleting)
                .accessibilityLabel(entry.kind == .completed ? "Completed occurrence" : entry.kind == .projected ? "Future occurrence" : entry.isCompleted ? "Mark task incomplete" : "Complete task")
                .accessibilityHint(entry.kind == .projected ? "This future occurrence becomes available after the current occurrence is completed." : "")
                .help(entry.kind == .projected ? "Complete the current occurrence first" : "Toggle task completion")
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.task.text.isEmpty ? "Untitled Task" : entry.task.text)
                        .font(.system(.body, design: .rounded)).strikethrough(entry.isCompleted)
                        .foregroundStyle(entry.isCompleted ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = entry.scheduledDate {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if entry.task.metadata.reminderEnabled {
                    LibraryIcon(name: "clockwavy", size: 17).foregroundStyle(CalendarStyle.accent)
                        .padding(.top, 3).accessibilityLabel("Reminder attached")
                }
            }
            if let document = model.documents[entry.task.documentID] {
                CalendarDocumentPreview(document: document) { environment.openCalendarDocument(document) }
                    .padding(.leading, 50)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("calendar-task-\(entry.id)")
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
            ForEach(events) { event in
                CalendarEventRow(event: event, day: day) { model.selectedEvent = event }
                if let note = model.eventNotes[event.id], !note.isTrashed {
                    CalendarDocumentPreview(document: note) { environment.openCalendarDocument(note) }
                        .padding(.leading, 15)
                }
                if event.id != events.last?.id || !tasks.isEmpty {
                    Divider().overlay(Color.white.opacity(0.04))
                }
            }
            ForEach(tasks) { entry in
                CalendarTaskRow(model: model, entry: entry)
                if entry.id != tasks.last?.id {
                    Divider().overlay(Color.white.opacity(0.04))
                }
            }
            if events.isEmpty && tasks.isEmpty {
                Text(model.isLoading ? "Loading..." : "Nothing scheduled")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
