# Penned Accounts

## Implemented Scope

Account Settings now uses Penned's existing custom back button, rounded black
typography, purple accents, asset icons, shared sheet headers, and frosted fields.
It supports native Sign in with Apple, Supabase email OTP, saved-account selection, name/contact-email
editing, photo import/removal, logout, and confirmed account deletion. The duplicate
native navigation toolbar and the reference app's floating button are not used.

Account details still use the original CloudKit profile service. Document libraries
now have explicit ownership and a separate, opt-in native CKSyncEngine adapter over
the existing GRDB database. Signing in assigns the unowned local library to that
account before opening its content; a separate adoption step is not required.
Explicit local-only mode remains available. Sync is disabled by default.
Signing out or deleting an account does not
delete or reassign its documents or its CloudKit document zone.

## Storage and Identity

- Existing documents remain in the existing GRDB `Vellix.sqlite` database and
  existing attachment directories. Migrations v20-v22 add library ownership,
  access guards, and synchronization metadata without replacing content IDs or
  uploading the SQLite file.
- `AuthUser` records are a local SwiftData cache in Application Support under
  `Vellix/Accounts.store`. Its configuration explicitly uses
  `cloudKitDatabase: .none`; automatic SwiftData CloudKit mirroring is not enabled.
- A provider-aware active-account pointer is stored in Keychain, not UserDefaults.
  Both the old `com.penned.currentAppleUserID` Keychain key and the older
  `auth.currentAppleUserId` preference migrate after a successful secure write.
  Existing Apple records require no identity rewrite. New optional email identity
  fields and a defaulted cleanup flag use SwiftData lightweight migration.
- Native Apple credential validation runs during session restoration and cached
  account activation. A rejected cached account cannot clear a different active
  session. Apple revocation notifications affect Apple sessions only.
- Account-store failure is reported separately and does not prevent the existing
  GRDB document application from opening.

Sign in with Apple identifies the Penned account. CloudKit's private database
belongs to the device's signed-in iCloud account, which can differ from the Apple
identity selected for sign-in. The profile is bound to the iCloud user record name
after successful sync; a different iCloud identity is rejected before an upload.
Supabase email authentication does not change the device's iCloud account.
See Apple's [private database documentation](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase).

## CloudKit Profile Contract

Container: `iCloud.im.lystaria.Penned`. Database: private. Record type:
`PennedAccountProfile`, in the default zone. Its deterministic record name is
`account-` plus a SHA-256 digest of the native Apple user identifier for Apple
accounts, unchanged from the original implementation. Email accounts use
`email-account-` plus the SHA-256 digest of
`supabase:<canonical project URL>:<lowercase Auth user UUID>`. Prefixes and
provider/project-qualified subjects prevent collisions. Neither contact email nor
verified email is used as the permanent identifier. Profiles remain in CloudKit;
no profile/document tables or Storage buckets are introduced in Supabase.

| Field | CloudKit Type | Meaning |
| --- | --- | --- |
| `name` | String | Editable Penned display name |
| `email` | String | Editable contact email, not a change to provider login credentials |
| `image` | Asset | Prepared account photo; nil removes the remote photo |

An existing cloud profile is fetched before first upload so another device's name
and photo are not replaced by initial provider defaults. Local profile edits are
saved before network work, marked pending, and retried on foreground/account-page
refresh or the explicit retry action. There is no polling loop or background push
profile sync. Concurrent server changes surface as native CloudKit errors rather
than being treated as successful saves; advanced field-level merging is not added.

Profile requests are serialized and guarded by active identity, cancellation, and a
local edit revision. A delayed fetch cannot replace newer edits or another selected
account. Photos reuse the existing image-preparation pipeline, including validation,
downsampling, and PNG encoding, rather than persisting original photo-library files.

## Supabase Email Authentication

The official `supabase-swift` SDK is pinned to **2.55.4** in Xcode and the headless
test harness. Native Sign in with Apple remains independent of Supabase. No Apple
user is migrated, linked, or merged into an email user, even when emails match.

`AuthService` routes both providers through the existing `AppState` lifecycle and
local `AuthUser` cache. Email identity is the provider/project plus Supabase Auth's
stable user UUID. `authenticationEmail` stores verified sign-in metadata;
`AuthUser.email` remains the independently editable contact email. Changing contact
email never calls Supabase's email-change API.

The flow is Continue with Email, email entry, `auth.signInWithOTP`, numeric code
entry, `auth.verifyOTP(type: .email)`, secure session persistence, then local account
creation/restoration. Resending calls `signInWithOTP` again. Invalid/expired codes,
rate limits, missing configuration and network errors stay in the sheet; no local
account is activated on those failures. Codes accept Supabase's supported 6-10
digits without assuming a fixed project OTP length. Closing cancels the attempt;
late results cannot replace the current account.

### Secure Session Storage and Switching

The SDK's default session slot represents one session, not a saved-account list.
Penned instead creates clients lazily per project/user UUID. Each uses
`PennedAuthKeychainStorage` with a distinct hashed service namespace and a fixed
session key within that namespace. Writes still use the SDK's native
`KeychainLocalStorage`; reads/deletes use native Security queries with the same
service/account attributes. Only `errSecItemNotFound` becomes an empty read or
successful no-op deletion. SDK migration/code-verifier keys are isolated
by the service too. OTP drafts use locked in-memory SDK storage, then transfer the
verified session into its account client with `setSession`. Drafts are discarded,
not signed out, because they share the same server session tokens.

The SDK serializes complete sessions and refreshes expired access tokens through
`auth.session`. Penned verifies the user with `auth.user()`, checks the selected
UUID, and confirms the latest session actually reached secure storage before
committing activation. A checked storage wrapper retains errors the SDK otherwise
logs internally, so inaccessible Keychain data is not treated as revocation.
The SDK's Keychain backend throws for absent items, including expected migration
probes. Previously, those harmless reads permanently marked the checked wrapper
as failed, so even a successfully saved OTP session could show "The account
session could not be saved securely." Normalizing missing items before they reach
that wrapper fixes the false failure without suppressing access, write, decoding,
or entitlement errors. Existing Keychain service names, keys and data are unchanged.
There are no auth tokens in SwiftData, UserDefaults, plist, or document records.
SDK request logging is disabled.

Automatic periodic token-refresh loops are disabled; restore/switch/foreground
validation refreshes on demand. The SDK can also refresh an expired slot during
initialization; the same per-account client and its refresh deduplication are
retained. A transient network failure keeps credentials for retry. A rejected
email session clears only its own credentials and clears the active pointer only
if it still points to that account. Switching providers/accounts does not log out
the outgoing account. An explicitly logged-out email account stays in the saved
list but requires OTP again when selected.

Email logout uses SDK `.local` scope, not its default `.global` scope. Local secure
credentials are removed even when the network is unavailable; remote revocation
is best effort in that case. Existing access JWTs can remain valid until expiry.
There is no promise that saved sessions survive Supabase administrator revocation,
session-duration limits, or a single-session policy. Cross-project sessions are
never sent to a newly configured project. See the
[SDK source](https://github.com/supabase/supabase-swift/tree/v2.55.4/Sources/Auth)
and [sign-out scope documentation](https://supabase.com/docs/guides/auth/signout).

## Manual Supabase Setup

No Supabase credentials, dashboard settings, SMTP settings, function deployment,
or live user accounts were configured by this implementation.

1. **Project URL.** Open the intended Supabase project's **Connect** dialog and
   copy its project URL. Use the base HTTPS project URL, not `/auth/v1`, a REST
   endpoint, a database connection string, or the dashboard URL.
2. **Publishable key.** Copy the `sb_publishable_...` key from Connect or
   **Settings > API Keys > Publishable and secret API keys**. Create publishable
   keys there if the project only has legacy keys. Open
   **`Vellix/Configuration/Supabase.xcconfig`** and replace its two placeholders.
   For `SUPABASE_URL`, keep `https:/$()/` and replace the placeholder hostname with
   your project's hostname; Xcode expands this to the full `https://` project URL.
   The escape prevents `//` being parsed as an xcconfig comment. Enter your public
   key as `SUPABASE_PUBLISHABLE_KEY`. Both Debug and Release app configurations use
   this file without replacing their existing build settings. The source
   `Resources/LaunchInfo.plist` contains `$(SUPABASE_URL)` and
   `$(SUPABASE_PUBLISHABLE_KEY)` substitutions; do not enter credentials there.
   `Accounts/SupabaseConfiguration.swift` remains the single reader/validator for
   the generated app Info.plist. Unset placeholders and unexpanded build settings
   are rejected with a configuration error, not sent as authentication requests.
   Never paste a secret, service-role key, database password or privileged JWT.
   Missing/invalid configuration produces a visible development error while Apple
   sign-in remains usable. See [API keys](https://supabase.com/docs/guides/getting-started/api-keys).
3. **Enable email.** Under **Authentication > Sign In / Providers**, enable the
   Email provider. Allow new users to sign up if first-time OTP users should create
   accounts; Penned sends `shouldCreateUser: true`. Keep native Apple outside
   Supabase; enabling a Supabase Apple provider is not required.
4. **Deliver a numeric code.** In **Authentication > Emails > Templates**, edit
   both **Confirm sign up** and **Magic Link**. With email confirmation enabled,
   new/unconfirmed users can receive the signup template; confirmed users receive
   the magic-link template. Set an appropriate subject and display `{{ .Token }}`
   as plain text instead of an authentication link using `{{ .ConfirmationURL }}`.
   For example, this includes the publicly hosted Penned logo in the email body:

   ```html
   <img src="https://www.penned.im/images/branding/penned.png"
        alt="Penned" width="80" height="80"
        style="display:block;margin:0 auto 20px;border:0;">
   <h2>Penned verification code</h2>
   <p>{{ .Token }}</p>
   <p>Return to Penned and enter this code to continue.</p>
   ```

   The logo must use a public HTTPS image URL, not a local asset-catalog path.
   This styles the email body, not the inbox's sender avatar. Do not place
   `{{ .Token }}` in an `href` or leave a confirmation/sign-in link in the code-only
   template. Save and preview both templates, then request a fresh email: changing
   a template does not change emails already delivered. Test both a new email
   user and an existing confirmed email user. The required **Site URL** can be
   `https://www.penned.im/` as the website fallback; the additional **Redirect URLs**
   list can remain empty for this OTP flow. Penned
   verifies typed codes and does not depend on opening a magic link or registering
   an auth URL callback. Set OTP length/expiry in Email provider settings to your
   desired security policy. The supported API flow is described in
   [passwordless email authentication](https://supabase.com/docs/guides/auth/auth-email-passwordless).
5. **Delivery limits and production SMTP.** The built-in sending service is for
   development, restricts recipients to project-team addresses and currently has a
   very small email quota (documented as 2/hour, subject to change). Configure a
   production SMTP provider under **Authentication > Emails > SMTP Settings**;
   verify its sender/domain configuration and delivery. Review project Auth rate
   limits and SMTP-provider quotas. OTP resends default to a 60-second interval;
   Penned displays server rate-limit errors instead of claiming another code was
   sent. Project settings are authoritative. See
   [custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp).
6. **Server deletion.** Deploy the included `penned-delete-account` Edge Function
   to this same project, using the instructions in `supabase/README.md`:

   ```sh
   supabase functions deploy penned-delete-account --project-ref <your-project-ref>
   ```

   The function's server environment must have this project's URL and an admin
   secret (`SUPABASE_SECRET_KEYS.default`, or the documented legacy server-only
   fallback). None belongs in the client plist. The handler verifies the caller's
   bearer token through Supabase Auth and deletes only that verified user; it
   accepts no deletion target supplied by the client. Gateway verification is
   disabled for this function in `supabase/config.toml`, but handler authentication
   is mandatory. Audit any existing `auth.users` triggers/cascades before deployment.
   A missing function produces an explicit setup error; a failed/unconfirmed
   response is never converted into deletion success.
7. **Real-device test.** Configure a staging project and SMTP, build on a physical
   device, and test both sign-in buttons. Send an email OTP, verify it, resend,
   submit an incorrect/expired code, cancel, and interrupt the network. Sign into
   two different email users plus Apple; relaunch and switch among all three.
   Wait for access-token expiry and verify refresh. Confirm separate profile names,
   photos, verified/contact emails, logout, revocation and deletion using disposable
   users. Test iCloud identity changes and force a failed iCloud cleanup after
   confirmed Supabase deletion. The GRDB document library must remain unchanged.

## Logout and Deletion

Logout clears the selected secure session but keeps cached accounts and documents.
Apple deletion retains the original CloudKit-profile deletion and manual Apple
disconnect behavior. Email deletion drains profile work, verifies the iCloud
binding, and requires authenticated confirmation from the server deletion function
before removing its iCloud profile and local cache. Other accounts and all GRDB
documents remain. No profile or document data is moved to Supabase.

After Supabase confirms deletion, a durable `remoteAuthDeleted` flag prevents
ordinary authentication/profile refresh. If iCloud cleanup fails, the UI says
deletion is pending and offers **Finish Account Deletion**, including after
relaunch, without trying to authenticate a deleted Supabase user. Only completion
of all cleanup displays success. Missing backend configuration or an unconfirmed
response leaves the local account for recovery. A lost response after server-side
deletion cannot be proven successful by the client; operator reconciliation may
be required, as documented in `supabase/README.md`. There is no distributed atomic
transaction across Supabase, CloudKit and device storage.

The app does not have an OAuth token-exchange server or a Sign in with Apple
developer signing secret. Deletion therefore uses Apple's documented manual
authorization-revocation flow: delete Penned account data, direct the user to Apple
Account settings, and respond to native credential-revoked notifications. The
post-deletion prompt provides that direction. It does not claim to delete the
Apple Account itself. See [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

## Changed Files

| File | Purpose |
| --- | --- |
| `Vellix/Accounts/AccountSettingsView.swift` | Account page, photo picker, edit sheets, account switcher, confirmations |
| `Vellix/Accounts/AccountPersistence.swift` | Local account container, validation, account errors and profile value type |
| `Vellix/Accounts/AccountIdentity.swift` | Provider/project-specific stable account identities |
| `Vellix/Accounts/SupabaseConfiguration.swift` | Central URL/publishable-key configuration and validation |
| `Vellix/Accounts/SignInView.swift` | Native Apple button and cancellable email/code/resend flow in shared sheet styling |
| `Vellix/Models/AuthUser.swift` | Provider identity, separate verified/contact emails, profile metadata and deletion cleanup state |
| `Vellix/Data/AppState.swift` | Session lifecycle, profile edits/sync, switching and deletion |
| `Vellix/Data/KeychainHelper.swift` | Secure active-account key and non-destructive Keychain updates |
| `Vellix/Services/AuthService.swift` | Apple credentials, cached-account validation and secure session storage |
| `Vellix/Services/AccountCloudStore.swift` | Explicit private CloudKit profile reads, writes, images and deletion |
| `Vellix/Services/EmailAuthentication.swift` | Injected email provider contract and actionable errors |
| `Vellix/Services/SupabaseEmailAuth.swift` | Official SDK OTP, isolated secure sessions, native missing-item normalization, refresh, logout and deletion |
| `Vellix/Spaces/PennedSettingsView.swift` | Route Account Settings and reuse the existing custom back control |
| `Vellix/VellixApp.swift` | Own/inject AppState, restore session and respond to identity changes |
| `Vellix/Vellix.entitlements` | Remove the invalid duplicate push entitlement; retain configured capabilities |
| `Vellix.xcodeproj/project.pbxproj` | Keep the new account test source out of the application target |
| `Vellix/VellixTests/AccountTests.swift` | Native persistence, session, profile, identity and failure tests |
| `Vellix/VellixTests/SupabaseAuthTests.swift` | Actual SDK with intercepted HTTP and isolated storage, never live auth |
| `Scripts/test-accounts.mjs` | Bounded headless macOS account test harness |
| `Scripts/fixtures/LegacyAccountStore.swift` | Old Apple-only model writer for real store-migration verification |
| `Vellix/Configuration/Supabase.xcconfig` | Shared Debug/Release public Supabase configuration placeholders |
| `Vellix/Resources/LaunchInfo.plist` | Build-setting substitution for the two public Supabase values |
| `Vellix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Resolved official SDK and transitive dependencies |
| `supabase/config.toml` | Deletion-function gateway/entry-point configuration |
| `supabase/functions/penned-delete-account/{index,handler,supabase}.ts` | Server-only authenticated self-deletion and SDK adapter |
| `supabase/functions/penned-delete-account/{handler,supabase}.test.ts` | Injected server and SDK-adapter security tests |
| `supabase/README.md` | Deployment, request contract, secrets and failure limitations |
| `Scripts/test-sheet-style.mjs` | Account routing, assets, shared styling and storage-boundary checks |
| `Docs/Accounts.md` | Account contract, verification boundaries and document-sync integration plan |

The original profile/authentication phase left the document system unchanged.
The document phase below extends the repositories and editor save boundary without
changing shared materials, collection layouts, or document backgrounds.

## Verification and External Setup

The results in this section describe the earlier account/profile phase. Current
document-phase results and remaining device checks appear under Verification Boundary below.

- 62 native account/SDK tests pass. Account tests use real SwiftData persistence and injected Apple,
  email-session and CloudKit boundaries. An old-schema writer creates an actual
  Apple-only store, then the new container opens/migrates it without resetting.
- SDK tests use intercepted HTTP, fake test sessions and isolated memory storage;
  they exercise official request/verification/refresh/persistence behavior without
  sending email or contacting live Supabase or real Keychain.
  Keychain-adapter tests inject native Security status codes, including missing
  items, inaccessible Keychain, missing entitlement, invalid returned data and
  idempotent deletion. The SDK OTP/restore test uses that adapter over an isolated
  in-memory backend, not the device's real Keychain.
- 118 sheet/source-contract checks pass.
- Debug and Release build settings resolve both public Supabase values from
  `Configuration/Supabase.xcconfig`; both generated app Info.plists contain the
  expanded values, and the xcconfig is not bundled as an app resource. Placeholder
  values are rejected before authentication.
- 64 server-handler security tests and 14 server SDK-adapter tests pass; all three
  server sources/tests type-check with Deno. These use injected HTTP, no live Auth.
- 156 existing native library regression tests pass.
- The Keychain missing-item fix passes a Debug generic iOS-device build with
  signing disabled. Debug and Release builds also passed during the earlier
  xcconfig integration; Release was not rerun for the Keychain-only change. No
  simulator is used. The prior Release build reported concurrency/deprecation
  warnings in untouched editor/library files.
- Entitlements and project plist validation pass; `git diff --check` passes.

Still required on real devices: native Apple authorization/cancellation/revocation,
secure session restoration, photo selection, rendering, first/second-device profile
sync, iCloud sign-out/change, offline edits/retry and deletion. Local tests and an
unsigned build do not prove provisioning or live CloudKit behavior.

The app identifier's provisioning must include Sign in with Apple and association
with `iCloud.im.lystaria.Penned`. Create/verify the profile record schema in the
CloudKit development environment and deploy it to production before distributing
a production build. No developer-portal settings, production schema, credentials or
remote data were changed by this implementation.

## Next Phase: Document Ownership and Cross-Device Sync

This phase is implemented client-side. It extends the existing library, not a
second document database. Live CloudKit transport and two-device behavior still
require the provisioning and device checks below. No migration or sync was run
against the developer's actual document library while implementing this phase.

### 1. Ownership and Migration

- v20 creates `libraries` and adds `libraryID` to Spaces and saved document styles.
  All pre-existing rows belong to `local`, which cannot enable sync. Documents,
  folders, templates, collections, tasks, snapshots and attachments inherit their
  library through their existing Space/document relationships.
- Account library IDs are `account-` plus SHA-256 of a provider-qualified owner
  key: `apple:<native Apple subject>` or the existing Supabase project/UUID
  identity. This does not change Apple profile record names or account IDs.
- After successful sign-in or session restoration, `LibraryWorkspace` saves
  pending edits, rechecks the active authenticated identity, and calls
  `LibraryRepository.claimLocalLibrary` before opening the account's workspace.
  This assigns authored unowned local Spaces (including archived Spaces), their
  associated content and local saved styles to the signed-in account in one
  ownership transaction. No document IDs, JSON, attachment paths or content
  relationships are rewritten or copied. This automatic assignment replaces
  the earlier workflow that required manual adoption after signing in.
  Untouched, provenance-tracked bootstrap defaults remain local; existing Spaces
  without that provenance are preserved and treated as authored.
- The current local Space and default Space are carried into the account
  workspace. An empty signed-out workspace does not replace an existing account's
  selected Space. An earlier-created empty account library is reused, not opened
  instead of the incoming local content. Reopening the account does not copy or
  reassign already-owned content, including content previously adopted manually.
- Content owned by another account is never included. Logout does not return
  owned Spaces to the unowned local library. Signing in does not enable sync or
  change an existing iCloud binding; newly assigned content is queued only if the
  destination account has already opted into document sync.
- Explicit local-only mode is still available through Library & Sync, with the
  choice remembered per account. That mode deliberately skips assignment until
  Open Account Library is chosen. The optional selective `adopt` command retains
  its existing confirmation and moves only the selected Spaces in that operation;
  its workspace reload does not claim the remainder. On the next default sign-in
  or session restoration, any still-unowned content joins that account unless
  local-only mode is explicitly selected. Selective adoption is no longer required
  in the default sign-in flow.

### 2. Account-Scoped Access and Switching

`LibraryWorkspace` retains one GRDB writer and creates scoped AppDatabase handles
and AppEnvironments over that writer. Repositories filter library enumeration and
direct access independently of the current Space filter. Database triggers guard
authored writes, including raw SQL updates, against cross-library ownership.

Before replacing a workspace, AppEnvironment waits for an in-progress Space
transition, drains persistent editor operations, captures/saves pending JSON, stops
old reminder scheduling, clears editor/collection/preview state, and revokes the old
database handle. Late callbacks cannot write through that closed handle. A failed
save prevents replacement; the app reports the failure instead of discarding the
old editor. The old library UI is hidden while its account is no longer active.
The error screen can retry or authenticate/return to the previous account, so
retained pending edits are not stranded behind the new account's screen.
Active Space preferences are library-specific. Reminder deep links cannot open a
document belonging to another account, and old task notification content is
removed when closing the old workspace.
The app's startup task distinguishes account checking from a completed signed-out
session. It does not open a temporary local workspace while authentication is
still restoring an account.

### 3. Native CKSyncEngine and Record Mapping

The container remains **`iCloud.im.lystaria.Penned`**, private database. Each account
library uses `PennedLibrary-<library ID>` as its custom zone name. Profile records
remain in their original default zone and are not handled by the document engine.

`LibrarySyncEngine` implements CKSyncEngineDelegate, scopes fetch/send work to its
one zone, preserves the SDK's serialization, uses native optimistic change tags,
and reconstitutes pending changes from the GRDB journal on startup. Automatic sync
starts only after opt-in. App foreground, silent notifications, explicit Sync Now,
and network restoration also trigger synchronization. Native scheduling remains
system-controlled; it is not a continuous polling loop.

Every send verifies the active Penned owner, persisted library/iCloud binding, and
current iCloud identity. Account switches stop the engine; iCloud changes cannot
rebind an existing queue. Returning to another iCloud account does not migrate a
library to it. A new installation using a different iCloud account cannot access
the first account's private database; use the same iCloud identity on both devices.

v22 adds metadata tables alongside the existing authored tables:
`librarySyncItems`, `librarySyncState`, `librarySyncInbox`,
`librarySyncConflicts`, `librarySyncAssets`, and the import-suppression flag.
They are not a second document store used by the editor.

### 4. Authored Data and Attachments

The row adapter synchronizes Spaces (including icon bytes), folders, templates and
their root documents, documents, canonical TipTap JSON, appearance/card settings,
snapshots, attachments/thumbnails, saved styles, collections, fields, views,
entries, values, task completions, daily-note settings, and event-note associations.
Existing primary/foreign keys are the wire identities, not regenerated copies.
Explicit first creation uses a stable default account Space ID when available.
Opening an empty account or receiving sync batches does not create a default.
Existing Space IDs remain unchanged.

Task bodies/history and inline properties remain in document JSON. Search text,
counts, task projections, tag catalogue/occurrence indexes, previews and editor
attachment projections are rebuilt/refreshed locally. Tag catalogue UUIDs are
device-local derived index identities, not wire-authored IDs; existing local tag
IDs are not replaced. Tag names, block IDs and occurrence IDs remain in the
unchanged authored JSON.

Row JSON is a CKAsset, avoiding the ordinary record-field size ceiling. Actual
attachment/style-image bytes use separate CKAsset fields with relative filenames
and SHA-256 manifests. No sandbox absolute path is sent. Received asset bytes are
verified and copied out of CloudKit's temporary area before advancing state.
Different bytes at an existing immutable filename pause sync and retain both
copies instead of overwriting a file. Hashing/file staging runs off the UI actor.
CloudKit quota failures remain visible with local work retained.

### 5. Offline Work, Deletes, and Recovery

SQL triggers journal each authored account-library edit in the same transaction
as the edit. Rollback rolls back the journal too. The journal remains durable even
when sync is paused or the app exits. A mutation identifier prevents an older
upload acknowledgment or echoed download from discarding a newer local edit.

Fetched rows enter a durable inbox before SDK state is persisted. Dependency
closure, prospective Space-relationship checks and deferred FK validation allow
template/document cycles and batches arriving out of order. Missing-parent rows
and partially delivered Space transfers remain staged across relaunch. Imports
commit transactionally with re-enqueueing suppressed, then refresh derived data
and loaded editors after saving any pending editor changes first.

Ordinary same-record conflicts use the current server revision and retain the
local authored row in Recovery Revisions; rich-text conflicts also create a
recovery snapshot when its document survives. Cascading remote deletion retains
the affected graph if it contains unsent content and stops orphan uploads.
Recovery preserves the original IDs. Restore parent Spaces/documents before
dependent attachments, collection metadata or snapshots; the previous live
version is retained when manually restoring a revision.

Deletes use durable, content-redacted tombstones, not repeated blind physical
deletes. Acknowledged tombstones no longer contain deleted document text or asset
manifests. A deleted CloudKit zone pauses sync without deleting the local library.
"Restore Removed Cloud Library" requires a separate confirmation before clearing
old system fields and re-uploading the retained local data to the same iCloud
identity. Account deletion still does not delete GRDB libraries or CloudKit
document zones. No general-purpose cloud-library deletion action was added.

Two independent documents claiming the same Daily Note date, or two event-note
associations claiming one event, are not silently merged, renumbered or discarded.
Sync pauses, retains the inbox, and exposes the incoming conflicting revision for
review. Move the existing note to another Space (or trash an existing Daily Note),
then retry. The original identifiers remain intact. Unsupported schema/relationship
changes likewise pause rather than partially applying a batch.

Recovery records and tracked/staged asset files are conservatively retained. No
automatic retention-limit purge or cache garbage collector is implemented in this
phase. This favors recoverability and can increase disk use; do not manually remove
the sync asset directory while uploads/recovery revisions need it. Deletion
revisions are inspectable but are not automatically replayed as destructive edits.

### Immediate Sync and Bootstrap-Space Correction

Enabled libraries explicitly request CKSyncEngine transfers on startup, sign-in,
foreground activation, silent push and network restoration. A committed local
write requests an upload without waiting for the automatic scheduler or a timer.
Manual operations carry a user-initiated CKOperationGroup. Requests are serialized
and coalesced; writes arriving during a transfer request another pass rather than
being discarded by an `already syncing` guard. A newly initialized zone is saved
before its first fetch. Existing engine state no longer queues a redundant zone
save at every launch. Automatic engine retry remains enabled for server throttling
and background work.

Queue notifications and acknowledgments read record names without decoding the
whole payload journal. Upload preparation decodes only the selected batch (up to
100 records), prioritizing Space/folder metadata before their dependent content.
Record names, payloads and durable dirty flags are unchanged.

iCloud identity checks run before engine creation, fetch selection, send operations
and prepared upload batches, not before every state/progress/import callback.
Concurrent identity checks share one in-flight request. Local owner, lease/binding
and enabled-state guards remain active; CKAccountChanged immediately invalidates
the engine and cancels pending work. Recoverable offline startup errors retain
connectivity monitoring so the same opted-in library can start when connectivity
returns. No sync opt-in or iCloud binding is changed automatically.

This requests sync immediately; it does not guarantee zero network/server/asset
transfer latency or immediate APNs delivery. Apple's
[CKSyncEngine scheduling documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
distinguishes immediate requests from indeterminate automatic scheduling.
Live two-device timing still requires measurement.

The repeated Personal Space came from two bootstrap paths: opening an empty account
created Personal before fetching remote Spaces, and sign-in adopted empty local
defaults created after an earlier account claimed the local library. Account
workspaces now open safely with no selected Space when empty. Repositories stay
scoped to an unavailable Space, never an unfiltered library. Incoming Spaces select
the saved or first available Space without inserting a replacement. A deliberate
document/template/folder creation can establish the initial Space.

Additive migration v23 adds local-only `bootstrapSpaces` provenance. Future fallback
Spaces, and migration-generated defaults on a verified empty installation, are
tracked. Editing a tracked Space or adding documents/folders/templates/Daily Note
settings promotes it to authored content. Automatic sign-in assignment leaves
untouched bootstrap defaults local but still assigns authored local content.
Explicit adoption remains available. Existing Spaces are not classified by name,
merged, deleted, renamed or reassigned by this migration; pre-existing duplicates
are retained because their provenance cannot safely be inferred. No CloudKit
record identity, authored wire payload or attachment path changes.

Regression checks cover repeated sign-out/sign-in, empty account imports without
Personal creation, first explicit creation, promotion of local defaults, explicit
empty Personal Spaces, coalesced requests, cancellation and retry. These are
temporary-database/scheduling tests, not live CKSyncEngine transport verification.

### 6. CloudKit Setup and Real-Device Checklist

1. Keep iCloud/CloudKit, Sign in with Apple, and Push Notifications enabled on the
   app identifier and provisioning profile, using the existing container. The app
   now declares the `remote-notification` background mode and registers for remote
   notifications through its native application delegate. This does not request
   permission to display notification alerts or change the task-reminder flow.
2. In the container's **development** private database, allow/verify the
   `PennedLibraryRecord` schema below. The first opted-in development upload can
   create it when the signed developer account has schema permissions. Do not
   clear/reset the container or existing profile schema.
3. Verify the following fields and deploy the development schema to production
   before distributing a production-signed build. No dashboard schema,
   provisioning, production record, or remote data was changed by this work.

| Field | CloudKit Type | Purpose |
| --- | --- | --- |
| `formatVersion` | Int64 | Wire version, currently 1 |
| `libraryID` | String | Must match the account library and private zone |
| `deleted` | Int64 | 0/1 tombstone marker |
| `mutationID` | String | Revision acknowledgment identity |
| `payload` | Asset | Typed row JSON with original GRDB keys |
| `filePaths` | List of String | Relative immutable filenames |
| `fileHashes` | List of String | Corresponding SHA-256 digests |
| `files` | List of Asset | Real file bytes, omitted for tombstones |

4. On device A, first verify the migrated local library without enabling sync.
   Sign in and verify that its Spaces, documents, templates and saved styles now
   belong to that account, with original IDs and content preserved, without a
   separate adoption step. Then separately enable iCloud sync in Account Settings
   > Library & Sync. Verify actual row records/assets in the custom private zone.
5. On device B, sign in to the **same Penned identity and same iCloud account** and
   enable sync for its account library. Any unowned local content on device B
   also joins the signed-in account; distinct existing Spaces keep their IDs and
   are not silently merged. Verify original IDs, nested pages, folders, collections
   and values, inline properties, templates/daily-note defaults, completed tasks,
   appearance images, saved styles and binary attachments. Existing EventKit
   identifiers can differ per device; event-note association matching must be
   checked with the actual calendars on both devices, not assumed from row tests.
6. Test airplane-mode edits, relaunch before upload, two-device edits to one page,
   edits during an upload, dependency batches interrupted by termination, Trash
   and permanent deletion, and recovery. Verify queued/inbox/recovery counts.
   Test independently-created same-day Daily Notes and the explicit resolution
   path. Recovery is whole-record restoration, not collaborative text merging.
7. Switch between Apple and email accounts, two email accounts, and local-only
   mode with pending editor text. Log out/delete an account and confirm its
   documents remain stored but are not exposed through the next account. Switch
   iCloud identities and confirm the old queue pauses instead of uploading there.
8. Verify silent-push/background delivery and production provisioning on physical
   devices. iOS determines background execution opportunities; immediate delivery
   is not guaranteed. Never enable sync by default on the basis of unit tests.

Future authored-schema migrations must update the journal trigger definitions and
wire-version compatibility together. Do not silently discard unknown fields or
reset GRDB/engine state to work around an upgrade incompatibility.

### Document-Phase Files

| File | Change |
| --- | --- |
| `Vellix/Persistence/LibraryOwnership.swift` | Library records, migration, transactional sign-in assignment and optional selective adoption |
| `Vellix/Persistence/LibraryAccess.swift` | Library predicates, database guards and revocable handles |
| `Vellix/Persistence/AppDatabase.swift` | v20-v23 migrations, shared-writer scopes, empty-install provenance and metadata transactions |
| `Vellix/Sync/LibrarySyncSchema.swift` | Typed row wire format, atomic journal triggers, inbox/state/assets/recovery schema |
| `Vellix/Sync/LibrarySyncStore.swift` | Opt-in/binding, lightweight prioritized pending names, bounded payload reads, SDK state, acknowledgments and recovery |
| `Vellix/Sync/LibrarySyncRecords.swift` | CKRecord/system-field mapping, real CKAssets and checksum validation |
| `Vellix/Sync/LibrarySyncImport.swift` | Transactional dependency imports, conflicts, cascades, tombstones and recovery |
| `Vellix/Sync/LibrarySyncEngine.swift` | Native CKSyncEngine delegate, immediate/coalesced transfers, bounded batches, boundary identity checks and offline retries |
| `Vellix/Sync/PennedSyncNotifications.swift` | Native remote-notification registration and wake-up forwarding |
| `Vellix/Accounts/LibraryWorkspace.swift` | Save pending edits before sign-in assignment, carry Space selection, serialize library switches and sync lifecycle |
| `Vellix/Accounts/AccountLibrarySheet.swift` | Adoption/sync confirmations, status and recovery UI using existing styling |
| `Vellix/Accounts/AccountSettingsView.swift` | Entry point for Library & Sync |
| `Vellix/Accounts/AccountIdentity.swift` | Provider-qualified library owner key; existing profile identity unchanged |
| `Vellix/VellixApp.swift` | Wait for account restoration before workspace selection; lifecycle/account/iCloud/notification integration |
| `Vellix/App/AppEnvironment.swift` | Pending-write drain, safe empty account workspaces, explicit first creation and remote Space selection without fallback insertion |
| `Vellix/Editor/TipTapEditorSession.swift` | Reload persisted synced JSON and newly downloaded attachment projections after a safe flush |
| `Vellix/Documents/DocumentRecords.swift` | Space library ownership field |
| `Vellix/Documents/DocumentRepositories.swift` | Scope document/Space/folder/template access and Space creation |
| `Vellix/Documents/DocumentStyleRepository.swift` | Style ownership, scoped access and retained sync assets |
| `Vellix/Spaces/SpaceOwnership.swift` | Library-aware defaults and bootstrap provenance/promotion triggers |
| `Vellix/Spaces/SpaceOperations.swift` | Read-only existing-Space fallback, scoped navigation and sync-aware attachment cleanup |
| `Vellix/Search/DocumentSearchService.swift` | Library-scoped search and folder/template projections |
| `Vellix/Tags/DocumentTagRepository.swift` | Library-scoped tag browsing |
| `Vellix/DailyNotes/DailyNoteRepository.swift` | Guard default-template/day reads by active library |
| `Vellix/Calendar/CalendarEventNoteRepository.swift` | Guard event-note lookup by library |
| `Vellix/Collections/CollectionRepository.swift` | Guard direct collection ownership |
| `Vellix/Attachments/AttachmentStore.swift` | Scoped attachment lookup and persistent sync staging location |
| `Vellix/Tasks/DocumentTaskRepository.swift` | Library-scoped task/history projections |
| `Vellix/Tasks/TaskNotificationsManager.swift` | Cancel/drain old-library reminders during account switching |
| `Vellix/Resources/LaunchInfo.plist` | Remote-notification background mode; existing Supabase substitutions retained |
| `Vellix.xcodeproj/project.pbxproj` | Correct app/test target membership for new tests |
| `Vellix/VellixTests/LibraryOwnershipTests.swift` | Migration, complete-library assignment, rollback, idempotence, default Space, styles and isolation checks |
| `Vellix/VellixTests/LibrarySyncTests.swift` | Independent-GRDB native-record/asset round trips, offline/recovery/conflict/deletion checks |
| `Vellix/VellixTests/LibraryWorkspaceTests.swift` | Sign-in assignment, legacy upgrade, pending/failed saves, identity changes, already-adopted selection and explicit local mode |
| `Vellix/VellixTests/SpaceEnvironmentTests.swift` | Pending editor writes, closed libraries and safe remote editor refresh |
| `Vellix/VellixTests/AccountTests.swift` | Library-provider separation without changing legacy Apple profile IDs |
| `Scripts/test-collections.mjs` | Real production sync/domain sources and new suites in the headless macOS harness |
| `Scripts/test-sheet-style.mjs` | Shared Library & Sync sheet coverage and structured xcconfig linkage checks independent of Xcode comments |
| `Docs/Accounts.md` | Actual implementation, setup, tests and remaining device-verification boundary |

### Verification Boundary

Initial document-phase checks: 194 native library/editor/sync/workspace tests and
62 existing account/SDK tests and 119 sheet/source-contract checks passed. The generic iOS Debug build passed with code
signing disabled. Project, entitlement and Info.plist parsing passed; the built app
contains `remote-notification` in UIBackgroundModes. Release and real-device tests
have not been run for this document phase.

After the immediate-sync/Personal-space/gallery correction: 220 native headless
tests, 62 account/SDK tests, 119 sheet contracts and 15 iPad contracts passed. The
unsigned generic iOS Debug build, project parsing and diff whitespace checks passed.
The new native tests cover bootstrap provenance, an existing empty Personal through
v22-v23 migration, repeated restoration, empty-account imports, bounded prioritized
queue reads, immediate request/coalescing/retry/cancellation and measured gallery
widths. The transport/physical-device limitations below still apply; no simulator
or physical-device sync timing was exercised.

Ownership migrations and row/asset synchronization are exercised using real GRDB,
native CKRecord/CKAsset objects, real temporary files, and independent temporary
SQLite databases. Auth tests use the existing injected provider/network boundaries.
These tests do **not** instantiate a live syncing CKContainer or prove server-side
change tags, CKSyncEngine scheduling/serialization against iCloud, APNs delivery,
device Keychain behavior, rendered UI, or real-device account/iCloud switching.
Generic-device unsigned build checks do not prove signing or provisioning. No iOS
simulator was launched or used.

Sign-in ownership is covered by a version-19 database fixture with existing
Spaces, document JSON, a template and a saved active Space, opened with an
already-restored Apple identity and no library-selection preference. Other tests
cover an earlier-created empty account library, complete assignment of archived
Spaces/folders/templates/styles, preserved defaults/selection, transaction
rollback, failed pending saves, identity changes during saves, idempotence,
cross-account isolation, optional local-only mode and queues for already-enabled
sync. These checks use temporary databases; they do not prove the actual sign-in
assignment or rendered behavior on a physical device. No live account session or
CloudKit transport was used to verify this change.

Apple references used for the native implementation:
[CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5),
[persistent state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate),
[CKAsset lifecycle](https://developer.apple.com/documentation/cloudkit/ckasset), and
[missing asset bytes in conflict-error records](https://developer.apple.com/documentation/cloudkit/ckasset/fileurl).
