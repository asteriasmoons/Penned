# Publish Template — Long‑Press Context Menu

Date: 2026-11-02
Author: Claude (verification + write‑up of Codex's in‑progress work)

## 1. What you asked for

Move publishing of templates **into the long‑press context menu**, so that
long‑pressing a template shows a **"Publish Template"** option. Publishing public
templates (and creating template categories) must be restricted to **you only**.

## 2. Status at a glance

**Done, and the backend is live.** Codex finished the feature. The app code is
complete and the Supabase backend it depends on is deployed and provisioned.
Nothing is half‑wired that I could find.

| Piece | State |
| --- | --- |
| "Publish Template" on long‑press | ✅ Implemented (gallery, your own template cards) |
| Old publish entry point removed | ✅ No publish button left in the editor toolbar |
| Author‑only (in‑app) | ✅ Gated at UI + app‑service layers |
| Author‑only (server) | ✅ Edge Function + database RLS both enforce it |
| `penned-gallery` Edge Function | ✅ Deployed, ACTIVE (version 2) |
| `template_gallery` DB migration | ✅ Applied (tables exist, RLS on) |
| Built / tested on device | ⚠️ Not done by Codex — see §7 |

## 3. How publishing works now

Publishing happens from the **Template Gallery**, not from the editor.

1. Open the Template Gallery from a **template** you are editing (the management
   controls only appear in a template‑authoring context — `document.templateID != nil`).
2. **Long‑press one of your own template cards** ("My Templates" / staging cards).
   The context menu shows **"Publish Template"** (plus "Move to Category").
   While publishing it reads **"Publishing Template…"** and is disabled.
3. On success you get a confirmation ("<Title> was published using its saved
   category."). On failure you get a **"Could Not Publish Template"** alert with
   the error.

Under the hood, `publishSelected` → the view's `publish` closure →
`AppEnvironment.publishGalleryTemplate(_:)`:

- Re‑confirms you are the publisher, and that the workspace/Space hasn't changed.
- Saves any open edits for that template first.
- Resolves the template's **public category** (it must already sit in a real
  public category — not "My Templates" — or publishing is refused with a clear
  message).
- Builds a full gallery package (document tree, attachments, native snapshot)
  via `TemplateGalleryPublisher.prepare`.
- Uploads it through `TemplateGalleryCloudStore.saveTemplate`, which POSTs/PUTs to
  the authenticated `penned-gallery` Edge Function.
- Uses a stable publication id per template, and a revision counter, so
  re‑publishing updates the same catalog entry instead of duplicating it.

## 4. Who can publish — author‑only enforcement

"Only I can publish / create categories" is enforced at **four independent
layers**, so hiding the menu is not the only thing protecting it:

1. **UI gate.** `canManageCategories = allowsManagement && isPublisher`.
   - `allowsManagement` → only inside a template‑authoring context.
   - `isPublisher` → `AppEnvironment.canPublishTemplates`, which checks the
     current Sign‑in‑with‑Apple identity against a fixed publisher Apple subject
     in `TemplateGalleryAuthorization` (`001664.f2fefbb84f024544b98e865fa6c6b49e.1524`).
   If false, the "Publish Template", "Move to Category", "Edit/Delete Template",
   and category‑management controls are not rendered at all.

2. **App‑service gate.** `publishGalleryTemplate` (and category moves) call
   `templatePublisherIdentity()`, which throws unless the live Apple identity is
   the publisher — and it is re‑checked *after* the async network work, so a
   mid‑flight account change can't slip a write through.

3. **Edge Function gate (server).** `supabase/functions/penned-gallery/index.ts`:
   `GET` (browsing the catalog) is public; every `POST`/`PUT`/`DELETE` requires a
   verified Penned publishing session whose Apple `subject` equals the
   `PENNED_GALLERY_ADMIN_APPLE_SUBJECT` secret — otherwise it returns **403**.

4. **Database RLS.** The migration enables row‑level security on
   `penned_gallery_categories` and `penned_gallery_templates` and **revokes all
   access from `anon` and `authenticated`**, granting only `service_role` (which
   only the Edge Function holds). No app client can read or write those tables
   directly; everything goes through the gated function.

**Verified:** your database has exactly **one** publishing owner, and it is that
same hard‑coded Apple subject — i.e. the gate points at your account, the sole
owner. (See §7 for the one value I couldn't read.)

## 5. Backend & deployment state (Supabase project "Penned")

- Edge Function `penned-gallery` — **ACTIVE**, version 2.
- Migration `202610310001_template_gallery` — **applied**.
- `penned_gallery_categories` — exists, RLS on, **1 category** currently.
- `penned_gallery_templates` — exists, RLS on, **0 templates** (nothing has been
  published through the new menu yet — expected).

Because a template must land in a real public category, keep at least one public
category present. You create/manage those through the publisher‑only **Manage
Categories** screen (also author‑only, same gates as above). The per‑user "New
Category" dialog was removed.

## 6. Other long‑press actions in the gallery (for completeness)

The same context‑menu system also carries:

- **Public template cards → "Save Template"** — available to *everyone*. Saves an
  independent editable copy into that user's "My Templates" (a download, not a
  publish). Does not grant any publishing/category rights.
- **Publisher‑only, on public cards** — "Move to Category", "Edit Template",
  "Update From Current Document", "Delete Template".
- Regular users see only a flat "My Templates" section; you (publisher) also see
  "Unsorted" staging and the public categories.

## 7. What to confirm / caveats

- **Server secret (please confirm).** The one value I could not read is the
  `PENNED_GALLERY_ADMIN_APPLE_SUBJECT` secret on the `penned-gallery` function.
  For publishing to succeed it must be set to your Apple subject
  `001664.f2fefbb84f024544b98e865fa6c6b49e.1524`. If it's unset or different,
  every publish returns 403 "forbidden". The cleanest confirmation is to publish
  one template and watch it succeed. (Everything else — your in‑app gate and the
  sole‑owner check — already points at that subject.)
- **Not built/tested by Codex.** Codex did not run a build, tests, or a device
  launch; its added regression tests are unrun. This feature is native
  Swift/SwiftUI only and does **not** require regenerating the editor JS bundle.
  A clean build in Xcode is still worth doing before relying on it.
- **Unrelated uncommitted work is in the tree.** The working copy also has
  separate, uncommitted editor/placeholder/selection changes (and new web‑clipper
  files staged). They're independent of this feature but will be in the same
  build.

## 8. Key files

- `Vellix/Templates/TemplateGalleryView.swift` — the long‑press context menus,
  "Publish Template" action, and publisher‑only gating.
- `Vellix/Templates/TemplateGalleryAuthorization.swift` — the publisher Apple
  subject and the UI eligibility check.
- `Vellix/App/AppEnvironment.swift` — `canPublishTemplates`,
  `templatePublisherIdentity()`, `publishGalleryTemplate(_:)`.
- `Vellix/Templates/TemplateGalleryPublisher.swift` — package preparation and
  category resolution.
- `Vellix/Templates/TemplateGalleryCloudStore.swift` — authenticated HTTP calls
  to the Edge Function.
- `supabase/functions/penned-gallery/index.ts` — server authorization + writes.
- `supabase/migrations/202610310001_template_gallery.sql` — tables + RLS.
