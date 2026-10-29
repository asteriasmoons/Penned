import SwiftUI

struct TaskHistoryPageHeader: View {
    let task: DocumentTaskRecord
    let appearance: DocumentAppearance
    @Binding var title: String
    var saveTitle: (String) -> Void
    var titleFocused: FocusState<Bool>.Binding
    var titleSize: CGFloat = 24
    var locked = false
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                completionCircle
                TextField("Untitled Task", text: Binding(get: { title }, set: { title = $0.components(separatedBy: .newlines).joined(separator: " ") }))
                    .font(appearance.fontStyle.font(size: titleSize, weight: .black))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textFieldStyle(.plain).lineLimit(1).disabled(locked)
                    .focused(titleFocused)
                    .onSubmit { saveTitle(title) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { scheduleLabels }
                VStack(alignment: .leading, spacing: 6) { scheduleLabels }
            }
            .font(appearance.fontStyle.font(size: 14))
            .foregroundStyle(Color(vellixHex: appearance.textColorHex).opacity(0.6))
        }
        .foregroundStyle(Color(vellixHex: appearance.textColorHex))
    }

    @ViewBuilder private var scheduleLabels: some View {
        HStack(spacing: 5) {
            LibraryIcon(name: "repeatfill", size: 15)
            Text(task.metadata.recurrence?.label ?? "Does Not Repeat")
        }
        HStack(spacing: 5) {
            LibraryIcon(name: "clockwavy", size: 15)
            Text(task.metadata.reminderSummary ?? "No Reminder")
        }
    }

    private var completionCircle: some View {
        TaskCompletionCircle(isChecked: task.checked, isSkipped: task.metadata.isSkipped,
            isEnabled: !locked && !isSaving, ink: Color(vellixHex: appearance.textColorHex), hitSize: 32) {
            finish(skipped: $0)
        }
    }

    private func finish(skipped: Bool) {
        guard !locked, !isSaving else { return }
        saveTitle(title)
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await environment.setTaskCompleted(id: task.id, completed: skipped || !task.checked,
                    expectedOccurrenceID: task.metadata.occurrenceID, skipped: skipped)
            } catch { environment.report(error) }
        }
    }
}
