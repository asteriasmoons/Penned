# Penned Calendar

## Navigation And Presentation

Calendar replaces Today in the third bottom-left library tab and in the sidebar. Home and Starred are unchanged. There are exactly two modes: Week and Day. `AppEnvironment.calendar` owns one shared `CalendarModel`; changing modes or opening a document does not reset its selected date or expansion state.

Week contains seven illustrated date cards in a four-card row and a centered three-card row, followed by the selected day's expandable agenda panel. Day uses the matching illustrated summary banner and a grouped vertical event/task timeline, not an hourly grid. Both modes share the existing selected date, previous/next navigation, and pull-to-refresh. The date-range heading is a button that returns to Today. Unscheduled document tasks retain a separate section in both modes, without inventing a due date.

Calendar uses the existing dark surfaces, lavender accent, rounded typography, and asset icons. Event-note and existing daily-note previews use `NestedPageThumbnail` with the actual document JSON, appearance, cover, and attachment store at 37 x 48, slightly smaller than Templates' 43 x 56. Calendar task rows instead use a compact source-document badge. Multiple task rows can refer to the same document without creating duplicate documents.

## Illustrated Week And Day Redesign

The two supplied Week/Day references drive this native presentation update. It
changes `CalendarView.swift` and `CalendarAgendaRows.swift`, not the editor's
Calendar/Week Strip block, its JavaScript bundle, or its collapse implementation.

### Artwork And Native Overlays

All fourteen imported image sets are present in `Vellix/Assets.xcassets`.
Weekday artwork uses Foundation's weekday number, independent of the locale's
first weekday: Sunday = `CardIMG1` (purple), Monday = `CardIMG2` (blue), Tuesday =
`CardIMG3` (pink), Wednesday = `CardIMG4` (teal), Thursday = `CardIMG5` (green),
Friday = `CardIMG6` (gold), Saturday = `CardIMG7` (blue-purple). The corresponding
wide versions are `BannerIMG1` through `BannerIMG7`. The selected date now resolves
both card and banner through that same weekday index: Monday's blue `CardIMG2`
uses blue `BannerIMG2`, and so on for all seven pairs. Both Week and Day banners
and their outlines follow the selected day's artwork; the Week panel is no longer
hardcoded to purple `BannerIMG1`. Event-category indicators remain independent.

Images render in original colors, with proportional aspect-fill cropping to
the card/banner bounds, never stretching. They contain no UI. Dates, counts,
labels, icons, colored outlines, the collapse button, Daily Note action, and
timeline are native SwiftUI views. Image backgrounds cannot intercept touches
and are excluded from accessibility. No images were generated or modified.

### Week Layout

- Seven equal cards occupy a 4+3 arrangement. The lower row is centered and
  retains exactly the same card width/height as the first row. Card dimensions
  derive from the Calendar's own available width, capped for large workspaces.
- Each card has a weekday abbreviation, day number, colored border, and dark
  rounded count panel. Counts come from `model.events(on:)` and `model.tasks(on:)`.
  Selecting a card calls the existing `model.select(day)` and highlights that
  card. VoiceOver receives the complete date, counts, selection, and note status.
- Small-width/large-text count layouts fall back from number-plus-word to the
  number beside the same event/task icon, preserving the actual value rather
  than clipping it. Font sizing follows Dynamic Type, not screen width.
- The selected-day panel has the selected weekday's banner and matching outline,
  the existing Create/Open Daily Note action, and a black internally scrolling
  agenda. The agenda viewport is bounded to 200-340 points according to available
  screen height, so events cannot make that panel grow indefinitely.
- The Daily Note button has a 14-point horizontal inset and top separation from
  the artwork, with 10 points before an expanded agenda or 14 points beneath it
  when collapsed. Its surface no longer touches the banner or outer outline.
- The native disclosure calls `model.toggleDay(model.selectedDate)`. Collapsing
  removes only the agenda viewport; the illustrated header, live summary, Daily
  Note action, and disclosure remain available. Reopening recreates the agenda
  views from the same retained records, without fetching a second data source.

### Day Layout

- The matching image banner is visually separate from the timeline and Daily Note
  action. It shows the dynamically formatted selected date, Today/Tomorrow prefix
  where applicable and real event/task counts. Day has no banner collapse button
  or collapse action. Its artwork always keeps the full Day banner height,
  regardless of the selected date's Week-panel expansion state.
- Timeline rows have a thin connecting rail and purple circular markers, plus
  their unchanged real event-category indicators. `CalendarEventRow` continues
  to use `event.calendarColor`; blue calendars stay blue, purple calendars stay
  purple, and no banner color is substituted into event records or indicators.
- Day has separate **All Day**, timed **Events**, and **Tasks** sections, in that order, shown
  when that section has records. All Day initially shows at most the first two
  events. Its 44-point disclosure header shows the full count and expands to all
  events or collapses back to two. Expansion is view state keyed by the selected
  civil date; it does not modify events or the Week panel's saved model state.
- The same fixed/scaled leading column aligns every timeline rail. All-day rows
  show All Day in that column rather than duplicating it beneath the title.
  Tasks and timed events show their actual occurrence/start time beside their
  marker. Task times are not duplicated in the title area. Timed events retain
  their full range/continuation labels beneath the title. An ongoing event enters
  the current day's timeline at midnight without changing its actual start/end.
- Bold titles and subtle separators appear over black. Event details, task
  completion/skip, and associated note/source-document links remain actionable.
- The Week agenda retains its flat chronological display. Day partitions those
  same records, preserving chronological ordering within each section and stable
  typed IDs for ties. Multi-day filtering and time labels still use the existing
  model and event type. No occurrence is copied, persisted, rescheduled, or
  fabricated for this presentation. Unscheduled tasks still have no invented time.
- Task rows retain `TaskCompletionCircle`, single/double-tap completion/skip,
  in-flight guards, reminders, source-document badges, and Calendar return routing.
  Day timeline task titles are bold; the separate iPad Tasks browser retains its
  existing default title styling and layout.

### Shared State And Navigation

`CalendarModel`, its EventKit service, repositories, task recurrence, document
opening, and persistence were not changed. Week and Day still bind to the same
`model.mode` and `model.selectedDate`. Switching modes does not call `select`,
`today`, or replace the model. Week uses the existing per-day `expandedDays` set;
Day's banner is not collapsible and does not read or change that expansion state.
Day's All Day section instead has independent view-local expansion by civil date.
Existing date selection/navigation continues to open the selected Week day.

The date heading's context menu retains Today, Expand All, and Collapse All
without adding an extra button row to the reference composition. The iPad
workspace (whose navigation bar is hidden by its existing shell) receives its
own Calendar heading; other presentations keep the existing navigation title
instead of showing duplicate headings.

The custom Week/Day control uses the requested luminous purple gradient only
for the selected segment. The page is explicitly pitch black and opts into dark
appearance. Existing navigation assets, header, event sheet, error/permission
states, template picker, and Daily Note loading/Space-switch guards remain.
The obsolete seven-section scroll target is replaced with top scrolling for
the selected-day presentation. The Week panel's internal scroll identity follows
the selected civil date, preventing another day's offset from hiding its first
events. The outer page stays lazy for long timelines and unscheduled tasks.

The shell still owns the unchanged bottom navigation. The Calendar retains its
110-point trailing inset so the final row can scroll above that navigation;
safe-area behavior is not replaced with absolute screen positioning. Accessibility
text sizes move the navigator into the scrollable content to keep it usable.

### Files And Verification

- `Vellix/Calendar/CalendarView.swift`: illustrated layouts, artwork mapping,
  native cards/banner overlays, shared control/navigation, bounded Week panel,
  black presentation, responsive sizing, and preserved Daily Note integration.
- `Vellix/Calendar/CalendarAgendaRows.swift`: grouped Day timeline, first-two
  All Day disclosure, aligned real time labels, and stable display ordering while
  retaining existing row actions/category colors. Optional inline time flags
  default to the previous behavior outside the Day timeline.
- `Docs/Calendar.md`: current behavior, artwork mapping, integration guarantees,
  and the verification boundary.

No builds, tests, Swift compilation, linters, app launches, or simulators were
run. Source review and whitespace checks do not establish pixel matching,
native hit testing, compile success, nested-scroll feel, or device performance.
Physical iPhone/iPad verification remains necessary for the two layouts,
small-screen/large-text behavior, Week-panel and All Day collapse/reopen, rapid date/mode
switches, authorization, event details, task actions, Daily Notes, and bottom-bar
clearance. No claim of on-device visual or functional validation is made.

### Daily Note And Source Badge (October 22, 2026)

The full-width Daily Note action uses `linedpages`, the existing Create/Open label, and trailing `chevright` within a subtle lavender surface. It still opens or creates the selected date's note through the existing template flow; loading and Space-switch guards remain intact.

Calendar task badges use `linedpages`, the actual source page's title, and `chevright`, with a 44-point button target. The task title and time remain one leading-aligned group with a 4-point gap, independent of the badge's tap height. In Week mode the badge aligns with the title; Day mode aligns it with the time. When the text group and badge cannot fit beside one another, the badge moves beneath the complete group instead of separating the title from its time. Calendar reserves only the circle's visible 19-point width before the 6-point gap to task text, bringing the circle, text, time, and badge back to the row's leading edge. Its unchanged 44-point completion control is horizontally centered over that visual column without clipping or shrinking it. The separate Tasks browser retains its original 44-point layout column. Completion still uses `checkwavy`, double-tap still skips, and reminder indicators still use `clockwavy`.

The badge resolves `entry.task.documentID`, never the parent or a title match. It opts into a Calendar return target so Back from an exact nested or collection page returns to Calendar rather than redirecting to its parent. Opening deeper pages still returns through their parents before reaching that Calendar entry point. The return target is cleared on closing the document, leaving Calendar, or changing Spaces, and is captured/restored with each existing iPad tab location. Calendar mode, date, expansion, and scroll ownership are unchanged.

Files changed for this scoped follow-up:

- `Vellix/Calendar/CalendarView.swift`: Daily Note button styling/assets and compact badges for unscheduled Calendar tasks.
- `Vellix/Calendar/CalendarAgendaRows.swift`: adaptive compact badges for Calendar tasks; existing event-note/daily-note previews and the separate iPad Tasks browser layout remain unchanged.
- `Vellix/App/AppEnvironment.swift`: exact-record validation and opt-in Calendar return routing before the ordinary parent fallback.
- `Vellix/App/PadWorkspaceModel.swift`: carries the return target in existing tab navigation metadata, without changing WebView ownership or lifecycle.
- `Vellix/VellixTests/SpaceEnvironmentTests.swift`: native routing cases for same-title pages, nested and collection pages, deeper navigation, Calendar state preservation, Trash and Space guards.
- `Vellix/VellixTests/PadWorkspaceTests.swift`: native Calendar return coverage across iPad tab switches.
- `Scripts/test-calendar-actions.mjs`: non-compiling asset/source-contract checks for the scoped UI, exact-ID route, return behavior, and preserved completion/reminder controls.
- `Docs/Calendar.md`: records these changes and their verification boundary.

No build, Swift compilation, app launch, or simulator is run. Node source checks can verify wiring and asset references, not native layout or hit testing. The added Swift tests are not executed; physical iPhone/iPad verification is still required for long titles, larger text, badge taps, and Calendar return after tab switching. Mac Calendar source, recurrence/persistence, and editor lifecycle are intentionally unchanged.

## Apple Calendar

`AppleCalendarService` isolates `EKEventStore` in an actor and returns immutable snapshots. It requests event access only when the user selects Connect Apple Calendar. Reading events requires full event access; EventKit does not provide read-only authorization. Penned never saves or deletes Apple events and does not request Apple Reminders access.

Fetching is limited to the visible week, shared by Week and Day, and suspended when Calendar is not visible. Reload generations discard obsolete results after fast navigation. Event-store changes, task/document changes, app activation, midnight, locale, and time-zone changes refresh the visible agenda. Denied/restricted access does not hide Penned tasks. Both application configurations contain the required privacy description and enable calendar access for the sandboxed Mac target.

Snapshots retain calendar colors, all-day status, timing, recurrence occurrence identity, and available location, notes, URL, organizer, status, and availability. Multi-day events are included on every overlapping day, with exclusive end dates. Duplicate fetch results are removed by source/calendar/server identity and original occurrence date. Distinct calendar copies remain separate to preserve their real calendar colors and avoid merging unrelated notes.

The SwiftUI event sheet displays only information supplied by EventKit. Open in Calendar uses `calshow:` with the event's date. This opens the corresponding date in Apple Calendar, not a guaranteed event-detail deep link: EventKit exposes no public event-ID URL API. Failed app opening is surfaced as an error.

## Tasks And Recurrence

The agenda reads `DocumentTaskRepository`, never a second task database. Current task completion calls `AppEnvironment.setTaskCompleted` with the expected occurrence UUID, captures pending source edits, updates authoritative document JSON, synchronizes its cached editor, and flushes the existing notification manager. Stale or duplicate completion attempts are rejected. Circular controls replace neither document checklists nor their editor behavior. The reminder icon is shown only when `reminderEnabled` is true.

Completed occurrences come from the task's existing history. Upcoming repeat dates are calculated by `TaskRepeatRule`, not persisted as additional tasks or notification requests. Both the current occurrence and later scheduled repeat dates have working completion controls. Completing a projected date records that exact scheduled date, task text, completion timestamp, and time zone through the existing task metadata/history pipeline. Earlier unfinished occurrences retain their current UUID, schedule, reminder, and unchecked state. As those earlier occurrences are completed, recurrence advances past dates already recorded in history. Completed dates appear once in Calendar, without an extra pending projection. Historic occurrence controls remain noninteractive; this does not add editing to the read-only history sheet.

Projected occurrence identifiers are validated against the task's current repeat rule before any write. Invalid dates, changed schedules, non-finite timestamps, already-recorded dates, and stale UUIDs are rejected. A projected row that has become the current occurrence during an asynchronous source capture completes the matching current date rather than failing or completing a different date. The existing per-task in-flight guard prevents simultaneous taps from producing duplicate writes, and the repository revalidates inside its transaction.

### Completion Control Correction (October 21, 2026)

The previous implementation rendered completion circles for projected repeat dates but disabled those buttons. The fix changes these files:

- `Vellix/Calendar/CalendarAgenda.swift`: makes pending scheduled occurrences actionable and filters already-recorded projection dates.
- `Vellix/Calendar/CalendarAgendaRows.swift`: retains the 44-point completion hit target and actual button action; removes the obsolete future-occurrence restriction labels.
- `Vellix/Tasks/DocumentTask.swift`: validates selected recurrence dates, records out-of-order completions without moving an earlier pending task, and advances past already-recorded dates.
- `Vellix/Tasks/DocumentTaskRepository.swift`: validates and persists the requested occurrence through authoritative document JSON in the existing scoped transaction.
- `Vellix/App/AppEnvironment.swift`: passes the selected Calendar occurrence to the repository while retaining source/history saves, Space checks, editor synchronization, and reminder flushing.
- `Vellix/VellixTests/CalendarTests.swift`: updates actionable-projection expectations and tests the single completed-row representation.
- `Vellix/VellixTests/DocumentTaskTests.swift`: adds native regression coverage for the Calendar-to-AppEnvironment completion path, overdue preservation, repeat advancement, duplicate/stale input, projected-to-current transitions, DST/month-end/interval validation, and disk reopening.
- `Scripts/test-task-history.mjs`: adds non-compiling source-contract checks for the button, routing, validation, and deduplication paths.
- `Scripts/test-ipad-workspace.mjs`: updates stale source assertions to follow the earlier explicitly typed scroll dimensions and existing phone gallery crop overrides while retaining the iPad sizing checks; no layout or gallery source change.
- `Docs/Calendar.md`: records the corrected interaction and verification boundary.

No build, compiler harness, app launch, or simulator is run for this correction. The new native tests are supplied but not executed. Source and JavaScript checks do not prove Swift compilation, device hit testing, notification delivery, or cross-device synchronization; tapping the completion circle on a physical device still needs verification.

### Document Circle Parity (October 21, 2026)

iPhone and iPad Calendar circles use the same interaction as document tasks: one tap completes or clears a non-repeating task; a double-tap skips an occurrence without first completing it. The native circle uses the exclusive double-before-single tap gesture already used by the task-page header. Both native surfaces now share `TaskCompletionCircle`, with the document editor's 19-point circle, 2-point outline, purple filled state, and 13-point white wavy check/X assets. Calendar retains a 44-point hit target. Busy or inactive controls cannot send another action. VoiceOver exposes both the primary completion action and an explicit Skip occurrence action.

Calendar forwards `skipped` all the way through `AppEnvironment.setTaskCompleted` to the existing document metadata transition and history projection. Current repeat dates advance through the same `DocumentTaskMetadata.completing` implementation as the editor. Skipped Calendar records use the X state, not a checkmark. Non-repeating completed or skipped tasks can be cleared while retaining their recorded history. The read-only history sheet and historic occurrence editing policy are unchanged. The WebView editor, gesture ownership, and lifecycle are not modified.

Files changed for this follow-up:

- `Vellix/Tasks/TaskCompletionCircle.swift`: shared native check/skip appearance, mutually exclusive tap gestures, enabled-state protection, and accessible actions.
- `Vellix/Tasks/TaskHistoryPageHeader.swift`: reuses the shared circle while preserving its existing save, lock, sizing, and completion behavior.
- `Vellix/Calendar/CalendarAgendaRows.swift`: replaces the separate completion-only control with the shared circle and forwards single/double outcomes.
- `Vellix/Calendar/CalendarAgenda.swift`: derives each occurrence's skipped state from its own history ID.
- `Vellix/Calendar/CalendarModel.swift`: accepts a skip outcome and forwards the same completed/skip values used by document tasks.
- `Vellix/App/AppEnvironment.swift`: carries skips from the iPhone/shared Calendar callback into the authoritative task save path.
- `Vellix/App/PadWorkspaceView.swift`: carries skips from each iPad Calendar tab's callback, with an explicit error if its owner is unavailable.
- `PennedMac/Workspace/MacWorkspaceModel.swift`: updates the shared callback signature; Mac row layout and controls are intentionally unchanged.
- `Vellix/VellixTests/DocumentTaskTests.swift`: supplies native integration tests for one recorded skip, one repeat advancement, per-occurrence X states, skipped projections, duplicate protection, and clearing non-repeating tasks.
- `Scripts/test-task-history.mjs`: checks exclusive gesture/visual parity and every native callback's skip routing alongside existing shipping-editor behavior tests.
- `Docs/Calendar.md`: records the corrected parity and remaining verification boundary.

No builds, native test compilation, app launches, or simulators are run. Native tap recognition and end-to-end UI behavior still require physical-device verification; source and JavaScript checks alone do not establish those results.

## Event Notes

Migration `v12_calendar_event_notes` stores one document association per calendar-event occurrence, with a cascading document foreign key. The real document and association are created atomically through the existing document repository and search indexing. Repeated creation reopens the same document. Recurring Apple events have separate notes for separate original occurrences.

Lookup uses the scoped server identity, falls back to a unique local ID for calendar moves, and uses the scoped external identifier after resynchronization. Floating and all-day recurrence identities use civil date/time components, so changing the device time zone does not orphan their notes. Resolved identity changes update the association. Ambiguous identifiers are never merged. If both local/server identifiers and calendar/source identities change, automatic recovery cannot be guaranteed; the original note remains a normal library document. Deleting an Apple event does not delete Penned notes. Trashed notes offer Restore instead of creating a duplicate; permanent document deletion removes its association.

## Files

- `Calendar/CalendarAgenda.swift`: date intervals, immutable event identities/snapshots, deduplication, task/history/recurrence projection.
- `Calendar/AppleCalendarService.swift`: isolated EventKit access/fetching, supported-platform app/settings navigation.
- `Calendar/CalendarEventNoteRepository.swift`: event-note associations, identity resolution, atomic creation.
- `Calendar/CalendarModel.swift`: shared mode/date/expansion/loading state, data refresh, completion coordination.
- `Calendar/CalendarAgendaRows.swift`: event markers, circular task controls, genuine document previews.
- `Calendar/CalendarView.swift`: Week and Day agendas, date navigation, expansion, permission states.
- `Calendar/CalendarEventDetailSheet.swift`: event information, Apple Calendar opening, event-note creation/reopening/restoration.
- `App/AppEnvironment.swift`: shared service ownership, existing completion and document-navigation integration.
- `App/VellixShellView.swift`, `Documents/LibraryChrome.swift`: replacement of Today with Calendar in existing navigation.
- `Documents/DocumentRepositories.swift`: reusable in-transaction document creation, with unchanged regular creation semantics.
- `Persistence/AppDatabase.swift`: association migration.
- `VellixApp.swift`: foreground refresh alongside existing reminder reconciliation.
- `Vellix.xcodeproj/project.pbxproj`: explicit source/test membership, calendar privacy descriptions, Mac calendar sandbox capability.
- `VellixTests/CalendarTests.swift`: regression coverage for expansion/mode state, DST, deduplication, multi-day events, recurring projections, unscheduled/template filtering, note identity, persistence, cascades, and rollback.

## Verification Boundary

No iOS application build, launch, simulator, or on-device test is performed by this implementation task. Native interaction/layout, actual calendar authorization, Calendar-app navigation, and notification delivery require the user's Xcode/device testing. Native regression tests are supplied but not executed. Earlier Calendar implementation checks included application-source and isolated SDK type checking, project membership, privacy configurations, and SQLite association uniqueness/rollback/cascade checks. Those earlier checks predate the October 21 completion correction and do not verify its Swift compilation or physical-device behavior.

Apple references: [Event-store access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [External identifiers](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier), [Event retrieval](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).
