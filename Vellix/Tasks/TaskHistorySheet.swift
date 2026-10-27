import Combine
import SwiftUI

struct TaskHistorySheetRequest: Identifiable {
    let task: DocumentTaskRecord
    var id: String { task.id }
}

nonisolated struct TaskHistoryTimestamp {
    let date: String
    let weekday: String
    let time: String

    init(occurrence: TaskCompletedOccurrence, fallbackTimeZoneID: String? = nil, locale: Locale = .current) {
        let zone = (occurrence.timeZoneID ?? fallbackTimeZoneID).flatMap(TimeZone.init(identifier:)) ?? .current
        let value = Date(timeIntervalSince1970: occurrence.completedAt)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        date = formatter.string(from: value)
        formatter.dateFormat = "EEEE"
        weekday = formatter.string(from: value)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        time = formatter.string(from: value)
    }
}

struct TaskHistorySheet: View {
    let request: TaskHistorySheetRequest
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var task: DocumentTaskRecord
    @State private var isAvailable = true
    @State private var errorMessage: String?

    init(request: TaskHistorySheetRequest) {
        self.request = request
        _task = State(initialValue: request.task)
    }

    private var title: String { task.text.trimmedNonEmpty ?? "Untitled Task" }
    private var occurrences: [TaskCompletedOccurrence] {
        task.metadata.history.sorted {
            $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt > $1.completedAt
        }
    }
    private var completionCount: Int { task.metadata.history.filter { $0.outcome == .completed }.count }
    private var skipCount: Int { task.metadata.history.filter { $0.outcome == .skipped }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(VellixSurface.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { reload() } label: {
                        Text("Try Again").frame(maxWidth: .infinity, minHeight: 44).pennedSheetField()
                    }.buttonStyle(.plain)
                } else if !isAvailable {
                    Text("This task is no longer available.").foregroundStyle(.secondary)
                } else {
                    summary
                    if occurrences.isEmpty {
                        VStack(spacing: 12) {
                            LibraryIcon(name: "clockfill", size: 36).foregroundStyle(PennedSheetStyle.accent)
                            Text("No History Yet").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        timeline
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .font(.system(.body, design: .rounded).weight(.black))
        .foregroundStyle(VellixSurface.controlInk)
        .pennedSheet(title: title, close: { dismiss() })
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged).receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(environment.$isSwitchingSpace) { switching in if switching { dismiss() } }
        .onChange(of: environment.selectedSpaceID) { _, _ in dismiss() }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            LibraryIcon(name: "clockfill", size: 28)
                .foregroundStyle(PennedSheetStyle.accent)
                .frame(width: 52, height: 52)
                .background(PennedSheetStyle.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("\(completionCount) \(completionCount == 1 ? "completion" : "completions")")
                    .font(.system(.title3, design: .rounded).weight(.black))
                Text("\(skipCount) \(skipCount == 1 ? "skip" : "skips")")
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var timeline: some View {
        let entries = occurrences
        return LazyVStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, occurrence in
                TaskHistoryTimelineRow(occurrence: occurrence, currentText: task.text,
                    fallbackTimeZoneID: task.metadata.recurrence?.timeZoneID,
                    isFirst: index == 0, isLast: index == entries.count - 1)
            }
        }
    }

    private func reload() {
        do {
            guard let current = try environment.documents.taskForHistoryPage(id: DocumentTaskPages.detailID(request.id)) else {
                isAvailable = false
                errorMessage = nil
                return
            }
            task = current
            isAvailable = true
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TaskHistoryTimelineRow: View {
    let occurrence: TaskCompletedOccurrence
    let currentText: String
    let fallbackTimeZoneID: String?
    let isFirst: Bool
    let isLast: Bool

    private var color: Color { occurrence.outcome == .completed ? PennedSheetStyle.accent : VellixSurface.coral }
    private var outcome: String { occurrence.outcome == .completed ? "Completed" : "Skipped" }
    private var timestamp: TaskHistoryTimestamp { TaskHistoryTimestamp(occurrence: occurrence, fallbackTimeZoneID: fallbackTimeZoneID) }

    var body: some View {
        HStack(spacing: 12) {
            marker
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(timestamp.date).fixedSize()
                        Spacer(minLength: 0)
                        time.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(timestamp.date).fixedSize(horizontal: false, vertical: true)
                        time
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timestamp.weekday).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(outcome).foregroundStyle(color)
                }.font(.system(.subheadline, design: .rounded).weight(.black))
                if let original = occurrence.taskText, original != currentText {
                    Text(original).font(.system(.footnote, design: .rounded).weight(.black))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .pennedSheetField()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(timestamp.time).monospacedDigit()
            .font(.system(.subheadline, design: .rounded).weight(.black))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var marker: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(PennedSheetStyle.accent.opacity(0.25)).opacity(isFirst ? 0 : 1)
                Rectangle().fill(PennedSheetStyle.accent.opacity(0.25)).opacity(isLast ? 0 : 1)
            }.frame(width: 2).padding(.vertical, -6)
            Circle().fill(color).frame(width: 19, height: 19)
            LibraryIcon(name: occurrence.outcome == .completed ? "checkwavy" : "xmarkwavy", size: 12)
                .foregroundStyle(VellixSurface.inverseInk).frame(width: 19, height: 19)
        }
        .frame(width: 24).frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
