# Long-Document Editing Performance

Date: November 4, 2026

## Two Separate Problems

1. Web editing: the supplied Safari evidence shows expensive layout/paint and a 533.5 ms ProseMirror DOM-observer callback in an approximately 66,506 px document. It does not identify a Penned function by itself. Penned's diagnostic-only `calloutMutationObserver` is not the production observer responsible for this callback.
2. Native interface: exporting `potential-hangs` from `/Users/asteriasmoons/Downloads/Penned.trace` confirms five main-thread microhangs: 253.17, 252.16, 273.47, 340.11 and 255.63 ms (plus a separate 1.05 s startup hang). The supplied stack analysis identifies catalogue icon/image compression in `WebClipperCoordinator.publishCatalogue()`. That is independent of the web editor's document-length scaling.

The fixes below address these independently. The browser fixture demonstrates a specific web-editor improvement; it does not prove that the exact iPhone 533.5 ms callback, or every source of layout/paint cost, has been eliminated.

## Shared Editing Root Cause

`MobileBlockSelection.extensions()` installed a node decoration for every selectable block, even with block-selection mode off. Its incremental index avoided rebuilding some model state, but the resulting `basePaint` still contained a document-sized set of permanent node decorations.

The installed `prosemirror-view` implementation of `DecorationSet.forChild()` scans `this.local` when obtaining decorations for a child. A flat document with N decorated blocks therefore makes child decoration resolution approach N-by-N work during view reconciliation. Ordinary DOM input reaches that reconciliation through ProseMirror's own DOM observer. Programmatic typing, formatting, selection updates and block insertion share the same view-update path.

A local browser CPU sample of the pre-fix native integration showed `forChild` among the dominant non-idle JavaScript frames in the long fixture. This supports the code-level scaling diagnosis, without attributing every Safari layout event to it.

### Fix

- Removed permanent per-block selection decorations and their document-wide map/remove/restore bookkeeping.
- Kept decorations only for actual selected blocks and the block moving during a swipe.
- Kept the existing incremental block registry, position mapping, per-element gesture bindings, nested selection ownership and native drag-scrolling bridge.
- Moved the two static swipe CSS rules to stable block DOM selectors. Textblock tags also cover freshly split paragraphs that do not yet have IDs. Scrollable table/media/card/collection surfaces retain their exclusions.
- Updated mutation reconciliation to recognize those stable DOM candidates, still verifying each candidate against the model and `nodeDOM()` before binding.
- Stopped repeatedly removing the absent selection-arming class from the editor root during idle updates.

This is independent of block type: ordinary paragraphs and other blocks no longer pay for selection decorations on all the other blocks. Large active selections still legitimately require their own highlights; this is not document virtualization.

### Existing Paths Intentionally Preserved

- `src/editor.js`: `reportContentHeight()` already schedules with RAF and suppresses duplicate measurements in the same frame. `snapshotPayload()` already caches by immutable document identity; ordinary updates already debounce at 500 ms.
- `src/caret-tracking.js`: height remains reported before caret geometry; passive transactions still do not request caret scrolling.
- `TipTapEditorSession.updateEditorContentGeometry()` and `DocumentEditorView`: existing finite-value checks, >1 pt guards, full editor hit-testing height, visual page bottom, WebView ownership and native scrolling remain unchanged.
- No document schema, list/callout caret rule, table formula algorithm, attachment storage, save/revision/flush logic, placeholder permission, or layout size/spacing was changed.
- Table resize-handle churn was also observed in source, but was not folded into this fix: the measured shared decoration bottleneck is present even in documents with no tables. Table resizing and calculations remain untouched.

## Separate Native Catalogue Fix

`publishCatalogue()` previously regenerated all toolbar icons, folder/Space icons and the account avatar on the main actor after database-change notifications, including ordinary editor saves. `icon(_:)` encoded the full tinted image to PNG, decoded it again and encoded a thumbnail.

`WebClipperCatalogueImages` now owns image preparation on its own actor:

- Deduplicates icon names across toolbar, Spaces and folders.
- Caches both successful and missing icons at the current display scale.
- Reuses thumbnails while their original bytes and requested size are unchanged.
- Evicts removed inputs, clears account thumbnails when accounts change, and invalidates scale-dependent entries when scale changes.
- Renders tinted icons directly at thumbnail size, avoiding the intermediate full-size PNG encode/decode.
- Checks task cancellation between image operations and uses autorelease pools for temporary images.

The coordinator snapshots current inputs, cancels superseded rendering, and checks generation, owner, environment identity and database accessibility after awaiting the worker. Account validation and App Group publication remain together on main, without an intervening suspension, so an old render cannot recreate a signed-out account connection. Existing immediate inbox draining remains; completion drains again so a newly established connection can import waiting clips.

The extension protocol, App Group, companion app, document importer and authentication credentials are unchanged. Catalogue database reads, the small connection-file publication, and inbox importing still use the existing coordinator; this change does not claim to move every clipper operation off main.

Apple documents immutable `UIImage` objects as safe to create and use from any thread: [UIImage](https://developer.apple.com/documentation/uikit/uiimage). Only image preparation moved; native UI/model access remains on the main actor.

## Files Changed

| File | Reason |
| --- | --- |
| `Vellix/Editor/MobileBlockSelection.swift` | Sparse selection decorations, static DOM targeting, no redundant idle arming-class writes. |
| `Vellix/Clipper/WebClipperCoordinator.swift` | Await cached background images and reject stale catalogue publications. |
| `Vellix/Clipper/WebClipperCatalogueImages.swift` | New actor for cached image decoding, tinting, rasterization and PNG compression. Included by the existing synchronized Xcode source folder. |
| `Vellix/VellixTests/AttachmentTests.swift` | Native image-worker regression covering output, repeated/changed inputs, account/scale reset and cancellation. |
| `/Users/asteriasmoons/Desktop/penned-editor/tests/mobile-selection-scaling.test.js` | New integration regressions for sparse decorations, large documents, nested ownership, gesture targets and newly split paragraphs. |
| `/Users/asteriasmoons/Desktop/penned-editor/tests/long-document-browser.mjs` | Reproducible browser fixture using the actual shipped bundle and native injected scripts; checks DOM-input persistence, insertion/undo and operation counts. |
| `Docs/LongDocumentEditingPerformance.md` | This implementation and verification record. |

No production JavaScript source needed changing for the shared-path correction: the affected plugin is injected by the actual iOS host. Nevertheless, `npm run build` completed through the project's normal esbuild + `scripts/sync-bundle.mjs` workflow, keeping `dist` and `Vellix/VellixEditor.bundle` synchronized. Generated/minified assets were not manually patched. A native rebuild is required to deliver the injected-script and clipper changes.

## Browser Measurement

Desktop headless Chrome, 390 x 844 viewport, real bundled editor plus the iOS native scripts. Twelve native DOM text insertions, synchronous flushing of the same ProseMirror DOM observer for measurement, then block insertion and undo. Both versions use the same freshly generated JS bundle; the before run substitutes a temporary copy of the pre-change native selection script. These are single-run local measurements, not iPhone frame-time promises.

| Fixture | Before | After |
| --- | --- | --- |
| 1,200 paragraphs, no tables, 66,634.5 px: idle selection decorations | 1,200 | 0 |
| Same: median synchronous input work | 9.4 ms | 6.2 ms |
| Same: block insertion including RAF settlement | 46.3 ms | 31.6 ms |
| 1,200 paragraphs + 12 tables, 70,006.5 px: idle selection decorations | 1,212 | 0 |
| Same: median synchronous input work | 10.4 ms | 6.9 ms |
| Same: block insertion including RAF settlement | 36.8 ms | 34.6 ms |
| Redundant arming-class removals over each measured operation sequence | 14 | 0 |

Document heights were identical before/after. Layout/style duration totals varied and did not uniformly improve; this patch specifically removes unnecessary reconciliation work rather than claiming to eliminate browser layout. Two-RAF input totals are dominated by the fixture's frame waiting and are not used as a latency improvement claim.

## Validation

- `npm run build`: passed, including app-bundle sync.
- Focused Node suites: 46/46 passed across mobile selection scaling/gestures, caret reporting, formatting, attachments, checklist runtime and collections.
- Additional focused checks: 6/6 mobile divider conversion/selection-exit cases and 2/2 normal-table DOM cases passed (54 focused Node cases in total).
- Browser regression: four fixtures (80/1,200 paragraphs, with/without tables) passed with `PENNED_ASSERT_IDLE_WRITES=1`. DOM input persisted; callout insertion undid to the prior document; all idle selection decoration and arming-write assertions passed.
- Image actor strict-concurrency typecheck: passed with the iOS simulator SDK, Swift 5 language mode and default MainActor isolation.
- iOS simulator app build: passed (unsigned, no app launch). Xcode printed existing actor-isolation/deprecation warnings and one anomalous compiler-driver message despite returning success.
- Native test build: blocked by the existing `LibrarySyncTests.swift:170` call to `TaskCompletedOccurrence` missing its required `scheduledAt` argument. That file was not changed. No native tests or on-device sessions were run; the new image-worker test is authored but not runtime-verified.
- `git diff --check`: passed in both repositories.

### Existing Broader-Suite Failures

The expanded 92-test run had 84 passes and 8 failures outside the changed plugin path:

- Desktop divider conversion availability (the desktop fixture does not install `MobileBlockSelection`).
- Four structured-placeholder expectations (empty `content` serialization and composition/caret cases; these tests use their own editor and do not load the mobile plugin).
- Three degenerate-table expectations for legacy `emptyTable` structure (source-only table tests do not install the mobile plugin).

The initial paragraph-gap suite also encountered its existing missing `document.elementFromPoint` JSDOM support and list/history expectation failures. No caret, placeholder, table or unrelated test implementation was altered to hide these failures. Some passing attachment/task suites also log the same missing JSDOM geometry API on synthetic events; the real-browser regression supplies actual browser geometry.

## Remaining On-Device Checks

The original iPhone should still be checked for long-document native typing/IME, wrapping, selection handles, swipe/drag selection across nested blocks, scrolling while editing, insertion/undo, save/reopen and attachment behavior. Also check clipper cold connection, repeated saves, avatar/Space-icon changes and sign-out/account switching while rendering is in flight. The supplied traces were inspected read-only; no new device trace or screenshot was requested or collected.


---

# Re-Investigation — Why the Device Is Still Slow (2026-11-04)

The 2026-11-04 fixes above improved a **headless JavaScript** benchmark but did **not**
improve long-document selection or new-line insertion on the physical iPhone. This
section explains why, with source-level evidence, and identifies the real bottleneck.

## Confirmed Root Cause: the document is rendered full-height, so all browser work is O(document)

The editor renders the **entire** document in one WKWebView whose own scrolling is
**disabled**, with the WebView frame sized to the full content height; native SwiftUI
does the scrolling.

- `Vellix/Editor/TipTapWebView.swift:434` — `webView.scrollView.isScrollEnabled = false`.
- `src/editor.js` `measureContentHeight()` / `reportContentHeight()` measure the full
  rendered height and post it to native; `Vellix/Editor/TipTapEditorSession.swift:831`
  `updateEditorContentGeometry(height:…)` sizes the WebView frame to that height.

Therefore WebKit's layout viewport **equals the whole document** (≈66,506px in the
supplied trace). Nothing is ever "off-screen" from WebKit's point of view, so:

- There is **no paint culling** — invalidation and repaint span the whole document.
- **`content-visibility: auto` cannot skip anything** (nothing is off-screen relative to
  the WebView's own viewport). This is why the earlier content-visibility attempt gave no
  device improvement — and separately it squared the selection highlights.
- Every **style recalc, layout/reflow, and repaint is O(document)** in node count / height.

This is the layer none of the prior fixes touched. The prior shared fix removed an
O(N²) **JavaScript** cost (`DecorationSet.forChild` scanning document-sized decorations).
That is real, but **JavaScript is not the device bottleneck** — the Safari evidence
(expensive layout/paint; a 533.5 ms ProseMirror DOM-observer callback) is dominated by
browser layout, which a JS fix leaves intact. That is exactly why the headless JS number
moved and the device did not.

## Selection delay — end-to-end trace

During a drag-select the selection changes continuously, and **each** change makes
ProseMirror's DOM observer reconcile and re-sync the DOM selection
(`readDOMChange` / `selectionToDOM`), which reads layout/coords and therefore forces a
**synchronous layout of the full document**, then repaints the selection highlight across
a full-document paint surface.

Our own JavaScript on selection change is cheap and does **not** force layout:

- `src/editor.js:3692` `editor.on("transaction", reportFormattingState)` is pure model
  work (`isActive`, selection textblocks, alignments) — no geometry reads.
- `src/caret-tracking.js` bails immediately for a non-empty selection
  (`if (!selection.empty || …) return`) **before** any `coordsAtPos`.
- `reportContentHeight` is not scheduled by selection-only transactions.

So the selection delay is **browser-intrinsic** (full-document layout + selection paint),
not our code. There is nothing in our JS left to optimize for it under this architecture.

## New-line insertion — end-to-end trace

Return splits one paragraph (a tiny transaction). The cost that follows is all rendering:

1. `editor.onUpdate` (`src/editor.js:1576`) → `reportContentHeight()` →
   `measureContentHeight` reads `getBoundingClientRect` (≈`src/editor.js:2404-2411`):
   forces **one** synchronous full-document reflow.
2. `src/caret-tracking.js:11` `coordsAtPos(head)` reuses that same frame's layout (cached),
   so our JS forces **one** reflow total, not several (reads are already batched, RAF-deduped).
3. The new height is posted to native; `updateEditorContentGeometry`
   (`TipTapEditorSession.swift:831`) **resizes the WebView frame** to the new content
   height, which triggers **another** full-document layout inside WebKit.
4. WebKit repaints; with a full-document paint surface this is not viewport-bounded.

Net per newline: 1 forced JS reflow (full doc) + 1 native-resize reflow (full doc) + a
full-surface repaint — each O(document). The transaction itself is negligible. This matches
the brief's suspicion about "content-height reporting, caret geometry, WKWebView layout and
native scroll-container sizing" interacting — they do, and each touches the whole document.

## What does NOT fix it (ruled out, with reasons)

- **JavaScript micro-optimization** — already RAF-batched/deduped and sparse-decorated;
  JS is not the bottleneck (headless improved, device did not).
- **`content-visibility`** — ineffective because the WebView viewport = full document; also
  squares overflowing selection highlights.
- **CSS `contain: layout`/`paint` on blocks** — unsafe in *this* editor. `contain: layout`
  makes each block a containing block for `position: absolute` descendants; the editor
  anchors selection highlights (`::after { position:absolute; inset:… }`), table handles,
  and tag/slash menus absolutely, so containment would re-anchor them (visual regressions),
  and `contain: paint` would clip the overflowing highlights. No safe CSS silver bullet.

## The actual fix: windowed rendering (keep the full model, render only the visible window)

This is the only approach that removes the O(document) browser cost **without** changing
how documents look or removing functionality:

- Keep the **complete document in the ProseMirror model**. Find, selection, caret,
  undo/redo, persistence and sync all operate on the model and are preserved.
- Render full DOM only for blocks **within/near the on-screen window**. Render far blocks as
  fixed-height, content-less **placeholders** (node views / decorations that reserve the
  block's measured height but emit no inner DOM), so layout and paint become
  **O(visible)** instead of O(document).
- Because the WebView itself does not scroll, the **native side must report the visible
  viewport** (scroll offset + height) to JS so JS knows which window to hydrate.
- Each block's rendered height is **measured once and cached** so placeholders preserve
  geometry and the native scroll-container size stays correct.
- Blocks entering the window **hydrate** to full DOM; blocks leaving **collapse** to
  placeholders.

This is a substantial, core-editor change and must preserve the brief's entire
functionality list (selection handles, block/drag selection, nested blocks, lists, tables,
callouts, collections, caret, scrolling, undo/redo, persistence, appearance). It should be
implemented deliberately, not folded in silently, because it touches the exact paths the
brief says to protect.

## Confirmed vs plausible vs unverifiable

- **Confirmed (source-level):** full-height non-scrolling WebView; per-edit forced reflow
  plus a native-resize reflow; selection-change browser reconcile/paint; our JS does not
  force layout on selection; `content-visibility` ineffective here; CSS containment unsafe
  due to absolute positioning + overflow.
- **Plausible (consistent with the trace, not isolated on-device):** the 533.5 ms
  DOM-observer callback is dominated by a forced full-document layout during PM
  reconciliation; the native-resize reflow is a per-newline amplifier. A secondary O(document)
  item remains in JS — `structured-placeholders` `decorations(state)` walks `doc.descendants`
  per view update — but at ~1200 cheap node visits this is sub-millisecond and not the cause.
- **Unverifiable without on-device profiling:** the exact ms split between style recalc /
  layout / paint / compositing on the iPhone, and whether windowed rendering actually hits
  the target latency on *this* device — that needs an on-device A/B after it is built.

The honest conclusion: the delays are **browser rendering over a full-height, non-virtualized
document**, not JavaScript. No safe CSS or JS tweak eliminates it; windowed rendering is the
real fix.
