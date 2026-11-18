# Penned application startup performance

## Report and evidence

Penned showed its existing library loading screen for approximately two minutes
when launched from Xcode on a physical iPhone. The target is at most 20 seconds,
preferably substantially less. This investigation is based on source inspection:
there is no phase-by-phase trace of the reported launch, and no build, test, or
device timing was run for these changes. The source establishes which operations
were on the critical path, not how many seconds each took on that phone.

## What the original launch waited for

1. The application delegate registered for remote notifications. Constructing
   `AppState` synchronously opened the separate SwiftData account store and
   fetched saved accounts. The root tasks waited in `checking` until the active
   session was restored. Apple sign-in awaited Apple's credential state; email
   sign-in restored the Supabase session and verified the account remotely.
   Initial scene activation could cancel and restart the first validation.
2. `LibraryWorkspace` opened the GRDB pool, configured its writer, checked
   bootstrap provenance, and ran pending migrations synchronously on the main
   actor. It resolved account ownership and the preferred Space before constructing
   the environment. Existing local Spaces and account libraries could go through
   the writer even when there was nothing to change.
3. A full library refresh ran before the workspace could replace the loader.
   It used summaries for several sections, but fetched recent and favorite
   document bodies for speculative preview preparation, queried templates twice,
   walked template bodies for component eligibility, and fetched every document ID
   to validate a usually empty editor cache. It prepared a recent editor model
   when the cache was empty. The iPhone shell mounts prepared models even when
   hidden, so the first Home render could spawn an interactive WKWebView and
   prepare an editor document nobody had opened.
4. Startup reminder reconciliation ran immediately during workspace opening.
   Its repository fetched `SELECT d.*` for every document in the library, then
   discarded most of those documents because they had no tracked tasks. The
   asynchronous reminder pass could repeat those full-library reads. Even after
   the newer gallery switched to summary paging, reminders still loaded all of
   those bodies. Also, Home issued a synchronous document-count query per folder
   row, and visible preview cells performed cached PNG reads/decoding in their
   SwiftUI bodies. The descriptor-backed cache-key path still re-read rich text
   when resolving collection references and checking collection ownership.
5. CloudKit profile refresh, library sync, descriptor backfill, Safari Clipper,
   and publishing had independent work that could coincide with the transition.
   A CloudKit document download was **not** required for Home. However, status
   counts ran synchronously during workspace activation, and automatic sync
   enablement could serialize the library into its journal on the main actor
   immediately after activation. Clipper separately queried its destination
   catalogue and scanned for imports during connection. Calendar data refresh
   was already guarded by visibility; its EventKit store was still eager.

There was no two-minute minimum display duration to remove. The existing loading
view is shown until the matching workspace is ready, or the existing recovery
screen is shown if opening fails. The recent descriptor migration, v33, already
creates local schema/triggers without parsing every document during migration;
its backfill was already separate. A device upgrading from much older versions
can still have required migrations that rewrite or index existing content.

## What changed

| Files | Startup change |
| --- | --- |
| [VellixApp.swift](../Vellix/VellixApp.swift), [AppState.swift](../Vellix/Data/AppState.swift), [AccountPersistence.swift](../Vellix/Accounts/AccountPersistence.swift) | Start account restore and document database preparation together. Open the account container on a worker; keep its main-context objects on the main actor. Share a validation already in flight and skip duplicate initial foreground work. Carry pending links to the mounted workspace. |
| [AppDatabase.swift](../Vellix/Persistence/AppDatabase.swift), [LibraryWorkspace.swift](../Vellix/Accounts/LibraryWorkspace.swift), [LibraryOwnership.swift](../Vellix/Persistence/LibraryOwnership.swift), [SpaceOperations.swift](../Vellix/Spaces/SpaceOperations.swift) | Open the single shared pool and run the same required migrations off-main while validating the session. Scope the library only after validation. Use a read fast path for an established account library and existing Space; creation and adoption still use their transactional paths. Recheck the request, active owner, and lease before publishing a prepared workspace. |
| [AppEnvironment.swift](../Vellix/App/AppEnvironment.swift), [DocumentRepositories.swift](../Vellix/Documents/DocumentRepositories.swift), [DocumentRecords.swift](../Vellix/Documents/DocumentRecords.swift), [HomeView.swift](../Vellix/Documents/HomeView.swift) | Load the initial selected-Space overview off-main with private, scoped repositories, then publish the populated state together. Use recent summaries, group Home's folder counts in one query, reuse the Space and template rows, and use current preview descriptors for template component checks with a JSON fallback when needed. On later refreshes, look up only selected, pending, and cached editor IDs instead of enumerating every document ID. Remove speculative editor/preview-content preparation, avoid refreshing an empty search, and construct the template gallery client only when used. All Docs and folder keyset pagination, search indexing, and the full library remain available. |
| [DocumentPreviewCache.swift](../Vellix/Documents/DocumentPreviewCache.swift), [DocumentPreviewPresentation.swift](../Vellix/Documents/DocumentPreviewPresentation.swift), [DocumentPreviewContent.swift](../Vellix/Documents/DocumentPreviewContent.swift), [CollectionRepository.swift](../Vellix/Collections/CollectionRepository.swift), [LibraryDocumentPreview.swift](../Vellix/Documents/LibraryDocumentPreview.swift) | Prime nearby Home PNGs off-main before mounting their cards. Preserve immediate disk fallback on a memory miss. Use descriptor collection IDs and scoped lightweight ownership queries; avoid repeated key lookups in a single card body. |
| [DocumentPreviewDescriptor.swift](../Vellix/Documents/DocumentPreviewDescriptor.swift), [AppEnvironment.swift](../Vellix/App/AppEnvironment.swift) | Start the existing utility-priority descriptor backfill from the mounted workspace, cancel it when its library closes, and add monotonic startup phase markers. No descriptor schema or preview key version change. |
| [DocumentTaskRepository.swift](../Vellix/Tasks/DocumentTaskRepository.swift), [TaskNotificationsManager.swift](../Vellix/Tasks/TaskNotificationsManager.swift), [AppleCalendarService.swift](../Vellix/Calendar/AppleCalendarService.swift) | Begin reminder reconciliation after mounting. Follow tracked-task sources and their ancestors using lightweight rows. Read editor JSON once per eligible task source in passes that need text; the eligibility-only pass does not read it. Keep serialized reminder updates and synchronous invalidation of obsolete reminders on actual edits. Construct the EventKit store only when calendar operations need it. |
| [LibraryWorkspace.swift](../Vellix/Accounts/LibraryWorkspace.swift), [LibrarySyncStore.swift](../Vellix/Sync/LibrarySyncStore.swift), [WebClipperCoordinator.swift](../Vellix/Clipper/WebClipperCoordinator.swift) | Load initial sync status in one off-main snapshot and start automatic sync after mounting. Seed the journal in its original atomic transaction on a worker, streaming rows and canceling/draining that work before workspace or sync-control changes. Move Clipper catalogue reads off-main and attempt the initial import drain after publishing the validated connection. Existing owner, cloud binding, active-editor protection, import, and conflict rules remain in force. |

## Why cached previews still appear on the first frame

- After fetching the overview, read the existing preview directory off-main and
  decode PNGs for up to the first four recent cards and two starred thumbnails
  that Home is configured to show, with an approximate 20 MiB decode budget.
  This opens existing files only; it does not run WebKit, render documents, or
  regenerate the cache before launch. The environment receives the images under
  both their existing exact cache keys and the existing document-ID fallback
  before the UI can mount. The cache directory and key format are unchanged.
- A card still prefers its exact cached image. If the key changed or a descriptor
  is missing, the existing persisted-PNG fallback is still available. The
  synchronous first-frame disk path remains for additional visible cards and
  any valid file outside the priming budget, so a persisted preview is not
  replaced by a gray frame while a view task loads it.
- If no usable PNG has ever been saved, the existing full-record/native fallback
  and on-demand snapshot generator still run. Nothing replaces those previews
  with a simplified renderer. Preview generation creates its own
  `TipTapEditorWebViewStore` in `DocumentPreviewCache.captureRenderer()`; it does
  not borrow the interactive editor's cache. Removing speculative interactive
  warmup does not remove that renderer. Opening a document still prepares its
  own model and waits for its presentation readiness; an already-opened model
  can still be reused.
- No changes were made to PNG writing, blank-image validation, persistence,
  pruning, or the filename comparison that keeps the newly written PNG from
  being deleted. No bulk regeneration or cache reset is required.

## Optimistic account sign-in (2026-11-16): remote validation removed from the critical path

A launch that still showed the loading screen for ~30 seconds pointed at the one
remaining **remote** dependency on the critical path. `AppState.bootstrap` waited
for `AuthService.fetchMeWithAutoRefresh`, whose `account-validation` phase performs
a network round-trip — for an email account, `SupabaseEmailAuth.restore` refreshes
the access token (`auth.session`) and fetches the user (`auth.user(jwt:)`); for an
Apple account, it queries `ASAuthorizationAppleIDProvider.credentialState`. The
workspace is scoped and mounted only after validation resolves, so a slow, paused,
or unreachable backend held the loader for the full network timeout. The local
`AuthUser` was already in hand from SwiftData before that call; only the remote
check was slow.

The validation was moved off the critical path:

- `AuthService.restoreLocalUser(modelContext:)` returns the locally-stored active
  account with no network access. `AuthService.validateActiveSession(_:)` performs
  the remote check and is safe to run in the background. `fetchMeWithAutoRefresh`
  is unchanged in behavior (it now composes the two) so existing callers and tests
  are unaffected.
- `AppState.bootstrap` now signs in optimistically from `restoreLocalUser` and
  mounts the library immediately, then runs `startSessionValidation` in a
  background `.utility` task. A new `account-validation.local` phase marks the
  (local) sign-in; `account-validation.finished` now marks when the background
  verification completes.
- The background task signs the account out **only** on a genuine revocation or
  expiry: `EmailAuthError.sessionExpired` (email) or an `AuthService.AuthServiceError`
  (Apple `credentialRevoked` / `credentialNotFound` / `unsupportedCredentialState`).
  `SupabaseEmailAuth.translate` maps every transient failure — `URLError`, HTTP 5xx,
  a paused or unreachable project — to `EmailAuthError.network`, never
  `sessionExpired`, so a slow or offline backend leaves the optimistic session in
  place and never forces a sign-out at launch. A stale background validation is
  guarded by the active account identity and is cancelled on any new sign-in.

No build, test, or device timing was run for this change. Confirmation is by
observation: if the loading screen now clears promptly, the ~30 seconds was the
remote validation; if it persists, compare the new `account-validation.local`
marker against the workspace-open and `library-overview.*` phases to locate the
remaining cost. Library scoping, ownership checks, and the `signedOut` /
recovery paths are unchanged; only the *timing* of remote verification moved.

## Revised startup and what remains unmeasured

The loading screen retains its design. Required credential validation and
store preparation overlap. Penned then opens the authorized Space, loads the
initial overview, primes the bounded Home images, and mounts the real workspace.
Descriptor maintenance, reminder scheduling, sync startup and catalogue work
are no longer prerequisites for displaying it. Publishing is still mounted
with the workspace and retains its existing local queue setup and network worker.
The major expected savings are fewer bodies read, fewer main-actor stalls, and
no hidden interactive editor competing with the initial library.

Filter the Xcode console for `[Penned Startup]`. Compare `account-store.*`,
`account-validation.*`, `document-store.*`, `library-overview.*`, and
`home-previews.*` by monotonic `uptimeMS`; `elapsedMS` marks each phase's
duration. `workspace-mounted` is relative to `launch-task.start`. This is a
SwiftUI lifecycle marker, not proof of the first drawn frame or a responsive
tap, and it excludes process time before the first scene task.

The shared Xcode scheme uses Debug/LLDB, with queue debugging disabled and
`-PennedKeyboardTrace` disabled. The detailed sync trace is opt-in too. There
is no source evidence that debugger attachment explains the reported two
minutes. Local scheme overrides, debugger overhead, and current physical-device
timings were not observed. Historical WebClipper PNG stalls were a separate
measurement; its image conversion is already on a worker in this source.

Required credential checks, pending transactional migrations, and first-time
local content adoption can still take time. Very large uncached documents and
previews can still require live rendering on first use. Background batches and
first-time sync seeding can still contend for SQLite's single writer. Moving
that work off the main actor does not eliminate the storage work itself. The
20-second target, actual tap responsiveness, first-frame cache behavior on a
physical device, and cold first-document open time remain to be measured.
