# Editor Responsiveness and Markdown Sharing (2026-10-29)

## Cause and Changes

The editor's callout investigation diagnostics were still enabled during normal
editing. Every transaction serialized the full ProseMirror document with
`editor.getJSON()` for diagnostic callout traversal; content updates serialized
it again. Callout rendering additionally scheduled repeated animation-frame and
timer probes that read layout, computed styles and canvas pixels. A diagnostic
MutationObserver watched editor-wide subtree/class/style changes. These are
concrete sources of unnecessary main-thread and native-bridge work; their share
of the reported device lag has not been measured with a runtime profile.

Those diagnostics now require the explicit JavaScript opt-in
`window.PENNED_EDITOR_DIAGNOSTICS === true`. The normal transaction/update path
checks the flag before obtaining document JSON. Probe helpers return before
layout reads, canvas work or scheduling, and the diagnostic observer is not
installed by default. Functional icon rendering, the existing 500ms save
debounce, content-height reporting, native editor readiness, selection, history
and document loading remain unchanged. Diagnostic opt-in must precede editor
startup to enable the diagnostic mutation observer.

The live editor's root now declares `spellcheck="false"`, inherited by editable
text blocks. This removes browser spelling underlines without replacing the
keyboard or changing autocorrection/capitalization settings.

Markdown previously shared a `.md` file plus an asset ZIP whenever the snapshot
contained assets, despite the current plain-Markdown serializer excluding image
and file-link dependencies. The Markdown service now writes exactly one file
at `<sanitized saved page title>.md` and returns only that URL. Existing title
commit/capture before opening the export sheet is retained. The complete selected
document is serialized once, with page breaks ignored and no child-document
recursion. TextBundle remains a distinct packaged export; PDF/image nested-card
previews and other formats are unchanged.

## Files Changed

- `../penned-editor/src/editor.js`: opt-in diagnostic guards and disabled spelling underlines.
- `Vellix/VellixEditor.bundle/tiptap.bundle.js`: nine corresponding bounded mechanical replacements, without a bundler or changes to HTML assembly/startup.
- `Vellix/Export/DocumentExportService.swift`: separate single-file Markdown generation from TextBundle packaging; keep title-based filenames and existing sharing/save/email consumers.
- `Docs/DocumentExport.md`: current single-file and serialization behavior.
- `Docs/EditorResponsiveness.md`: source findings, changes and verification limits.

## Verification Boundary

Source inspection and scoped diffs only. No builds, tests, compiler/bundler
commands, application launches, simulators or runtime profiling were performed.
Typing latency, absence of spelling underlines, and save/share/email of one
title-named complete Markdown file still require device verification. No
performance measurement or claim of proven elimination of all lag is made.
