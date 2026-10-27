import SwiftUI

struct MacCalendarBrowser: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @ObservedObject private var model: CalendarModel
    init(workspace: MacWorkspaceModel, tab: MacWorkspaceTab) { self.workspace = workspace; model = workspace.calendar(for: tab) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Calendar").font(.system(size: 16, weight: .heavy, design: .rounded))
                Spacer()
                MacIconButton("Previous Week", icon: "chevleft") { model.navigate(-1) }
                Text(model.selectedDate.formatted(.dateTime.month(.wide).year())).font(.headline)
                MacIconButton("Next Week", icon: "chevright") { model.navigate(1) }
                Button("Today") { model.today() }
                if model.access != .allowed { Button("Connect Apple Calendar") { Task { await model.requestAccess() } } }
            }.padding(.horizontal, 18).frame(height: 52)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
                                Spacer()
                                Button("Daily Note") {
                                    workspace.perform { let document = try await workspace.environment.openDailyNote(day: DailyNoteDay(date: day)); try await workspace.open(document) }
                                }.font(.caption)
                            }
                            ForEach(model.events(on: day)) { event in
                                Button { model.selectedEvent = event } label: {
                                    HStack(spacing: 10) {
                                        RoundedRectangle(cornerRadius: 2).fill(event.calendarColor).frame(width: 3, height: 28)
                                        Text(event.title).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(event.timeLabel(on: day)).font(.caption).foregroundStyle(.secondary)
                                    }.padding(8)
                                }.buttonStyle(.plain)
                            }
                            ForEach(model.tasks(on: day)) { entry in
                                HStack {
                                    Button { Task { await model.complete(entry) } } label: {
                                        LibraryIcon(name: entry.isCompleted ? "checkwavy" : "checklist", size: 17)
                                    }.buttonStyle(.plain).disabled(!entry.canComplete)
                                    Text(entry.task.text).strikethrough(entry.isCompleted).frame(maxWidth: .infinity, alignment: .leading)
                                    Button(entry.task.documentTitle) {
                                        workspace.perform { let document = try workspace.environment.documents.requireDocument(id: entry.task.documentID); try await workspace.open(document) }
                                    }.font(.caption)
                                }.padding(.vertical, 6)
                            }
                            Divider()
                        }
                    }
                    if let error = model.errorMessage { Text(error).foregroundStyle(VellixSurface.coral) }
                }.padding(24)
            }
        }
        .background(VellixSurface.workspace)
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .sheet(item: $model.selectedEvent) { CalendarEventDetailSheet(event: $0, model: model).frame(width: 520, height: 580) }
    }
}

struct MacTaskBrowser: View {
    @ObservedObject var workspace: MacWorkspaceModel
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var browser: MacBrowserState
    @State private var revision = 0
    private var tasks: [DocumentTaskRecord] { ((try? environment.tasks.all()) ?? []).filter { $0.checked == browser.showsCompletedTasks } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks").font(.system(size: 16, weight: .heavy, design: .rounded)); Spacer()
                MacSegmentedControl("Status", selection: $browser.showsCompletedTasks, options: [false, true], label: { $0 ? "Completed" : "Open" }).frame(width: 180)
            }.padding(.horizontal, 18).frame(height: 52)
            Divider()
            List(tasks) { task in
                HStack(spacing: 12) {
                    Button {
                        workspace.perform { try await environment.setTaskCompleted(id: task.id, completed: !task.checked, expectedOccurrenceID: task.metadata.occurrenceID); revision += 1 }
                    } label: { LibraryIcon(name: task.checked ? "checkwavy" : "checklist", size: 18) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.text).strikethrough(task.checked)
                        if let date = task.metadata.scheduledDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(task.documentTitle) { workspace.perform { let document = try environment.documents.requireDocument(id: task.documentID); try await workspace.open(document) } }
                        .font(.caption)
                }.padding(.vertical, 6)
            }.id(revision)
        }.background(VellixSurface.workspace)
            .onReceive(NotificationCenter.default.publisher(for: .vellixTasksChanged)) { _ in revision += 1 }
    }
}
