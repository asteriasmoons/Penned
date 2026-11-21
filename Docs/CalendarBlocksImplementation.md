# Penned Calendar Blocks — Implementation Plan

## Confirmed product behavior

- **Week Strip** is a date-based content container, modeled on the existing `tabs`/`tabPanel` editor structure. Selecting a date shows only the content authored for that date. Each day's body supports all existing rich-text marks, colors, and nested blocks.
- Users can compose custom calendars by inserting a Week Strip into an Infocard or document. Do not introduce an extra formatting bar or mandatory Day/Week/Month controls.
- **Existing Event** is a separate insertable block, displayed like a simple blockquote: narrow accent stripe at left, event details at right. It references the original calendar event and opens the existing event-detail sheet when tapped. It must not copy the event.

## Existing integration points inspected

- Web editor source: `~/Desktop/penned-editor/src/tabs.js`, `src/editor.js`, `src/tiptap.html`, and `src/public-document.js`.
- Native editor insertion menu: `Vellix/Editor/DocumentEditorView.swift` (`Other Blocks`).
- Native bridge: `Vellix/Editor/TipTapBridgeTypes.swift`, `TipTapEditorSession.swift`, `TipTapWebView.swift`.
- Calendar data and event sheet: `Vellix/Calendar/CalendarModel.swift`, `CalendarEventDetailSheet.swift`, `AppleCalendarService.swift`.
- Calendar currently includes EventKit-backed events; event identity and permissions must be carried across the bridge rather than recreated in JS.

## Stage 1 — Week Strip schema and UI

1. Implement distinct `weekStrip` and `weekDayPanel` nodes (or carefully generalized shared Tabs node-view logic) rather than merely renaming a Tabs block. Each panel has a stable date key (`YYYY-MM-DD`) and block ID; parent stores week anchor, selected date, appearance and identity.
2. Initialize seven consecutive dates according to the user's locale/calendar first weekday, with today's date selected when appropriate. Date keys must be stable across reopening, duplication, and document serialization.
3. Use a horizontal seven-day strip with short weekday labels and day numbers; scroll or compress gracefully on phones. Selecting a day switches visible content without mutating the hidden day's document content or polluting undo history.
4. Support week navigation. Define whether a strip represents a fixed week or a persistent multiweek calendar **before** enabling navigation; otherwise changing the displayed week risks orphaning date content. Persist per-date bodies if navigating across weeks.
5. Keep editor marks, paste/copy, undo/redo, selection, keyboard toolbar, and nested Infocard insertion working through the existing ProseMirror editor.
6. Add insertion menu entry, slash menu entry, rendering CSS, HTML import/export, read-only rendering, block selection, copy/duplicate ID remapping, and document thumbnail support.

## Stage 2 — Linked Existing Event block

1. Introduce `linkedCalendarEvent` as an atomic, selectable block with event identity and source/calendar metadata. Keep event title, time, and location as **display-only resolved data**, not authoritative duplicate data.
2. Add `Calendar > Existing Event` to the native insertion submenu. Present a native picker of available Penned calendar events and insert the chosen event reference.
3. Resolve event data through the existing calendar/EventKit layer and bridge it to the web editor. Update references when the source event changes; show a non-destructive unavailable/deleted state if the event can no longer be found or accessed.
4. Render a thin left accent strip and right-side event details. Tapping anywhere in the event block sends its identity to Swift, which opens the existing `CalendarEventDetailSheet` with the actual event.
5. Respect calendar permissions, multi-calendar identity, recurrence/occurrence IDs, timezone, and event changes. Do not accidentally create duplicate calendar entries when inserting or duplicating document blocks.
6. Make the block render safely in shared/read-only/exported documents without exposing private calendar data to unauthorized viewers.

## Stage 3 — Integration and delivery

- Build the editor bundle using the existing `penned-editor` build/sync pipeline only after source changes are complete. Check generated bundle differences against existing uncommitted edits.
- Inspect in-app on iPhone-size and iPad-size layouts, including a Week Strip nested in an Infocard and a linked event opening the sheet.
- Preserve all unrelated uncommitted work. No automatic commits or pushes.

## Open product choice

Week navigation semantics are not yet settled: a **fixed seven-date strip** (like a dated Tabs block) versus **a navigable calendar with persistent content for every date**. This choice affects data shape, persistence, and duplication. The initial implementation should not silently choose the latter.
