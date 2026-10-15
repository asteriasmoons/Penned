import SwiftUI

struct TaskEditorRequest: Identifiable {
    let id = UUID()
    let context: DocumentTaskContext
}

private enum TaskSheetPanel: String {
    case conversion, scheduling, reminder, repeatOptions, customRepeat
    var title: String {
        switch self {
        case .conversion: return "Checklist"
        case .scheduling: return "Task"
        case .reminder: return "Remind Me"
        case .repeatOptions, .customRepeat: return "Repeat"
        }
    }
}

struct TaskEditorSheet: View {
    @ObservedObject var model: DocumentEditorModel
    @ObservedObject var notifications: TaskNotificationsManager
    let request: TaskEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var context: DocumentTaskContext
    @State private var panel: TaskSheetPanel
    @State private var reminderDate: Date
    @State private var frequency: TaskRepeatFrequency
    @State private var interval: Int
    @State private var weekdays: Set<Int>
    @State private var scheduledTime: Date
    @State private var anchorDay: Int
    @State private var anchorMonth: Int
    @State private var isConfirming = false
    @State private var selectedDetent: PresentationDetent
    private let accent = Color(vellixHex: "#714FAB")

    init(model: DocumentEditorModel, notifications: TaskNotificationsManager, request: TaskEditorRequest) {
        self.model = model
        self.notifications = notifications
        self.request = request
        let metadata = request.context.metadata
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let date = metadata?.scheduledDate ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? Date()
        let rule = metadata?.recurrence
        self._context = State(initialValue: request.context)
        self._panel = State(initialValue: metadata == nil ? .conversion : .scheduling)
        self._reminderDate = State(initialValue: date)
        self._frequency = State(initialValue: rule?.frequency == .weekdays ? .weekly : rule?.frequency ?? .daily)
        self._interval = State(initialValue: rule?.interval ?? 1)
        let configuredDays = rule?.weekdays ?? []
        let selectedDays = rule?.frequency == .weekdays ? Array(2...6)
            : (configuredDays.isEmpty ? [Calendar.current.component(.weekday, from: date)] : configuredDays)
        self._weekdays = State(initialValue: Set(selectedDays))
        self._scheduledTime = State(initialValue: date)
        let original = rule.map { Date(timeIntervalSince1970: $0.anchor) } ?? date
        let calendar = rule?.calendar ?? .current
        self._anchorDay = State(initialValue: rule?.anchorDay ?? calendar.component(.day, from: original))
        self._anchorMonth = State(initialValue: rule?.anchorMonth ?? calendar.component(.month, from: original))
        self._selectedDetent = State(initialValue: .height(290))
    }

    var body: some View {
        presentedContent
        .onChange(of: panel) { _, value in updateDetent(value) }
        .onChange(of: model.taskContext) { _, current in receiveContext(current) }
        .alert("Task", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var presentedContent: some View {
        sheetContent
        .tint(accent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .presentationDetents([.height(290), .fraction(0.58), .large], selection: $selectedDetent)
        .interactiveDismissDisabled(isConfirming)
    }

    private func updateDetent(_ panel: TaskSheetPanel) {
        switch panel {
        case .reminder: selectedDetent = .large
        case .repeatOptions, .customRepeat: selectedDetent = .fraction(0.58)
        case .conversion, .scheduling: selectedDetent = .height(290)
        }
    }

    private func receiveContext(_ current: DocumentTaskContext?) {
        guard let current, current.blockID == context.blockID else { return }
        context = current
    }

    private var sheetContent: some View {
        VStack(spacing: 16) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { panelContent }.padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }
        .padding(20)
        .font(.system(.body, design: .rounded))
        .foregroundStyle(.white)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .disabled(isConfirming)
    }

    private var header: some View {
        HStack {
            Text(panel.title).font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            if panel != .conversion && panel != .scheduling {
                Button { panel = .scheduling } label: { LibraryIcon(name: "chevleft", size: 20) }
                    .accessibilityLabel("Back to Task")
            }
            Button { dismiss() } label: { LibraryIcon(name: "xmarkwavy", size: 23).foregroundStyle(.secondary) }
                .accessibilityLabel("Close")
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var panelContent: some View {
        switch panel {
        case .conversion: conversion
        case .scheduling: scheduling
        case .reminder: reminder
        case .repeatOptions: repeatOptions
        case .customRepeat: customRepeat
        }
    }

    private var conversion: some View {
        VStack(spacing: 12) {
            row("Convert to Task", icon: "clockfill") {
                model.convertChecklist(context, toTask: true)
                panel = .scheduling
            }
            Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var scheduling: some View {
        VStack(spacing: 8) {
            row("Remind Me", icon: "clockwavy", detail: context.metadata?.reminderEnabled == true
                ? context.metadata?.scheduledDate?.formatted(date: .abbreviated, time: .shortened) : nil) {
                reminderDate = context.metadata?.scheduledDate ?? reminderDate
                panel = .reminder
            }
            row("Repeat", icon: "repeatfill", detail: context.metadata?.recurrence?.label) { panel = .repeatOptions }
            Divider().padding(.vertical, 6)
            Button("Convert Back to Checklist") {
                model.convertChecklist(context, toTask: false)
                dismiss()
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
        }.disabled(context.metadata == nil)
    }

    private var reminder: some View {
        VStack(spacing: 12) {
            DatePicker("Reminder Date", selection: $reminderDate, displayedComponents: [.date])
                .datePickerStyle(.graphical)
            DatePicker("Time", selection: $reminderDate, displayedComponents: [.hourAndMinute])
                .padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if context.metadata?.reminderEnabled == true {
                Button("Remove Reminder", role: .destructive) {
                    saveConfiguration(reminder: false,
                        scheduledDate: context.metadata?.recurrence == nil ? nil : context.metadata?.scheduledDate,
                        recurrence: context.metadata?.recurrence)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            actions(confirm: "Set") {
                var rule = context.metadata?.recurrence
                if rule != nil {
                    rule?.anchor = reminderDate.timeIntervalSince1970
                    rule?.hour = Calendar.current.component(.hour, from: reminderDate)
                    rule?.minute = Calendar.current.component(.minute, from: reminderDate)
                    rule?.timeZoneID = TimeZone.current.identifier
                }
                saveConfiguration(reminder: true, scheduledDate: reminderDate, recurrence: rule)
            }
        }
    }

    private var repeatOptions: some View {
        VStack(spacing: 4) {
            ForEach(TaskRepeatFrequency.allCases, id: \.self) { option in
                row(option.title, icon: "repeatfill", detail: repeatDetail(option)) { applyStandardRepeat(option) }
            }
            Divider().padding(.vertical, 8)
            row("Custom...", icon: "repeatfill") {
                scheduledTime = context.metadata?.scheduledDate ?? scheduledTime
                panel = .customRepeat
            }
            if context.metadata?.recurrence != nil {
                Button("Remove Repeat", role: .destructive) {
                    saveConfiguration(reminder: context.metadata?.reminderEnabled ?? false,
                        scheduledDate: context.metadata?.reminderEnabled == true ? context.metadata?.scheduledDate : nil, recurrence: nil)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var customRepeat: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Repeat Frequency", selection: $frequency) {
                ForEach([TaskRepeatFrequency.daily, .weekly, .monthly, .yearly], id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            Stepper(value: $interval, in: 1...365) {
                Text("Every \(interval) \(unit)")
            }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.hourAndMinute])
                .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if frequency == .weekly {
                HStack(spacing: 4) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Button {
                            if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                        } label: {
                            Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(weekdays.contains(day) ? accent.opacity(0.25) : .white.opacity(0.05), in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                            .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                    }
                }
            }
            if frequency == .monthly || frequency == .yearly {
                if frequency == .yearly {
                    Picker("Month", selection: $anchorMonth) {
                        ForEach(1...12, id: \.self) { month in Text(Calendar.current.monthSymbols[month - 1]).tag(month) }
                    }.pickerStyle(.menu)
                }
                Stepper("Day \(anchorDay)", value: $anchorDay, in: 1...31)
            }
            Text("When you complete your task, it schedules the next occurrence using your configuration, based on the completed task's scheduled date.")
                .font(.system(size: 15, design: .rounded)).foregroundStyle(accent)
                .padding(12).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            actions(confirm: "Confirm") { applyCustomRepeat() }
        }
    }

    private var unit: String {
        switch frequency {
        case .daily, .weekdays: return interval == 1 ? "day" : "days"
        case .weekly: return interval == 1 ? "week" : "weeks"
        case .monthly: return interval == 1 ? "month" : "months"
        case .yearly: return interval == 1 ? "year" : "years"
        }
    }

    private func repeatDetail(_ frequency: TaskRepeatFrequency) -> String {
        let date = context.metadata?.scheduledDate ?? Date()
        switch frequency {
        case .daily: return "Mon - Sun"
        case .weekdays: return "Mon - Fri"
        case .weekly: return date.formatted(.dateTime.weekday(.wide))
        case .monthly: return "On day \(Calendar.current.component(.day, from: date))"
        case .yearly: return date.formatted(.dateTime.month(.wide).day())
        }
    }

    private func row(_ title: String, icon: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryIcon(name: icon, size: 22).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(accent)
                    if let detail { Text(detail).font(.system(size: 14, design: .rounded)).foregroundStyle(accent) }
                }
                Spacer(minLength: 4)
                LibraryIcon(name: "chevright", size: 16).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func actions(confirm: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Button(action: action) {
                if isConfirming { ProgressView().tint(.black) }
                else { Text(confirm) }
            }
                .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 44)
                .background(accent, in: RoundedRectangle(cornerRadius: 8))
                .disabled(isConfirming || context.metadata == nil || (panel == .customRepeat && frequency == .weekly && weekdays.isEmpty))
        }.buttonStyle(.plain)
    }

    private func applyStandardRepeat(_ frequency: TaskRepeatFrequency) {
        let date = context.metadata?.scheduledDate ?? Date()
        let rule = TaskRepeatRule(frequency: frequency,
            weekdays: frequency == .weekly ? [Calendar.current.component(.weekday, from: date)] : [],
            hour: context.metadata?.scheduledDate.map { Calendar.current.component(.hour, from: $0) } ?? 9,
            minute: context.metadata?.scheduledDate.map { Calendar.current.component(.minute, from: $0) } ?? 0,
            anchor: date.timeIntervalSince1970)
        saveRepeat(rule)
    }

    private func applyCustomRepeat() {
        let date = context.metadata?.scheduledDate ?? Date()
        let rule = TaskRepeatRule(frequency: frequency, interval: interval,
            weekdays: frequency == .weekly ? (weekdays.isEmpty ? [Calendar.current.component(.weekday, from: date)] : weekdays.sorted()) : [],
            hour: Calendar.current.component(.hour, from: scheduledTime),
            minute: Calendar.current.component(.minute, from: scheduledTime),
            anchorDay: frequency == .monthly || frequency == .yearly ? anchorDay : nil,
            anchorMonth: frequency == .yearly ? anchorMonth : nil, anchor: date.timeIntervalSince1970)
        saveRepeat(rule)
    }

    private func saveRepeat(_ rule: TaskRepeatRule) {
        do {
            let scheduled = try rule.first(onOrAfter: context.metadata?.scheduledDate ?? Date())
            saveConfiguration(reminder: context.metadata?.reminderEnabled ?? false, scheduledDate: scheduled, recurrence: rule)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func saveConfiguration(reminder: Bool, scheduledDate: Date?, recurrence: TaskRepeatRule?) {
        guard !isConfirming else { return }
        isConfirming = true
        let target = context
        Task {
            defer { isConfirming = false }
            do {
                try await model.configureTask(target, reminder: reminder, scheduledDate: scheduledDate, recurrence: recurrence)
                let message = reminder && model.document?.templateID == nil ? await notifications.authorizeReminder() : nil
                await notifications.flush()
                model.taskFeedback = message ?? notifications.statusMessage ?? (model.document?.templateID != nil
                    ? "Template Schedule Saved" : "Task Schedule Saved")
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}
