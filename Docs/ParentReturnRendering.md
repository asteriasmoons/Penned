# Parent Return Rendering

## Trace-Confirmed Lifecycle Failure

The supplied physical-device capture contains two document IDs and a Child ->
Parent return, not a working Grandchild -> Child comparison. Its parent sequence:

| Epoch milliseconds | Evidence |
| --- | --- |
| `1794977085932` | A new host claims the parent's existing WKWebView. |
| `1794977085948` | Rendering observation activates, before window attachment. |
| `1794977085958` | The old host releases with `ownsHost=false`; the new host still owns the WebView. |
| `1794977085964` | `editor-view-disappeared` cancels the shared monitor, 16 ms after activation. |
| `1794977085974` | The new host enters the window, after cancellation. |

The same parent's session reports loaded/prepared/ready with unchanged load
generation and no bridge error. The capture contains no viewport-refresh
execution or block-probe results. This confirms premature observation teardown
and host replacement; it does not prove missing model text or an internal WebKit
painting defect.

Source inspection identifies an avoidable structural-identity change:
`vellixHideEditorNavigationBar` used `if isActive { self.toolbar(...) } else { self }`
around the entire editor. Selection switches those distinct branches. The
outgoing subtree's unconditional `onDisappear` could then cancel the shared
session after the replacement's `onAppear` activated it.

Apple explains conditional branch identity and its effect on view lifetime in
[Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/).
This supports correcting the application lifecycle first, not attributing the
symptom to an unconfirmed WebKit engine defect.

## Partial Block/Text Rendering Diagnostics

The screenshot also shows a heading label's colored silhouette without its
normal text. This is a partial block/content rendering failure, not evidence that
the entire WebView or entire document is absent. Page-level readiness and the
first six DOM children are insufficient to characterize it.

`TipTapBlockRenderDiagnostics.swift` now supplies the diagnostic-only JavaScript
probe. It uses the existing read-only `getDocument` command to derive model
counts entirely inside JavaScript. Document JSON and text are never sent back
to Swift. The canonical model, DOM, text layout, and final on-screen painting
are explicitly distinct evidence levels.

Each probe returns a summary and up to 24 separate **`block-render`** events
under `[Penned Render]`, correlated by probe/render/request/document IDs and
the reason (`visible-layout-settled`, `visible-probe-deferred`, or `first-user-scroll`).
The probe receives the actual native clipped viewport, rather than treating
the full-height WKWebView as if every block were on screen.

Sampling prioritizes visible heading labels and viewport hit-tested blocks,
then other visible blocks and offscreen labels. Geometry scanning is bounded
to 160 ordinary units and 128 heading labels. A sampling summary reports limits
and truncation; it must not be described as exhaustive inspection of every
block in a large document.

Per-block records include:

- Stable block ID/key and model type, model text-character/child counts, and
  intentional visibility attributes where a model ID matches the DOM.
- Actual DOM text-character counts and sampled text-node counts.
- Up to 16 nonzero `Range.getClientRects()` rectangles, with native-viewport
  intersection counts; up to 8 text nodes and 256 characters per node are sampled.
- The first text surface's computed font, font size, text color,
  `-webkit-text-fill-color`, opacity, visibility, clipping, and transform, with
  relevant ancestor styles.
- Heading-label tile, editable `.penned-label-text`, surface, and SVG frame
  metrics separately. A colored tile does not imply that its text was painted.
- Up to four InfoCard/callout/paragraph text surfaces per sampled container,
  exposing partial child rendering instead of only the container rectangle.
- Explicit `modelTextButEmptyDOM`, `textButNoRangeRects`, and
  `missingLabelTextSurface` flags, plus model label IDs missing from the DOM.
- Whole-model node-type/text counts, image availability, sampling counts, and
  probe elapsed time for diagnosing overhead or incomplete samples.

Hidden titles/descriptions, collapsed bodies, and template placeholders can
produce intentional model/layout differences; interpret the flags with the
visibility attributes, ancestor styles, and native `placeholderMode` field.
Missing model matches are unknown, not assumed zero text. A populated range is
layout evidence, not a pixel-paint acknowledgment. A successful font check can
also use a fallback; it does not establish that a specific font supplied glyphs.

Interpretation for the pictured label:

1. Model text present but the text span absent/empty: inspect node-view/contentDOM
   construction or synchronization, not just the whole WebView's visible state.
2. DOM text present but no range rectangles, or hidden/clipped/transparent styles:
   inspect that text surface and its ancestors.
3. Model text, DOM text, range geometry, and styles remain populated before and
   after the successful scroll while glyphs appear only afterward: that narrows
   the remaining failure toward text/layer painting rather than missing content.

This instrumentation does not modify label shapes, colors, icon rendering,
selection or content. It is native-injected
diagnostic code and does not require an editor-bundle rebuild. It remains Debug
only and retains the existing time/event limits and pending-probe checkpoint.
No builds or tests were run.

References: [CSSOM View range rectangles](https://drafts.csswg.org/cssom-view/#dom-range-getclientrects),
[CSS Font Loading checks](https://drafts.csswg.org/css-font-loading/#font-face-set-check),
and the project's existing read-only `getDocument` implementation in
`penned-editor/src/structured-placeholders.js`.

## Observed Evidence

- Returning Child -> Parent could show the native cover/title but leave the web
  body mostly blank for approximately 25 seconds.
- A small manual scroll then made the body appear immediately.
- Scrolling immediately on return also revealed the body immediately. Waiting
  25 seconds is therefore not necessary for this content to become available.
- Grandchild -> Child worked immediately.
- Renewing only the native WebView container did not resolve the symptom. That
  attempted correction is removed, including its view-identity counter.

These are user-observed results. No device run was performed during this change.

## Source Trace

`DocumentEditorView.documentTopControls` captures/saves the outgoing page, then
calls `AppEnvironment.returnFromDocument`. Both nested return cases use the same
parent branch: resolve the parent from the editor cache or repository, then call
`select(parent)`. There is no separate root-parent versus intermediate-parent
back-navigation branch in that path.

`DocumentEditorCache.prepareForOpening` reuses the parent's model/session. For
already-ready content, the initial WebKit snapshot/readiness handshake is not
restarted. `CompactEditorDeck` keeps inactive editors mounted with zero opacity.
`DocumentEditorView.documentScrollView` owns the scrolling; the WKWebView is sized
to its body inside that outer native scroll view. Its internal offset remains
pinned by the existing coordinator.

The manual-scroll result originally suggested stale viewport/drawing state.
The later trace establishes native host churn and premature diagnostic teardown.
Correct that lifecycle first. The screenshot and timing alone do not establish
the exact reason for missing text; block-level evidence is still needed if the
symptom survives stable editor presentation.

## Primary Research

1. [WebKit's iOS WKWebView implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm):
   `_visibleContentRect` intersects the web viewport with an enclosing view.
   `_didScroll`, explicitly handling ancestor-scroll movement, schedules a
   visible-content-rectangle update. Updates are delivered through a Core
   Animation precommit handler. `didMoveToWindow` handles activity/window changes;
   reattachment is not equivalent to an enclosing-scroll update. This directly
   supports targeting the path the user's successful scroll exercises. This is
   upstream source, not identification of the precise WebKit revision on device.
2. [WebKit bug 310087](https://bugs.webkit.org/show_bug.cgi?id=310087):
   documents missing composited content when exposed scrolling geometry lags
   layout. A WebKit engineer reproduced it and explained the UI-process geometry
   dependency. It was fixed upstream in April 2026; its iOS shipping version is
   not established here. Its brief flash during JS layout/scroll is not identical
   to Penned's retained-parent stall. It corroborates the mechanism, not a claim
   that Penned necessarily has this exact bug.
3. [Apple's CADisplayLink documentation](https://developer.apple.com/documentation/quartzcore/cadisplaylink)
   describes display-synchronized callbacks and invalidation when finished.
4. [Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)
   explains structural identity, distinct conditional branches, and view lifetime.

No source found establishes an Apple-endorsed one-pixel workaround for this exact
Penned failure. That attempted mitigation is removed. The first two sources
remain historical research, not the basis for the current lifecycle correction.

## Implemented Correction

`TipTapRenderRecovery` is owned by each iOS editor session and holds only weak
references to that session, its host, and the outer scroll view.

1. Keep the same editor subtree: the navigation helper always applies one toolbar
   modifier, varying `.hidden` versus `.automatic` without branching the content.
2. The existing logical selected-ID transition seeds the monitor with target,
   previous document, and parent IDs before SwiftUI updates. It deactivates the
   previous document's monitor. View callbacks remain a fallback, not the only
   source of route context; they do not replace a seeded activation.
3. A disappearing view stops its local selection driver but skips shared
   editor/preview/keyboard/save cleanup while its document still owns presentation.
   Real deselection, Space switching, settings presentation, and app-inactive
   handling retain their existing cleanup. Opening-surface tracing follows the
   same ownership rule.
4. Native layout callbacks carry their host and actual store ownership. Only the
   current host drives diagnostics; late releases/layout from an old host cannot
   change that ownership. Claims/layout discover the actual enclosing scroll view
   instead of relying on a possibly outdated SwiftUI scroll proxy.
5. Debug-only display callbacks start when the actual host is in a window.
   Two stable visible-layout samples trigger DOM/block and JS-frame probes, then
   stop the display link. A sample that cannot settle within 1.5 seconds is logged
   as deferred; a later real host/layout event can re-arm it inside the existing
   observation window. These are diagnostic conditions, never opening gates.
6. No programmatic scrolling, forced redraw, DOM mutation, or host remount is
   performed by the monitor. Retained status tracks prior visible-layout sampling
   on the cached session, not replaceable SwiftUI view state.

Presentation-layer opacity is logged separately from model visibility: an
outdated presentation opacity is evidence, not an additional readiness gate.
There is no pulse or rendering retry loop.

The same WKWebView, coordinator, TipTap instance, editor model, live content, and
undo history remain cached. There is no `reload`, `setContent`, body checkpoint,
focus command, forced keyboard display, or snapshot added by this correction.

## Diagnostic Identifiers

Filter Xcode for **`[Penned Render]`**. Logging is automatically enabled in Debug
on iPhone and iPad. Existing **`[Penned Document Open]`** logs are preserved.

Each normal diagnostic line contains epoch milliseconds (`ts`), process uptime,
activation elapsed milliseconds, `render` UUID, opening `request` UUID when
available, document ID, event name, and structured fields. Events before an
activation use `render=-`, but retain their available document/request IDs.
IDs are public diagnostic identifiers; titles, text, JSON bodies, image sources,
authentication, and attachment URLs are not logged.

| Events | Meaning |
| --- | --- |
| `back-request`, `back-save-completed`, `back-target-selected` | Identify the outgoing page, save completion, chosen parent, whether it is cached, and whether that parent itself has a parent. |
| `activation`, `deactivation` | Bound one visible-editor attempt. `from`, `sourceParent`, `targetParent`, `parentReturn`, and `retained` distinguish Child -> root Parent from Grandchild -> Child. |
| `editor-disappearance-ignored` | A view disappeared while its document still owns presentation; shared session cleanup was deliberately not run. |
| `host-claimed`, `host-release` | Record container identity and whether it owns the WebView. The existing stale-host rejection remains unchanged. |
| `webview-superview-changed`, `webview-window-changed`, `webview-hidden-changed`, `webview-alpha-changed` | Native view lifecycle/visibility transitions. |
| `host-layout`, `readiness-change`, `visible-layout-settled` | Bound native geometry and readiness. Settled layout includes view/layer hierarchy with model and presentation opacity. This does not mean pixels were proven visible. |
| `visible-probe-waiting`, `visible-probe-deferred` | Name an unsatisfied diagnostic sampling condition or unstable geometry. They do not reject navigation or alter readiness. |
| `outer-scroll-attached`, `outer-scroll-event`, `first-user-scroll` | Correlate offsets and user tracking with the first real scroll that could reveal the blank body. `observedAtMS` preserves the KVO observation time before deferred logging. |
| `dom-probe-start`, `dom-probe-result`, `dom-probe-failed`, `block-render` | Correlated async JS liveness, block/text model and DOM counts, range geometry/styles, image/font availability, and viewport/body dimensions. No content strings are returned. |
| `animation-frame-probe-start`, `animation-frame-probe-result`, `animation-frame-probe-failed` | Time two real JS requestAnimationFrame callbacks separately from a responsive command bridge. |
| `activation-checkpoint` | At 2 seconds, show current native/readiness state and pending probe IDs. A missing DOM or rAF result can be correlated with its start instead of mistaken for success. |
| `navigation-start`, `navigation-committed`, `navigation-finished`, navigation failure events, `webcontent-process-terminated`, `bridge-event` | Detect a process exit/reload or bridge error rather than silently treating it as a paint-only problem. Error domain/code is sanitized. |
| `probe-discarded` | A previous activation ended/replaced the one that requested this callback; no state or navigation is changed. |
| `observation-window-ended`, `diagnostic-budget-reached`, `log-encoding-failed` | Explain when observation is bounded or a diagnostic could not be encoded. |

Every state sample includes the current WebView/host identity, window attachment,
WebView bounds and actual window intersection after ancestor clipping, model and
presentation visibility, internal/outer offsets and sizes, native body height,
selection/editing state, and the session's existing load/input/presentation
generations and ready flags. Detailed samples include up to 12 view/layer
ancestors and up to 8 native content subviews.

The display link ends after its bounded sampling attempt. Debug scrolling observation lasts
60 seconds per activation, with at most 18 throttled offset samples and 160
diagnostic records. DOM/rAF probes occur at settled layout and
the first real user scroll; there is no per-keystroke probing or new diagnostic
file I/O. Release builds omit these diagnostic probes, observers, display links,
checkpoints, and log output. The stable-identity and cleanup-ownership fixes
apply in both Debug and Release.

## Reading a Capture

On the next device run, capture one Child -> Parent return without touching the
screen at first. If it is blank, scroll slightly once. Capture the working
Grandchild -> Child return too. Include both diagnostic prefixes from the back
request through the scroll/result, including the two-second checkpoint.

- DOM `blocks`/`textCharacters` populated, expected geometry/color, ready state,
  attachment, and a nonzero visible rectangle, but a blank screen: investigate
  the remaining painting/compositing stage, rather than reloading saved content.
- A quick DOM result but an overdue rAF result that arrives with the user scroll:
  frame scheduling/visibility differs from bridge liveness.
- Both probes overdue: inspect WebContent/main-thread responsiveness and process
  events before calling this only a compositor problem.
- Hidden/clipped/zero-sized/wrong-host state: the precise native blocker and
  ancestor samples identify an application layout/ownership problem.
- The old failure sequence (`activation`, stale `host-release`, immediate
  `deactivation`, then window attachment) should no longer cancel observation of
  the selected editor. If a transient disappearance still occurs, expect
  `editor-disappearance-ignored` and subsequent probes, not silent cancellation.

The old `-PennedDisableViewportRefresh` launch argument is no longer needed and
has no effect; the programmatic pulse was removed entirely.

## Limits and Unchanged Behavior

DOM layout and rAF acknowledgment do not prove that WebKit's remote compositing
pixels reached the display. No public API used here exposes WebKit's internal
exposed-rectangle IPC acknowledgments. DOM geometry reads may themselves flush
layout, so samples are explicitly labeled requests/results, not pre-paint proof.
The visible symptom must still be correlated with the timestamps. No snapshot
probe is added, because it could change the rendering behavior under investigation
and must not become another mandatory opening gate.

No builds, compilation, tests, app launches, or device timing measurements were
performed. The lifecycle defect is trace/source-supported; resolution of the
partial-text symptom still requires physical-device confirmation. No startup settings, database, autosave, sync,
preview generation/PNG persistence, web bundle, editor content, Enter behavior,
or drag-selection implementation changed.

## Files Changed

- `Vellix/Editor/TipTapRenderRecovery.swift`: remove the pulse; retain read-only
  host-owned, bounded native/DOM/frame diagnostics and preserve explicit route fields.
- `Vellix/Editor/DocumentEditorView.swift`: stable toolbar modifier and
  presentation-owned disappearance cleanup/tracing; retained status leaves view state.
- `Vellix/Editor/TipTapWebView.swift`: identity/ownership-aware diagnostic layout
  callbacks. Existing ownership, loading, readiness, and reload logic remain intact.
- `Vellix/App/AppEnvironment.swift`: seed diagnostic navigation context at the
  existing selection transition without changing selection/navigation behavior.
- `Docs/EditorInteractionFixes.md`: record the trace-confirmed correction and link here.
- `Docs/ParentReturnRendering.md`: findings, sources, implementation, capture
  instructions, event identifiers, and limitations.
