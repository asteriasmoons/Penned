// Mac-target platform adapter. Based on Vellix/Calendar/CalendarEventDetailSheet.swift.
// iPhone/iPad implementations remain in their original target.
import SwiftUI

struct CalendarEventDetailSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: CalendarEvent
    @ObservedObject var model: CalendarModel
    @State private var creatingNote = false
    @State private var openingCalendar = false
    @State private var errorMessage: String?

    private var current: CalendarEvent { model.selectedEvent ?? event }
    private var note: DocumentRecord? { model.eventNotes[current.id] ?? model.eventNotes[event.id] }
    private var isAvailable: Bool { model.events.contains { $0.id == current.id } && model.access == .allowed }

    var body: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize { header; Divider().padding(.horizontal, 20) }
            ScrollView {
                VStack(spacing: 0) {
                if dynamicTypeSize.isAccessibilitySize { header; Divider().padding(.horizontal, 20) }
                VStack(alignment: .leading, spacing: 20) {
                    details.padding(16).pennedSheetField()
                    if !isAvailable {
                        Text("This event is no longer available in the visible calendar range.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button {
                        openingCalendar = true
                        Task {
                            defer { openingCalendar = false }
                            do { try await AppleCalendarNavigation.open(current) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            LibraryIcon(name: "mooncal", size: 20)
                            Text("Open in Calendar")
                            Spacer()
                            if openingCalendar { ProgressView() }
                            else { LibraryIcon(name: "chevright", size: 16) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(CalendarStyle.accent)
                        .disabled(openingCalendar || !isAvailable)
                    Divider()
                    Text("EVENT NOTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let note {
                        if note.isTrashed {
                            Text("Your event note is in Trash.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Restore Event Note") { environment.restore(note); model.refresh() }
                                .buttonStyle(MacActionButtonStyle()).controlSize(.large).tint(CalendarStyle.accent)
                        } else {
                            CalendarDocumentPreview(document: note, showsExcerpt: true) {
                                environment.openCalendarDocument(note)
                                dismiss()
                            }
                        }
                    } else {
                        Button {
                            guard !creatingNote else { return }
                            creatingNote = true
                            defer { creatingNote = false }
                            do {
                                let note = try environment.createEventNote(for: current)
                                environment.openCalendarDocument(note)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        } label: {
                            HStack(spacing: 10) {
                                LibraryIcon(name: "addwavy", size: 20)
                                Text("Create new Event Note").fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(CalendarStyle.accent, in: Capsule())
                        }.buttonStyle(.plain).foregroundStyle(VellixSurface.inverseInk)
                            .disabled(creatingNote || !isAvailable)
                    }
                }.padding(20)
                }
            }
        }
        .foregroundStyle(.primary)
        .pennedSheet(close: { dismiss() })
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .macAlert("Calendar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.title).font(.system(.title2, design: .rounded).weight(.black))
                    .fixedSize(horizontal: false, vertical: true)
                Label { Text(current.calendarTitle).font(.caption.weight(.semibold)) } icon: {
                    Circle().fill(current.calendarColor).frame(width: 8, height: 8)
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(current.calendarColor.opacity(0.16), in: Capsule())
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            detail("Date", value: dateLabel)
            if current.isAllDay { detail("Time", value: "All Day") }
            else {
                detail("Starts", value: current.start.formatted(date: .abbreviated, time: .shortened))
                detail("Ends", value: current.end.formatted(date: .abbreviated, time: .shortened))
            }
            detail("Calendar", value: current.calendarTitle)
            if let timeZone = current.timeZoneID { detail("Time Zone", value: timeZone) }
            if let availability = current.availability { detail("Availability", value: availability) }
            if let status = current.status { detail("Status", value: status) }
            if let organizer = current.organizer { detail("Organizer", value: organizer) }
            if let location = current.location { detail("Location", value: location) }
            if let notes = current.notes { detail("Notes", value: notes) }
            if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link(destination: url) { Text(url.absoluteString).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                    .tint(CalendarStyle.accent)
            } else if let url = current.url { detail("URL", value: url.absoluteString) }
        }
    }

    private var dateLabel: String {
        let last = current.isAllDay ? max(current.start, current.end.addingTimeInterval(-1)) : current.end
        if Calendar.current.isDate(current.start, inSameDayAs: last) {
            return current.start.formatted(date: .complete, time: .omitted)
        }
        return current.start.formatted(date: .abbreviated, time: .omitted) + " - " + last.formatted(date: .abbreviated, time: .omitted)
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
