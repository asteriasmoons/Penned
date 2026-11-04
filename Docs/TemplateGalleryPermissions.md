# Template Gallery Publisher Permissions

Date: 2026-11-02

## Corrected Rule

Regular users have one personal gallery section: My Templates. They cannot
create their own template categories, move templates between categories, or
publish public templates. They do not see Unsorted in the gallery.

The existing authorized publisher account can see Unsorted, create and manage
public categories, publish templates, and sort them. These authoring controls
remain limited to the template-editor context, not regular-document editing.
Curated public categories other than Unsorted remain browsable by everyone;
those are publisher-managed catalog sections, not user-created categories.

## Changes

- Regular users' personal templates are displayed in a flat My Templates grid.
  Legacy category values are ignored for this presentation, so existing templates
  remain visible without destructive category migrations.
- Unsorted is filtered out of public category presentation for non-publishers,
  including differently cased or whitespace-padded names.
- Personal category context menus require both publisher eligibility and a
  template-authoring context. The per-user New Category alert and action have
  been removed entirely.
- Category creation remains in the existing publisher-only Manage Categories
  screen, using the authenticated public gallery service.
- Publisher public-card context menus include Move to Category through the
  existing revision-checked public template update flow.
- The application service rechecks the current publisher identity before moving
  a personal/template-authoring record. Hiding the menu is not its only guard.
- Publisher sheets close or become unavailable when management eligibility is
  lost. The public service still independently authorizes public writes.
- Newly created private templates, saved copies, and duplicated templates default
  to My Templates. The application chooses Unsorted for a new template created
  by the publisher account, retaining the publisher's staging workflow.
- Save Template remains available to regular users and creates an independent
  private template. It does not grant publishing or category-management rights.

## Existing Authorization

Publisher eligibility reuses
`TemplateGalleryAuthorization.canShowPublishingControls(appleUserID:)` and the
current native Sign in with Apple identity. No new identity system, publisher
flag in user preferences, or additional privileged account was introduced.

The existing `penned-gallery` Edge Function checks authenticated mutation
requests against `PENNED_GALLERY_ADMIN_APPLE_SUBJECT`. Its implementation and
database access policies were inspected but not changed or deployed.

This correction governs app presentation and management permissions. It does
not turn already-public gallery records into a new server-private draft state;
the existing catalog read API remains public. Unpublished local template drafts
continue using the existing library-owned document/template storage.

## Files Changed

- `Vellix/Templates/TemplateGalleryAuthorization.swift`: reusable Unsorted
  visibility policy based on the existing publisher role.
- `Vellix/Templates/TemplateGalleryView.swift`: regular-user My Templates grid,
  publisher-only grouping and sorting, removal of per-user category creation,
  filtered public categories, and guarded publisher sheets.
- `Vellix/App/AppEnvironment.swift`: central publisher eligibility, live identity
  checks for category moves, and role-appropriate template-creation defaults.
- `Vellix/Editor/DocumentEditorView.swift`: supplies publisher identity separately
  from whether the editor context permits management.
- `Vellix/Documents/DocumentRepositories.swift`: My Templates default for private
  creation, saving, and duplication; explicit staging category for the application.
- `Vellix/Templates/TemplateGalleryImporter.swift`: public templates saved to a
  personal gallery now use My Templates rather than Unsorted.
- `Vellix/VellixTests/VellixTests.swift`: role-based visibility, non-publisher
  eligibility, private/staging defaults, and updated saved-copy persistence cases.
- `Docs/TemplateGalleryPermissions.md`: this correction and verification boundary.
- `Docs/TemplateGalleryUsability.md` and `Docs/TemplateAuthoring.md`: update the
  earlier category behavior to reflect publisher-only management.

## Verification Boundary

No builds, tests, simulators, launches, linters, or runtime verification commands
were run. Added and updated regression tests remain unrun. Account-dependent UI,
live server configuration, and device behavior have not been verified.

No JavaScript editor code, caret/selection handling, document rendering, schema,
or stored user content was changed. No database migration, JavaScript bundle
regeneration, or backend deployment is required for these native changes.

## Manual Checks

1. As a regular user, open the gallery from both a document and a template editor.
   Confirm personal templates appear only under My Templates, with no Unsorted,
   private subcategories, Move to Category, New Category, or publishing controls.
2. Save a public template and create or duplicate a private template. Confirm
   their saved category is My Templates and they remain editable and usable.
3. Confirm curated public categories can still be browsed and their cards retain
   the Save Template action without publisher permissions.
4. As the publisher, create a template and confirm Unsorted staging remains
   available. Long-press templates to move them, and manage public categories
   through the existing publisher-only screen.
5. Reopen both roles' galleries with legacy categorized personal templates.
   Confirm regular users see all their templates in My Templates, while the
   publisher retains applicable staging and sorting views.
6. Switch away from the publisher account while management UI is open. Confirm
   it closes and public writes remain protected by the existing server checks.
