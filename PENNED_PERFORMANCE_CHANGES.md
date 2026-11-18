# Penned — Library Performance & Scalability Overhaul

Changes for genuine incremental loading / keyset pagination and a persistent
preview descriptor, implemented in three stages: **Phase 1** (descriptor
foundation), **Phase 2** (summary + pagination data layer), and the
**switch‑over** (wiring the gallery, overview, and preview pipeline to use them).

Two non‑negotiable requirements shaped the work:

1. **Genuine database‑level keyset pagination** — never "fetch everything then
   paginate", load progressively on scroll, and keep filter/sort/search/
   collections/navigation correct across the *entire* library including unloaded
   documents.
2. **Full, accurate previews — no simplified fallbacks.** Existing
   `ImmediateDocumentPreview` fidelity preserved wherever a cached PNG is
   unavailable; no stale/incomplete/placeholder previews.

---

## Decisive architectural constraint

The preview descriptor **cannot be a column on `documents`**.
`LibrarySyncRecords.validate` enforces `Set(row.values.keys) == liveColumns` on
every incoming CloudKit record, and the sync triggers are frozen to the column
list captured at install (v22). Adding any column to `documents` would make a
migrated device reject every incoming document row from an un‑migrated device
(and vice‑versa), silently breaking sync during the exact mixed‑version window a
new build creates.

**Resolution:** the descriptor lives in its own **local‑only** table, absent from
`LibrarySyncSchema.tables` (so no sync triggers are created for it and it is
never enqueued), maintained by the project's own proven **dirty‑set + reconcile**
pattern — identical to how `DocumentTaskIndex` already indexes document JSON.

---

## Phase 1 — Persistent preview descriptor

A local‑only derived index of the preview‑relevant facts that otherwise require
parsing a document's full `tipTapJSON`.

### New file: `Documents/DocumentPreviewDescriptor.swift`
- `struct DocumentPreviewDescriptor`
  - `contentHash` — SHA256 of the canonical body (stands in for raw `tipTapJSON`).
  - `features: OptionSet` — 16 flags, one per presentation check in the preview
    cache key (callouts, listGrids, codeBlock, gridCards, headingLabel,
    texturedLabel, decorativeLabel, tabs, minimalFields, fourDotDivider,
    templateComponent, attachment, inlineTags, toggles, clipSources,
    inlineProperties).
  - `pageReferenceIDs`, `collectionIDs` — referenced pages / collections.
- `enum DocumentPreviewDescriptorIndex`
  - `install(in:)` — creates `documentPreviewDescriptors` + a
    `previewDescriptorChanges` dirty table + triggers on `documents`
    (INSERT / UPDATE OF tipTapJSON / DELETE), and backfills every existing
    document once.
  - `reconcile(in:limit:)` — drains the dirty set, recomputing descriptors.
  - `descriptor(for:)` — pure computation from a `DocumentRecord`; equals the
    stored descriptor, so record and summary paths produce identical keys.
  - `schemaVersion` — bump to force a global descriptor rebuild.

### `Persistence/AppDatabase.swift`
- **Migration `v33_preview_descriptors`** → `DocumentPreviewDescriptorIndex.install`
  (additive, non‑destructive, one‑time backfill).
- **`registerCustomSQL(_:)`** registered in `prepareDatabase` on both the shared
  pool and the in‑memory connection:
  - `LOCALIZED_STANDARD` collation (Finder‑style `localizedStandardCompare`), so
    database‑level title ordering matches the gallery's historical in‑memory sort.
  - `penned_contains(haystack, needle)` — case/diacritic‑insensitive substring
    (`localizedCaseInsensitiveContains`), for exact title search.
- **Descriptor reconcile wired into the central `write`**, beside the existing
  `DocumentTaskIndex` / `DocumentTagIndex` reconciles. Because sync import
  (`applyIncoming`) also runs through `write`, descriptors stay current after
  **every local save and every synchronization import**, with no path able to
  forget it.

### `Documents/ImmediateDocumentPreview.swift` / `LibraryDocumentPreview.swift`
- **Reverted the `visibleNodeLimit: 40` cap** added in an earlier perf pass.
  Fallback rendering is full‑fidelity again (honours requirement 2).

---

## Phase 2 — Lightweight summary + database‑level pagination

### `Documents/DocumentRecords.swift`
- **`struct DocumentSummary`** — a read‑only projection carrying every
  gallery/navigation/preview‑key field **except `tipTapJSON` and `plainText`**,
  with `appearance` / `isThemed` / `cardStyle` mirrored exactly from
  `DocumentRecord`, plus `init(_ record:)` for cheap projection and
  `columns` / `columns(alias:)` SELECT helpers.
- **`enum DocumentSummarySort`** — `updated` / `created` / `title`.
- **`struct LibraryOverview`** — `recent` / `favorites` / `dailyNotes` /
  `trashed` are now `[DocumentSummary]`; `all` removed; `documentCount` added.

### `Documents/DocumentRepositories.swift`
- **`summaryPage(where:arguments:sort:after:limit:)`** — the keyset engine
  (`ORDER BY` + cursor predicate derived together per sort; title uses
  `COLLATE LOCALIZED_STANDARD`).
- **Scope methods** (keyset, search‑aware): `topLevelSummaries`,
  `folderSummaries(folderID:)`, `dailyNoteSummaries`.
- **Counts:** `topLevelSummaryCount`, `folderSummaryCount(folderID:)`.
- **Bounded sections:** `recentSummaries`, `favoriteSummaries`,
  `trashedSummaries`, `allDailyNoteSummaries`.
- **Hybrid search** (`matchClause` / `ftsMatchQuery`): exact substring on titles
  via `penned_contains`, body via the FTS5 `documentSearch` index restricted to
  `content:(…*)`; results keep the normal browse ordering (no relevance re‑sort).
- **Preview‑key helpers:** `summary(id:)`, `childrenSummaries(of:)` (mirrors
  `children(of:)` exactly, body‑free), `previewDescriptor(id:)`.

---

## The switch‑over — wiring the UI to the new data layer

### New file: `Documents/LibraryBrowseStore.swift`
`@MainActor ObservableObject` that holds only the loaded window of
`DocumentSummary` rows and fetches the next page from the database as the user
scrolls. Scope = `.all` or `.folder(String?)`. `configure` reloads only on a real
parameter change; `loadMoreIfNeeded` triggers near the end of the window;
`reload` resets to page one.

### Preview cache key — now descriptor‑sourced
`Documents/DocumentPreviewContent.swift`:
- **`protocol DocumentPreviewSubject`** adopted by both `DocumentRecord` and
  `DocumentSummary` (cheap metadata + derived appearance/card style).
- **`cacheKey(_:children:descriptors:…)`** rewritten to source JSON‑derived facts
  from descriptors. Every token string and the input ordering are preserved; the
  *only* substantive change is `tipTapJSON` → descriptor `contentHash` and each
  `hasX(json)` → a descriptor flag. **Version token bumped to
  `library-preview-v18-descriptor`**, so existing cached PNGs regenerate once.
- A **`DocumentRecord` convenience overload** computes descriptors itself, so
  every existing record‑based caller (and the generator) keeps working unchanged.
- **`CollectionRepository.presentationCacheKey(forSummary:documents:colorScheme:)`**
  + `resolveSummaryKeyInputs` — mirror `previewContent` + `cacheKey(for:)` using
  descriptors and child summaries (no body loaded); throws
  `PreviewKeyResolutionError.missingDescriptor` to force a record‑path fallback
  when a descriptor isn't available yet.

`Documents/DocumentPreviewCache.swift`:
- Body‑free lookups: `presentationCacheKey(for summary:)`,
  `cachedPresentationImage(for summary:)`, `loadPresentationImage(for summary:)`.

### Gallery cell — `Documents/LibraryDocumentPreview.swift`
- **`LibraryDocumentCell(summary:)`** — resolves and shows the cached PNG from the
  descriptor alone (no body). Only when no cached preview exists does it load the
  full record and hand off to the unchanged `LibraryDocumentPreview` (full
  `ImmediateDocumentPreview` fidelity + snapshot generation). Self‑heals: once the
  snapshot exists it drops the record and shows the image.
- `LibraryDocumentPreview` (record‑based) is **unchanged**, keeping its 9 existing
  callers intact.

### Gallery view — `Documents/DocumentBrowserView.swift`
- Input changed from `documents: [DocumentRecord]` to `summaries: [DocumentSummary]`
  (bounded surfaces) plus `allowsPagination` (default true).
- `.all` / `.folder` drive the `LibraryBrowseStore`; `filteredDocuments` returns
  the loaded window; other modes filter the explicit list in memory.
- `documentColumns`, daily‑note grouping, selection, `preview()` all operate on
  summaries; opening/restoring loads the record by id on tap.
- Progressive load via per‑cell `.onAppear { store.loadMoreIfNeeded(...) }`.
- `settledEmpty` prevents the empty state flashing before the first page loads.
- `folderItemCount` uses `folderSummaryCount` instead of scanning a full list.
- **`DocumentSummaryContextMenu`** — mirrors `DocumentContextMenu`, keyed by a
  summary; the few body‑needing actions load the record lazily.

### `App/AppEnvironment.swift`
- **`refresh()`** no longer calls `allDocuments()`. Builds `overview` from the
  summary queries + `documentCount`; loads only ~12 recent records (+ up to 5
  favorites) for editor warmup and preview prewarming.
- **`@Published var libraryGeneration`** bumped every refresh; paginated surfaces
  reload on its change.
- **`select(_ summary:)`** overload (loads the record, then selects).

### `Editor/DocumentEditorWarmupPolicy.swift`
- `documentIDs(recent:…)` now takes `[DocumentSummary]`.

### Consumer updates (overview no longer exposes `.all`)
- `App/VellixShellView.swift` — destinations use `summaries:` / bare `mode:`;
  "Pages" badge and All Docs count use `documentCount`.
- `App/PadWorkspaceView.swift` — destinations likewise; `onChange(of: overview.all)`
  → `onChange(of: libraryGeneration)`; `PadCollectionsView` passes
  `allowsPagination: false` with summary owners.
- `App/PadWorkspaceSidebar.swift` — starred list uses `LibraryDocumentCell` +
  `DocumentSummaryContextMenu` + an `open(_ summary:)` overload; folder counts via
  `folderSummaryCount`.
- `App/PadWorkspaceModel.swift` — tab title lookup via `summary(id:)`.
- `App/PadSettingsView.swift` — `.folders` destination uses bare `mode:`.
- `Documents/HomeView.swift` — empty check via `documentCount`; preview strip and
  starred list use `LibraryDocumentCell` + `DocumentSummaryContextMenu`; folder
  counts via `folderSummaryCount`.

---

## Behavioural notes & caveats

- **One‑time preview regeneration:** the cache‑key version bump
  (`…v17…` → `…v18-descriptor`, plus the added block tokens and descriptor
  `schemaVersion` 2) invalidates existing cached PNGs; they regenerate once on
  first launch after the update. Within the approved "regenerate" scope.
- **Consistent full‑content search (all sections):** every library surface —
  All Docs, Folders, Recents, Starred, Trash, Daily Notes — now searches document
  titles (exact, case/diacritic‑insensitive substring) **and complete body content
  via FTS5**, using the same hybrid rule. Bounded sections resolve matches at the
  database level (`DocumentRepository.fullTextMatches(amongst:query:searchesBody:)`,
  IDs in → matched IDs out, no bodies loaded); each section's scope/filter is
  preserved (e.g. Starred searches only starred documents). See §7.
- **Sync untouched:** the descriptor table is outside `LibrarySyncSchema.tables`;
  no sync triggers, no column‑set change, no effect on CloudKit records.

*(The earlier scroll‑reset‑on‑mutation, startup‑backfill, and stale‑test caveats
are resolved in the completion pass below.)*

---

# Completion pass

Seven follow‑up requirements, addressed below.

## 1. Document opening is not slowed by the summary library

The opening pipeline is: fetch the full `DocumentRecord` by id → prepare the
editor (`editorCache.prepare`, which parses the TipTap JSON and drives the
WKWebView) → present. The **editor preparation dominates** the cost; the record
fetch is a single row.

- **No extra fetch.** `PadWorkspaceModel.openDocument` already re‑read the record
  by id internally, so the gallery/sidebar previously fetched the record at the
  tap site and `openDocument` fetched it again. A new `openDocument(id:)` entry
  point does the one authoritative read; gallery taps, the sidebar, and the
  context menu's "Open in New Tab" now call it, so opening is a single fetch.
  `AppEnvironment.select(_:)` likewise already re‑fetched internally.
- **Prewarming is unchanged and still effective.** `refresh()` loads the ~12
  recent records (not summaries) and passes them to editor warmup
  (`DocumentEditorWarmupPolicy`) and `documentPreviews.prewarm`, so the documents
  a user is most likely to open are warmed exactly as before.
- **Large libraries.** Opening cost is independent of library size — it is one
  row fetch plus editor prep for the single opened document, whether it came from
  All Docs, a folder, search, collections, or deep navigation, and whether or not
  it was prewarmed. The library refactor adds no per‑open latency.

Editor‑preparation speed for very complex documents is a pre‑existing concern of
the editor itself and is unchanged by this work; the library refactor neither
improves nor regresses it.

## 2. Preview descriptor coverage — the complete strategy

The invalidation guarantee does **not** rest on the feature flags. It rests on
the descriptor's **`contentHash` = SHA256 of the entire canonical document body.**
Any change to any block — tables, blockquotes, information cards, callouts (with
or without icons), tabs, nested pages, nested cards and their size variants,
clipped‑web information/TOC cards, template components, collections nodes,
everything — changes the body, hence `contentHash`, hence the preview key. There
is no block that can change its content without invalidating the preview.

The **feature flags are presentation‑version tokens**, not the invalidation
mechanism. Each flag lets a specific block's *rendering logic* be version‑bumped
so that a renderer change regenerates only the affected documents, instead of a
global bump regenerating everything. Correctness holds with or without a per‑block
flag (a renderer change with no flag is covered by bumping the global
`library-preview` token).

Referenced and external dependencies were audited against the actual block
renderers (`ImmediateDocumentPreview`) and data model:

- **Referenced pages / nested pages.** The key folds in each resolved child
  (DB children + `pageReference` targets) and each child's `contentHash`, so a
  change to a referenced document invalidates the parent's preview. The descriptor
  stores `pageReferenceIDs`; children are re‑resolved at key time.
- **Referenced collections (gallery / Kanban / table modes).** `CollectionSnapshot`
  is `Codable` over its `record`, `fields`, `views` (the **view mode lives here**),
  and `entries` (with values, covers, appearance). The key encodes the resolved
  snapshots, so changing a collection's view mode, fields, entries, or entry values
  invalidates every document that embeds it. Both the record and summary key paths
  resolve collections identically via `collectionIDs(forDocument:)` +
  `collectionID(forEntry:)`.
- **Template components (daily notes).** A `templateComponent` node stores its
  `definition` and `response` **inline** in the node attrs — they are part of the
  body, so `contentHash` covers them. They do not reference a mutable external
  template.
- **Clipped web content.** The clip's content is inline (body → `contentHash`),
  and the `clipSources` flag carries a day‑stamped presentation token.
- **Attachments / cover / card images.** Paths are in the body/metadata (hashed);
  Penned stores attachments content‑addressed, so replacing media yields a new
  path and a new hash.

Flags added this pass (free, since the version bump already regenerates
everything): **`table`, `blockquote`, `informationCard`, `richLink`** — each with
a matching `*-presentation-v1` token — giving those common blocks granular future
regeneration. Descriptor `schemaVersion` is bumped to 2 to rebuild descriptors
with the expanded flag set.

Full fidelity is preserved: no simplified rendering, node limits, or placeholders
were introduced.

## 3. Cross‑device descriptors, reconciliation, and non‑blocking backfill

- **Cross‑device updates.** When a document changes on another device and syncs
  in, `LibrarySyncStore.applyIncoming` runs inside `AppDatabase.write`. The
  descriptor trigger (`AFTER UPDATE OF tipTapJSON` / `INSERT`) has **no `remote`
  guard**, so it fires during import and the descriptor is recomputed from the
  imported body in the same transaction's reconcile — before the import commits.
  Imported documents are therefore indexed immediately, per device, with no stale
  window.
- **Cost of per‑device generation.** Each device computes descriptors only from
  bodies it already stores, one parse per changed/imported document, inside the
  write that already touched that document. Negligible incremental cost; no
  network, no extra I/O.
- **Startup is not blocked by backfill.** The v33 migration **no longer parses
  every document.** It creates the table and triggers only. Existing documents are
  indexed by a **background backfill** (`runBackfill`) launched after `bootstrap`,
  which indexes documents lacking a current‑version descriptor in bounded batches
  (48 at a time) off the main thread via `writeMetadata` (no reconciles, no
  notifications), yielding between batches. Upgrading a library of thousands of
  complex documents adds **no launch delay**.
- **No stale previews during backfill.** The summary key path throws
  `missingDescriptor` for any not‑yet‑indexed document, and the gallery cell falls
  back to the always‑correct record path (loads that one body, renders full
  fidelity, generates the PNG). Correctness never depends on the backfill having
  finished.

**Why local‑only remains the right design.** Descriptors are cheap, fully
derived data (a hash + flags + referenced ids) that every device can regenerate
from the body it already holds. Syncing them would (a) require a schema change to
a synchronized table, which the sync record validator's exact column‑set match
would turn into a mixed‑version sync break, (b) add CloudKit record churn for data
that is trivially recomputable, and (c) risk a synced descriptor disagreeing with
a device's own rendering version. Local generation is cheaper, cannot break sync,
and is self‑healing. The requirement — accurate and efficient on every device
with no startup delay or sync problem — is met by local generation plus
import‑time reconciliation plus background backfill.

## 4. In‑place gallery updates — no scroll reset

`store.reload()` (reset to an empty first page) is **no longer** used for
mutations. `LibraryBrowseStore.refresh()` re‑fetches the currently loaded range
from the database with the same keyset order and **replaces `items` in place**.
Because the list is identified by document id, SwiftUI diffs the result:

- **Star / unstar, rename, metadata change:** the row updates or reorders in place.
- **Trash / restore:** the row leaves or (re)enters the window.
- **Duplicate:** the new row appears in order.
- **Move between folders / membership change:** the row leaves the folder scope's
  result if it no longer qualifies.

The user's **scroll position and selection are preserved** (selection is
intersected with the surviving ids). It never materializes the whole library — it
fetches only as many rows as are already loaded — and keyset pagination continues
correctly from the refreshed window. Query/sort/scope changes still reset to the
top (correct), via `reload()`.

## 5. Test updates

- `overview.all` removed from `SpaceEnvironmentTests`, `VellixTests`,
  `LibraryWorkspaceTests`; a `@testable` helper `AppEnvironment.topLevelDocument
  Summaries` (new `VellixTests/LibraryOverviewTestSupport.swift`) reproduces the
  former list as summaries, preserving each assertion's intent and ordering.
- `DocumentLaunchTests` reconstructed exact cache‑key strings against the old
  format (`library-preview-v10-collections` + raw JSON — already stale vs. the
  shipping v17). Those three tests
  (`calloutRendererRevision…`, `inlineRendererRevision…`,
  `componentRendererRevision…`) were rewritten to assert the **invalidation
  behaviour relationally** (feature present ⇒ key changes; plain document stable;
  detection correct) instead of reconstructing the internal format — more robust
  and format‑independent. `CollectionTests` and `DocumentPreviewTests` were
  already relational and needed no change.
- The repository's record methods (`allDocuments`, `recent`, `favorites`,
  `trashed`) remain, so tests using them are unaffected.

## 6. Preserved functionality

No document features, editor behaviour, navigation, search, preview rendering,
synchronization, or presentation styles were simplified or removed. The record
based `LibraryDocumentPreview` and its callers are unchanged; previews remain
full‑fidelity; sync is untouched; collections, daily notes, nested pages, tabs,
template components, and clipped content all render and invalidate as before.

## 7. Consistent full‑content search across all sections

Previously only All Docs and Folders searched full body content (FTS5); the
bounded sections filtered title + `previewText` in memory. That inconsistency is
removed — **all** sections now search titles and complete contents via FTS5.

- **`DocumentRepository.fullTextMatches(amongst:query:searchesBody:)`** — given the
  candidate ids of a bounded section plus the query, returns the subset matching by
  title substring (`penned_contains`) and, when keyword scope is on, by full body
  through the `documentSearch` FTS index. It reuses the exact `matchClause` the
  paginated surfaces use, so the two paths stay identical. Only ids cross the
  boundary — no document bodies are loaded.
- **`DocumentBrowserView`** — bounded surfaces now resolve `boundedMatches` from the
  database (on query/scope/section change) and `filteredDocuments` filters by that
  set; a transient title‑only match shows instantly and upgrades to full‑content the
  moment the database result lands. Paginated surfaces are unchanged (they search in
  `LibraryBrowseStore`). Each section's scope, sorting, navigation, and
  document‑opening behaviour are preserved — Starred still returns only starred
  documents, etc.

## 8. First‑launch migration & preview diagnostics

Structured `os.Logger` output, per device, lightweight and non‑blocking. Device tag
(`iPhone`/`iPad` + OS version) distinguishes devices; no CloudKit state is added for
logging.

- **`[Penned Migration]`** (`DocumentPreviewDescriptorIndex.runBackfill`) — logs
  device‑local initialization, descriptor `schemaVersion`, total documents requiring
  backfill, per‑batch processed count, running total, remaining, per‑batch failures,
  duration, and a completion line that distinguishes *completed* from *stopped with N
  still pending*. Progress is measured from the real backlog delta
  (`remainingBackfillCount`), so it reflects actual completed work, not estimates.
- **`[Penned Previews]`** (`PennedPreviewDiagnostics`) — a one‑time launch
  declaration of the preview cache version (`DocumentPreviewContent.previewCacheVersion`)
  and the **lazy, on‑demand** regeneration model: previews are keyed by that version,
  a version change invalidates them, and each regenerates the next time its document
  renders. There is **no bulk preview queue**, so the count awaiting regeneration is
  not determinable and completion reflects only previews rendered so far — **never
  "all possible" previews, and never implied complete because the descriptor backfill
  finished.** Regenerations and failures are counted at the actual PNG‑write site
  (throttled summary lines + per‑failure error lines).
- No document contents, identifiers, or personal data are logged.

## 9. Instant preview paint on cold launch (regression fix)

**Symptom:** gallery cards showed a blank gray surface for ~1s before the preview
appeared — on **every** launch, because no preview was ever cached.

**Diagnosis (from the device, not theory).** Pulling the app's cache directory off
the device showed the preview folder was **completely empty — zero PNGs** — even
though cards "render after ~1s." Previews were being rendered live for display but
never persisted. File‑based instrumentation (written to disk and pulled off the
device, since `os.Logger` notices don't surface in the Xcode console) pinpointed
three distinct, compounding bugs, all introduced by the overhaul:

1. **Snapshot generation was disconnected.** The gallery only ever *read* snapshots
   via `loadPresentationImage` (read‑only). `DocumentPreviewCache.image(for:)` — the
   one function that renders a snapshot **and writes the PNG** — had no production
   caller at all (only tests). So nothing was ever written.
2. **A warmed background editor blocked all generation.** `DocumentEditorView.onAppear`
   calls `setEditorActive(true)`; a prewarmed editor is mounted on the home screen,
   so `activeEditors == 1` permanently. `image(for:)` defers rendering whenever an
   editor is active (`guard activeEditors.isEmpty`), so every render was deferred and
   never ran.
3. **The prune deleted each file immediately after writing it.** After a write, the
   code removed other `"<id>-"` files via `old != url` (full‑URL inequality). On iOS
   `contentsOfDirectory` returns `/private/var/…` URLs while the write URL is
   `/var/…`, so the just‑written file compared as "not the kept file" and was deleted.

**Fix (three parts).**
1. `LibraryDocumentPreview.loadVisibleSnapshot()` now, on a cache miss, calls
   `image(for:)` — rendering **and persisting** the PNG. It runs only on the record
   fallback (cards with no cached preview), so the body‑free fast path is unchanged.
2. `image(for:)` gained an `ignoringActiveEditors` parameter; `loadVisibleSnapshot`
   passes `true`. That path runs only when no document is open
   (`selectedDocumentID == nil`), so a warmed background editor no longer blocks
   persistence, while the guard still protects real editing.
3. The prune compares `lastPathComponent` instead of full URLs, so it never deletes
   the file it just wrote.

**Verified on device:** after one render pass the preview directory holds the
expected PNGs (one per visible document) and they persist. Subsequent launches read
them from disk instantly — no gray, no re‑render.

A key‑independent fallback (`orphanedPreviewImage(forDocumentID:)`, by `"<id>-"`
filename prefix) is also retained in `cachedPresentationImage(for:summary:)` so a
persisted preview still resolves if a future cache‑key change orphans it from the
computed key.

## Remaining limitations

- **The first time any document is shown**, its snapshot is rendered live once
  (~1s) to create and persist the PNG; every launch after that is instant. There is
  no image to display until one has been generated at least once.

---

## File manifest

**New**
- `Documents/DocumentPreviewDescriptor.swift`
- `Documents/LibraryBrowseStore.swift`

**Modified**
- `Persistence/AppDatabase.swift`
- `Documents/DocumentRecords.swift`
- `Documents/DocumentRepositories.swift`
- `Documents/DocumentPreviewContent.swift`
- `Documents/DocumentPreviewCache.swift`
- `Documents/LibraryDocumentPreview.swift`
- `Documents/ImmediateDocumentPreview.swift`
- `Documents/DocumentBrowserView.swift`
- `Documents/HomeView.swift`
- `App/AppEnvironment.swift`
- `App/VellixShellView.swift`
- `App/PadWorkspaceView.swift`
- `App/PadWorkspaceSidebar.swift`
- `App/PadWorkspaceModel.swift`
- `App/PadSettingsView.swift`
- `Editor/DocumentEditorWarmupPolicy.swift`

**Completion pass — additional changes**
- `Documents/DocumentPreviewDescriptor.swift` — fast migration (no eager backfill),
  background `runBackfill`/`backfillBatch`, four new block flags, `schemaVersion` 2.
- `Documents/DocumentPreviewContent.swift` — `table`/`blockquote`/`informationCard`/
  `richLink` presentation tokens.
- `Documents/LibraryBrowseStore.swift` — in‑place `refresh()` (scroll‑preserving).
- `Documents/DocumentBrowserView.swift` — mutation uses `store.refresh()`; taps/
  context menu open by id.
- `App/PadWorkspaceModel.swift` — `openDocument(id:)` single‑fetch entry point.
- `App/PadWorkspaceSidebar.swift` — `open(_ summary:)` opens by id.
- `App/AppEnvironment.swift` — `startDescriptorBackfill()` kickoff after bootstrap.
- `VellixTests/LibraryOverviewTestSupport.swift` — **new**, `topLevelDocumentSummaries` helper.
- `VellixTests/SpaceEnvironmentTests.swift`, `VellixTests/VellixTests.swift`,
  `VellixTests/LibraryWorkspaceTests.swift` — `overview.all` → helper.
- `VellixTests/DocumentLaunchTests.swift` — three cache‑key tests made relational.
