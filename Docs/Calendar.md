# Penned Calendar

## Navigation And Presentation

Calendar replaces Today in the third bottom-left library tab and in the sidebar. Home and Starred are unchanged. There are exactly two modes: Week and Day. `AppEnvironment.calendar` owns one shared `CalendarModel`; changing modes or opening a document does not reset its selected date or expansion state.

Week contains seven date bubbles and seven independently expandable sections. Date selection expands and locates that day without collapsing others. Previous/next, Today, Expand All, Collapse All, and pull-to-refresh have real actions. Day uses the same rows and date navigator, with one daily agenda rather than an hourly grid. Unscheduled document tasks have a separate section in both modes, without inventing a due date.

Calendar uses the existing dark surfaces, lavender accent, rounded typography, and asset icons. Calendar document previews use `NestedPageThumbnail` with the actual document JSON, appearance, cover, and attachment store at 37 x 48, slightly smaller than Templates' 43 x 56. Multiple task rows can refer to the same document without creating duplicate documents.

## Apple Calendar

`AppleCalendarService` isolates `EKEventStore` in an actor and returns immutable snapshots. It requests event access only when the user selects Connect Apple Calendar. Reading events requires full event access; EventKit does not provide read-only authorization. Penned never saves or deletes Apple events and does not request Apple Reminders access.

Fetching is limited to the visible week, shared by Week and Day, and suspended when Calendar is not visible. Reload generations discard obsolete results after fast navigation. Event-store changes, task/document changes, app activation, midnight, locale, and time-zone changes refresh the visible agenda. Denied/restricted access does not hide Penned tasks. Both application configurations contain the required privacy description and enable calendar access for the sandboxed Mac target.

Snapshots retain calendar colors, all-day status, timing, recurrence occurrence identity, and available location, notes, URL, organizer, status, and availability. Multi-day events are included on every overlapping day, with exclusive end dates. Duplicate fetch results are removed by source/calendar/server identity and original occurrence date. Distinct calendar copies remain separate to preserve their real calendar colors and avoid merging unrelated notes.

The SwiftUI event sheet displays only information supplied by EventKit. Open in Calendar uses `calshow:` with the event's date. This opens the corresponding date in Apple Calendar, not a guaranteed event-detail deep link: EventKit exposes no public event-ID URL API. Failed app opening is surfaced as an error.

## Tasks And Recurrence

The agenda reads `DocumentTaskRepository`, never a second task database. Current task completion calls `AppEnvironment.setTaskCompleted` with the expected occurrence UUID, captures pending source edits, updates authoritative document JSON, synchronizes its cached editor, and flushes the existing notification manager. Stale or duplicate completion attempts are rejected. Circular controls replace neither document checklists nor their editor behavior. The reminder icon is shown only when `reminderEnabled` is true.

Completed occurrences come from the task's existing history. Upcoming repeat dates are calculated by `TaskRepeatRule` as read-only projections, not persisted tasks or additional notification requests. Only the current occurrence is completable. Future projections become actionable when earlier occurrences are completed; Penned deliberately does not skip an overdue occurrence or silently complete a different scheduled date. Historic occurrence controls are noninteractive because the existing task system does not support rewriting old completion history.

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

No iOS application build, launch, simulator, or on-device test is performed by this implementation task. Native interaction/layout, actual calendar authorization, Calendar-app navigation, and notification delivery require the user's Xcode/device testing. Native regression tests are supplied but not executed. Full application-source type checking against the iOS SDK passed with existing unrelated warnings; the seven new Calendar files also passed isolated SDK type checks. Project source membership, both privacy configurations, and SQLite association uniqueness/rollback/cascade checks passed. These checks are not evidence of real-device verification.

Apple references: [Event-store access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [External identifiers](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier), [Event retrieval](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).
