# Insert Templates at the Caret

## Behavior

- `/template` opens the existing personal/public template gallery. The in-editor Templates button uses the same insertion flow.
- The preview action is **Insert Template**. It inserts the template's body blocks at the current caret, not into a new document. The slash trigger is removed first.
- The destination keeps its title, cover, appearance, existing content, and editor context. The source template remains unchanged.
- Existing caret bookmarks preserve the insertion position across the native sheet. Moving the caret updates the intended location; cancellation, document reload, read-only mode, and block-selection mode cannot apply a stale request.
- Insertion is a single undoable editor operation. Native resources remain available for redo and reopening.
- Template-gallery publishing, category management, personal saving, and permissions are unchanged. Use Template outside the document editor retains its existing new-document behavior.

## Data Integrity

The native snapshot importer independently copies nested pages, attachment files, collections, fields, views, entry values, placeholder guidance, and rich formatting using its existing remapping logic. Root-owned resources transfer to the current document in the same database transaction; no temporary root document is committed. Nested references back to the copied root point to the destination instead.

The editor receives attachment and collection payloads before inserting the copied blocks, then captures and saves the resulting document through the existing persistence path. Confirmed failed insertions discard only their newly copied resources. An uncertain bridge-delivery failure retains resources rather than deleting files that inserted content might reference. Existing Daily Note component restrictions still apply.

## Files

- `penned-editor/src/editor.js`: slash entry, gallery request, native insertion commands, history boundaries, snapshot reporting.
- `penned-editor/src/caret-slots.js`: validates the existing insertion bookmark token without consuming it.
- `penned-editor/tests/template-insertion.test.js`: caret placement, native toolbar entry, rich blocks, cancellation, stale requests, undo/redo, and reload coverage.
- `Vellix/Editor/TipTapBridgeTypes.swift`: typed template-gallery request.
- `Vellix/Editor/TipTapEditorSession.swift` and `PennedMac/Editor/MacTipTapEditorSession.swift`: route requests and scope them to the current document.
- `Vellix/Templates/TemplateInsertionSheet.swift`: shared gallery presentation and native insertion orchestration, retaining existing gallery management actions.
- `Vellix/Editor/DocumentEditorView.swift` and `PennedMac/Editor/MacEditorPresentations.swift`: present the shared insertion sheet; the iOS editor's Templates button requests caret insertion.
- `Vellix/Templates/TemplateGalleryImporter.swift`: reuses snapshot import for independently copied resources and rejection cleanup.
- `Vellix/Templates/TemplateGalleryView.swift` and `Vellix/Templates/TemplatePreviews.swift`: configurable preview action label; other gallery callers keep their existing default.
- `Vellix/VellixTests/VellixTests.swift`: native regression coverage for destination/source preservation, nested-page remapping, collection ownership, and cleanup.
- `Vellix/VellixEditor.bundle`: regenerated with `npm run build`, including the user's existing editor-source changes. No unrelated source changes were reverted.

## Validation

- `npm run build` completed and synchronized the shipped editor bundle.
- All 45 focused JavaScript tests passed, including four new template insertion tests. The group covers insertion, caret tracking, attachments, collections, page references, and formatting. Existing attachment tests emit JSDOM geometry warnings but their assertions pass.
- iOS Simulator-target and PennedMac application builds completed with signing disabled. Xcode emitted existing warnings, including its anomalous `command failed with exit code 0` diagnostic; both commands exited successfully. This is compilation, not an on-device interaction check.
- The added native regression test still needs execution; the existing native suite has an unrelated `LibrarySyncTests.swift` initializer mismatch (`scheduledAt`).
- On-device checks remaining: open personal/public previews from both editor entry points, insert amid text and inside a callout, verify keyboard/caret placement, undo/redo, and reopen documents with copied images, nested pages, and collections.
