# Editor Pages Not Opening: 2026-10-27

## Symptom

On the physical iPhone, tapping an existing page left the library visible until
the 12-second opening timeout displayed:

> This page could not be prepared. Please try opening it again.

The saved document was queued, but the editor never reported `ready`. This was
an editor bootstrap failure, not missing or corrupt saved document content.

## Confirmed Cause

The gradient painter's native loader was appended **after** the required editor
scripts had already been inlined into the HTML. Both native asset caches used:

```swift
html = html.replacingOccurrences(
    of: "</body>",
    with: "<script>\(safeJS)</script></body>"
)
```

This replaces every matching string, not just the HTML document's final body
tag. TipTap's own bundled HTML parser contains a JavaScript template string:

```js
const html = `<body>${content}</body>`;
```

The replacement therefore inserted the painter's script tag **inside TipTap's
JavaScript source**. The HTML parser treated the injected closing script tag as
the end of the editor script. Its remaining source became page text instead of
executing, so TipTap never initialized or sent its ready message.

Disabling the painter's contents did not remove this defect: the loader still
inserted the script wrapper, even when the file contained only comments and a
no-op. The confirmed cause was this HTML replacement. The earlier explanation
that a repaint loop caused this particular startup failure was not established
by the runtime evidence.

## Runtime Evidence

Read-only queries through the existing Xcode debugger on the running iPhone
showed:

- `document.readyState` was `complete`.
- `typeof window.tiptapCommand` was `undefined`.
- The `.tiptap-editor` element did not exist.
- The delivered editor script ended with the disabled painter's comments and
  no-op, rather than the real editor bundle's end.
- The page's body text contained the remaining JavaScript, including the ready
  notification that should have executed.

The native logs were consistent with this: HTML navigation finished, document
loads stayed queued with `ready=false`, and the opening timeout eventually fired.

## Fix Applied

- Removed the painter-file HTML injection from
  `Vellix/Editor/TipTapWebView.swift` and
  `PennedMac/Editor/MacTipTapWebView.swift`.
- Reverted the unsuccessful iPhone media-wait workaround in
  `Vellix/Editor/TipTapEditorSession.swift` and
  `Vellix/Editor/MobileEditorInteractions.swift`. It addressed a later preparation
  step that the failing editor never reached.
- Kept the standalone editor painter inert. Its comments now identify the
  confirmed loader failure rather than claiming an unverified repaint cause.
- Implemented gradient geometry inside the existing `textStyle` TipTap extension
  using ProseMirror-owned inline decorations. No new startup script is injected.

No document records, attachment files, persistence rules, or iPad WebView
ownership/hosting arrangements were changed by this fix.

## Prevention

- Never replace bare HTML closing-tag strings after JavaScript, CSS, or JSON has
  been embedded in the HTML. Those strings can be valid data inside a script.
- Keep editor features in the existing editor modules and extension lifecycle.
  Do not restore this loader when refreshing the bundled editor resources.
- Gradient measurement must not mutate ProseMirror-owned block elements or
  write layout-only paint data into saved document JSON.
- Gradient geometry runs after layout without becoming a condition for editor
  startup or page-opening readiness.

## Verification Boundary

The original bootstrap corruption was confirmed on the running physical iPhone.
The source fix was applied to both native loaders. Codex did not build, install,
relaunch, or run tests afterward, and has not confirmed the corrected installation
opening a page. Reopening documents on a freshly installed corrected build still
requires physical-device confirmation. iPad and Mac runtime confirmation also
remain outstanding.

The later gradient-angle implementation likewise has no new build, test, or
physical-device verification. See [Inline Text Color](InlineTextColor.md) for its
rendering contract and delivery details.
