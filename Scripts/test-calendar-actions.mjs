import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

const read = path => readFile(new URL("../" + path, import.meta.url), "utf8");
const view = await read("Vellix/Calendar/CalendarView.swift");
const rows = await read("Vellix/Calendar/CalendarAgendaRows.swift");
const environment = await read("Vellix/App/AppEnvironment.swift");
const pad = await read("Vellix/App/PadWorkspaceModel.swift");
const section = (source, start, end) => {
    const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
    assert.ok(from >= 0 && to > from, `Missing source section: ${start}`);
    return source.slice(from, to);
};

test("the requested calendar asset icons exist", async () => {
    for (const icon of ["linedpages", "chevright", "checkwavy", "clockwavy"]) {
        const path = `Vellix/Assets.xcassets/${icon}.imageset/`;
        const asset = JSON.parse(await read(path + "Contents.json"));
        const image = asset.images.find(image => image.filename);
        assert.ok(image, icon);
        await access(new URL("../" + path + image.filename, import.meta.url));
    }
});

test("Daily Note uses linedpages and chevright in the existing full-width themed button", () => {
    const action = section(view, "private var dailyNoteAction:", "private func openDailyNote(");
    assert.match(action, /LibraryIcon\(name: "linedpages"/);
    assert.match(action, /else \{ LibraryIcon\(name: "chevright"/);
    assert.doesNotMatch(action, /name: "mooncal"/);
    assert.match(action, /openDailyNote\(DailyNoteDay\(date: model.selectedDate\)\)/);
    assert.match(action, /"Create Daily Note" : "Open Daily Note"/);
    assert.match(action, /if openingDailyNote \{ ProgressView\(\) \}/);
    assert.match(action, /frame\(maxWidth: \.infinity, minHeight: 52/);
    assert.match(action, /background\(CalendarStyle.accent.opacity\(0.12\)/);
    assert.match(action, /disabled\(openingDailyNote \|\| environment.isSwitchingSpace\)/);
});

test("scheduled and unscheduled Calendar rows opt in without restyling the separate Tasks browser", async () => {
    assert.match(rows, /var showsDocumentBadge = false/);
    assert.match(rows, /CalendarTaskRow\(model: model, entry: entry, showsDocumentBadge: true\)/);
    assert.match(view, /CalendarTaskRow\(model: model, entry: \$0, showsDocumentBadge: true\)/);
    assert.match(rows, /if !showsDocumentBadge, let document = model.documents\[entry.task.documentID\]/);
    const tasks = section(await read("Vellix/App/PadWorkspaceView.swift"), "ForEach(filteredTasks)", "if filteredTasks.isEmpty");
    assert.doesNotMatch(tasks, /showsDocumentBadge/);
});

test("the compact document badge uses the requested icons and routes by the exact source record", () => {
    const badge = section(rows, "private func documentBadge(", "struct CalendarDayAgenda:");
    assert.match(badge, /openCalendarDocument\(document, returnToCalendar: true\)/);
    assert.match(badge, /LibraryIcon\(name: "linedpages"/);
    assert.match(badge, /LibraryIcon\(name: "chevright"/);
    assert.match(badge, /Text\(document.title\)/);
    assert.match(badge, /lineLimit\(1\)/);
    assert.match(badge, /minHeight: 44/);
    assert.match(badge, /calendar-task-document-\\\(entry.id\)-\\\(document.id\)/);
    assert.doesNotMatch(badge, /NestedPageThumbnail|parentDocumentID|first\(where/);
    assert.match(rows, /model.documents\[entry.task.documentID\]/);
});

test("the badge stays in the text column with adaptive wrapping for long names and larger text", () => {
    const details = section(rows, "private var calendarTaskDetails:", "private func documentBadge(");
    assert.match(rows, /taskDetails.frame\(maxWidth: \.infinity, alignment: \.leading\)/);
    assert.match(details, /ViewThatFits\(in: \.horizontal\)/);
    assert.match(details, /model.mode == \.week \? \.firstTextBaseline : \.lastTextBaseline/);
    assert.match(details, /\} else \{\s*taskTextAndTime/);
    assert.match(details, /VStack\(alignment: \.leading, spacing: 4\) \{\s*taskTextAndTime\s*documentBadge\(document\)/);
});

test("Calendar reserves only the visible circle width so the circle, text, time and badge start at the left", async () => {
    const circle = await read("Vellix/Tasks/TaskCompletionCircle.swift");
    assert.match(circle, /var hitSize: CGFloat = 44/);
    assert.match(circle, /\.frame\(width: 19, height: 19\)\s*\.frame\(width: hitSize, height: hitSize, alignment: alignment\)/);
    const row = section(rows, "struct CalendarTaskRow:", "private var taskTitle:");
    assert.match(row, /HStack\(alignment: \.top, spacing: 6\)/);
    assert.match(row, /alignment: \.top\) \{ skipped in/);
    assert.match(row, /\.frame\(width: showsDocumentBadge \? 19 : 44, height: 44, alignment: \.top\)/);
    assert.doesNotMatch(row, /topTrailing|hitSize:|\.offset\(|\.clipped\(|padding\(\.trailing, -/);
});

test("the title and time stay four points apart independently of the badge's 44-point tap height", () => {
    const group = section(rows, "private var taskTextAndTime:", "private func documentBadge(");
    assert.match(group, /VStack\(alignment: \.leading, spacing: 4\) \{\s*taskTitle\s*scheduledTime\s*\}/);
    assert.doesNotMatch(group, /documentBadge|frame\(|Spacer\(/);
    const details = section(rows, "private var calendarTaskDetails:", "private var taskTextAndTime:");
    assert.match(details, /HStack\(alignment:[^\n]+\{\s*taskTextAndTime.fixedSize\(horizontal: true, vertical: true\)\s*documentBadge\(document\).fixedSize\(\)/);
    assert.doesNotMatch(details, /\bscheduledTime\b|\btaskTitle\b/);
    assert.match(rows, /if !showsDocumentBadge \{\s*VStack\(alignment: \.leading, spacing: 5\) \{ taskTitle; scheduledTime \}/);
});

test("checkwavy completion, double-tap skip and clockwavy reminder behavior are retained", async () => {
    const circle = await read("Vellix/Tasks/TaskCompletionCircle.swift");
    assert.match(circle, /isSkipped \? "xmarkwavy" : "checkwavy"/);
    assert.match(circle, /TapGesture\(count: 2\).exclusively\(before: TapGesture\(\)\)/);
    assert.match(rows, /Task \{ await model.complete\(entry, skipped: skipped\) \}/);
    assert.match(rows, /if entry.task.metadata.reminderEnabled \{\s*LibraryIcon\(name: "clockwavy"/);
});

test("Calendar origin takes precedence over parent fallback and clears when the document is closed", () => {
    const back = section(environment, "func returnFromDocument(", "func focusLibrarySearch(");
    assert.match(back, /selectedDestination == \.calendar, calendarDocumentReturnID == document.id/);
    assert.ok(back.indexOf("calendarDocumentReturnID == document.id") < back.indexOf("document.parentDocumentID"));
    assert.match(back, /selectedDocumentID = nil\s*refresh\(\)/);
    assert.match(back, /select\(parent\)/);
    assert.match(environment, /if selectedDocumentID == nil \{ calendarDocumentReturnID = nil \}/);
    assert.match(environment, /if selectedDestination != \.calendar \{ calendarDocumentReturnID = nil \}/);
    assert.doesNotMatch(back, /calendar.select|calendar.mode|CalendarModel\(/);
});

test("badge opens validate current identity and Space without resolving the parent or a matching title", () => {
    const open = section(environment, "func openCalendarDocument(", "func createEventNote(");
    assert.match(open, /requireDocument\(id: document.id\)/);
    assert.match(open, /guard !current.isTrashed/);
    assert.match(open, /guard !isSwitchingSpace, current.spaceID == selectedSpaceID/);
    assert.match(open, /select\(current\)/);
    assert.match(open, /if returnToCalendar, selectedDestination == \.calendar/);
    assert.match(open, /calendarDocumentReturnID = current.id/);
    assert.doesNotMatch(open, /parentDocumentID|\.title ==/);
});

test("iPad captures and restores the return target as existing tab navigation metadata", () => {
    const observed = section(pad, "var observedLocation:", "func capture(");
    const apply = pad.slice(pad.indexOf("private func apply("));
    assert.match(pad, /struct PadWorkspaceLocation:[\s\S]*?var calendarDocumentReturnID: String\?/);
    assert.match(observed, /calendarDocumentReturnID: environment.calendarDocumentReturnID/);
    assert.match(apply, /if location.destination.base == \.calendar \{\s*environment.calendarDocumentReturnID = location.calendarDocumentReturnID/);
    assert.match(pad, /if result.documentID == nil \{ result.calendarDocumentReturnID = nil \}/);
    assert.doesNotMatch(apply, /WKWebView|loadHTMLString|calendar.select|CalendarModel\(/);
});

test("native routing regressions cover exact nested and collection pages plus deeper navigation and iPad tabs", async () => {
    const tests = await read("Vellix/VellixTests/SpaceEnvironmentTests.swift");
    assert.match(tests, /@Test\(arguments: \["nested", "collection"\]\)/);
    assert.match(tests, /calendarBadgeOpensExactPageAndReturnsToCalendarInsteadOfItsParent/);
    assert.match(tests, /calendarReturnSurvivesDeeperPagesWithoutChangingOrdinaryParentNavigation/);
    assert.match(tests, /calendarBadgeRejectsTrashedAndOtherSpaceDocuments/);
    assert.match(await read("Vellix/VellixTests/PadWorkspaceTests.swift"), /calendarBadgeReturnSurvivesSwitchingIPadTabs/);
});
