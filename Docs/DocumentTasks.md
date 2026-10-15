# Document-Integrated Tasks

## Behavior

- A checklist is not a tracked task until the user explicitly chooses Convert to Task.
- The `clockfill` toolbar action appears only in checklist context. There is no inline three-dots button; tap tracked task metadata to edit its schedule.
- The task scheduling menu has Remind Me and Repeat as its primary actions. Convert Back to Checklist removes tracking without removing content or formatting.
- Reminders use a calendar and time picker. Repeat supports daily, weekdays, weekly, monthly, yearly, and custom intervals with weekday, month, and day-of-month controls where applicable.
- Inline repeat and reminder indicators are separate, use `repeatfill` and `clockwavy`, and display in `#714FAB`. The task sheet uses the same icons and accent. A daily rule is labeled Daily.
- Confirmation awaits the editor command, canonical document save, and notification reconciliation. Permission denials are reported without discarding the saved configuration.

## Persistence And Recurrence

`taskItem.attrs.trackedTask` is authoritative. It contains task and occurrence UUIDs, a scheduled timestamp, reminder state, recurrence configuration, and completed occurrences. Rich text remains in the original checklist node.

Migration `v11_document_tasks` adds a document-task index, completion index, and transactional document-change queue. SQLite triggers enqueue changes; `AppDatabase.write` reconciles those changes before committing. This includes edits, moves, snapshots, deletion, and template changes, without depending on an open editor. Task and completion indices cascade when a source document is permanently deleted.

The task index is derived and cannot independently edit content. Source text is retrieved from document JSON. Each record exposes its current document, root document, parent page, and block identifiers.

Completion appends a uniquely identified occurrence. Repeating completion computes the next date from the completed occurrence's scheduled date, changes the occurrence UUID, and leaves the original checkbox unchecked for its next occurrence. It does not skip overdue occurrences based on the current time. Calendar arithmetic preserves wall-clock time across DST and retains the original day/month anchor when shorter months or non-leap years require clamping.

Task changes participate in ProseMirror history. Undo restores the previous task metadata and the database index follows that restored document. Reopening an explicitly completed non-repeating task retains its historical completion and starts a new occurrence identity.

Template and document copies receive fresh task/occurrence IDs and empty completion histories. Enter creates an ordinary next checklist item, not another tracked task. Templates retain the configured absolute dates and recurrence rules, but do not generate notifications until instantiated as documents. Nested template pages follow the same rules.

## Notifications

`TaskNotificationsManager` owns permissions, pending requests, delivered-request cleanup, foreground validation, and notification navigation. Its identifier is deterministically derived from the persisted task and occurrence IDs. Reconciliation replaces changed requests and removes requests belonging to removed, completed, untracked, archived, trashed, or template tasks.

It schedules one non-repeating notification for the current occurrence, not a system-level repeating notification. The next notification is scheduled when the user completes the occurrence. Notifications open the source document. Startup and foreground activation refresh the pending queue. In-memory databases and previews never change system notifications.

iOS has a pending-request limit. The manager schedules up to 60 nearest future task reminders, reduced further if other requests need capacity. Later reminders are replenished on app activation or task/document changes. Dates already in the past are retained as overdue configuration, not turned into immediate alerts.

## Future Tasks And Calendar

`AppEnvironment.tasks` provides `all`, `tasks(documentID:includingNestedPages:)`, `scheduled(on:calendar:)`, `upcoming`, `recurring`, `reminders`, and `completedOccurrences` queries. Returned tasks include recurrence, reminder, source references, current occurrence, and history. Completed-occurrence results include task, document, and block references.

Use `AppEnvironment.setTaskCompleted(id:completed:)` for completion outside the editor. It captures any pending source edits, writes the source checklist and occurrence history transactionally, then updates its cached editor without replacing its rich-text content. The repository requires an expected occurrence ID to reject stale duplicate completion requests.

No Calendar UI, EventKit event synchronization, or unrelated editor redesign was added.

## Changed Files

| File | Reason |
| --- | --- |
| `Vellix/Tasks/DocumentTask.swift` | Task metadata, occurrence history, recurrence rules, calendar arithmetic, and bridge context. |
| `Vellix/Tasks/DocumentTaskRepository.swift` | Derived SQL indices, source-document updates, hierarchy-aware queries, and stale-occurrence protection. |
| `Vellix/Tasks/TaskNotificationsManager.swift` | Real local notification permission, scheduling, replacement, cancellation, and navigation. |
| `Vellix/Persistence/AppDatabase.swift` | Task migration, transactional index reconciliation, and in-memory notification isolation. |
| `Vellix/Documents/StructuredTemplateContent.swift` | Independent task identities and histories in cloned content. |
| `Vellix/Documents/DocumentRepositories.swift` | Task identity regeneration on document copies and template materialization. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Task context, scheduling, completion, and snapshot events. |
| `Vellix/Editor/TipTapEditorSession.swift` | Task commands, immediate saves, scheduling confirmation, completion, and cached-editor synchronization. |
| `Vellix/Editor/TaskEditorSheet.swift` | Functional conversion, reminder, repeat, custom-repeat, removal, and confirmation controls. |
| `Vellix/Editor/DocumentEditorView.swift` | Conditional clock asset, scheduling-sheet presentation, and existing banner integration. |
| `Vellix/App/AppEnvironment.swift` | Repository/manager ownership, notification navigation, and external completion coordination. |
| `Vellix/VellixApp.swift` | Foreground reminder reconciliation and background save flushing. |
| `Vellix/VellixTests/DocumentTaskTests.swift` | Native regression tests for recurrence boundaries, disk persistence, nested pages, templates, copies, and deletion. |
| `Vellix-backend/src/document-tasks.js` | Existing-checklist node behavior plus tracked-task attributes, metadata, commands, paste isolation, and snapshots. |
| `Vellix-backend/src/editor.js` | Task extension and command integration into the existing editor. |
| `Vellix-backend/src/tiptap.html` | Compact metadata and active-only checklist actions using existing asset icons. |
| `Vellix-backend/tests/document-tasks.test.js` | Headless task node, interaction, history, copying, and context regression tests. |
| `Vellix-backend/tests/document-task-runtime.test.js` | Generated-bundle bridge round-trip regression test. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js`, `tiptap.html` | Rebuilt and synchronized web editor runtime. |
| `Docs/DocumentTasks.md` | Integration and verification report. |

## Verification Boundary

The web editor bundle is rebuilt and synchronized. The 40-test focused suite, including generated-bundle bridge round trips, passes, exercising conversion, scheduling metadata, completion, reloading, ordinary checklist behavior, rich-text preservation, task copying, splitting, read-only external completion, and undo/redo. A separate SQLite schema check passed for the change queue and task/history deletion cascades.

Previous headless Chrome checks at 390 x 640 and 1280 x 720 verified the custom metadata icon masks, the previous `#FF499E` text and icon color, removal of inline dots, metadata-tap scheduling requests, normal text editing, and checkbox completion requests. These checks cover the web editor, not the native SwiftUI task sheet or keyboard toolbar. The subsequent `#714FAB` color swap was not retested, as requested.

Swift source parsing and isolated non-build type checks cover the new task domain, repository, notification manager, and scheduling sheet. The isolated checks use signature stand-ins for surrounding application types, not an application build. Native regression tests were added but not executed.

The existing table tests have five pre-existing failures unrelated to the new task extension; table runtime files were intentionally left unchanged. No iOS/Xcode build, app launch, simulator run, or iPhone notification/keyboard/layout test was performed.
