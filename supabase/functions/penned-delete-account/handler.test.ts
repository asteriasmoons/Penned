import assert from "node:assert/strict";
import { after, test } from "node:test";
import { type AccountAuth, createDeleteAccountHandler } from "./handler.ts";

const userID = "9d78a049-eaba-4e1f-a9d0-a7f0a60a379b";
const otherID = "b6f5e110-933a-48bb-92d2-0ff65475976b";
// Deliberately not signed: only the injected Auth boundary can authenticate it.
const jwt = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1bnRydXN0ZWQifQ.c2lnbmF0dXJl";
const user = { id: userID, role: "authenticated", is_anonymous: false };
const realFetch = globalThis.fetch;
globalThis.fetch = () => { throw new Error("Network is forbidden in these tests"); };
after(() => { globalThis.fetch = realFetch; });

function setup(overrides: Partial<AccountAuth> = {}) {
  const calls: Array<[string, string?]> = [];
  const auth: AccountAuth = {
    getUser: async (token) => {
      calls.push(["getUser", token]);
      return { data: { user }, error: null };
    },
    deleteUser: async (id) => {
      calls.push(["deleteUser", id]);
      return { error: null };
    },
    ...overrides,
  };
  const handler = createDeleteAccountHandler(() => auth);
  return { calls, handler };
}

function request(init: RequestInit = {}, query = "") {
  const headers = new Headers(init.headers);
  if (!headers.has("authorization")) headers.set("authorization", `Bearer ${jwt}`);
  return new Request(`https://example.invalid/functions/v1/penned-delete-account${query}`, {
    method: "POST",
    ...init,
    headers,
  });
}

async function expectError(response: Response, status: number, code: string) {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { error: code });
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(response.headers.get("content-type") ?? "", /application\/json/);
}

for (const method of ["GET", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]) {
  test(`${method} cannot authenticate or delete`, async () => {
    const { calls, handler } = setup();
    const response = await handler(request({ method }));
    await expectError(response, 405, "method_not_allowed");
    assert.equal(response.headers.get("allow"), "POST");
    assert.deepEqual(calls, []);
  });
}

for (const authorization of ["", "Basic abc", "Bearer", "Bearer abc", "Bearer sb_publishable_fake", "Bearer sb_secret_fake", `Bearer ${jwt}, Bearer ${jwt}`, `Bearer ${"a".repeat(16385)}.b.c`]) {
  test(`rejects malformed/API-key authorization (${authorization.slice(0, 40)})`, async () => {
    const { calls, handler } = setup();
    const response = await handler(request({ headers: { authorization } }));
    await expectError(response, 401, "authentication_required");
    assert.equal(response.headers.get("www-authenticate"), "Bearer");
    assert.deepEqual(calls, []);
  });
}

test("missing Authorization and apikey alone are not authentication", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(new Request("https://example.invalid", {
    method: "POST", headers: { apikey: "sb_publishable_fake" },
  })), 401, "authentication_required");
  assert.deepEqual(calls, []);
});

for (const status of [400, 401, 403, 404, 422]) {
  test(`Auth rejects invalid/expired/wrong-project JWT (${status})`, async () => {
    let deleted = false;
    const { handler } = setup({
      getUser: async () => ({ data: { user }, error: { status } }),
      deleteUser: async () => { deleted = true; throw new Error("must not delete"); },
    });
    await expectError(await handler(request()), 401, "authentication_required");
    assert.equal(deleted, false);
  });
}

for (const status of [0, 429, 500, 503, undefined]) {
  test(`Auth infrastructure failure (${status}) is not success or invalid credentials`, async () => {
    const { calls, handler } = setup({
      getUser: async () => ({ data: { user: null }, error: { status } }),
    });
    await expectError(await handler(request()), 503, "authentication_unavailable");
    assert.deepEqual(calls, []);
  });
}

test("thrown Auth failure never reaches delete", async () => {
  const { calls, handler } = setup({ getUser: async () => { throw new Error("private detail"); } });
  await expectError(await handler(request()), 503, "authentication_unavailable");
  assert.deepEqual(calls, []);
});

test("no Auth user is not authenticated", async () => {
  const { calls, handler } = setup({ getUser: async () => ({ data: { user: null }, error: null }) });
  await expectError(await handler(request()), 401, "authentication_required");
  assert.deepEqual(calls, []);
});

for (const invalidUser of [{ ...user, role: "service_role" }, { ...user, role: "anon" }, { ...user, role: undefined }, { ...user, is_anonymous: true }]) {
  test(`non-user/anonymous credential cannot delete (${JSON.stringify(invalidUser)})`, async () => {
    const { calls, handler } = setup({ getUser: async () => ({ data: { user: invalidUser }, error: null }) });
    await expectError(await handler(request()), 403, "registered_user_required");
    assert.deepEqual(calls, []);
  });
}

test("invalid Auth user ID fails closed", async () => {
  const { calls, handler } = setup({ getUser: async () => ({ data: { user: { ...user, id: "not-a-uuid" } }, error: null }) });
  await expectError(await handler(request()), 502, "invalid_auth_response");
  assert.deepEqual(calls, []);
});

for (const body of [undefined, "", "  ", "{}", " { } "]) {
  test(`only the verified user is deleted (body ${JSON.stringify(body)})`, async () => {
    const { calls, handler } = setup();
    const response = await handler(request({ body, headers: { "content-type": "application/json", "x-user-id": otherID } }));
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { deletedUserID: userID });
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(calls, [["getUser", jwt], ["deleteUser", userID]]);
  });
}

for (const body of [`{"userID":"${otherID}"}`, `{"id":"${userID}"}`, `{"user_id":"${otherID}"}`, `{"deletedUserID":"${otherID}"}`, '{"shouldSoftDelete":true}', '{"confirm":true}', "[]", "null", "true", '"text"', "{", "{}{}", '{"__proto__":{}}']) {
  test(`rejects unexpected/malformed body ${body}`, async () => {
    const { calls, handler } = setup();
    await expectError(await handler(request({ body, headers: { "content-type": "application/json" } })), 400, "empty_object_required");
    assert.deepEqual(calls, [["getUser", jwt]]);
  });
}

test("query cannot select another user", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({}, `?userID=${otherID}`)), 400, "query_parameters_not_allowed");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("nonempty body requires JSON content type", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({ body: "{}" })), 415, "json_body_required");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("body is limited without trusting Content-Length", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({ body: " ".repeat(1025) })), 413, "body_too_large");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("declared oversized body is rejected", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({ headers: { "content-length": "1025" } })), 413, "body_too_large");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("malformed Content-Length is rejected", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({ headers: { "content-length": "invalid" } })), 400, "invalid_body");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("invalid UTF-8 cannot become a valid body", async () => {
  const { calls, handler } = setup();
  await expectError(await handler(request({ body: new Uint8Array([0xff]), headers: { "content-type": "application/json" } })), 400, "invalid_body");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("configuration failure is sanitized and does not authenticate", async () => {
  const handler = createDeleteAccountHandler(() => { throw new Error("server secret"); });
  await expectError(await handler(request()), 500, "server_configuration_error");
  await expectError(await handler(request({ headers: { authorization: "" } })), 401, "authentication_required");
});

test("admin error is never deletion success", async () => {
  const { handler } = setup({ deleteUser: async () => ({ error: { status: 500 } }) });
  await expectError(await handler(request()), 502, "deletion_failed");
});

test("admin exception/timeout is sanitized, with no automatic retry", async () => {
  let attempts = 0;
  const { handler } = setup({ deleteUser: async () => { attempts++; throw new Error("server secret"); } });
  await expectError(await handler(request()), 502, "deletion_failed");
  assert.equal(attempts, 1);
});

test("each request must pass live Auth verification, including a retry after deletion", async () => {
  let exists = true;
  let lookups = 0;
  let deletes = 0;
  const { handler } = setup({
    getUser: async () => {
      lookups++;
      return exists ? { data: { user }, error: null } : { data: { user: null }, error: { status: 401 } };
    },
    deleteUser: async () => {
      deletes++;
      exists = false;
      return { error: null };
    },
  });
  assert.equal((await handler(request())).status, 200);
  await expectError(await handler(request()), 401, "authentication_required");
  assert.equal(lookups, 2);
  assert.equal(deletes, 1);
});

test("success cannot precede the completed admin deletion", async () => {
  const started = Promise.withResolvers<void>();
  const deletion = Promise.withResolvers<{ error: null }>();
  const { handler } = setup({ deleteUser: () => { started.resolve(); return deletion.promise; } });
  let completed = false;
  const response = handler(request()).then((value) => { completed = true; return value; });
  await started.promise;
  assert.equal(completed, false);
  deletion.resolve({ error: null });
  assert.deepEqual(await (await response).json(), { deletedUserID: userID });
});

test("overlapping callers retain their own verified deletion targets", async () => {
  const otherJWT = "b3RoZXI.dXNlcg.c2lnbmF0dXJl";
  const firstLookup = Promise.withResolvers<void>();
  const releaseFirst = Promise.withResolvers<void>();
  const deleted: string[] = [];
  const { handler } = setup({
    getUser: async (token) => {
      if (token === jwt) { firstLookup.resolve(); await releaseFirst.promise; }
      return { data: { user: { ...user, id: token === jwt ? userID : otherID } }, error: null };
    },
    deleteUser: async (id) => { deleted.push(id); return { error: null }; },
  });
  const first = handler(request());
  await firstLookup.promise;
  const second = await handler(request({ headers: { authorization: `Bearer ${otherJWT}` } }));
  assert.deepEqual(await second.json(), { deletedUserID: otherID });
  releaseFirst.resolve();
  assert.deepEqual(await (await first).json(), { deletedUserID: userID });
  assert.deepEqual(deleted, [otherID, userID]);
});

test("a broken request body never reaches deletion", async () => {
  const { calls, handler } = setup();
  const body = new ReadableStream({ start(controller) { controller.error(new Error("interrupted body")); } });
  const incoming = request({ body, duplex: "half" } as RequestInit);
  await expectError(await handler(incoming), 400, "invalid_body");
  assert.deepEqual(calls, [["getUser", jwt]]);
});

test("streamed chunks cannot bypass the byte limit with a small Content-Length", async () => {
  const { calls, handler } = setup();
  let cancelled = false;
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(512).fill(32));
      controller.enqueue(new Uint8Array(513).fill(32));
    },
    cancel() { cancelled = true; },
  });
  const incoming = request({ body, duplex: "half", headers: { "content-length": "2" } } as RequestInit);
  await expectError(await handler(incoming), 413, "body_too_large");
  assert.equal(cancelled, true);
  assert.deepEqual(calls, [["getUser", jwt]]);
});
