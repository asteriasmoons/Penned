import SwiftUI

struct CalendarView: View {
    private static let agendaBottomInset: CGFloat = 110
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pennedWorkspaceTabActive) private var workspaceTabActive
    @ObservedObject var model: CalendarModel
    @State private var configuringDailyNote: DailyNoteDay?
    @State private var openingDailyNote = false
    @State private var agendaPosition: ScrollPosition

    init(model: CalendarModel) {
        self.model = model
        _agendaPosition = State(initialValue: model.mode == .week
            ? ScrollPosition(id: model.initialScrollDate(), anchor: .top)
            : ScrollPosition(idType: Date.self, edge: .top))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                navigator
                Divider().padding(.horizontal, 18)
            }
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if dynamicTypeSize.isAccessibilitySize { navigator; Divider() }
                        calendarActions
                        dailyNoteAction
                        if model.mode == .week {
                            expansionControls
                            ForEach(model.days, id: \.self) { day in
                                VStack(alignment: .leading, spacing: 18) {
                                    weekSection(day)
                                    if day == model.days.last { unscheduledAgenda }
                                }
                                // Leave only the trailing room needed to top-align the final day.
                                .frame(minHeight: day == model.days.last ? max(0, geometry.size.height - Self.agendaBottomInset) : nil,
                                    alignment: .topLeading)
                                .id(day)
                            }
                        } else {
                            Text(dayHeading(model.selectedDate))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                            CalendarDayAgenda(model: model, day: model.selectedDate)
                            unscheduledAgenda
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, Self.agendaBottomInset)
                }
                .scrollPosition($agendaPosition, anchor: .top)
                .refreshable { await model.refreshAndWait() }
                .onChange(of: model.selectionRevision) { _, _ in
                    scrollAgenda(to: model.mode == .week ? model.scrollTargetDate : nil)
                    model.acknowledgeScrollRequest()
                }
                .onChange(of: model.mode) { _, mode in
                    scrollAgenda(to: mode == .week ? model.initialScrollDate() : nil)
                    model.acknowledgeScrollRequest()
                }
            }
        }
        .background(VellixSurface.appBackground)
        .foregroundStyle(VellixSurface.ink)
        .tint(CalendarStyle.accent)
        .navigationTitle("Calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Calendar").font(.system(size: 22, weight: .black, design: .rounded))
            }
        }
        .sheet(item: $model.selectedEvent) { event in CalendarEventDetailSheet(event: event, model: model) }
        .sheet(item: $configuringDailyNote) { day in
            NavigationStack {
                DailyNotesSettingsView(onSelected: {
                    configuringDailyNote = nil
                    openDailyNote(day)
                })
                .pennedSheet(title: "Daily Notes", close: { configuringDailyNote = nil })
            }
        }
        .alert("Calendar", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear {
            model.acknowledgeScrollRequest()
            if workspaceTabActive && (horizontalSizeClass != .compact || environment.selectedDocumentID == nil) { model.activate() }
        }
        .onDisappear { model.deactivate() }
        .onChange(of: environment.selectedDocumentID) { _, id in
            if !workspaceTabActive || (horizontalSizeClass == .compact && id != nil) { model.deactivate() }
            else { model.activate() }
        }
        .onChange(of: workspaceTabActive) { _, active in if active { model.activate() } else { model.deactivate() } }
    }

    private func scrollAgenda(to day: Date?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let day { agendaPosition.scrollTo(id: day, anchor: .top) }
            else { agendaPosition.scrollTo(edge: .top) }
        }
    }

    @ViewBuilder private var unscheduledAgenda: some View {
        if !model.unscheduledTasks.isEmpty {
            Text("Unscheduled").font(.system(.headline, design: .rounded)).padding(.top, 12)
            ForEach(model.unscheduledTasks) { CalendarTaskRow(model: model, entry: $0, showsDocumentBadge: true) }
        }
    }

    private var navigator: some View {
        VStack(spacing: 14) {
            Picker("Calendar View", selection: $model.mode) {
                ForEach(CalendarAgendaMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack(spacing: 6) {
                navigationButton("Previous \(model.mode.rawValue)", icon: "chevleft", direction: -1)
                Text(rangeHeading).font(.system(.headline, design: .rounded))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                navigationButton("Next \(model.mode.rawValue)", icon: "chevright", direction: 1)
            }
            ViewThatFits(in: .horizontal) {
                dateRow(expandsToFill: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    dateRow(expandsToFill: false)
                }
            }
        }.padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 0 : 18).padding(.top, 10).padding(.bottom, 16)
    }

    private func dateRow(expandsToFill: Bool) -> some View {
        HStack(spacing: expandsToFill ? 0 : 6) {
            ForEach(model.days, id: \.self) { day in
                CalendarDateBubble(date: day, selected: model.calendar.isDate(day, inSameDayAs: model.selectedDate),
                    hasContent: !model.events(on: day).isEmpty || !model.tasks(on: day).isEmpty,
                    hasDailyNote: model.dailyNote(on: day) != nil) { model.select(day) }
                    .frame(maxWidth: expandsToFill ? .infinity : nil)
            }
        }.frame(maxWidth: expandsToFill ? .infinity : nil)
    }

    private var calendarActions: some View {
        HStack(alignment: .center, spacing: 12) {
            accessNotice.frame(maxWidth: .infinity, alignment: .leading)
            Button("Today", action: model.today)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CalendarStyle.accent)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(CalendarStyle.accent.opacity(0.16), in: Capsule())
                .fixedSize().frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }.frame(maxWidth: .infinity)
    }

    private var dailyNoteAction: some View {
        Button { openDailyNote(DailyNoteDay(date: model.selectedDate)) } label: {
            HStack(spacing: 10) {
                LibraryIcon(name: "linedpages", size: 24)
                Text(model.dailyNote(on: model.selectedDate) == nil ? "Create Daily Note" : "Open Daily Note")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(VellixSurface.ink)
                Spacer(minLength: 8)
                if openingDailyNote { ProgressView() }
                else { LibraryIcon(name: "chevright", size: 16) }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(CalendarStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: VellixRadius.md))
            .overlay { RoundedRectangle(cornerRadius: VellixRadius.md).strokeBorder(CalendarStyle.accent.opacity(0.24), lineWidth: 1) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(CalendarStyle.accent)
        .disabled(openingDailyNote || environment.isSwitchingSpace)
        .accessibilityHint("Daily note for " + DailyNoteDay(date: model.selectedDate).title)
        .accessibilityIdentifier("daily-note-action")
    }

    private func openDailyNote(_ day: DailyNoteDay) {
        guard !openingDailyNote else { return }
        openingDailyNote = true
        Task {
            defer { openingDailyNote = false }
            do { try await environment.openDailyNote(day: day) }
            catch DailyNoteError.chooseTemplate { configuringDailyNote = day }
            catch DailyNoteError.unavailableTemplate { configuringDailyNote = day }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func navigationButton(_ title: String, icon: String, direction: Int) -> some View {
        Button { model.navigate(direction) } label: {
            LibraryIcon(name: icon, size: 18).frame(width: 40, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private var rangeHeading: String {
        if model.mode == .day { return model.selectedDate.formatted(.dateTime.month(.abbreviated).day().year()) }
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMM d, yyyy"
        return formatter.string(from: model.week.start, to: model.week.end.addingTimeInterval(-1))
    }

    private var expansionControls: some View {
        HStack(spacing: 20) {
            Button { withAnimation { model.expandAll() } } label: {
                Label { Text("Expand All") } icon: { LibraryIcon(name: "chevdown", size: 12) }
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(model.days.allSatisfy(model.expandedDays.contains))
            Button { withAnimation { model.collapseAll() } } label: {
                Label { Text("Collapse All") } icon: { LibraryIcon(name: "chevup", size: 12) }
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(model.days.allSatisfy { !model.expandedDays.contains($0) })
            Spacer(minLength: 0)
        }.font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(CalendarStyle.accent)
    }

    @ViewBuilder private var accessNotice: some View {
        switch model.access {
        case .allowed: EmptyView()
        case .notRequested:
            Button {
                Task { await model.requestAccess() }
            } label: {
                HStack(spacing: 10) {
                    LibraryIcon(name: "mooncal", size: 20)
                    Text("Connect Apple Calendar").fixedSize(horizontal: false, vertical: true)
                    if model.isRequestingAccess { ProgressView() }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).foregroundStyle(CalendarStyle.accent).disabled(model.isRequestingAccess)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Calendar access is off. Your Penned tasks are still available.").font(.subheadline).foregroundStyle(.secondary)
                Button("Open Settings", action: AppleCalendarNavigation.openSettings)
                    .frame(minHeight: 44).buttonStyle(.plain).foregroundStyle(CalendarStyle.accent)
            }
        case .restricted:
            Text("Calendar access is restricted on this device.").font(.subheadline).foregroundStyle(.secondary)
        case .unavailable:
            Text("Apple Calendar access is unavailable.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func weekSection(_ day: Date) -> some View {
        let expanded = model.expandedDays.contains(day)
        return VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation { model.toggleDay(day) } } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayHeading(day)).font(.system(.headline, design: .rounded))
                            .foregroundStyle(model.calendar.isDateInToday(day) ? CalendarStyle.accent : VellixSurface.ink)
                        Text(summary(day)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    LibraryIcon(name: expanded ? "chevup" : "chevdown", size: 16)
                        .foregroundStyle(.secondary).padding(.top, 4)
                }.padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(dayHeading(day))")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { CalendarDayAgenda(model: model, day: day) }
            Divider().padding(.top, 8)
        }
    }

    private func dayHeading(_ day: Date) -> String {
        let prefix = model.calendar.isDateInToday(day) ? "Today - " : model.calendar.isDateInTomorrow(day) ? "Tomorrow - " : ""
        return prefix + day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func summary(_ day: Date) -> String {
        let events = model.events(on: day).count, tasks = model.tasks(on: day).count
        let notes = model.events(on: day).filter { model.eventNotes[$0.id]?.isTrashed == false }.count
        var parts: [String] = []
        if events > 0 { parts.append("\(events) \(events == 1 ? "event" : "events")") }
        if tasks > 0 { parts.append("\(tasks) \(tasks == 1 ? "task" : "tasks")") }
        if notes > 0 { parts.append("\(notes) \(notes == 1 ? "note" : "notes")") }
        if model.dailyNote(on: day) != nil { parts.append("Daily Note") }
        return parts.isEmpty ? "Nothing scheduled" : parts.joined(separator: ", ")
    }

}

private struct CalendarDateBubble: View {
    let date: Date
    let selected: Bool
    let hasContent: Bool
    let hasDailyNote: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 34

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                    .foregroundStyle(.secondary)
                Text(date.formatted(.dateTime.day())).font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(selected ? VellixSurface.inverseInk : CalendarStyle.accent)
                    .frame(width: diameter, height: diameter)
                    .background(selected ? CalendarStyle.accent : VellixSurface.controlInk.opacity(0.04), in: Circle())
                    .overlay { if Calendar.current.isDateInToday(date) { Circle().stroke(CalendarStyle.accent, lineWidth: 1.5) } }
                HStack(spacing: 3) {
                    Circle().fill(hasContent ? CalendarStyle.accent : .clear).frame(width: 4, height: 4)
                    if hasDailyNote { RoundedRectangle(cornerRadius: 1).fill(CalendarStyle.accent).frame(width: 5, height: 5) }
                }.frame(height: 5)
            }.frame(minWidth: diameter + 6, minHeight: 66).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasDailyNote ? "Daily Note" : hasContent ? "Scheduled content" : "Nothing scheduled")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
