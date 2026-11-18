# Penned Document Opening Diagnostics

This is instrumentation, not an opening fix. In an iOS Debug build, filter the
Xcode console for `[Penned Document Open]`. The native trace is in the app
target. For the four individual font/image milestones and the explicit TipTap
`setContent` marker, the app also needs an editor bundle generated from the
updated `penned-editor` sources. With an older bundle, native tracing still
works; `javascript-presentation-returned webMilestones=false` identifies that
case. Missing web milestones alone do not prove a font or image stall.

## Capture

1. On the affected iPhone or iPad, open the same library screen where it
   happens. Clear the filtered console before tapping.
2. Tap a document once. If it does not open, wait a few seconds, then tap the
   same card again. Keep the output from before the first tap through the
   result. When repeated taps never open the document, include at least 12
   seconds after the last accepted request so the timeout is captured.
3. Include the screen (e.g. All Docs or Home recents), device, and physical tap
   count. Keep both tap IDs, not just the last request's lines. Repeat once
   without the second tap to learn whether the first request eventually opens.

`ts` is Unix time in milliseconds. `elapsed` uses monotonic time from the tap
(or non-card entry); `duration` is the elapsed time for the indicated stage.
`tap` follows the action through iPad routing. `request` is the existing
opening UUID, assigned only when the environment accepts the request.
`surface-tap` comes from existing parent gestures and has its own ID; it is
not proof that a particular card received the gesture.

## Read the Trace

| Question | Events and evidence |
|---|---|
| Did the card receive the tap? | `card-tap` logs before its branches. `surface-tap` without a matching-time `card-tap` shows the parent saw the tap but the button action did not run. If neither appears, use the physical tap count or a recording; these logs cannot locate that touch. |
| Did routing or validation stop it? | `card-tap-not-opening`, `workspace-request-rejected`, `workspace-transition-ignored`, `workspace-transition-rejected`, `workspace-apply-ignored`, or `request-rejected` identify the reason. `workspace-save-start` with no completion shows a transition still waiting upstream of the opening UUID. |
| Was a request replaced or cleared? | `request-accepted replacesRequest=...`, `request-cancelled`, `pending-document-assigned`, `request-uuid-assigned`, `request-uuid-changed`, and `switching-space-changed`. Compare the old and new request UUIDs, not just the document ID. |
| What did it reuse? | `editor-cache-route`, `standby-candidate`, `session-opening-start`, and `load-no-op`. Compare the session ID, previous load request, loaded document, generation, and whether a bridge error was already present. Error contents are not logged. |
| Did TipTap load it? | `editor-load-queued`, `tiptap-bridge-ready`, `set-content-sent`, `tiptap-set-content-returned`, `set-content-acknowledged`, `document-loaded`. The native acknowledgment means the command returned, not that the editor was shown. `load-callback-discarded` records expected and actual generations or missing bridge/session. |
| What readiness check stalled? | Check the last start/completion pair: `presentation-preparation-start`, `javascript-presentation-start`, `fonts-wait-start` / `fonts-wait-completed`, `image-decode-start` / `image-decode-completed`, `javascript-layout-acknowledged`, `native-webview-layout`, `snapshot-start` / `snapshot-returned`. `frame-check-blocked` names the unsatisfied condition; `native-collection-layout` reports a separate, non-gating signal. Image completion means the existing decode wait settled; the editor still ignores per-image decode errors. |
| Was the fallback or observer consumed? | `layout-fallback-armed`, `layout-fallback-fired`, `layout-fallback-skipped`, `snapshot-unavailable`, and `frame-confirmed` explain the frame path. `readiness-event` records what passed the filter; `readiness-observer-delivered observerActive=false` means the one-shot observer was consumed. Check `callback-discarded` or `navigation-rejected` before assuming a readiness signal was absent. |
| Was pending state stranded? | `timeout-fired ownsRequest=true` followed by `timeout-skipped-cleanup reason=switching-space` without a later clear is distinct from `timeout-cleared-pending` or a stale timer rejected on UUID mismatch. `timeout-cancelled` means the sleep was interrupted. |
| Which attempt actually displayed the editor? | Compare `frame-confirmed` and its `currentOpeningRequest` with `navigation-selected`, `editor-view-appeared`, `editor-surface-eligible`, and `editor-content-visible`. A retained view may have appeared on an earlier attempt. Content visibility requires the matching rendered document with a ready editor in a visible, intersecting UIKit window. It is not independent proof of compositor pixels or absence of unrelated overlays. |

WebKit work can start under one request and finish after another is accepted.
The async load and frame logs keep their originating UUID; the navigation and
visibility milestones use the attempt that presented the editor. A different
`frameProducerRequest` is evidence that the presenting request reused an
earlier frame, not that the second tap itself caused WebKit to become ready.
