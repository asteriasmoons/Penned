# Penned Publish to Web: phases 1 and 2

Phases 4-5 are now implemented. See [PublishingAutomation.md](PublishingAutomation.md)
for the durable queue, native publishing interface, access controls and current
verification/deployment boundaries. Earlier phase status statements below are
historical implementation notes.

Phase 3 follow-up: the public viewer is implemented in the existing Astro site on
Vercel. See [PublishingViewer.md](PublishingViewer.md) for the current rendering,
visible-collection/page policy, deployment, file inventory and verification.
The original Phase 1-2 exclusions described below are historical: new publications
now carry explicit visible-only page/card and collection projections. They still
never contain destination bodies, parent/sibling records or hidden fields.

Implemented October 25, 2026. This document describes the native publishing
foundation, Supabase backend, privacy contract, and interfaces for the next phases.
The publishing sheet and automatic upload queue remain subsequent phases.
No private document database or CloudKit zone becomes public.

## Verified existing configuration

- App project: `Desktop/Vellix`, including the native `PennedMac` target.
- Editor source: `Desktop/penned-editor`, TipTap 3 bundled into WKWebView.
- Website: `~/Penned-Site`, Astro 7 with static marketing pages.
- Supabase: `https://rfujrtehopxvybsjlwus.supabase.co`, loaded from the existing
  `Vellix/Configuration/Supabase.xcconfig` and app Info settings.
- A read-only Auth settings request returned HTTP 200 with email enabled and
  Apple disabled. Publishing does not require enabling Supabase's Apple provider.
- Live verification on October 25 confirmed all five publishing tables, RLS,
  service-only RPC execution, and the private 16 MiB Storage bucket. Neither the
  anonymous nor authenticated client role has direct publishing-table privileges.
- The authenticated CLI now has deployment access to project
  `rfujrtehopxvybsjlwus`. Credentials were read through that tooling into test
  process memory only; none were written into source or printed.
- `penned-publishing` is active (version 3), with gateway JWT verification disabled
  and authentication enforced in its handler. Its hosted routing was corrected:
  Supabase forwards `/penned-publishing/...`, not the external
  `/functions/v1/penned-publishing/...` prefix. Both forms have regression coverage.
- Configured the previously absent `PENNED_APPLE_AUDIENCES` using the existing
  iOS and Mac bundle IDs below. Invalid Apple credentials now reach the verifier
  and return 401 instead of an application-level route failure.
- The existing `penned-delete-account` function was absent from the live project.
  Its unchanged implementation was tested, deployed, and verified using only a
  disposable email account. The existing migration was not reapplied or rewritten.

## Document privacy contract

`PublishingDocumentBuilder` reads a specifically selected, saved document from a
library-scoped `AppDatabase`. It verifies the signed-in account owns that library,
or is explicitly publishing from the unowned local library. CloudKit need not be
enabled. Existing document, library, and account identifiers are preserved.

The upload includes only title, subtitle, icon, cover, appearance, approved TipTap
content, and an explicit manifest of referenced media. It excludes parent and
sibling records, breadcrumbs, folders, Spaces, snapshots, local file paths, task
tracking metadata, tag catalogue identifiers, and unrelated attachments.

Nested `pageReference` nodes become `{ "type": "privateReference" }`. They carry
no destination identifier, title, preview, image, or nested body. Collection nodes
become `{ "type": "privateCollection" }` with no collection identifier, rows,
fields, entry previews, or underlying documents. These are intentional public
schema nodes. A future viewer must display an inert private-content indicator or
omit them; it must never resolve them through the private library. Publishing
collection projections or separately published document links requires a future
explicit policy extension.

Unknown node and mark types fail closed. Native and server projections maintain
explicit allowlists. Unsupported private URL marks are removed, while their
visible text remains. Server validation independently constructs a fresh public
payload rather than persisting the submitted object wholesale.

Current limits: 2 MiB request JSON, 20,000 public nodes, depth 64, 200 referenced
media files, 16 MiB per file, and 64 MiB of referenced media per publication.
Exceeding a limit reports an error without modifying the live version.

Media descriptors contain `id`, `name`, `mimeType`, `size`, and `sha256`. Native
identifiers are stable for an unchanged file within a selected document. The
server computes uploaded byte digests itself, verifies accepted content types,
and atomically matches every descriptor against that publication's immutable
uploaded media before committing a document.

## Authentication and account lifecycle

Email publishing reuses the existing refreshed Supabase email session. Every
owner request calls Supabase Auth `getUser(jwt)` and requires a registered,
confirmed email identity. The server chooses the owner from that verified result;
it never accepts an owner ID from the client.

Apple publishing uses a separate publishing session because enabling Supabase
identity linking would not preserve Penned's existing separation of Apple and
email identities. The existing Apple button now attaches a cryptographically
random nonce. After the normal local sign-in succeeds, Penned exchanges the Apple
identity token and raw nonce with `auth/apple` in the background. A publishing
network failure does not undo local Apple sign-in; it is available through
`AppState.publishingAuthenticationError`.

The server verifies Apple's signature against its HTTPS JWKS, RS256, issuer,
configured bundle audience, expiration, issue time, maximum age, subject, and the
SHA-256 nonce. It ignores the token's email when selecting ownership. The database
keys principals by provider and verified subject, so an Apple subject can never
merge with an email account based on email addresses.

Apple access tokens expire after 15 minutes. Refresh credentials rotate on every
refresh and have an absolute 30-day lifetime. Only hashes are stored server-side.
The app stores credentials in a separate project/account-scoped Keychain service,
coalesces refreshes, and checks account identity around asynchronous work. Token
exchanges and refresh credentials cannot be replayed. Apple authorization tokens
issued before account revocation cannot recreate a session after deletion.
Fresh authorization and forgetting an account now cancel/remove its older refresh
task. A completed older task cannot clear a newer refresh entry or restore old
credentials. Native concurrency regressions cover those lifecycle boundaries.

Existing Apple accounts need a fresh Continue with Apple authorization to acquire
their first publishing session. The existing settings UI can present that sign-in
flow; no new publishing UI is introduced here.

Email account deletion cascades from `auth.users` through its publishing owner,
publications, and media metadata. Apple account deletion first revokes its
publishing owner and all sessions/publications, then follows the existing iCloud
profile cleanup. If publishing authorization or revocation fails, deletion reports
the error and retains the account. Apple users without a publishing session must
authorize again before deletion. The existing durable deletion-pending flag also
records confirmed Apple publishing revocation so iCloud cleanup can resume after
a restart without repeating remote revocation. Original local documents remain.

Unpublishing retains the private saved publication for explicit republication.
Deleting an account revokes serving and removes publication metadata. Physical
objects left by account deletion or interrupted uploads remain in private storage
and require an operational retention/garbage-collection policy; they are never
served without a current publication manifest and valid link. The per-media
deletion API can remove unreferenced files before account removal. No background
garbage-collection schedule is installed by these phases.

## Database and storage boundary

Apply `supabase/migrations/202610250001_publishing.sql` once. It creates:

- Private provider/subject owners, hashed Apple sessions, and consumed Apple-token
  records in `penned_private`.
- `public.penned_publications` with an owner/source uniqueness constraint,
  256-bit random public token, version, active state, settings, and saved payload.
- `public.penned_publication_media` with immutable object metadata and retirement
  state used for race-safe deletion of files outside the current manifest.
- Private `penned-publications` Storage bucket with a 16 MiB object limit.
- Restricted transactional RPCs for identities, sessions, publication mutations,
  media retirement/deletion, and owner revocation.

All new tables have RLS. Anonymous and authenticated roles have no direct table
or RPC grants. There are intentionally no client-access table policies: the Edge
Function supports both identity providers and authorizes every operation. Only
the server role can invoke the mutation RPCs. A restrictive policy on
`storage.objects` denies client access to this specific bucket even if the project
already has a broad permissive Storage policy; other buckets remain unchanged.

Every mutation locks the owner and selected publication, checks its owner and
expected server version, verifies media, and commits all document/settings changes
in one PostgreSQL transaction. Failure retains the previous document, token,
settings, and version. Draft creation is idempotent for the owner/source pair.
Only the explicit `publish` action can activate an inactive publication. An
automatic `update` cannot resurrect an unpublished page.

Public reads look up one random token and expose no source/owner identifiers.
Expired, unpublished, missing, and regenerated old links return 404. Media URLs
include the current publication token and media ID. The server checks both the
active publication and its current manifest before streaming private Storage
bytes, including range requests. It issues no public or signed Storage URLs that
could outlive publication access checks. Responses use `no-store`, `nosniff`, and
`no-referrer`. Public text is noindex unless its explicit setting permits indexing.
File responses also carry a restrictive sandbox CSP. Unpublishing cannot erase
copies a visitor has already downloaded.

## HTTP API

Base: `https://rfujrtehopxvybsjlwus.supabase.co/functions/v1/penned-publishing`.
JSON requests use `Content-Type: application/json`. Native calls send the existing
publishable key as `apikey`; it does not establish ownership. Management calls
also require `Authorization: Bearer <verified email JWT or Apple publishing token>`.
Public GET/HEAD calls require no account or credentials.

| Method and path | Request | Result |
| --- | --- | --- |
| `POST /auth/apple` | `identityToken`, raw hex `nonce` | Apple access/refresh tokens, subject, expiry |
| `POST /auth/refresh` | `refreshToken` | Rotated Apple credentials |
| `DELETE /auth/revoke` | Apple access token | Revokes this Apple publishing session |
| `POST /publications` | `sourceLibraryID`, `sourceDocumentID` | Existing or new inactive publication status |
| `GET /publications/:id` | Owner credentials | Status, current server version, settings, link |
| `PUT /publications/:id/media/:mediaID` | File bytes; MIME Content-Type and percent-encoded `X-File-Name` | Server-verified media descriptor |
| `DELETE /publications/:id/media/:mediaID` | `expectedVersion` | Deletes only media outside the current manifest |
| `PUT /publications/:id` | `action`: `publish` or `update`, `expectedVersion`, `document`, optional `settings` | Atomically committed status |
| `POST /publications/:id/settings` | `expectedVersion`, `settings` | Updated status |
| `POST /publications/:id/unpublish` | `expectedVersion` | Inactive status, version incremented |
| `POST /publications/:id/regenerate` | `expectedVersion` | New random link, version incremented |
| `DELETE /owner` | Owner credentials | Revokes the owner's publications and sessions |
| `GET` or `HEAD /public/:token` | No credentials | Public document, approved settings, version, update time |
| `GET` or `HEAD /public/:token/media/:mediaID` | Optional byte range | Only a currently referenced media file |

Settings: `showTitle`, `showAuthor`, `showTableOfContents`, `allowIndexing`, explicit
`authorName`, and nullable ISO `expiresAt`. Hidden author names are removed from
public responses. Passwords, comments, email-restricted reader access, and custom
slugs are rejected rather than silently simulated.

Status has `id`, `sourceLibraryID`, `sourceDocumentID`, `version`, `active`, `token`,
`publicURL`, `settings`, and `updatedAt`. Use the returned server version as
`expectedVersion`; the document's local body revision is not a server version.
HTTP 409 requires refreshing status and resolving stale work rather than blindly
retrying with a new version. A timeout can occur after a successful commit; fetch
status before deciding how to retry. Saved title/style changes do not all increment
Penned's body revision, so the later automatic queue must observe complete saved
public content, not only `DocumentRecord.revision`.

## Native and website integration

Construct `PublishingService` with the current library's `AppDatabase` and
`AttachmentStore`, a `PublishingClient` using `SupabaseConfiguration.load()`, a
current-account closure, and an access-token closure calling
`AppState.publishingAccessToken()`.

`prepare(documentID:)` produces the saved selected document and privacy flags
without networking. `publish(documentID:settings:replacing:)` uploads verified media
and explicitly publishes. `update(documentID:publication:settings:)` is the separate
interface for subsequent automatic updates; it cannot activate an unpublished
page. `status` and `change` support controls and conflict handling. Capture pending
editor changes through the existing editor save pipeline before initiating a
user-requested publication in the later UI phase.

The website's `src/lib/publishing.ts` exposes `createPublishingReader(projectURL)`
with `read(token)` and `mediaURL(token, mediaID)`. It sends no account credentials,
does not cache private publication responses, returns null for unavailable links,
and preserves real errors. It does not render a page or add a static route for
every publication. The later viewer must validate/render the defined public schema
and use only this public API. Existing marketing pages and branding are unchanged.

## Deployment configuration

The migration and both backend functions are now deployed and live-tested. The
following configuration is retained as the deployment contract, not a request to
repeat the already-applied migration. Use the existing project's authenticated
CLI or Dashboard for future deployments.
Keep deployment credentials in local tooling or a secret manager, never in source
or the chat.

1. Review the migration against the project's existing schema and Storage policies.
   Apply the migration to a staging instance, then the existing project. A linked
   CLI can preview pending migrations with `supabase db push --dry-run` before
   applying them. Do not reset a database.
2. Set `PENNED_APPLE_AUDIENCES=im.lystaria.Vellix,im.lystaria.PennedMac` as a function
   secret/configuration value. These are the actual current target bundle IDs.
   Native Apple sign-in verifies with Apple's public keys and needs no Apple
   private signing key or email-based Supabase provider linking.
3. Deploy `penned-publishing` using `supabase/config.toml` with gateway JWT
   verification disabled. This is required for public visitors and the separate
   Apple publishing tokens. The handler performs owner authentication itself.
4. Confirm the standard hosted `SUPABASE_URL` and `SUPABASE_SECRET_KEYS` or legacy
   `SUPABASE_SERVICE_ROLE_KEY` are available only in the function environment.
5. Leave `PENNED_PUBLISH_BASE_URL` unset until the actual viewer exists. Links then
   point to the real public JSON endpoint. When the viewer is deployed, set it to
   its HTTPS route prefix; no viewer domain is invented by the native app.
6. Verify Apple sign-in on actual signed iOS/Mac builds, email publishing with a
   real account, Storage uploads/ranges, conflict responses, unpublish/link rotation,
   account deletion, and anonymous denial of direct table/Storage access.

The local migration tests use embedded PostgreSQL (PGlite) with isolated
Auth/Storage schema fixtures. The separate live verification below exercises the
actual hosted Auth, function gateway, PostgREST, PostgreSQL and Storage stack.

## Live verification and remaining device checks

`supabase/scripts/verify-live.mjs` creates uniquely named disposable email users,
publications and files, and cleans them up in `finally`. It requires explicit live
opt-in and CLI deployment access. Never point it at someone else's credentials or
substitute real document/account IDs for its generated fixtures.

Nine live verification groups passed with the modern publishable key:

- All five tables/RLS, all client table grants, all five privileged RPC grants,
  private bucket, object size limit and restrictive Storage policy.
- Real hosted routing; unauthenticated and forged email/Apple credential rejection.
- Real Supabase email OTP verification and refresh, stable owner identity, and
  idempotent draft creation. Administrative magic links avoid sending test mail.
- Cross-account management denial and direct anonymous/authenticated table/RPC denial.
- Publication creation and update; independent server stripping of private parent,
  nested-page, collection, author and workspace canaries. Native tests separately
  prove that the selected document builder never loads parent/sibling content.
- Real private media upload/download, SHA-256 matching, byte ranges (206/416),
  denial of staged media, in-use deletion protection and direct/signed client access.
- Atomic stale-version/missing-media failures, link regeneration with old content
  and media links revoked, settings, expiration, unpublishing and explicit republish.
- Apple publishing-session rotation, replay rejection, sign-out, provider isolation,
  owner revocation and rejection of pre-deletion credentials. This group uses an
  explicitly seeded disposable session; it does NOT simulate a valid Apple signature
  or claim to prove Continue with Apple.
- The existing email deletion endpoint removes only its authenticated fixture user,
  revokes its public page and credentials, cascades publication metadata, and leaves
  the second fixture account intact.

Penned-Site's actual `src/lib/publishing.ts` was also loaded by the live harness:
it reads the real public payload, constructs the correct media URL and returns null
after unpublishing. No viewer route, rendering UI or marketing-page change was made.

The user deferred physical-device checks. Still required before claiming complete
device authentication verification: use a signed updated iPhone/iPad app and Mac
app to authorize Continue with Apple, then verify Keychain restoration after a cold
restart, refresh, account switching/sign-out and the real Apple/iCloud deletion
flow using a disposable account. Real email delivery and the on-device OTP flow
also remain physical/manual checks; the hosted OTP verification/refresh APIs passed.
No additional backend credentials or Supabase settings are currently needed.

Private orphaned objects still require the operational retention policy described
above. Automatic publication updates, trash-triggered revocation, publishing
controls and the rendered public viewer are intentionally outside phases 1 and 2.

## Verification commands

Verified locally: 70 account/session tests, 11 native document/media/service tests, 11
backend contract/database tests, 3 publishing SDK/cryptography tests, 2 website
reader tests, and the existing deletion endpoint's 64 handler plus 14 SDK tests
passed (175 total), in addition to the nine live verification groups above.
iOS Simulator compile-only and native Mac app builds succeeded with signing
disabled, and the Astro website build succeeded. The Edge Function and website
reader also passed TypeScript checking. No app or simulator was launched. Existing
non-publishing isolation/deprecation warnings remain; the publishing session's
actor-isolated Codable warning was corrected.

From the app project:

```
node Scripts/test-accounts.mjs
PENNED_PUBLISHING_TESTS=1 node Scripts/test-collections.mjs
node --test --test-timeout=10000 supabase/functions/penned-delete-account/handler.test.ts
```

From `supabase/` after `npm ci`:

```
npm test
npm run check
npm run test:adapters
./node_modules/.bin/deno test --allow-env --deny-net functions/penned-delete-account/supabase.test.ts
npm run test:live -- --project-ref rfujrtehopxvybsjlwus --confirm-live --reader /Users/asteriasmoons/Penned-Site/src/lib/publishing.ts
```

From `~/Penned-Site`:

```
npm test
npm run build
```

The focused document harness uses the real production persistence, repositories,
projection, publishing service and client. Native HTTP regressions use URLProtocol;
the live API tests are separate and explicitly exercise the hosted backend. The
broader `node Scripts/test-collections.mjs` harness still cannot compile its existing
task-history/UI-dependent fixtures (`AppEnvironment`, `TaskHistoryTimestamp` and a
missing `scheduledAt` argument). Those unrelated fixtures and task code were left
unchanged; this is not reported as a passing full library suite.

## Verification follow-up changes

Only these files changed during the deployed-backend follow-up:

| File | Reason |
| --- | --- |
| `supabase/functions/penned-publishing/handler.ts` | Accept the actual hosted gateway path without widening route matching |
| `supabase/tests/routing.test.ts` | External/hosted route parity, credential rejection and incorrect-prefix regressions |
| `supabase/scripts/verify-live.mjs` | Opt-in isolated live lifecycle/security tests, fixture cleanup and actual website-reader verification |
| `supabase/package.json` | Explicit `test:live` command; no dependency changes |
| `Vellix/Publishing/PublishingAppleAuth.swift` | Correct session Codable isolation and cancel/identify refresh tasks across reauthorization/sign-out |
| `Tests/Publishing/PublishingAuthTests.swift` | Concurrent refresh, fresh authorization and forgotten-account regressions |
| `Tests/Publishing/PublishingDocumentTests.swift` | Actual native service/client upload integrity, selected-source privacy, cancellation and conflict coverage |
| `Docs/Publishing.md` | Current deployment state, exact validation boundaries and this change inventory |

Live-only changes: configured the Apple audiences, redeployed the corrected
publishing function, and deployed the unchanged existing account-deletion function.
No user content, existing account, database reset, or schema rewrite was involved.

## Changed-file inventory

| File in app project | Purpose |
| --- | --- |
| `Vellix/Publishing/PublishingTypes.swift` | Public JSON, settings, media, status and error contracts |
| `Vellix/Publishing/PublishingProjection.swift` | Native allowlisted selected-document projection and private-reference rules |
| `Vellix/Publishing/PublishingDocumentBuilder.swift` | Scoped saved-document and referenced-media preparation |
| `Vellix/Publishing/PublishingClient.swift` | Real authenticated HTTP management and media API |
| `Vellix/Publishing/PublishingService.swift` | Account-checked prepare/publish/update/status/control workflow |
| `Vellix/Publishing/PublishingAppleAuth.swift` | Nonce, Keychain publishing sessions and refresh handling |
| `Vellix/Services/EmailAuthentication.swift` | Publishing-token interface on existing email authentication |
| `Vellix/Services/SupabaseEmailAuth.swift` | Verified refreshed email access token for publishing |
| `Vellix/Services/AuthService.swift` | Provider-preserving publishing authentication and Apple owner revocation |
| `Vellix/Data/AppState.swift` | Background Apple authorization, token access and deletion integration |
| `Vellix/Accounts/SignInView.swift` | iOS Apple nonce and publishing-session handoff |
| `PennedMac/Accounts/MacSignInView.swift` | Matching native Mac sign-in integration |
| `Vellix/VellixTests/AccountTests.swift` | Publishing revocation and durable account-deletion regressions |
| `Tests/Publishing/PublishingAuthTests.swift` | Native session, expiry, subject and secure-write tests |
| `Tests/Publishing/PublishingDocumentTests.swift` | Native privacy, ownership, CloudKit independence and media tests |
| `Scripts/test-accounts.mjs` | Include publishing authentication in the existing headless account suite |
| `Scripts/test-collections.mjs` | Focused publishing mode using existing real domain compilation |
| `supabase/config.toml` | New public/owner publishing Edge Function entrypoint |
| `supabase/README.md` | Link the publishing implementation alongside the retained deletion function |
| `supabase/functions/.env.example` | Actual Apple bundle audience configuration |
| `supabase/functions/penned-publishing/contract.ts` | Server public-document and settings validation |
| `supabase/functions/penned-publishing/handler.ts` | Real HTTP publishing, sessions, public reads and media lifecycle |
| `supabase/functions/penned-publishing/supabase.ts` | Supabase Auth/database/Storage adapter and Apple signature verification |
| `supabase/functions/penned-publishing/media.ts` | Media type/signature validation |
| `supabase/functions/penned-publishing/index.ts` | Deno Edge Function composition |
| `supabase/functions/penned-publishing/supabase.test.ts` | Real SDK request and cryptographic verification tests |
| `supabase/migrations/202610250001_publishing.sql` | Tables, RLS, private bucket, policies and atomic RPCs |
| `supabase/tests/contract.test.ts` | Adversarial privacy and validation tests |
| `supabase/tests/database.test.ts` | Actual migration, permissions, HTTP lifecycle and transaction tests |
| `supabase/package.json` | Pinned validation/test dependencies and scripts |
| `supabase/package-lock.json` | Reproducible tooling/dependency resolution |
| `Docs/Publishing.md` | Implemented contracts, deployment, limits and this inventory |

| File in website project | Purpose |
| --- | --- |
| `src/lib/publishing.ts` | Anonymous public-reading interface for the later viewer |
| `tests/publishing.test.ts` | Credential-free reading, unavailable links and media URL checks |
| `package.json` | Website test command |

Existing GRDB schemas, private document identifiers, CloudKit synchronization,
editor runtime, assets, native layouts, and website marketing pages are retained.
