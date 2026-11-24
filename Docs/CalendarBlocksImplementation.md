# Penned Calendar Blocks — Implementation Plan

## Implemented Header and Collapse Controls — November 21, 2026

This section describes the current header/collapse implementation. The original
planning notes below are retained as historical context, not as a list of changes
made by this update.

### Before

The calendar header showed a generated week date range between the navigation
arrows. It had no editable calendar title and no way to collapse the large daily
content area or the divider immediately below the date bubbles.

### Changes

- The header now contains the previous-week arrow, a directly editable title,
  the disclosure button, and the existing next-week `chevright` arrow at the
  far right. The disclosure reuses the existing glass navigation-button
  material, asset masks, and navigation tint, using `chevup` when expanded and
  `chevdown` when collapsed. No icon-rendering pipeline changes were needed;
  both assets are already registered by the native editor. All three arrow
  icons are 21 px instead of 30 px, with the existing 36 px tap targets retained.
  Collapse and next occupy adjacent 36 px grid tracks without an extra gap;
  an equal 72 px reservation on the left centers the editable title within the
  calendar instead of shifting it toward the previous arrow. The title shrinks
  and truncates within its own track in narrow calendars without overlapping
  the controls.
  The extra black overlay on active and inactive date bubbles is 20%, scoped to
  those date controls rather than shared glass or nested labels.
- Replace the visible date-range label with a text input. New and legacy
  calendars without a title use **Calendar**. Users can tap the title and type
  directly; the current range remains an accessibility label on the date strip,
  not a visible heading. The title uses Black weight (900), the existing font and
  content text color, with a 16 px minimum for the editable field. It can shrink within a
  narrow nested calendar without pushing the navigation buttons outside the header.
- Add `title` and `collapsed` attributes to the existing `weekStrip` schema via
  its shared defaults and sanitizer. Defaults are `"Calendar"` and `false`.
  The title is a string capped at 240 characters; collapse is a boolean, with
  explicit string-boolean parsing for HTML round trips.
- Both controls update only the matching block's attribute with
  `setNodeAttribute`, after checking the current live node and block ID. They do
  not replace the calendar, rebuild date panels, change panel IDs, or clear
  any authored content. They use the existing document transaction, autosave,
  undo, and opaque-JSON synchronization path, not per-device UI preferences.
- Collapse hides the content **and the divider below the date bubbles**, and
  removes their reserved height/margin. The title, previous/next navigation,
  disclosure, and all seven date bubbles remain visible. Each calendar stores
  its own state, so reopening the document or changing the visible week does
  not automatically expand it.
- Keep the existing `contentDOM` and all date panels mounted. Collapse uses
  zero-height clipping, visibility, `inert`, and `aria-hidden`, rather than
  `display: none` or removing/recreating editable children. Hidden content
  cannot receive a caret or accessibility focus. Descendant visibility is also
  forced hidden, including active nested tabs/calendars, so native collection
  region reporting cannot redisplay a nested overlay outside the clipped area.
  Report the block-height change through the existing editor height callback.
  The NodeView `update` is an arrow callback so it retains the Calendar
  extension's `this.options`; a method callback bound by ProseMirror would
  otherwise throw when collapse changes and interrupt the height update.
  Debug console prefix `PENNED-CALENDAR` includes `collapse-request`,
  `collapse-result`, and `collapse-blocked` for the disclosure click path.
- The title's input/composition/keyboard events belong to that input and are
  excluded from ProseMirror's body handlers. Composition is committed on
  completion/blur; ordinary input immediately updates the saved attribute.
  Enter in the title commits and dismisses that field. Enter inside a date's
  rich-text body is unchanged. Date navigation/disclosure blur the title without
  focusing the document. Header settings long press excludes inputs/buttons.
- Blank-space caret insertion explicitly ignores a collapsed calendar. Its
  collapsed background cannot create invisible paragraphs.

### Files

- `penned-editor/src/week-strip-settings.js`: title/collapse defaults and validation.
- `penned-editor/src/week-strip.js`: editable title, disclosure, saved-state
  presentation, attribute-only edits, and input event ownership.
- `penned-editor/src/tiptap.html`: responsive title field, existing asset-mask
  disclosure styling, and collapsed content/divider rules.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: corresponding Calendar defaults,
  sanitizer, and NodeView changes in the shipped resource. These sections were
  synchronized directly from the maintained source using the bundle's existing
  imports/aliases; unrelated bundled implementations were left intact.
- `Vellix/VellixEditor.bundle/tiptap.html`: matching styles in the shipped resource.
- `Docs/EditorInteractionFixes.md`: summary and link to this reference.

No native settings sheets, database migrations, navigation/readiness conditions,
preview-cache behavior, or selection-drag logic were modified for this feature.

### Sources and Verification

The implementation follows the existing Calendar NodeView architecture and
[ProseMirror's NodeView/contentDOM/stopEvent contract](https://prosemirror.net/docs/ref/#view.NodeView),
with persisted attributes registered through the existing
[Tiptap node schema](https://tiptap.dev/docs/editor/extensions/custom-extensions/node-views).
Child editing remains owned by ProseMirror; the header controls own only their
own events and attributes.

No builds, compilation, tests, editor-bundle build, simulator sessions, or app
launches were run. Review was source/diff based. Direct title typing, visual
collapse height, keyboard behavior, save/reopen, and cross-device delivery still
require device confirmation; no runtime verification is claimed.

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
