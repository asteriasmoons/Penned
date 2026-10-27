# Publish to Web: Phases 4 and 5

Implemented October 25, 2026. This extends the existing publishing services,
Supabase backend and Vercel reader; it does not replace native editor ownership,
CloudKit reconciliation, authentication or account deletion.

## Included Child Pages (October 26)

`Visitors Can Follow Block Links` now publishes an approved snapshot of the
selected document's referenced descendants, including nested cards/pages and
visible collection-entry pages. These are stored in the parent publication's
`linkedPages` array, not as independent publications. Only active descendants
reachable from visible previews are included; parent/sibling/unrelated bodies,
hidden collection fields, private identifiers and local paths stay excluded.
Previously supported separately published external references remain compatible.

The native builder prepares each child's actual content, appearance and media,
uses opaque page keys, detects reference cycles, bounds the complete snapshot,
and uploads all files through the parent's existing publication-scoped Storage.
Enabling/disabling the toggle commits settings and content together. Saved child
changes alter the parent's fingerprint and use the existing durable queue. Trashed
or missing explicit references become unavailable rather than keeping a stale
published child body indefinitely. Migration `v29_publication_linked_pages`
requeues existing active, unblocked opt-in publications on the updated app.

Visitors open `/p/<parent-link>?page=<opaque-key>`. The server reads
`/public/<parent-link>/pages/<key>` using the same reader grant as the parent.
Each response contains only the requested page, with its actual saved styling,
per-page search/contents and a parent-page back link. Reading-position restoration
is scoped to each page. Password/email gates, expiration, link regeneration,
account deletion and unpublishing remain properties of the one parent
publication. Turning following off denies child endpoints and child-only media;
images already visible in the parent's previews remain available as intended.

The web/backend cannot retrieve unpublished private CloudKit document bodies.
Existing published documents receive their descendant snapshots automatically
after the updated native app is installed and its queue runs; no child needs a
manual publish action. No native application or simulator was built/launched for
this change; the headless production-domain test harness was used instead.

Changed files:

| File | Reason |
| --- | --- |
| `Vellix/Publishing/PublishingTypes.swift` | Backward-compatible included-page payload and opaque parent keys |
| `Vellix/Publishing/PublishingDocumentBuilder.swift` | Scoped descendant snapshots, media union and safe internal links |
| `Vellix/Publishing/PublishingVisibleContent.swift` | Unavailable references and collection-field privacy for included entries |
| `Vellix/Publishing/PublishingProjection.swift` | Preserve safe unavailable-reference nodes without private attributes |
| `Vellix/Publishing/PublishingService.swift` | Prepare the requested child snapshot only when following is enabled |
| `Vellix/Publishing/PublishingQueue.swift` | Atomic toggle changes, child-save propagation and safe legacy upgrade |
| `Vellix/Persistence/AppDatabase.swift` | Requeue existing opted-in publications after app update |
| `supabase/functions/penned-publishing/contract.ts` | Validate reachable, bounded page graphs and shared manifests; redact disabled child media |
| `supabase/functions/penned-publishing/visible-content.ts` | Accept only page targets declared in the same publication |
| `supabase/functions/penned-publishing/handler.ts` | Parent-authorized child endpoint, selected-page responses and media access |
| `penned-editor/src/public-document.js`, `src/public-document.d.ts` | One link mechanism for page/card/table/gallery/Kanban destinations |
| `Penned-Site/src/lib/publishing.ts`, `src/lib/public-document.ts` | Validated child reads and parent-scoped media/link URLs |
| `Penned-Site/src/pages/p/[token].astro`, `src/pages/p/[token]/[...resource].ts` | Dynamic child selection, back link and child-specific status checks |
| `Penned-Site/src/scripts/public-reader.ts`, `src/styles/reader.css` | Independent reading positions and compact native-style parent navigation |
| `Penned-Site/vendor/penned-reader/index.mjs`, `index.d.mts`, `source.json` | Generated actual-editor renderer and source fingerprint |
| `Tests/Publishing/PublishingViewerTests.swift`, `PublishingQueueTests.swift` | Real saved child hierarchies/media/privacy, automatic edits and atomic toggle regressions |
| `supabase/tests/linked-pages.test.ts` | Page-graph, media, privacy, inherited access and revocation regressions |
| `Penned-Site/tests/publishing.test.ts`, `tests/reader-rendering.test.ts` | Existing grants, safe routes and every supported linked collection view |
| `Docs/PublishingAutomation.md`, `Docs/PublishingViewer.md` | Current behavior, file inventory and verification boundaries |

Claude's author-avatar and table-of-contents changes are retained. Account sign-in,
the editor/WebView lifecycle, marketing pages and independent-publication behavior
were intentionally left unchanged.

Verified: 35 headless native tests, 30 backend tests, 19 website tests, Deno source
checking, Swift parsing and the Astro production build passed. Website commit
`d727a4c` is READY on Vercel production (`www.penned.im`); the Edge Function is
deployed to the existing Supabase project. Real native-generated fixtures were
published through verified disposable Supabase accounts with only parent records.
Local and production browser checks passed at 390x844, 834x1112 and 1440x1000:
child/grandchild/collection-entry navigation, back links, read-only rendering,
viewport containment, console health, saved serif/color appearance, and toggle-off
child/media denial. One parent password grant opened children and protected media
without another gate. Live link regeneration and unpublishing revoked the included
pages and media. Only disposable fixtures were used; no user document was mutated.
Playwright was used because the Browser plugin was unavailable. Native application
installation and physical-device interaction remain device checks.

## October 26 Reader and Presentation Corrections

Publishing now generates `https://penned.im/p/...` links. The domain already serves
the existing Vercel project and redirects its apex to `www.penned.im`; no DNS or
marketing-page changes were needed. Existing Vercel document URLs redirect to the
custom domain. Cached native Vercel links preserve their token/custom path while
moving to Penned, and same-version remote URL changes are no longer discarded.

Every saved collection view is projected independently with its actual visible
fields, filtered/sorted rows, cover settings, gallery columns and Kanban groups.
The public view switcher changes only the visitor's reading presentation, never
the original document. Hidden fields and destination-page bodies remain excluded.
The gallery and table use the native editor's existing DOM/CSS structure, including
empty cover slots, cover aspect ratio, spacing, card footers and column tracks.
Kanban follows the native vertical columns, card styling, chips, colors and height.
The reader no longer forces smaller two-column gallery styles on mobile. Selected
views survive automatic reader refreshes; search ignores inactive view panels.

The missing Advanced Options icon used a nonexistent `sliders` asset; it now uses
Penned's `settingswavy` asset. Sheet blur backgrounds now reinitialize when UIKit
reattaches their view, without depending on another controller appearance callback.
No editor ownership, gestures or sheet design were replaced.

Migration `v27_publication_collection_views` queues existing active, unblocked
publications for the richer projection on the updated native app. Normal account
scope, expected-version conflict protection and revocation rules remain intact.
Older publications cannot expose saved views that were never exported until the
updated app uploads their approved projection; no private backend lookup fills gaps.

Verification: 30 native publishing tests, 23 backend tests, 14 website tests and
2 presentation-source checks passed, together with iOS/Mac and website builds.
Browser checks used a saved native fixture published through the real backend,
not mocked API responses, at 390x844, 834x1112 and 1440x1000: gallery cover slots,
native grid metrics, table tracks, vertical Kanban, real saved-view switching,
read-only behavior, viewport overflow and console health passed. Intermittent
physical-device sheet transitions still need device confirmation.

Website release `b5c14e7` (following `af14bec`) is deployed. The same browser flow
passed against `https://www.penned.im` at all three viewport sizes. Actual newly
created publication URLs use `penned.im`, and old Vercel document URLs were verified
to return a 308 redirect to the same path on `www.penned.im`. Playwright was used
because the Browser plugin was unavailable. The backend fixture was disposable;
no user documents or account data were used. Native icon, cached-link, projection
and blur changes require installing the updated native app; no app/simulator was
launched for verification.

Changed files and reasons for this correction:

| Files | Reason |
| --- | --- |
| `Vellix/Publishing/PublishingVisibleContent.swift` | Export every saved view without private view/field identifiers or entry bodies |
| `supabase/functions/penned-publishing/visible-content.ts` | Independently validate views, resolve approved links and strip private configuration |
| `supabase/functions/penned-publishing/index.ts` | Safe Penned viewer URL default; deployed environment also corrected |
| `Vellix/Publishing/PublishingTypes.swift`, `PublishingQueue.swift` | Repair cached Vercel URLs and retain same-version remote URL corrections |
| `Vellix/Persistence/AppDatabase.swift` | Durable, conflict-protected publication projection upgrade |
| `Vellix/Publishing/PublishingSheet.swift`, `PublishingOptionsSheet.swift` | Existing Advanced/Email Settings asset icons |
| `Vellix/Resources/PennedSheetStyle.swift` | Reinstall blur after view reattachment |
| `penned-editor/src/public-document.js` | Native gallery/table structure, native-style Kanban and saved-view menu |
| `Penned-Site/vendor/penned-reader/index.mjs`, `source.json` | Exported reader and source fingerprint |
| `Penned-Site/src/styles/reader.css`, `src/lib/public-document.ts` | Remove conflicting collection overrides and use native presentation colors |
| `Penned-Site/src/scripts/public-reader.ts` | View switching, bounded menus, gallery fades, search and refresh state |
| `Penned-Site/src/pages/p/[token].astro` | Redirect old Vercel document links to the custom domain |
| `Tests/Publishing/PublishingViewerTests.swift`, `PublishingQueueTests.swift`, `presentation-source.test.mjs` | Saved-view privacy/layout, cached-domain and sheet/icon regressions |
| `supabase/tests/visible-content.test.ts`, `Penned-Site/tests/reader-rendering.test.ts` | View validation, link isolation and native DOM regressions |
| `Penned-Site/scripts/verify-reader.mjs` | Focused real-backend fixture preparation to avoid unnecessary broad checks |
| `Docs/PublishingAutomation.md` | Current correction scope, evidence and remaining physical-device check |

## Automatic Updates

### October 26 Short Links and Collection Glyphs

Default publication paths are now eight random lowercase letters/digits, with a
unique constraint and transaction lock for collision handling. Migration
`202610260001_short_publication_paths.sql` assigns paths to existing default links
without changing their full tokens or owner-chosen custom paths. Regeneration
rotates both identifiers. Eight-character URLs are convenient identifiers, not
authentication: password, verified-email, expiration and revocation rules remain
unchanged. The migration is applied and recorded in the live project. The actual
Collections Test document is available at `https://www.penned.im/p/6cplpqth`;
both the short path and its existing full token returned the same publication.

The table's raw `sf:flag.fill` / `sf:square.text.square` strings were missing
browser assets. The public-reader exporter now exports the native symbol catalog,
and unknown symbol names fall back to a document glyph instead of becoming text.
Kanban uses native plain chevrons/plus glyphs, omits empty property containers,
matches compact card/type spacing and retains the native-looking read-only footer.
No native editor bundle, application build, authentication UI or document content
was changed for this correction.

Changed files for this follow-up:

| Files | Reason |
| --- | --- |
| `supabase/migrations/202610260001_short_publication_paths.sql` | Generate, backfill and rotate collision-checked eight-character default paths |
| `supabase/functions/penned-publishing/supabase.ts` | Resolve separately published destinations to their short/custom paths |
| `supabase/functions/penned-publishing/visible-content.ts` | Retain only verified public destination identifiers, including short paths |
| `supabase/tests/database.test.ts` | Migration, uniqueness, custom paths, regeneration, token compatibility and access regression checks |
| `supabase/functions/penned-publishing/supabase.test.ts` | Verify owner/library-scoped link lookup returns short paths |
| `supabase/tests/visible-content.test.ts` | Verify short nested-page links never trust private caller-supplied destinations |
| `penned-editor/src/public-document.js` | Short links and native Kanban controls, footer and empty-value layout |
| `penned-editor/scripts/export-symbol-icons.swift` | Export real glyphs from the app's actual SF Symbol catalog |
| `penned-editor/scripts/export-public-reader.mjs` | Include native symbol assets in repeatable reader exports |
| `Penned-Site/src/lib/public-document.ts` | Resolve native symbol assets and avoid printing raw symbol identifiers |
| `Penned-Site/src/styles/reader.css` | Native Kanban control/card sizing, line heights and footer |
| `Penned-Site/vendor/penned-reader/index.mjs`, `icons.json`, `source.json` | Generated renderer, glyph manifest and source fingerprint |
| `Penned-Site/public/viewer-assets/symbols/*.png` | Native symbol glyph assets for all supported symbol choices |
| `Penned-Site/tests/reader-rendering.test.ts` | Real glyph files, short linked paths, compact empty-property cards and read-only controls |
| `Docs/PublishingAutomation.md` | Follow-up file inventory, evidence and remaining device checks |

Verification: 25 backend tests, 4 Deno adapter tests, 16 website tests, Deno source
checking and the Astro production build passed. Browser verification used the
actual user's public document, not a fixture response: saved-view switching,
table glyphs, compact Kanban cards and viewport containment passed at 430px.
Website commit `bc47e09` is deployed and Vercel reports the production deployment
READY on `www.penned.im`. The actual short URL passed browser checks at 390x844,
834x1112 and 1440x1000: all three saved views, table glyphs, Kanban collapsing,
read-only content, viewport containment and browser console checks passed. The
original full-token URL still returns the same document/version. Temporary asset
upload tags were removed after GitHub accepted the production commit.
No native app or simulator was built or launched. Safari/device visual parity
still needs physical-device confirmation.

SQLite migration `v25_publication_queue` creates `publicationJobs`, keyed by
account owner, library and document. Database triggers mark candidates in the same
transaction as successful document, attachment, appearance/style, Space or
collection changes, including CloudKit imports. Rollbacks cannot queue a failed
save. Dependencies are conservatively invalidated across the affected library;
the actual approved projection fingerprint determines whether an upload is needed.

`v26_publication_revocations` records explicit trash/archive/delete intents. A
restore does not cancel a pending revocation or silently resume publishing.
Missing content on a newly hydrating CloudKit device is never inferred deleted.

`PublishingQueue` retains pending work and failures across process restarts. It
checks every five seconds while the application runs, discovers remote publication
status every thirty seconds, and retries with bounded exponential backoff.
Reachability changes, foregrounding and explicit Retry permit immediate retries.
iOS suspension does not promise background execution: queued work resumes when
the app is permitted to run. No queue credential or password is stored in SQLite.

Fingerprints cover the complete approved content, title/subtitle, cover/icon,
appearance, media descriptors, visible collection data and page/card previews,
not just the body's revision counter. Already acknowledged media is not uploaded
again. Immutable media IDs incorporate bytes, name and MIME type, so a rename does
not collide with an existing immutable upload.

Every automatic commit uses the last acknowledged server version. Content
conflicts are blocked for review, never resolved by blindly fetching a newer
version and uploading stale local content. Metadata-only server changes can be
rebased only when the source fingerprint proves the document itself unchanged.
Lost success responses reconcile by fingerprint; saves during an upload remain
pending. Remove Link interrupts in-flight operations and records a durable stop
intent. An automatic `update` cannot reactivate an inactive publication.

Existing hashless publications get a baseline only when the server proves the
saved approved projection equivalent, including media bytes. This does not
rewrite public content. A different or unavailable local document must first sync
or be explicitly reviewed; it is not automatically treated as the newer version.

## Native Interface

The existing send/share controls open the new publishing sheet on iPhone, iPad
and Mac after saving the exact document's pending title and body. It uses Penned's
existing sheet chrome, fields, typography, icons and accent controls.

### Shared Account Session

Sign-in is available only through Account Settings. Publishing does not host a
sign-in sheet, offer a second login or launch an Apple authorization controller.
Ordinary connection errors show Retry Connection, not a sign-in action. The
library-recovery screen opens Account Settings rather than a separate login.

Apple's credential and nonce from the normal Account Settings login are now
staged in account/project-scoped Keychain storage before the signed-in screen
appears. The backend exchange is shared by concurrent requests, retries offline
without discarding the staged credential, and persists its refreshable session.
Email publishing continues using the existing verified Supabase session without
sending another verification code. Account switches, sign-out and deletion cancel
in-flight exchanges; no account credential can be returned for a different owner.

An older Apple login that stored only the local Apple user ID cannot safely mint
a server session from that ID. If no usable backend session or fresh signed Apple
credential exists, reconnection is confined to Account Settings; publishing never
starts a separate sign-in. Real Apple/device authorization remains a device check.

The session correction passed 76 focused account/authentication tests and native
iOS and Mac compile-only builds. Added coverage includes staged credential
recreation, offline exchange retry, concurrent main-session reuse, verified-email
session reuse, account-switch rejection and absence of interactive legacy recovery.

| Session-correction file | Reason |
| --- | --- |
| `Vellix/Accounts/SignInView.swift`, `PennedMac/Accounts/MacSignInView.swift` | Pass the main login nonce synchronously instead of starting a detached publishing login |
| `Vellix/Services/AuthService.swift` | Stage the main credential and share/cancel account-bound sessions without interactive publishing authentication |
| `Vellix/Publishing/PublishingAppleAuth.swift` | Durable credential staging, coalesced exchange and refresh, cancellation and secure cleanup |
| `Vellix/Data/AppState.swift` | Remove the separate authorization task and guard account operations during switching/deletion |
| `Vellix/Publishing/PublishingSheet.swift` | Remove all sign-in UI; retain ordinary connection retry |
| `Vellix/Publishing/PublishingTypes.swift` | Direct genuine session recovery to Account Settings only |
| `Vellix/VellixApp.swift` | Route library recovery through Account Settings |
| `Tests/Publishing/PublishingAuthTests.swift`, `Vellix/VellixTests/SupabaseAuthTests.swift` | Session-reuse and isolation regressions |
| `Docs/PublishingAutomation.md` | Record the corrected sign-in boundary and legacy credential limitation |

Implemented: saved-document preview, Create Link, URL display/copy, system sharing,
browser opening, QR code, current status, last successful content-publication time,
retry/conflict states, Remove Link, regeneration, custom paths, passwords, allowed
people/domains, expiration and supported advanced reader options. Access changes
are saved through the authenticated publishing service, not local-only controls.

Expiration uses the end of the selected local calendar day. Never Expire removes
the deadline. A regenerated link revokes the old token and custom path. Custom
paths are globally unique, 3-80 lowercase letters/numbers/hyphens; a collision
returns a real validation error. External domain attachment is not implemented.

Supported advanced options: contents, title, optional author/name, Created With
Penned footer, hashtag visibility, following separately published block links and
search-engine indexing. Restricted pages cannot enable public indexing.

As explicitly approved, comments, external-domain attachment, visitor duplication,
presentation mode and analytics have clearly inactive places. They do not save
pretend preferences or report fake counts. Other sharing/export/transfer modes
are not implemented by this publishing task. The working Share Link action uses
the actual system share interface.

## Access Security

Passwords use random salts and PBKDF2-SHA256 with 600,000 iterations; plaintext
passwords are never returned or stored. Reader grants are random, stored hashed,
scoped to a publication/access epoch and expire after seven days. SQL checks the
current publication while granting access, preventing a simultaneous password,
expiry, unpublish or regeneration change from issuing a stale success.

Email restrictions require a real Supabase email OTP verification against the
allowed exact address or domain. Password and email requirements are cumulative.
Adding an allowed address is an access-list operation, not a pretend invitation.
The reader's code-request action invokes actual configured email delivery.

Durable per-publication and per-client attempt limits run before password hashing
or email dispatch. Content and media check publication state, expiry and reader
grant on every request. Access settings/rotation revoke prior grants. Private
access lists, password hashes, source IDs and workspace data never enter public
HTML or the public payload.

The website stores grants only in host-only HttpOnly/Secure/SameSite cookies and
proxies protected media on the same origin. Grants are not placed in URLs or
JavaScript storage. The proxy forwards validated ranges and streams actual bytes;
it does not reuse a compressed upstream Content-Length after Fetch decoding.
Mutation endpoints require a same-origin request. Reader HTML, status and media
responses remain no-store.

## Already-open Readers

The reader checks the current version periodically and on return/online events.
It handles the gateway's weak as well as strong ETags. A newer version refreshes
the document while retaining its visible block/heading offset and toggle state.
It defers refresh during text selection, search, an open image/contents view,
active scrolling or media playback. Revocation/access-policy changes clear the
opened content and require access again instead of leaving a stale private view.

## Files Changed

| App file | Reason |
| --- | --- |
| `Vellix/Persistence/AppDatabase.swift` | Transactional queue/dependency and explicit-revocation migrations |
| `Vellix/Publishing/PublishingQueue.swift` | Durable account/library queue, discovery, retry, deduplication, conflict and lifecycle handling |
| `Vellix/Publishing/PublishingTypes.swift` | Source fingerprint, media/status/access summaries, settings and robust timestamps |
| `Vellix/Publishing/PublishingClient.swift` | Discovery, access configuration, source fingerprints and real URL validation errors |
| `Vellix/Publishing/PublishingService.swift` | Automatic transfers, media reuse, baseline proof and cancellable operation authorization |
| `Vellix/Publishing/PublishingDocumentBuilder.swift` | Immutable media identity includes renamed descriptors |
| `Vellix/Publishing/PublishingPresentation.swift` | Account/scene runtime binding and shared publishing row/button components |
| `Vellix/Publishing/PublishingSheet.swift` | Main native publishing interface and real system sharing/browser/copy actions |
| `Vellix/Publishing/PublishingOptionsSheet.swift` | URL/password/email/domain/expiry/advanced sheets and actual QR generation |
| `Vellix/App/AppEnvironment.swift` | Library-owned publishing queue and stop on library closure |
| `Vellix/App/VellixShellView.swift` | iPhone/iPad publishing runtime integration |
| `Vellix/Editor/DocumentEditorView.swift` | Save and open publishing from the selected document's existing share control |
| `PennedMac/Workspace/MacWorkspaceView.swift` | Native Mac publishing runtime integration |
| `PennedMac/Editor/MacDocumentEditorContainer.swift` | Native Mac share-control presentation after saving |
| `Tests/Publishing/PublishingQueueTests.swift` | Actual SQLite/client/service queue regressions and explicitly enabled live native workflow |
| `Scripts/test-collections.mjs` | Include queue and regressions in the focused publishing harness |
| `Docs/PublishingAutomation.md`, `Docs/Publishing.md`, `Docs/PublishingViewer.md` | Current implementation, boundaries and verification inventory |

| Backend file | Reason |
| --- | --- |
| `supabase/migrations/202610250003_publication_controls.sql` | Access state, paths, source fingerprints, reader grants/limits and atomic control operations |
| `supabase/migrations/202610250004_reader_grant_races.sql` | Race-safe reader grant issuance |
| `supabase/migrations/202610250005_source_baselines.sql` | CAS-protected, non-content-changing source baseline |
| `supabase/functions/penned-publishing/access.ts` | Password hashing, verified-email access, reader grants and limits |
| `supabase/functions/penned-publishing/handler.ts` | Owner controls/discovery, baseline proof and gated document/media reads |
| `supabase/functions/penned-publishing/supabase.ts` | Scoped summaries, slug lookups, isolated visitor Auth calls and collision errors |
| `supabase/functions/penned-publishing/contract.ts` | New settings, hashtag filtering and equivalent-projection validation |
| `supabase/tests/database.test.ts`, `supabase/tests/visible-content.test.ts` | Migrations, grants, access epochs, CAS, validation and projection regressions |
| `supabase/scripts/verify-native-queue.mjs` | Real Swift queue against disposable live Supabase data with cleanup |

| Website file | Reason |
| --- | --- |
| `src/lib/publishing.ts` | Custom paths, explicit access-gate result and reader-grant header |
| `src/lib/public-document.ts` | Same-origin protected media references |
| `src/components/publishing/ReaderGate.astro` | Real password/email-code reader gate |
| `src/pages/p/[token].astro` | Gate rendering, version metadata, protected-media CSP and branding option |
| `src/pages/p/[token]/[...resource].ts` | Secure cookie exchange, version checks and streaming media proxy |
| `src/scripts/public-reader.ts` | Version refresh and reading-position retention without interrupting interactions |
| `src/styles/reader.css` | Penned-style gate fields and controls |
| `tests/publishing.test.ts` | Slug/grant/gate regressions without account credentials |
| `scripts/verify-reader.mjs` | Live browser checks for updates, access, proxy media, settings and revocation |

## Production Release Verification

The Supabase controls, race-safe reader grants and source-baseline migrations are
deployed to `rfujrtehopxvybsjlwus`, together with the publishing Edge Function.
The website is deployed at `https://penned-site-pi.vercel.app`; release commits
are `302bd21` and `462c696` on Penned-Site `main`.

215 focused tests passed: 70 account/authentication, 28 native publishing/queue,
22 backend, 4 backend SDK adapter, 13 website and 78 account-deletion tests.
Native Mac, iPhone/iPad and website builds passed. The actual Swift queue also
published a disposable saved document to the live backend, uploaded its media,
automatically updated its saved title/appearance and revoked document/media access.

Production browser checks passed at desktop, tablet and phone sizes: supported
blocks and collections, text selection, read-only controls, search, contents,
toggles, image viewing, PDF/audio/video, byte ranges, linked-content boundaries,
link rotation, expiration/unavailable behavior and already-open revocation.
Separate production controls checks passed automatic refresh with reading-position
retention, custom paths, passwords, HttpOnly/Secure cookies, actual protected
media, real Supabase email-code verification and access-policy revocation.

Production testing caught Astro inlining the small access-form script, which the
strict CSP correctly blocked. The handler now lives in the existing external
reader entry; the CSP was not weakened. The form uses POST as a safe fallback.
A regression test and the production access workflow passed after redeployment.

These are focused results, not a claim that the unrelated broader native library
harness is fixed. Its existing task-history fixture compile gaps remain recorded
in `Publishing.md`. The native builds were not installed or launched; users need
the updated app installed to use the new native controls and queue.

## Verification and Remaining Checks

Run focused native checks with `PENNED_PUBLISHING_TESTS=1 node Scripts/test-collections.mjs`.
The opt-in real native integration is `node scripts/verify-native-queue.mjs
--project-ref rfujrtehopxvybsjlwus --confirm-live` from `supabase/`. It passes a
disposable verified session only through child process memory, saves through real
repositories, publishes with the actual Swift client/queue, verifies public reads
and automatic title/appearance/media updates, then revokes access and cleans up.

Website live controls: `node scripts/verify-reader.mjs --mode controls
--project-ref rfujrtehopxvybsjlwus --confirm-live --fixtures
/tmp/penned-reader-verification --base-url https://penned-site-pi.vercel.app`.
The existing prepare/cleanup modes use only their tracked disposable fixtures.

Native Mac and iPhone/iPad compile-only builds passed; no app/simulator launch is
claimed. Focused queue tests cover disk reopening, rollback, offline/retry,
coalescing, saves during upload, lost acknowledgements, conflicts, metadata-only
rebases, explicit revocation/restore, missing sync content, account switching and
interrupting an in-flight upload. Backend/reader/account/deletion regressions and
live API/browser checks passed. Full native visual/device interaction and real
multi-device CloudKit transport remain device checks, not claims from unit tests.

The user deferred real email inbox delivery and physical Apple/device authorization.
The actual hosted email-code verification was exercised with a disposable code
issued by Supabase. Real delivery must use the project's configured Auth email
sender and a template containing the OTP token. Existing global Auth templates,
SMTP, Apple audiences and device credentials were not replaced or reconfigured.

## Published Child Icons and Snapshot Navigation

The public reader now pre-renders real approved child pages with the initial
authorized response, then swaps same-publication pages without a document reload.
Back navigation restores the saved page, window position and collection scroll
positions. Covers/backgrounds are preloaded into bounded, in-memory image blobs;
no private document bodies are persisted in browser storage. Cold/unseen pages
keep the current document visible while fetching rather than covering it with a
loading screen. First visits and media not yet downloaded still require network
time. This is not a claim that every uncached image is instantly available.

Read-ahead is capped at eight pages/256 KiB of approved JSON. The browser caches
at most twelve pages/8 MiB and forty images/32 MiB. Cached pages expire at their
publication deadline and after 45 seconds without successful access verification.
Version changes, access denial, link regeneration and unpublishing invalidate
snapshots. Parent passwords and reader grants apply to every prefetched child.

Changed files and purpose:
- `supabase/functions/penned-publishing/reader-payload.ts`: shared gated response,
  bounded child/ancestor read-ahead and exact field icons from approved collection
  projections, including documents published before the native exporter fix.
- `supabase/functions/penned-publishing/handler.ts`: request that response only
  after existing publication/access checks; allow only the scoped snapshots flag.
- `supabase/tests/reader-payload.test.ts` and `linked-pages.test.ts`: snapshot
  limits, real hierarchy, non-mutation, field icons and inherited access gates.
- `Vellix/Publishing/PublishingVisibleContent.swift`: retain resolved field icons
  when future native collection-child projections are created.
- Editor `src/public-document.js`: render a saved property icon instead of always
  substituting the property kind's generic icon.
- Website `src/lib/publishing.ts`: optional typed read-ahead request/response.
- Website `src/components/publishing/ReaderPageBody.astro` and
  `src/pages/p/[token].astro`: reuse the unchanged branded presentation for both
  the active page and inert pre-rendered snapshots; remove the loading overlay.
- Website `src/scripts/reader-navigation.ts`: memory/decoded-image cache, immediate
  History API navigation, bounded prefetch and access/version invalidation.
- Website `src/scripts/public-reader.ts`: dispose old page listeners/observers,
  preserve toggles and restore reading controls after snapshot swaps.
- Website `tests/reader-navigation.test.ts`, `publishing.test.ts` and
  `reader-rendering.test.ts`: cache/security limits, lifecycle and exact SF glyphs.
- Website `vendor/penned-reader/index.mjs` and `source.json`: regenerated renderer
  and matching source provenance; existing icon assets were reused unchanged.

Verification: 33 backend tests, Deno type checking, 22 website tests and the Astro
production build passed. Real public Collections Test/Make Coffee navigation ran
twenty snapshot taps per viewport at 390 and 1440 pixels with artificial network
delay: maximum synchronous DOM swap measured 5.9 ms and 4.7 ms respectively, with
zero full document navigations and no JavaScript errors. Browser back/forward,
search and actual flag/category glyph assets passed. Separate live disposable
fixtures passed child/grandchild navigation at 390/834/1440 pixels, follow-off
media protection and the inherited parent password grant. These web/backend fixes
do not require an app build for existing published documents. Native UI and real
physical Safari device interactions were not launched or claimed as verified.
Live link-regeneration/unpublish checks also removed already-open cached child
content and denied protected media. All disposable accounts/publications/media
were cleaned up. Website deployment is the connected `penned-site` production
project, served through `www.penned.im`; native/editor changes remain local for
the next normal app update, while the server restores existing published icons.
Production browser verification on `www.penned.im` passed the same twenty cached
taps per viewport: maximum measured DOM swap was 7.7 ms at 390 pixels and 5.8 ms
at 1440 pixels, with no document reloads or JavaScript errors. Those figures
measure cached navigation, not initial website/media download time.
