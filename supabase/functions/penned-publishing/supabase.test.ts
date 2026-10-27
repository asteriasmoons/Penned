import assert from "node:assert/strict";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "npm:jose@6.1.3";
import { appleVerifier, createPublishingStore } from "./supabase.ts";
import { digest } from "./handler.ts";

Deno.test("Apple verification checks signature, audience, nonce, issuer, age and expiration without consulting email", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256"), nonce = "a".repeat(64);
  const key = await exportJWK(publicKey);
  key.kid = "apple-test";
  const verifier = appleVerifier(["im.lystaria.Vellix"], createLocalJWKSet({ keys: [key] }));
  const now = Math.floor(Date.now() / 1000);
  async function token(changes = {}) {
    return await new SignJWT({ sub: "original-apple-subject", email: "same-as-email-account@example.com", nonce: await digest(nonce), iss: "https://appleid.apple.com", aud: "im.lystaria.Vellix", iat: now, exp: now + 600, ...changes })
      .setProtectedHeader({ alg: "RS256", kid: "apple-test" }).sign(privateKey);
  }
  assert.equal((await verifier(await token(), nonce)).subject, "original-apple-subject");
  for (const changes of [{ aud: "other-app" }, { iss: "attacker" }, { exp: now - 1 }, { iat: now - 1000 }, { nonce: "wrong" }]) {
    await assert.rejects(verifier(await token(changes), nonce), /invalid_apple_credential/);
  }
  await assert.rejects(verifier(await token(), "b".repeat(64)), /invalid_apple_credential/);
  const foreign = await generateKeyPair("RS256");
  const forged = await new SignJWT({ sub: "original-apple-subject", nonce: await digest(nonce), iss: "https://appleid.apple.com", aud: "im.lystaria.Vellix", iat: now, exp: now + 600 }).setProtectedHeader({ alg: "RS256", kid: "apple-test" }).sign(foreign.privateKey);
  await assert.rejects(verifier(forged, nonce), /invalid_apple_credential/);
});

Deno.test("Supabase adapter authenticates the caller with Auth, keeps server credentials server-side and scopes reads", async () => {
  const userID = crypto.randomUUID(), ownerID = crypto.randomUUID(), publicationID = crypto.randomUUID();
  const environment: Record<string, string> = { SUPABASE_URL: "https://example.invalid", SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_fixture" }) };
  const requests: Request[] = [];
  const store = createPublishingStore(name => environment[name], async (input, init) => {
    const request = new Request(input, init); requests.push(request);
    assert.equal(request.headers.get("apikey"), "sb_secret_fixture");
    if (request.url.endsWith("/auth/v1/user")) {
      assert.equal(request.headers.get("authorization"), "Bearer caller.jwt.signature");
      return Response.json({ id: userID, role: "authenticated", email_confirmed_at: new Date().toISOString(), identities: [{ provider: "email" }] });
    }
    assert.equal(request.headers.get("authorization"), "Bearer sb_secret_fixture");
    const url = new URL(request.url);
    assert.equal(url.searchParams.get("id"), "eq." + publicationID);
    assert.equal(url.searchParams.get("owner_id"), "eq." + ownerID);
    return Response.json(null);
  });
  assert.deepEqual(await store.emailIdentity("caller.jwt.signature"), { id: userID });
  assert.equal(await store.publication(publicationID, ownerID), null);
  assert.equal(requests.length, 2);
});

Deno.test("unverified email users, anonymous users and Apple-only Supabase identities cannot become email publishing owners", async () => {
  const user = { id: crypto.randomUUID(), role: "authenticated", email_confirmed_at: new Date().toISOString(), identities: [{ provider: "email" }] };
  for (const changes of [{ email_confirmed_at: null }, { is_anonymous: true }, { identities: [{ provider: "apple" }] }]) {
    const store = createPublishingStore(name => ({ SUPABASE_URL: "https://example.invalid", SUPABASE_SERVICE_ROLE_KEY: "fixture-key" }[name]), async () => Response.json({ ...user, ...changes }));
    await assert.rejects(store.emailIdentity("caller.jwt.signature"), /verified_email_required/);
  }
});

Deno.test("linked pages remain owner/library scoped, omit expired targets and bound large collection query sizes", async () => {
  const documents = Array.from({ length: 1000 }, (_, i) => `document-${i}-` + "x".repeat(180));
  let calls = 0; const requested = new Set<string>();
  const store = createPublishingStore(name => ({ SUPABASE_URL: "https://example.invalid", SUPABASE_SERVICE_ROLE_KEY: "fixture-key" }[name]), async (input, init) => {
    const request = new Request(input, init), url = new URL(request.url); calls++;
    assert.ok(request.url.length < 8000);
    assert.equal(url.searchParams.get("owner_id"), "eq.owner");
    assert.equal(url.searchParams.get("source_library_id"), "eq.library");
    assert.equal(url.searchParams.get("active"), "eq.true");
    const ids = url.searchParams.get("source_document_id")!.slice(4, -1).split(",");
    ids.forEach(id => requested.add(id));
    return Response.json([{ source_document_id: ids[0], token: "a".repeat(64), custom_path: "a1b2c3d4", settings: {} },
      { source_document_id: "expired", token: "b".repeat(64), settings: { expiresAt: "2000-01-01T00:00:00Z" } }]);
  });
  const links = await store.linkedPublications!("owner", "library", documents);
  assert.ok(calls > 1); assert.deepEqual([...requested].sort(), documents.sort());
  assert.equal(links.size, calls); assert.equal(links.has("expired"), false);
  assert.ok([...links.values()].every(path=>path==="a1b2c3d4"));
});
