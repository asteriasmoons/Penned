# Editor Readiness & Performance — Codex Handoff Continuation

**Date:** 2026-11-16
**Task:** Continue Codex's in-progress "Editor Readiness & Performance" implementation (Codex stopped when its usage allowance was exhausted).
**Constraints honored:** No builds run. No tests run. No uncommitted work discarded. No completed implementation duplicated. No functioning system replaced. No unrelated changes.

---

## 1. Initial State — What Codex Had Already Completed

Codex's editor-readiness work was **wired end-to-end** before it stopped. The architecture is a single reusable *standby documentless editor runtime* that is prepared after the library becomes idle and then handed to exactly one document when the user opens it. Every structural piece was in place:

**Reusable editor infrastructure** — `Vellix/Editor/DocumentEditorCache.swift`
- `standbyRuntime: TipTapEditorWebViewStore?` — the parked, documentless editor.
- `prepareStandbyRuntime()` (line 76) — builds a documentless `TipTapEditorSession` with `isStandbyRuntime = true`, marks the `editor-standby.start` diagnostic.
- `discardStandbyRuntime()` (line 84) — tears the standby runtime down via `discardUnusedRuntime()`.
- `takeStandbyRuntime()` (line 89) — hands the parked runtime to one document; discards it on bridge error.
- `prepareForOpening(_:payloads:timing:)` (line 100) — reuses a retained model if present (marks `runtime-selected` route `retained-document`), otherwise calls `makeModel(...)`, which consumes the standby runtime through `takeStandbyRuntime()` (line 133).

**Idle-time warm-up kickoff** — `Vellix/App/VellixShellView.swift`
- `canPrepareUnusedEditor` gates warm-up on: scene active, database accessible, not switching space, `selectedDocumentID == nil`, `pendingDocumentID == nil`, not in settings.
- `prepareUnusedEditorWhenIdle()` waits ~600 ms, yields the main RunLoop, then calls `prepareStandbyRuntime()` (line 118) **only when `!environment.documentPreviews.isCapturingPreview`** (retrying every ~300 ms while a preview is capturing).
- Discards the standby runtime on background / inactive scene phase, memory warning, and `onDisappear` (lines 52, 55, 57).

**Document-opening path** — `Vellix/App/AppEnvironment.swift` (iOS `requestDocumentOpening`, ~line 767)
- Reads the record off the main actor, marks `document-read`.
- Computes `openingPayloads(for:)` (CollectionStore), hands them to `prepareForOpening(record, payloads:, timing:)` (line 791), marks `model-prepared`.
- `awaitEditorPresentation(...)` presents the document only once `model.session.hasLoadedDocument(id)` **and** `model.session.isPresentationReady`, with a retained-document fast path and a Combine subscription on `$isPresentationReady` / `$bridgeErrorMessage` otherwise.
- Discards the standby runtime on teardown (lines 1130, 1257).

**Opening payload analysis** — `Vellix/Collections/CollectionStore.swift`
- `openingPayloads(for document:)` (~line 82) analyzes the collection IDs embedded in the document's TipTap JSON and returns the payloads the editor needs.

**Timing diagnostics** — `Vellix/Editor/TipTapEditorSession.swift`
- `PennedDocumentOpeningTiming` (line 18): a `@MainActor` per-open timer that emits ordered, de-duplicated phase marks: `tap`, `document-read`, `runtime-selected`, `editor-bridge-ready`, `model-prepared`, `layout-start`, `frame-check-start`, `presentation-ready` (route `snapshot` / `layout-fallback` / `retained-document`), `workspace-selected`, `timeout`, `failed`.
- `isStandbyRuntime`, `openingTiming`, `beginOpening(_:)`.
- `confirmPresentationIfReady()` (line 603) confirms the editor is **visually displayed** by taking a `WKSnapshot` (`afterScreenUpdates: true`) to prove WebKit produced real pixels, then sets `isPresentationReady = true`.

**Preview-protection coordination**
- `DocumentPreviewCache.isCapturingPreview` (line 30) is a computed property: `{ !pending.isEmpty }`. It reflects, in real time, whether any preview render task is in flight. The warm-up kickoff consults it so editor prewarming never contends with live preview capture.

---

## 2. Incomplete Work — The One Integration Gap

Codex left **exactly one** dangling, half-integrated change: the diagnostic hook that distinguishes an editor being *visually displayed* from an editor being *actually ready to receive input*.

- `TipTapEditorSession.noteInteractivePresentation()` (line 143) was **defined** — it sets `observedInteractionEnabled = true` and emits the `interaction-enabled` timing mark — but it was **never called** anywhere in the codebase.
- Its backing flag `observedInteractionEnabled` is **never read** (declaration + the two writes are its only three occurrences), confirming the hook is purely diagnostic and carries no behavioral weight.

Consequence before the fix: the `interaction-enabled` measurement never fired, so the instrumentation could record *presentation-ready* (displayed) but had no signal for *input-ready* — precisely the distinction the task requires, and the one measurement needed to avoid claiming readiness without evidence.

Every other Codex symbol was verified to have a live call site (`prepareStandbyRuntime`, `discardStandbyRuntime`, `takeStandbyRuntime`, `prepareForOpening`, `discardUnusedRuntime`, `beginOpening`). No other orphaned or half-applied edits were found.

---

## 3. Investigation — What Was Causing Remaining Editor-Readiness Delay

The structural opening path was already efficient: the expensive, document-independent work (WKWebView creation, TipTap JavaScript/extension initialization, editor configuration) is completed on the parked standby runtime *after* the library is idle, so a real open only does document-specific work (loading the saved JSON, applying collection/page/attachment payloads, laying out, and confirming pixels).

The remaining issue was **measurement, not mechanism**. Without `interaction-enabled` firing, there was no way to tell whether the moment the editor paints (`presentation-ready`) is also the moment it can accept typing/selection/focus, or whether input-readiness lags behind the first painted frame. The task explicitly forbids claiming a target met without supporting measurements, so closing this instrumentation gap was the prerequisite for any readiness claim.

---

## 4. Changes Made (by me) and Why

**File:** `Vellix/Editor/TipTapEditorSession.swift`, inside `confirmPresentationIfReady()`.

Two additive lines, one in each branch where `isPresentationReady` becomes true (the WKSnapshot callback and the 0.75 s layout-fallback):

```swift
if self.preparesInteractivePresentation, self.isPresentationReady { self.noteInteractivePresentation() }
```

**Why here:** `confirmPresentationIfReady()` is the single point where the editor's displayable pixels are confirmed. Firing `noteInteractivePresentation()` there — guarded by `preparesInteractivePresentation` — means the `interaction-enabled` mark fires for the genuinely editable editor and **not** for standby, warm-up, or preview-capture runtimes (which reach presentation-ready via the non-interactive path). That makes the two marks meaningfully distinct:
- `presentation-ready` = a frame is on screen (any runtime).
- `interaction-enabled` = the interactive, input-capable editing surface is live.

**Why it is safe:** `observedInteractionEnabled` is never read, and `PennedDocumentOpeningTiming.mark(_:)` de-duplicates phases, so the call is idempotent and cannot alter editor behavior, document state, or the opening flow. It only emits a diagnostic. No functioning system was modified; Codex's method was completed, not replaced.

No other code was changed.

---

## 5. Architecture — How Background Editor Preparation and Reuse Now Work

1. **Library loads and goes idle.** Once the library is usable and no document is selected/pending, `VellixShellView` schedules `prepareUnusedEditorWhenIdle()`.
2. **Standby runtime is prepared off the critical path.** After a short delay and a main-RunLoop yield — and only while no preview is capturing (`!isCapturingPreview`) — `DocumentEditorCache.prepareStandbyRuntime()` builds a documentless `TipTapEditorSession` (`isStandbyRuntime = true`), paying the WKWebView + TipTap JS/extension startup cost once, in the background, without blocking navigation.
3. **User taps a document.** `requestDocumentOpening` reads the record off the main actor, computes its opening payloads, and calls `prepareForOpening`. If a retained model for that document already exists it is reused (`runtime-selected` / `retained-document`); otherwise the parked standby runtime is consumed via `takeStandbyRuntime()`, so the only remaining work is this document's content.
4. **Presentation is confirmed before the document is shown.** `awaitEditorPresentation` waits for `hasLoadedDocument(id)` and `isPresentationReady`; `confirmPresentationIfReady()` proves real pixels with a WKSnapshot, then (now) marks `interaction-enabled` for the interactive surface.
5. **Lifecycle discipline.** The standby runtime is discarded on background, inactive scene phase, memory warning, view disappearance, and opening teardown, so at most one parked editor exists and it never leaks across documents.

Document integrity is preserved because each open either reuses a document's own retained model or takes a *documentless* standby runtime and loads that single document into it — there is no shared mutable editor state across documents, and the standby runtime is discarded (not reused) on any bridge error.

---

## 6. Startup Protection — Recent Startup Optimizations Remain Intact

None of the startup optimizations documented in `Docs/ApplicationStartupPerformance.md` were touched. In particular:
- The warm-up is still *deferred until after the library is idle* and yields the main RunLoop, so it does not reintroduce the previously-removed hidden-interactive-editor warm-up that contributed to slow startup.
- Library loading still uses lightweight summaries, overlapped account/database preparation, deferred reminder reconciliation, deferred background services, and reduced sync contention — all untouched.
- The only change is two diagnostic lines inside the editor's presentation-confirmation path, which runs during document opening, not during library startup.

---

## 7. Preview Protection — The Preview Fixes Remain Intact

The previously-resolved preview regression fixes are fully preserved and were not modified:
- Immediate display of existing cached previews, generation on cache misses, independent preview rendering, PNG persistence, descriptor cache-key behavior, blank-image validation, and the corrected PNG pruning (filename-comparison, not full-path) are all unchanged.
- The warm-up kickoff still defers to `isCapturingPreview` (`{ !pending.isEmpty }`), so editor prewarming cannot block preview generation or cause gray placeholder flashes.
- My change touches only `confirmPresentationIfReady()` in the editor session; it does not reference, gate, or alter any preview rendering, cache, or persistence path.

---

## 8. Expected Behavior

**First document open:** Tapping a document opens it with its content displayed and the editor ready for typing, selection, formatting, and scrolling, because the WKWebView + TipTap runtime was prepared in advance on the standby runtime and only document-specific work remains at tap time. The timing trace now emits both `presentation-ready` (displayed) and `interaction-enabled` (input-ready).

**Switching documents:** Subsequent opens take the same path — a retained model if available, otherwise a freshly parked standby runtime that is re-prepared once the library returns to idle — so opening stays consistently fast without leaking state between documents.

---

## 9. Remaining Limitations

- **No device measurements were taken.** Per the explicit constraint, no build, install, or test was run. The diagnostics (`presentation-ready` vs `interaction-enabled`, and the full opening trace) are in place to *measure* first-open and switch latency on a real device, but no latency figure is claimed here, and neither the ≤20 s startup target nor the "instant open" target is asserted as verified.
- **`interaction-enabled` measures capability, not first user interaction.** It fires when the interactive editing surface is confirmed live, which is the correct "ready for input" signal; it is not a measure of when the user first focuses the editor or when the software keyboard animates in.
- **Verification boundary carries over.** As with Codex's earlier `EditorPageOpening.md` work, iPhone, iPad, and Mac runtime confirmation of the corrected build remains outstanding until someone runs it on-device.

---

## Codex vs. My Changes — Summary

| Area | Author |
|---|---|
| Standby documentless runtime infra (`DocumentEditorCache`) | Codex |
| Idle warm-up kickoff + lifecycle discard (`VellixShellView`) | Codex |
| Opening path: payloads to `prepareForOpening` to `awaitEditorPresentation` (`AppEnvironment`) | Codex |
| `openingPayloads(for:)` (`CollectionStore`) | Codex |
| `PennedDocumentOpeningTiming` + all phase marks (`TipTapEditorSession`) | Codex |
| `isCapturingPreview` preview-protection gate (`DocumentPreviewCache`) | Codex |
| `noteInteractivePresentation()` **definition** | Codex |
| **Wiring `noteInteractivePresentation()` into `confirmPresentationIfReady()` (2 guarded, additive lines)** | **Me** |

That one wiring change is the entirety of my code contribution; everything else is Codex's, preserved as-is.
