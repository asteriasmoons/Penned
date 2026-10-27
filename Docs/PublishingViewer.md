# Penned Public Document Viewer: Phase 3

Phase 4-5 integration now adds native publishing controls, durable automatic
updates, custom paths, password/email access and live reader refresh. See
[PublishingAutomation.md](PublishingAutomation.md) for current behavior and checks.

The October 26 follow-block-links update includes approved child pages and visible
collection-entry pages inside the parent's publication. Children do not need their
own publication records or URLs. See the linked-page section in that document for
the opt-in privacy boundary, inherited access controls and deployment checks.

Implemented October 25, 2026 in the existing Penned website, editor source and
native publishing foundation. The website remains Astro; only `/p/[token]` is
rendered on demand through the Vercel adapter. Marketing pages remain prerendered.
Public documents load from the actual Supabase publishing API on each request,
without rebuilding the site when a publication is updated.

## Reading Experience

The viewer uses Penned branding, local rounded typography, the native editor CSS,
and 650 exported app asset icons. It reads saved title, subtitle, icon, cover,
backgrounds, paper, font, text colors and appearance values. The saved Faded mode
is applied only when explicitly enabled; Immersive is not faded. Theme patterns
are shown only while the saved background still matches that theme's defaults,
matching the native `patternTheme` rule. Solid, gradient, image, blur and remote
Unsplash backgrounds are supported. Paper breaks create separate paper surfaces.

Supported saved content includes inline marks and gradients, headings, paragraphs,
lists, completed/skipped tasks, colored quotes and callouts, expandable nested
toggles, dividers, tables, properties, tags and template component responses.
Tables use the existing formula engine rather than guessed display values.
Controls display saved responses but do not modify the document.

The public renderer reuses TipTap's schema/HTML serializer, the actual text-color,
property and template normalization modules, and the table workbook/parser. It
does not instantiate the editable editor, node views, native bridges or gesture
recognizers. Native app/editor ownership and lifecycle are unchanged.

The compact reading header provides document search and an optional contents
drawer. Search works across inline formatting and closed toggles, with CSS
Highlights and a tested DOM-preserving fallback. Text remains selectable. Images
open in a zoomable viewer; audio/video have browser playback controls; PDF and
other supported files open their actual publication media. No editable HTML or
original-document mutation endpoint is exposed to visitors.

## Visible Content and Privacy

Pages and cards are always visible using their actual saved title, excerpt, cover,
font, text color and card style. Native card dimensions and whole-face scaling
are retained. Destination document bodies are not silently included. Miniatures
use the approved visible preview, not the destination's private block tree.

Collections include the selected saved view's visible fields, matching/sorted rows,
gallery covers and Kanban columns, order, color and collapsed state. Hidden fields,
filters, private IDs and entry document bodies are excluded. The public renderer
provides real table, gallery and collapsible Kanban presentations, not placeholders.

`allowFollowLinkedContent` defaults to false, including older native settings.
Pages/cards/collection entries remain visible and inert while false. When enabled,
the server may resolve a destination only if it is independently published, active,
unexpired, and owned by the same publishing account in the same source library.
Client-submitted public tokens are ignored. Owner-side destination IDs are stripped
before storage; public output removes destination tokens when following is off.
Rotated or revoked destination links fail closed; republishing refreshes saved links.

The legacy Phase 1-2 `privateReference`/`privateCollection` nodes contain no preview
or row data, so existing publications must be republished with the updated native
projection to obtain those presentations. The viewer explicitly identifies that
unavailable saved content; it never fetches private library data to reconstruct it.

## Media and Revocation

Local file/thumbnail paths are replaced with explicit publication manifest IDs.
All bytes remain in the private `penned-publications` bucket. Public media requests
check publication status, expiry and current manifest membership on every request.
No public bucket or durable signed media URL is used. Byte ranges support browser
playback. Attachment dimensions are retained when present; older dimensionless
images load eagerly so lazy loading cannot collapse them to zero height.

The media primary key is now `(publication_id, id)`, allowing separate publications
to upload the same native local media ID without colliding across accounts. This
additive scope correction preserves existing rows and matches existing URL checks.
Migration: `supabase/migrations/202610250002_publication_media_scope.sql`.

Viewer HTML is no-store at browser, CDN and Vercel layers. The content security
policy disallows inline scripts, framing, object embedding and arbitrary media
origins. Public links use no-referrer behavior. Already-open viewers recheck access
on visibility/online changes, expiry, and at 45-second intervals. Revocation clears
document content and stops/removes media. Previously downloaded bytes cannot be
recalled. Network failure is reported distinctly from an unpublished document.

## Reproducible Checks

Verified against production `https://penned-site-pi.vercel.app` after Git revision
`22164a8` (following the user's `fbdbd91` and `40a1999` deployments). The live
`PENNED_PUBLISH_BASE_URL` now points to that origin's `/p` route. An authenticated
owner status request returned that viewer URL and opening it returned the actual
saved publication, not the JSON API endpoint.

Passed: 70 account/session tests, 15 native publishing tests, 18 backend
contract/database tests, four publishing SDK/cryptography tests, 10 website
reader/rendering tests, 64 existing account-deletion handler tests and 14 deletion
SDK tests (195 focused tests). Website production build, TypeScript checks,
Edge Function type checking, native Mac and iPhone/iPad compile-only builds passed.
The website's complete dependency audit reported zero vulnerabilities. The broader
unrelated library fixture compile gap remains documented in `Publishing.md`.

The nine live Phase 1-2 API/security/lifecycle groups passed again, including
real Supabase email OTP/refresh, two-account isolation, private Storage/RLS,
atomic conflicts, media integrity, expiry, unpublish, token rotation and account
deletion. Real Apple authorization is not claimed: its live session lifecycle
test deliberately uses a seeded disposable fixture, and cryptography is tested
locally.

Production Chrome checks passed at 1440x1000, 834x1112 and 390x844: actual native
content and all three collection layouts, formulas, saved component values,
selection, toggles, search (including closed content), contents navigation,
image viewing, audio/video metadata, PDF bytes and HTTP byte ranges. Also checked
default inert cards, opt-in same-owner links, already-open revocation, reopened
404s, republishing and link rotation. No browser console/runtime or unexpected
network errors occurred. Screenshots are in
`/tmp/penned-reader-verification/production`; phone/tablet viewport checks are not
claims of physical Safari/device testing.

After verification, all disposable reader accounts, publications and media were
removed. A former production fixture URL was checked again and returned the
viewer's unavailable state with HTTP 404. Screenshots remain local evidence only.

Website at `/Users/asteriasmoons/Penned-Site`:

```sh
npm test
npm run build
npm audit
node scripts/verify-reader.mjs --mode verify --project-ref rfujrtehopxvybsjlwus --confirm-live --fixtures /tmp/penned-reader-verification --base-url https://penned-site-pi.vercel.app --screenshots /tmp/penned-reader-verification/production
```

The opt-in live harness obtains CLI-managed project credentials in process memory,
creates only disposable accounts and publications, and never reads user documents.
Its source documents are saved through real native GRDB repositories, with actual
Penned assets and valid image/PDF/audio/video files. It uses the real backend;
there are no intercepted API responses. Cleanup removes the tracked fixture users,
publications and media, not existing production data.

To generate the saved native fixtures before the harness's `prepare` mode:

```sh
PENNED_PUBLISHING_TESTS=1 PENNED_READER_FIXTURE_DIR=/tmp/penned-reader-verification PENNED_READER_FIXTURE_ASSETS=/tmp/penned-reader-verification/assets node Scripts/test-collections.mjs
```

Required asset files in that directory: `Penned.png`, `Guide.pdf`, `Tone.wav` and
`Clip.mp4`. Do not regenerate fixture IDs while a live fixture run is active.
Use `--mode cleanup` after verification; its restricted `live.json` tracks only
fixture IDs/object paths and must not be committed.

The editor export is reproducible without rebuilding/syncing the native bundle:

```sh
node scripts/export-public-reader.mjs --site /Users/asteriasmoons/Penned-Site --app /Users/asteriasmoons/Desktop/Vellix
```

Run this from `/Users/asteriasmoons/Desktop/penned-editor`. Generated `source.json`
records source/CSS hashes; the website contains the checked-in renderer, CSS and
assets, so Vercel builds do not need access to either native project checkout.

## Changed Files

App project:

| File | Purpose |
| --- | --- |
| `Vellix/Publishing/PublishingVisibleContent.swift` | Actual saved visible page/card/collection projections and preview media references |
| `Vellix/Publishing/PublishingDocumentBuilder.swift` | Integrate visible projections with the existing ownership/media preparation |
| `Vellix/Publishing/PublishingProjection.swift` | Approved public atoms and attachment dimensions |
| `Vellix/Publishing/PublishingTypes.swift` | Backward-compatible follow-linked-content setting |
| `Tests/Publishing/PublishingDocumentTests.swift` | Native projection/service regressions with real saved references |
| `Tests/Publishing/PublishingViewerTests.swift` | Hidden-data exclusion, visible previews, legacy settings and opt-in native fixture export |
| `Scripts/test-collections.mjs` | Include new production projection and tests in focused publishing mode |
| `supabase/functions/penned-publishing/visible-content.ts` | Fresh allowlisted visible projection constructors and bounded link candidates |
| `supabase/functions/penned-publishing/contract.ts` | Public atom/settings/media validation and default-off token filtering |
| `supabase/functions/penned-publishing/handler.ts` | Verified owner/library link resolution before atomic publication |
| `supabase/functions/penned-publishing/supabase.ts` | Scope separately published destinations to the actual owner/library/status |
| `supabase/functions/penned-publishing/supabase.test.ts` | Owner/library/expiry and bounded-query regressions for large linked collections |
| `supabase/migrations/202610250002_publication_media_scope.sql` | Publication-scoped media key without resetting data |
| `supabase/tests/database.test.ts` | Composite media scope, ownership and cascade regressions |
| `supabase/tests/visible-content.test.ts` | New public projection/privacy/validation regressions |
| `Docs/Publishing.md`, `Docs/PublishingViewer.md` | Current policy, architecture, file inventory and verification boundaries |

Editor source project:

| File | Purpose |
| --- | --- |
| `src/public-document.js`, `src/public-document.d.ts` | Shared read-only schema/renderer and its website type contract |
| `scripts/export-public-reader.mjs` | Export actual renderer, isolated native CSS and original app assets |
| `package.json`, `package-lock.json` | HTML serialization/PostCSS dependencies and patched transitive dependency |

Website project:

| File | Purpose |
| --- | --- |
| `astro.config.mjs` | Vercel on-demand rendering; disable development toolbar in CSP-protected viewer |
| `.gitignore` | Exclude generated Vercel build artifacts |
| `package.json`, `package-lock.json` | Adapter, actual TipTap serializer/schema, local font and verification dependencies |
| `src/lib/publishing.ts` | Existing anonymous reader contract plus follow-linked-content setting |
| `src/lib/public-document.ts` | Manifest-only media, actual saved appearance and renderer integration |
| `src/components/publishing/ReaderIcon.astro` | Penned's exported icon assets and emoji presentation |
| `src/pages/p/[token].astro` | Dynamic document route, security/cache headers and complete reading shell |
| `src/styles/reader.css` | Responsive native-style paper, blocks, cards, collections, media and loading states |
| `src/scripts/public-reader.ts` | Read-only search/contents/toggles/media, native card scaling and access rechecks |
| `tests/publishing.test.ts`, `tests/reader-rendering.test.ts` | API reader, actual schema/block/media/security regressions |
| `scripts/verify-reader.mjs` | Isolated live API and responsive real-browser verification/cleanup |
| `vendor/penned-reader/index.mjs`, `index.d.mts`, `source.json`, `icons.json` | Generated native-source renderer/type/provenance/icon manifest |
| `public/viewer-assets/editor.css` and PNGs listed in `icons.json` | Scoped native editor CSS and 650 original asset rasterizations |

## Deliberately Unchanged and Remaining Checks

Native editing, SwiftUI WebView ownership, native gestures, existing marketing
pages, Apple/email identity architecture and the account-deletion endpoint are
not replaced. Phase 4-5 native publishing controls and automatic upload/sync remain
separate tasks. The follow-linked-content setting is available through the existing
publishing service/API; no premature publisher settings sheet was added.

Physical signed iPhone/iPad/Mac Apple authorization, Keychain restoration and real
email delivery remain deferred as requested. Compile-only builds do not prove those
flows. Browser playback depends on supported codecs; unsupported files still have
their actual-file link. HEIC body images use an existing publication preview when
available; Safari/device codec behavior and legacy images without a preview still
need device verification. Parent/sibling/private workspace content is never a
fallback. Old stripped publications require explicit republishing, not a site rebuild.
