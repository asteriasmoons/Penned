import assert from "node:assert/strict";
import { createDeleteAccountHandler } from "./handler.ts";
import { createSupabaseAuth } from "./supabase.ts";

const id = "9d78a049-eaba-4e1f-a9d0-a7f0a60a379b";
const jwt = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1bnRydXN0ZWQifQ.c2lnbmF0dXJl";
// Nonfunctional fixtures, never real credentials.
const serverKey = "sb_secret_test_only_not_a_credential";
const legacyKey = "legacy_server_key_test_only";
const environment = {
  SUPABASE_URL: "https://example.invalid",
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: serverKey }),
  SUPABASE_SERVICE_ROLE_KEY: legacyKey,
};
const user = { id, role: "authenticated", is_anonymous: false };

function getEnv(values: Record<string, string | undefined> = environment) {
  return (name: string) => values[name];
}

function incoming() {
  return new Request("https://example.invalid/functions/v1/penned-delete-account", {
    method: "POST",
    headers: { authorization: `Bearer ${jwt}` },
  });
}

Deno.test("real SDK verifies user JWT then hard-deletes only that ID with server credentials", async () => {
  const calls: Request[] = [];
  const fetchMock: typeof fetch = async (input, init) => {
    const request = new Request(input, init);
    calls.push(request);
    assert.equal(request.headers.get("apikey"), serverKey);
    assert.equal(request.redirect, "error");
    assert.ok(request.signal);
    if (calls.length === 1) {
      assert.equal(request.method, "GET");
      assert.equal(request.url, "https://example.invalid/auth/v1/user");
      assert.equal(request.headers.get("authorization"), `Bearer ${jwt}`);
      return Response.json(user);
    }
    assert.equal(calls.length, 2);
    assert.equal(request.method, "DELETE");
    assert.equal(request.url, `https://example.invalid/auth/v1/admin/users/${id}`);
    assert.equal(request.headers.get("authorization"), `Bearer ${serverKey}`);
    assert.deepEqual(await request.json(), { should_soft_delete: false });
    // Supabase Auth returns {} on successful deletion, not the deleted user.
    return Response.json({});
  };
  const handler = createDeleteAccountHandler(() => createSupabaseAuth(getEnv(), fetchMock));
  const response = await handler(incoming());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deletedUserID: id });
  assert.equal(calls.length, 2);
});

Deno.test("legacy server key fallback is used only when modern dictionary is absent", async () => {
  const fetchMock: typeof fetch = (input, init) => {
    const request = new Request(input, init);
    assert.equal(request.headers.get("apikey"), legacyKey);
    assert.equal(request.headers.get("authorization"), `Bearer ${jwt}`);
    return Promise.resolve(Response.json(user));
  };
  const auth = createSupabaseAuth(getEnv({ ...environment, SUPABASE_SECRET_KEYS: undefined }), fetchMock);
  assert.equal((await auth.getUser(jwt)).error, null);
});

for (const secretKeys of ["", "not-json", "null", "{}", '{"default":null}', '{"default":123}', '{"default":" "}']) {
  Deno.test(`invalid modern key configuration fails closed (${secretKeys})`, () => {
    assert.throws(() => createSupabaseAuth(getEnv({ ...environment, SUPABASE_SECRET_KEYS: secretKeys })));
  });
}

for (const values of [{}, { SUPABASE_URL: "https://example.invalid" }, { SUPABASE_SECRET_KEYS: environment.SUPABASE_SECRET_KEYS }]) {
  Deno.test(`missing configuration fails closed (${JSON.stringify(Object.keys(values))})`, () => {
    assert.throws(() => createSupabaseAuth(getEnv(values)));
  });
}

Deno.test("real SDK maps Auth rejection to 401 without an admin call", async () => {
  let calls = 0;
  const fetchMock: typeof fetch = () => {
    calls++;
    return Promise.resolve(Response.json({ msg: "invalid JWT", code: "bad_jwt" }, { status: 401 }));
  };
  const handler = createDeleteAccountHandler(() => createSupabaseAuth(getEnv(), fetchMock));
  const response = await handler(incoming());
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: "authentication_required" });
  assert.equal(calls, 1);
});

Deno.test("real SDK maps admin failure to sanitized 502 without retrying", async () => {
  let calls = 0;
  const fetchMock: typeof fetch = () => {
    calls++;
    return Promise.resolve(calls === 1 ? Response.json(user) : Response.json({ msg: "private database error" }, { status: 500 }));
  };
  const handler = createDeleteAccountHandler(() => createSupabaseAuth(getEnv(), fetchMock));
  const response = await handler(incoming());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "deletion_failed" });
  assert.equal(calls, 2);
});
