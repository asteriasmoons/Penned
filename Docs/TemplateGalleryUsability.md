# Template Gallery Long-Press Actions and My Templates

Date: 2026-11-02

Permission correction: regular users have only My Templates and cannot create
or manage categories. Unsorted and public sorting belong to the publisher.
See [TemplateGalleryPermissions.md](TemplateGalleryPermissions.md).

## Requested Behavior

- Let the publisher sort templates by long-pressing their cards, not through a
  visible button beneath each template. Regular users have no category controls.
- Provide My Templates in the gallery.
- Let users long-press a public gallery template and choose Save Template to
  retain an editable copy in their own template gallery.

## Gallery Behavior

My Templates contains the current Space's user-created and saved templates.
For regular users it is one flat grid, without Unsorted or private subcategories.
The publisher retains staging/category groups. Existing legacy category values
are preserved in storage rather than deleting or moving user content.

In the publisher's template editor, long-pressing a personal card presents
Move to Category. The visible category button beneath the card has been removed.
Moves use the existing repository operation through a publisher-checked
application service. New categories are created only through the publisher's
authenticated Manage Categories screen, not a per-user category dialog.

Public cards present Save Template on long press, whether their preview has
finished loading or not. This action is available to ordinary users and does not
require publisher privileges. Saving shows a progress indicator, a success
confirmation, or an error. A second save of the same public card is disabled
within that gallery presentation while saving or after success.

Publisher-only per-card management and public Move to Category actions are in
the public card's context menu rather than a button beneath it. Header publishing
and category management are publisher-only and limited to template-authoring
contexts. Unsorted is hidden from regular gallery users. Saving an existing
public template does not grant authoring or category permissions.

Card thumbnails, title styling, grid sizing, tap-to-preview, and Use Template
remain on their existing paths. The gallery reads personal templates from
Penned's observed overview, so saves and category moves update the open sheet
without stale per-sheet category overrides or repeated database reads.

## Save and Ownership

`AppEnvironment.saveGalleryTemplate` fetches the selected package through the
existing gallery service with its expected revision. It captures the active
Space and workspace generation and checks them again before writing, so a
workspace change during download cannot silently redirect the save.

`TemplateGalleryImporter.saveTemplate` extends the existing native package
importer. It inserts the personal template record, its owned document tree,
attachment records, and collections within the existing database transaction:

- Every imported page has fresh identity and the saved template's `templateID`.
- Nested-page references, media paths, attachment identities, collection
  identities, views, entries, and property values use the existing remapping code.
- Guidance and formatting are retained. Interactive component responses are
  reset using the same helper used for saving personal templates elsewhere.
- The saved root reference and canonical JSON are written to the template record.
- Saved public templates start in My Templates. Private creation and duplication
  also use My Templates; only publisher-created drafts use Unsorted staging.
- Source documents and the public package are not modified. No intermediate
  ordinary document is created by Save Template.
- Failed imports retain the existing transaction rollback and copied-file cleanup.

The normal `importPackage` entry point still produces ordinary editable
documents. Use Template still uses the existing personal-template duplication
path. Existing storage and library synchronization handle the new records;
there is no new table, migration, backend endpoint, or separate saved-template
storage system.

## Files Changed

- `Vellix/Templates/TemplateGalleryView.swift`: My Templates grouping, personal
  category context menus, public Save Template context menus and feedback,
  observed personal data, and removal of beneath-card action buttons.
- `Vellix/Templates/TemplateGalleryImporter.swift`: optional template-owned import
  using the existing atomic native tree, media, and collection importer.
- `Vellix/App/AppEnvironment.swift`: workspace-checked public-template saving and
  personal gallery data sourced from the existing observed overview, plus
  publisher-checked management and creation defaults.
- `Vellix/Editor/DocumentEditorView.swift`: removes the stale personal-template
  snapshot argument from the gallery sheet. No caret or selection code changed.
- `Vellix/VellixTests/VellixTests.swift`: regression cases for saved ownership,
  nested guidance, assets, collection entries, category persistence, incomplete
  packages, normal imports, and using saved templates as ordinary documents.
- `Docs/TemplateGalleryUsability.md`: this implementation and handoff report.
- `Docs/TemplateAuthoring.md`: links the gallery behavior and clarifies that
  saving existing templates does not enable regular-document authoring.

## Verification and Remaining Limits

No builds, tests, simulators, launches, linters, or runtime verification commands
were run. Regression tests were added but remain unrun. Visual behavior, service
availability, device gestures, and live synchronization are not claimed verified.

These changes are native Swift/SwiftUI only. They do not modify the JavaScript
editor or require editor-bundle regeneration for this gallery feature.

The Saved indication is scoped to the current gallery presentation. Saving the
same public template again after reopening creates another independent personal
copy; no persistent public-to-personal subscription or duplicate-tracking schema
has been introduced. Public package downloading still requires the existing
gallery service; a preview alone does not contain all importable assets.

## Manual Checks

1. As a regular user, open the gallery and confirm My Templates is the only
   personal section, with no Unsorted or category-management actions.
2. As the publisher, long-press a card to move it to an existing category. Create
   categories only through Manage Categories. Confirm moves survive reopening
   and no category button appears beneath cards.
3. Long-press a public card, including a not-yet-loaded preview, and choose Save
   Template. Confirm progress and success or error feedback.
4. Confirm the saved copy appears under My Templates without closing
   the gallery. Confirm it also appears on the Templates page, not in ordinary
   document browsing until Use Template creates a document.
5. Open the saved template and check nested pages, guidance, formatting, images,
   covers, collections, entry pages, fields, and views. Reopen it to check
   persistence; ordinary users must not gain category-management controls.
6. Use the saved template and confirm it creates independent ordinary documents
   with the established placeholder-filling behavior.
7. Change Space during a slow download. Confirm the operation reports the stale
   workspace rather than saving into an unintended Space.
8. Check publisher context actions and public previews. Confirm their existing
   behavior is retained and ordinary users are not shown publisher controls.
