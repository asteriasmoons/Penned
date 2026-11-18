# Library From Template

## Behavior

- **Home > Add > From Template** and **All Docs > Add > From Template** open the existing template gallery as a new-document picker.
- Selecting a template opens its preview. **Use Template** creates and opens a new ordinary document in the active Space, leaving the source template unchanged.
- Personal templates use the existing `createDocument(title:from:)` duplication path. Public templates use the native snapshot importer, preserving independent nested pages, attachments, collections, rich formatting, and placeholders.
- Public-template creation validates the package and rejects a stale Space after an asynchronous fetch. Existing Daily Note component restrictions remain enforced.
- Navigating directly to **Templates** still opens template management. Its bottom add button is hidden; bottom navigation, search, and the existing top New Template action are unchanged.
- In-editor **Templates** and `/template` still insert blocks at the caret. They do not use this library creation flow.

## Files Changed

- `Vellix/Documents/LibraryChrome.swift`: routes the shared From Template menu action to a creation picker and hides only the add menu on Templates.
- `Vellix/Templates/TemplateDocumentCreationSheet.swift`: reuses the gallery and previews with creation callbacks, cached/public catalogue loading, progress, and error handling. Template-management actions are disabled in this picker.
- `Vellix/App/AppEnvironment.swift`: adds public-gallery document creation using existing import, editor preparation, refresh, and selection paths.
- `Docs/LibraryFromTemplate.md`: documents this change.

## Validation

No builds, tests, simulators, launches, linters, or automated verification commands were run for this change, as requested. Native editor code and the web-editor source/bundle were intentionally left unchanged.

Manual checks: use From Template from Home and All Docs, confirm a new document opens without changing the source, then navigate directly to Templates and confirm the bottom add button is absent.
