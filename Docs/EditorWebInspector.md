# Document Editor Safari Web Inspector

Date: 2026-11-01

## Change

The document editor's actual WKWebView now receives `isInspectable = true`
immediately after creation, guarded by iOS 16.4 / macOS 13.3 availability.
This is no longer restricted to debug builds, iPads, or a particular presentation
mode. Existing debug diagnostic-coordinator assignment remains unchanged.

## Actual Editor Instance

In each platform implementation, the document editor's WebView store creates
its retained `webView` using `TipTapWebView.makeWebView(coordinator:)`.
The SwiftUI host attaches that same `store.webView` and schedules the editor
session's document load on it. The setting is applied in this factory, so it is
not limited to an unrelated or preview-only WebView.

## Files Changed

- `Vellix/Editor/TipTapWebView.swift`: enables inspection on the retained
  iPhone/iPad editor WebView and the shared platform factory.
- `PennedMac/Editor/MacTipTapWebView.swift`: applies the same setting to the
  Mac document editor's retained WebView.
- `Docs/EditorWebInspector.md`: records the change, instance ownership, and scope.

## Scope and Verification

No document model, rendering, selection, editing, navigation-delegate, JavaScript
configuration, scrolling, or WebView ownership behavior was changed for this
request. No new WebViews were created. On OS versions older than the guarded API,
the existing behavior is unchanged.

No builds, tests, simulators, launches, or verification commands were run.
Safari discovery and attachment have not been verified on a device.
This native setting does not require regenerating the JavaScript editor bundle.
The separate placeholder-deletion correction is documented independently.
