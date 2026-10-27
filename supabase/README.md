# Penned Supabase Auth Deletion

Publish to Web phases 1 and 2 now live alongside this existing function. Their
privacy contract, migration, endpoints, native/website integration, deployment
requirements and checks are documented in [Docs/Publishing.md](../Docs/Publishing.md).
The account-deletion endpoint below remains in place.

Server-only support for deleting the requesting Supabase Auth account, intended
for the email-auth integration. Read alongside `Docs/Accounts.md` for the client
OTP/session setup and CloudKit cleanup sequence. This folder contains the server
boundary only and does not alter native Sign in with Apple deletion.

## Request Contract

`POST https://<project-ref>.supabase.co/functions/v1/penned-delete-account`

- Send `Authorization: Bearer <current Supabase user access-token JWT>`. Send the
  project's public/publishable key on `apikey` when invoking through the SDK or
  gateway; that key is not user authentication. Never send an admin secret.
- Send no body, or `{}` with `Content-Type: application/json`. Maximum body size
  is 1,024 bytes, including whitespace. Query parameters and all body fields,
  including user IDs, are rejected. Headers cannot select a deletion target.
- Every POST with a well-formed bearer JWT calls `auth.getUser(jwt)` against this
  project's Auth server. Token decoding, local sessions, API keys, caller IDs and
  user metadata are not used as proof of identity. Rejected, expired, deleted-user
  and wrong-project tokens cannot authorize deletion. Anonymous users and users
  without the `authenticated` role are rejected.
- After verification and body validation, the server calls
  `auth.admin.deleteUser(verifiedUser.id, false)` once (hard deletion). Only a
  successful admin operation produces HTTP 200 with exactly
  `{"deletedUserID":"<verified user UUID>"}`. All responses use `Cache-Control:
  no-store`. The handler does not log credentials or return upstream error details.
  Auth deletion returns an empty object, so success does not require an ID in the
  admin response; the returned UUID comes only from the verified Auth user. See
  [Supabase Auth's deletion implementation](https://github.com/supabase/auth/blob/master/internal/api/admin.go).

Supabase documents that [getUser contacts Auth to establish the user identity](https://supabase.com/docs/reference/javascript/auth-getuser)
and that [admin deletion is server-only](https://supabase.com/docs/reference/javascript/auth-admin-deleteuser).

Errors are JSON objects with an `error` code, never `deletedUserID`:

| Status | Meaning |
| --- | --- |
| 400 | Query parameters, malformed body, or anything except an empty object |
| 401 | Missing/malformed bearer JWT or rejected authentication/no current user |
| 403 | Anonymous user or non-`authenticated` role |
| 405 | Any method except POST, including OPTIONS; `Allow: POST` |
| 413 | Body exceeds 1,024 bytes |
| 415 | Nonempty body is not `application/json` |
| 500 | Missing/invalid server configuration |
| 502 | Admin deletion failed or Auth returned an invalid user ID |
| 503 | Auth verification unavailable, including network errors/rate limits |

No CORS preflight exception or wildcard CORS policy is added. This is for the
native app, not a cross-origin browser client. Unsupported methods do no Auth or
admin work. Every accepted deletion is explicitly authenticated in the handler.

## Server Configuration

`index.ts` passes only server environment variables to `supabase.ts`:

- `SUPABASE_URL`: the target project's URL.
- `SUPABASE_SECRET_KEYS`: the platform-provided JSON dictionary; the `default`
  secret is preferred when the dictionary exists.
- `SUPABASE_SERVICE_ROLE_KEY`: legacy fallback only when that dictionary is absent.

A malformed dictionary or missing `default` fails closed rather than silently
falling back. These variables must belong to the same project. Supabase documents
the [hosted/local environment variables and secret handling](https://supabase.com/docs/guides/functions/secrets).
No key value belongs in this repository, app bundle, plist, client environment,
request, test fixture or README. Do not overwrite the built-in variables with
client-provided values. The Supabase SDK is pinned to `2.118.0` in `supabase.ts`.

`config.toml` deliberately sets `verify_jwt = false` for this function only so
the handler is the authentication boundary, independent of gateway/API-key or
JWT-signing-key compatibility. This does **not** make deletion public: a real
user JWT must still pass `getUser(jwt)`. Current Supabase documentation says the
gateway supports asymmetric JWTs too; disabling it is not inherently required
by asymmetric signing. It also warns that passing the gateway with an API key
does not authenticate a user. See [authorization headers and the platform check](https://supabase.com/docs/guides/functions/auth-headers).

## Deployment (Operator Action Only)

Nothing here has been deployed and no real credentials are needed for the tests.
Use an existing, reviewed Supabase project. From the repository root, with the
[Supabase CLI installed and authenticated](https://supabase.com/docs/guides/functions/deploy):

```sh
supabase functions deploy penned-delete-account --project-ref <project-ref>
```

The CLI reads the per-function configuration in `supabase/config.toml`. Confirm
that the deployed function has JWT gateway verification disabled and the expected
server variables available. Do not run `supabase db push`, add migrations, or
deploy other functions for this task. No project reference or credentials are
committed. Test against disposable test accounts in a staging project before
production use, including expired/foreign tokens and forced deletion failures.

Before production deployment, audit any existing database triggers and foreign
keys referencing `auth.users`: the admin Auth operation can activate pre-existing
cascades/triggers or fail on constraints. This function adds none and makes no
direct application-table or Storage calls. Do not deploy into a project where
existing cascades violate the required document/profile retention policy.

## Limits And Recovery

- Scope is the requesting Supabase Auth user only. No CloudKit operations,
  document/profile cleanup, GRDB/SwiftData changes, database migrations, storage
  removal, account adoption, ownership transfer or cross-user/admin deletion API
  is introduced. Existing database effects of Auth deletion still require the
  operator audit described above.
- Supabase can refuse Auth deletion when the user owns Storage objects or when
  database constraints/triggers fail. This function reports failure and does not
  delete/reassign objects or work around retention rules. See [Supabase user management](https://supabase.com/docs/guides/auth/managing-user-data#deleting-users).
- Existing access JWTs can remain cryptographically valid until expiry even
  after Auth deletion; refresh-token/session removal is not universal immediate
  revocation at every downstream verifier. The live `getUser` lookup guards this
  endpoint, not every other service. See [removing account access](https://supabase.com/docs/guides/auth/managing-user-data#removing-account-access).
- Possession of a valid registered-user access token authorizes deletion. No
  password re-entry, recent-login/MFA requirement, UI confirmation, distributed
  rate limiter or external provider token revocation is added. Client confirmation
  and product-specific step-up policies require separate integration work.
- Each upstream HTTP request has a 10-second timeout and rejects redirects. The
  handler does not retry deletion automatically or create an idempotency ledger.
  Concurrent requests can race: one may succeed while another fails.
- **Lost-response caveat:** deletion can commit before a timeout, connection loss
  or lost HTTP 200. A retry may then fail `getUser` with 401 because the user is
  already gone. A 401/502/503 or timeout does not prove deletion did not happen,
  and must not be converted into success or a fabricated `deletedUserID`. Without
  a separate durable receipt/reconciliation design, the client cannot distinguish
  a lost success from invalid credentials using this endpoint alone. An operator
  can reconcile the outcome through trusted server-side Auth administration.

## Offline Tests

Node.js 22.18+ with built-in TypeScript stripping (or a newer supported Node.js):

```sh
node --test --test-timeout=10000 supabase/functions/penned-delete-account/handler.test.ts
```

The tests inject the Auth boundary and prohibit `fetch`; no SDK download, server,
credentials, Supabase instance, app build or simulator is needed. They cover
methods, bearer/API-key rejection, Auth errors, anonymous/non-user rejection,
request/body limits, cross-user attempts, admin failures, exact success output,
per-request verification and retries after deletion. They do not prove live
project configuration, Supabase Auth behavior, database cascades or deployment.

With Deno 2 installed, also test the actual SDK adapter with mocked HTTP. This
covers empty successful deletion responses, server/user header separation, hard
deletion, key precedence, missing/malformed configuration and upstream failures:

```sh
deno test --no-lock --deny-net --deny-env supabase/functions/penned-delete-account/supabase.test.ts
```

The first Deno run resolves the pinned public SDK into its cache; test execution
is denied network and environment access and uses no real credentials. The actual
Edge entry point and both test files can also be type-checked without running the
function or granting access to credentials:

```sh
deno check --no-lock supabase/functions/penned-delete-account/index.ts supabase/functions/penned-delete-account/handler.test.ts supabase/functions/penned-delete-account/supabase.test.ts
```

That check resolves the pinned public SDK dependency; it is not an offline test.
