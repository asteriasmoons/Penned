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

## Earlier Verification Boundary

The web editor bundle is rebuilt and synchronized. The 40-test focused suite, including generated-bundle bridge round trips, passes, exercising conversion, scheduling metadata, completion, reloading, ordinary checklist behavior, rich-text preservation, task copying, splitting, read-only external completion, and undo/redo. A separate SQLite schema check passed for the change queue and task/history deletion cascades.

Previous headless Chrome checks at 390 x 640 and 1280 x 720 verified the custom metadata icon masks, the previous `#FF499E` text and icon color, removal of inline dots, metadata-tap scheduling requests, normal text editing, and checkbox completion requests. These checks cover the web editor, not the native SwiftUI task sheet or keyboard toolbar. The subsequent `#714FAB` color swap was not retested, as requested.

Swift source parsing and isolated non-build type checks cover the new task domain, repository, notification manager, and scheduling sheet. The isolated checks use signature stand-ins for surrounding application types, not an application build. Native regression tests were added but not executed.

The existing table tests have five pre-existing failures unrelated to the new task extension; table runtime files were intentionally left unchanged. No iOS/Xcode build, app launch, simulator run, or iPhone notification/keyboard/layout test was performed.

## Earlier Editable Task History Pages (October 20, 2026)

Explicit checklist-to-task conversion now creates real persisted child documents:

1. The task's text becomes the initial title of a nested task page. The source task has a green-dot **Completed Tasks** link that opens this page.
2. The task page retains the custom circular completion control and displays the repeat and reminder assets with their schedule labels.
3. A nested **Completed Tasks** page holds completion and skip records with scheduled date, original task text, outcome, and event date/time. Times explicitly use `h:mm a` (AM/PM), including reminder labels.

Both pages, their titles, and the recorded entries are editable. Additional notes and nested pages are supported. The source task's occurrence history is still authoritative for recurrence and reminders; editing a recorded checklist entry does not complete the source task again. A document-level `taskHistoryProjection` watermark records which occurrence IDs have already been appended, so subsequent completions preserve edits and do not resurrect manually deleted entries. Source undo retracts its recorded occurrences without deleting unrelated notes. Customized page titles are preserved; otherwise the task title follows source text changes.

Single taps wait 300 ms to distinguish the gesture from a double tap. Double tapping the source or task-page completion circle records one **skipped** occurrence, without first recording a completion. Recurring skips advance the existing calendar-based recurrence rule once; nonrecurring skips stay closed and stop outstanding reminders. Records retain their original task text and time zone. Legacy history decodes as completed events.

Page creation and appending happen within the existing document/task-index transaction, using stable task-derived document IDs. Migration `v24_task_history_pages` backfills existing tracked tasks. The normal document search, parent hierarchy, library ownership, and synchronization paths carry the pages and editable content. Copies/templates remap task/page identities, clear inherited occurrence records, and retain authored notes and nested pages. Live editor updates append/retract only occurrence nodes and update the watermark through ProseMirror transactions, preserving current typing, marks, and selection. No WebView ownership/lifecycle changes were made.

### Files Changed for This Addition

| File | Change |
| --- | --- |
| `Vellix/Tasks/DocumentTask.swift` | Backward-compatible outcome/text/time-zone history, skip transitions, AM/PM reminder labels. |
| `Vellix/Tasks/DocumentTaskRepository.swift` | Transactional, idempotent editable page projection; occurrence outcomes in repository queries/actions. |
| `Vellix/Tasks/TaskHistoryPageHeader.swift` | Editable task-page title, custom completion circle, double-tap skip, repeat/reminder labels. |
| `Vellix/Persistence/AppDatabase.swift` | Existing-task history-page backfill migration. |
| `Vellix/Documents/DocumentRepositories.swift` | Scoped page/task lookup and consistent identity mapping for cloned task/page trees. |
| `Vellix/Documents/StructuredTemplateContent.swift` | Independent copied tasks/pages while retaining authored notes and clearing inherited occurrences. |
| `Vellix/Editor/TipTapContentAnalyzer.swift` | Persist projection metadata and recognize the source's inline task-page link. |
| `Vellix/Editor/TipTapBridgeTypes.swift` | Explicit skip outcome and task text in completion events. |
| `Vellix/Editor/TipTapEditorSession.swift` | Complete/skip handling, live history updates, nested-page refresh/navigation. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Equivalent integration in the existing separate Mac adapter. |
| `Vellix/Editor/DocumentEditorCache.swift` | Refresh cached task/history pages on reopening. |
| `PennedMac/Editor/MacDocumentEditorCache.swift` | Equivalent cached-page refresh on Mac. |
| `Vellix/Editor/DocumentEditorView.swift` | Shared task-page header and main-thread history update observation on iPhone/iPad. |
| `PennedMac/Editor/MacDocumentEditorContainer.swift` | Shared header and update observation in the Mac document surface. |
| `Vellix/App/AppEnvironment.swift` | Preserve pending task-page/history edits before external complete/skip actions. |
| `Vellix-backend/src/document-tasks.js` | Single/double-tap lifecycle, green-dot link, AM/PM labels, schema metadata, incremental history refresh. |
| `Vellix-backend/src/editor.js` | Preserve/load document-level projection metadata in the existing editor load transaction. |
| `Vellix-backend/src/tiptap.html` | Green-dot history-link styling. |
| `Vellix/VellixEditor.bundle/tiptap.bundle.js` | Mechanically synchronized task functions and metadata-load hooks in the existing artifact, without rebuilding. |
| `Vellix/VellixEditor.bundle/tiptap.html` | Matching history-link styling in the shipping resource. |
| `Scripts/install-task-history-hooks.mjs` | AST-scoped artifact synchronization with dependency/shape assertions; no compiler or bundler. |
| `Scripts/test-task-history.mjs` | Shipping-editor regressions for gestures, navigation, editing, watermark round trips, incremental updates, and retraction. |
| `Vellix-backend/tests/document-tasks.test.js` | Maintained-source single/double-tap, link, text, and timestamp checks. |
| `Vellix-backend/tests/document-task-runtime.test.js` | Account for the single-tap recognition window in the existing runtime test. |
| `Vellix/VellixTests/DocumentTaskTests.swift` | Added native tests for migration-compatible history, skip recurrence, hierarchy, editing/deletion, copies, and independent notes/pages. |
| `Docs/DocumentTasks.md` | Behavior, file inventory, and current verification boundary. |

### Current Verification

- **111 passed**: `node --test Scripts/test-task-history.mjs Scripts/test-mobile-editor-interactions.mjs Scripts/test-block-swipe-selection.mjs Scripts/test-phone-gallery-loading.mjs Scripts/test-mac-editor-navigation.mjs Scripts/test-mac-document-scrolling.mjs`.
- **11 passed**: `node --test tests/document-tasks.test.js` in `Vellix-backend`.
- JavaScript syntax checks passed for maintained task/editor source and the mechanically updated shipping artifact; scoped `git diff --check` passed.
- No build, bundling, Swift compilation, app launch, or simulator run was performed. New native tests were added but not executed. The existing source-lock fixture was not rebaselined.

Physical iPhone/iPad/Mac verification remains necessary for the native title/circle layout, single/double-tap feel with the keyboard, page navigation, disk reopening, recurrence/reminder delivery, and two-device synchronization of editable history. Existing iPad WebView ownership, unrelated styling/settings, and Mac navigation/scrolling architecture were intentionally left unchanged.

## Read-Only History Sheet (October 21, 2026)

The current history interface supersedes the page-navigation/editing interface described above. Tapping the source task's green-dot link opens a **non-editable sheet**, not a nested document. The sheet header uses the task's actual current text, not a generic "Task History" heading or a customized legacy document title.

The sheet uses the existing `pennedSheet` chrome, frosted `pennedSheetField` surfaces, rounded black typography, violet/coral semantic colors, and `clockfill`, `checkwavy`, and `xmarkwavy` assets. The timeline shows newest events first, with a stable ID tie-break for equal timestamps, completion/skip counts, each event's date and weekday, and an explicit AM/PM time in its recorded time zone. Original task text is retained on entries when it differs from the current task name. Empty, unavailable, and load-error states use actual repository results rather than sample records.

There are no text fields, completion actions, editing gestures, delete controls, or embedded editors in the history sheet. Its only actions are dismissal and retrying a failed read. Ordinary document editing and the source task's single-tap completion/double-tap skip behavior are unchanged. Existing stored task/history documents, prior edits, and notes are retained without a destructive migration; the sheet reads the authoritative task occurrence history. Legacy `pageOpenRequest` task-page IDs are intercepted natively for both source links and links from existing task pages. Ordinary nested-page navigation keeps its original parent-scoped path.

The open sheet refreshes when task data changes and dismisses on Space, document, or Mac-tab transitions. Presenting it dismisses the iPhone/iPad keyboard without replacing or reparenting the existing editor WebView. Both platform adapters use the same shared sheet.

### Files Changed for the Sheet

| File | Change |
| --- | --- |
| `Vellix/Tasks/TaskHistorySheet.swift` | New shared, read-only timeline sheet, typed request, live scoped reads, counts/status/empty/error states, and time-zone-aware AM/PM display. |
| `Vellix/Editor/TipTapEditorSession.swift` | Scoped history request routing and request reset in the mobile editor model. |
| `PennedMac/Editor/MacTipTapEditorSession.swift` | Equivalent routing/reset in the existing Mac model adapter. |
| `Vellix/Editor/DocumentEditorView.swift` | Present the history sheet on iPhone/iPad, dismiss the keyboard, and clear requests when leaving the document. |
| `PennedMac/Editor/MacEditorPresentations.swift` | Present the shared sheet on Mac and clear requests on document/tab changes. |
| `Scripts/test-task-history.mjs` | Shared-design, task-name title, no-editing-controls, scoped routing, and timeline/read-refresh source checks alongside shipping-editor regressions. |
| `Vellix/VellixTests/DocumentTaskTests.swift` | Added native sheet-routing, foreign-task rejection, ordinary-page preservation, event-zone, weekday/date, and AM/PM tests. |
| `Docs/DocumentTasks.md` | Current read-only-sheet behavior and per-file verification report. |

### Sheet Verification Boundary

**114 checks passed** with `node --test Scripts/test-task-history.mjs Scripts/test-mobile-editor-interactions.mjs Scripts/test-block-swipe-selection.mjs Scripts/test-phone-gallery-loading.mjs Scripts/test-mac-editor-navigation.mjs Scripts/test-mac-document-scrolling.mjs`. Scoped `git diff --check` and JavaScript syntax checks also passed. No compiler, bundler, app launch, or simulator was run. Native regression tests were added but not executed. Rendered sheet layout, Dynamic Type sizing, native presentation/dismissal, and physical iPhone/iPad/Mac behavior remain unverified until an authorized native run. Persistence, synchronization, recurrence, notifications, existing saved content, and WebView ownership/lifecycle architecture were intentionally left unchanged for this presentation change.
