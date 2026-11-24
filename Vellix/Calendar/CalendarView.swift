import SwiftUI

struct CalendarView: View {
    private static let agendaBottomInset: CGFloat = 110
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pennedWorkspace) private var workspace
    @Environment(\.pennedWorkspaceTabActive) private var workspaceTabActive
    @ObservedObject var model: CalendarModel
    @State private var configuringDailyNote: DailyNoteDay?
    @State private var openingDailyNote = false
    @State private var agendaPosition = ScrollPosition(edge: .top)
    @ScaledMetric(relativeTo: .caption) private var minimumCardHeight: CGFloat = 108

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, min(geometry.size.width, 680) - 36)
            VStack(spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize {
                    navigator.frame(maxWidth: 644).padding(.horizontal, 18)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if dynamicTypeSize.isAccessibilitySize { navigator }
                        accessNotice
                        if model.mode == .week {
                            weekCards(width: contentWidth)
                            weekPanel(width: contentWidth,
                                agendaHeight: min(340, max(200, geometry.size.height * 0.36)))
                        } else {
                            dayBanner(width: contentWidth)
                            dailyNoteAction
                            Text(dayHeading(model.selectedDate))
                                .font(.system(.title3, design: .rounded).weight(.black))
                                .padding(.horizontal, 6)
                            CalendarDayAgenda(model: model, day: model.selectedDate, showsTimeline: true)
                        }
                        unscheduledAgenda
                    }
                    .frame(maxWidth: 644, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, Self.agendaBottomInset)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollPosition($agendaPosition, anchor: .top)
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await model.refreshAndWait() }
                .onChange(of: model.selectionRevision) { _, _ in
                    scrollAgendaToTop()
                    model.acknowledgeScrollRequest()
                }
                .onChange(of: model.mode) { _, _ in
                    scrollAgendaToTop()
                    model.acknowledgeScrollRequest()
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(CalendarStyle.accent)
        .navigationTitle("Calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Calendar").font(.system(size: 26, weight: .black, design: .rounded))
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

    private func scrollAgendaToTop() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            agendaPosition.scrollTo(edge: .top)
        }
    }

    @ViewBuilder private var unscheduledAgenda: some View {
        if !model.unscheduledTasks.isEmpty {
            Text("Unscheduled").font(.system(.headline, design: .rounded)).padding(.top, 12)
            ForEach(model.unscheduledTasks) { CalendarTaskRow(model: model, entry: $0, showsDocumentBadge: true) }
        }
    }

    private var navigator: some View {
        VStack(spacing: 10) {
            if workspace != nil {
                Text("Calendar").font(.system(.title, design: .rounded).weight(.black))
            }
            HStack(spacing: 0) {
                ForEach(CalendarAgendaMode.allCases) { mode in
                    Button { model.mode = mode } label: {
                        Text(mode.rawValue)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background {
                                if model.mode == mode {
                                    Capsule().fill(LinearGradient(
                                        colors: [CalendarStyle.accent, Color(red: 0.66, green: 0.16, blue: 0.91)],
                                        startPoint: .top, endPoint: .bottom))
                                        .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1) }
                                        .shadow(color: CalendarStyle.accent.opacity(0.4), radius: 4)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                    .accessibilityIdentifier("calendar-view-\(mode.rawValue.lowercased())")
                }
            }
            .padding(2).background(Color(white: 0.13), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("Calendar View")
            HStack(spacing: 6) {
                navigationButton("Previous \(model.mode.rawValue)", icon: "chevleft", direction: -1)
                Button(action: model.today) {
                    Text(rangeHeading).font(.system(.headline, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Go to today")
                .accessibilityHint("Returns the calendar to today")
                .contextMenu {
                    Button("Today", action: model.today)
                    Button { model.expandAll() } label: {
                        Label { Text("Expand All") } icon: { LibraryIcon(name: "chevdown", size: 14) }
                    }
                    Button { model.collapseAll() } label: {
                        Label { Text("Collapse All") } icon: { LibraryIcon(name: "chevup", size: 14) }
                    }
                }
                navigationButton("Next \(model.mode.rawValue)", icon: "chevright", direction: 1)
            }
        }.padding(.top, 10).padding(.bottom, 6)
    }

    private func weekCards(width: CGFloat) -> some View {
        let cardWidth = max(1, (width - 24) / 4)
        let cardHeight = max(minimumCardHeight, cardWidth * 1.2)
        let days = model.days
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(days.prefix(4)), id: \.self) { day in
                    dateCard(day, width: cardWidth, height: cardHeight)
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(days.dropFirst(4)), id: \.self) { day in
                    dateCard(day, width: cardWidth, height: cardHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private func dateCard(_ day: Date, width: CGFloat, height: CGFloat) -> some View {
        CalendarIllustratedDateCard(date: day, artwork: CalendarDayArtwork(date: day, calendar: model.calendar),
            selected: model.calendar.isDate(day, inSameDayAs: model.selectedDate),
            eventCount: model.events(on: day).count, taskCount: model.tasks(on: day).count,
            hasDailyNote: model.dailyNote(on: day) != nil) { model.select(day) }
            .frame(width: width, height: height)
    }

    private var selectedDayExpanded: Bool { model.expandedDays.contains(model.selectedDate) }
    private var selectedDayArtwork: CalendarDayArtwork {
        CalendarDayArtwork(date: model.selectedDate, calendar: model.calendar)
    }

    private func banner(width: CGFloat, dayView: Bool) -> some View {
        CalendarIllustratedDayBanner(title: compactDayHeading(model.selectedDate),
            eventCount: model.events(on: model.selectedDate).count,
            taskCount: model.tasks(on: model.selectedDate).count,
            artwork: selectedDayArtwork,
            expanded: dayView || selectedDayExpanded,
            expandedHeight: max(dayView ? 126 : 96, width / (dayView ? 2.9 : 4.1)),
            toggle: dayView ? nil : { model.toggleDay(model.selectedDate) })
    }

    private func weekPanel(width: CGFloat, agendaHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            banner(width: width, dayView: false)
            dailyNoteAction
                .padding(.horizontal, 14).padding(.top, 14)
                .padding(.bottom, selectedDayExpanded ? 10 : 14)
            if selectedDayExpanded {
                ScrollView {
                    CalendarDayAgenda(model: model, day: model.selectedDate)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                .frame(height: agendaHeight)
                .scrollBounceBehavior(.basedOnSize)
                .id(DailyNoteDay(date: model.selectedDate).key)
                .accessibilityLabel("Selected day events and tasks")
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(selectedDayArtwork.border.opacity(0.9), lineWidth: 2) }
        .shadow(color: selectedDayArtwork.border.opacity(0.22), radius: 5)
    }

    private func dayBanner(width: CGFloat) -> some View {
        banner(width: width, dayView: true)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selectedDayArtwork.border, lineWidth: 2) }
            .shadow(color: selectedDayArtwork.border.opacity(0.45), radius: 5)
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
            LibraryIcon(name: icon, size: 16)
                .frame(width: 30, height: 30)
                .background(CalendarStyle.accent.opacity(0.12), in: Circle())
                .overlay { Circle().strokeBorder(CalendarStyle.accent.opacity(0.45), lineWidth: 1.5) }
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private var rangeHeading: String {
        if model.mode == .day { return model.selectedDate.formatted(.dateTime.month(.abbreviated).day().year()) }
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMM d, yyyy"
        return formatter.string(from: model.week.start, to: model.week.end.addingTimeInterval(-1))
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

    private func dayHeading(_ day: Date) -> String {
        let prefix = model.calendar.isDateInToday(day) ? "Today - " : model.calendar.isDateInTomorrow(day) ? "Tomorrow - " : ""
        return prefix + day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func compactDayHeading(_ day: Date) -> String {
        let prefix = model.calendar.isDateInToday(day) ? "Today - " : model.calendar.isDateInTomorrow(day) ? "Tomorrow - " : ""
        return prefix + day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

}

private struct CalendarDayArtwork {
    let index: Int

    init(date: Date, calendar: Calendar) { index = calendar.component(.weekday, from: date) }

    var card: String { "CardIMG\(index)" }
    var banner: String { "BannerIMG\(index)" }
    var border: Color {
        switch index {
        case 1: Color(red: 0.77, green: 0.28, blue: 1)
        case 2: Color(red: 0.10, green: 0.65, blue: 1)
        case 3: Color(red: 1, green: 0.23, blue: 0.75)
        case 4: Color(red: 0.16, green: 0.91, blue: 0.92)
        case 5: Color(red: 0.24, green: 0.93, blue: 0.55)
        case 6: Color(red: 1, green: 0.78, blue: 0.16)
        default: Color(red: 0.64, green: 0.43, blue: 1)
        }
    }
}

private struct CalendarIllustratedDateCard: View {
    let date: Date
    let artwork: CalendarDayArtwork
    let selected: Bool
    let eventCount: Int
    let taskCount: Int
    let hasDailyNote: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .caption2) private var countFontSize: CGFloat = 10

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 4) {
                    count(eventCount, singular: "Event", plural: "Events", icon: "mooncal")
                    count(taskCount, singular: "Task", plural: "Tasks", icon: "checkwavy")
                }
                .padding(.horizontal, 4).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 9))
            }
            .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    Image(artwork.card).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(artwork.border, lineWidth: selected ? 2.5 : 1.8) }
            .shadow(color: artwork.border.opacity(selected ? 0.7 : 0.15), radius: selected ? 5 : 2)
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(eventCount) events, \(taskCount) tasks" + (hasDailyNote ? ", Daily Note" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("calendar-date-\(DailyNoteDay(date: date).key)")
    }

    private func count(_ value: Int, singular: String, plural: String, icon: String) -> some View {
        HStack(spacing: 3) {
            LibraryIcon(name: icon, size: 9).foregroundStyle(artwork.border)
            ViewThatFits(in: .horizontal) {
                Text("\(value) \(value == 1 ? singular : plural)").fixedSize()
                Text("\(value)").lineLimit(1).minimumScaleFactor(0.6)
            }
            .font(.system(size: countFontSize, weight: .semibold, design: .rounded))
        }
    }
}

private struct CalendarIllustratedDayBanner: View {
    let title: String
    let eventCount: Int
    let taskCount: Int
    let artwork: CalendarDayArtwork
    let expanded: Bool
    let expandedHeight: CGFloat
    let toggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title).font(.system(.title3, design: .rounded).weight(.black))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black, radius: 2)
                if let toggle {
                    Button(action: toggle) {
                        LibraryIcon(name: expanded ? "chevup" : "chevdown", size: 14)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.65), in: Circle())
                            .overlay { Circle().strokeBorder(artwork.border.opacity(0.8), lineWidth: 1) }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse day agenda" : "Expand day agenda")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("calendar-day-disclosure")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { eventSummary; taskSummary }
                VStack(alignment: .leading, spacing: 6) { eventSummary; taskSummary }
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .shadow(color: .black, radius: 2)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: expanded ? expandedHeight : 88, alignment: .topLeading)
        .background {
            GeometryReader { geometry in
                Image(artwork.banner).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .clipped()
    }

    private var eventSummary: some View {
        Label { Text("\(eventCount) \(eventCount == 1 ? "Event" : "Events")") }
            icon: { LibraryIcon(name: "mooncal", size: 17).foregroundStyle(artwork.border) }
    }

    private var taskSummary: some View {
        Label { Text("\(taskCount) \(taskCount == 1 ? "Task" : "Tasks")") }
            icon: { LibraryIcon(name: "checkwavy", size: 17).foregroundStyle(artwork.border) }
    }
}
