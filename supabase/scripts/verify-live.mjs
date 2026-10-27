// Explicitly opt in: npm run test:live -- --project-ref <ref> --confirm-live
// Uses CLI-managed credentials in memory; creates and removes only its own fixtures.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { pathToFileURL } from "node:url";

const args = process.argv.slice(2), ref = args[args.indexOf("--project-ref") + 1];
assert.ok(args.includes("--confirm-live") && /^[a-z]{20}$/.test(ref ?? ""), "Supply --project-ref and --confirm-live");
const url = `https://${ref}.supabase.co`, base = url + "/functions/v1/penned-publishing";
const keys = JSON.parse(execFileSync("supabase", ["projects", "api-keys", "--project-ref", ref, "--reveal", "--output", "json"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
const anon = keys.find(key => key.name === "anon")?.api_key, secret = keys.find(key => key.name === "service_role")?.api_key;
assert.ok(anon && secret, "Project API credentials unavailable");
const publicKey = keys.find(key => key.type === "publishable")?.api_key ?? anon;
const options = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const admin = createClient(url, secret, options);
const readerPath = args.includes("--reader") ? args[args.indexOf("--reader") + 1] : null;
const reader = readerPath ? (await import(pathToFileURL(readerPath).href)).createPublishingReader(url) : null;
const run = randomUUID(), subject = "penned-live-" + run, users = [], publications = [], paths = new Set();
const hash = value => createHash("sha256").update(value).digest("hex");
const random = () => randomBytes(32).toString("hex");
const exchangeHash = hash(subject);
let checks = 0;
const pass = name => { checks++; console.log("PASS " + name); };
function checked(result) { if (result.error) throw new Error(result.error.code ?? result.error.name ?? "Supabase operation failed"); return result.data; }
async function call(path, { token, method = "GET", body, bytes, headers = {}, status = 200 } = {}) {
  const response = await fetch(base + "/" + path, { method, headers: { apikey: publicKey, ...(token ? { Authorization: "Bearer " + token } : {}),
    ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
    body: bytes ?? (body === undefined ? undefined : JSON.stringify(body)), signal: AbortSignal.timeout(45000) });
  assert.equal(response.status, status, `${method} ${path.split("/")[0]}: expected ${status}, received ${response.status}`);
  return response;
}
const json = async (path, options) => (await call(path, options)).json();
async function emailSession(index) {
  const email = `penned-publishing-${run}-${index}@example.com`;
  const user = checked(await admin.auth.admin.createUser({ email, email_confirm: true, password: random() })).user;
  users.push(user.id);
  const link = checked(await admin.auth.admin.generateLink({ type: "magiclink", email }));
  const client = createClient(url, publicKey, options);
  const data = checked(await client.auth.verifyOtp({ type: "magiclink", token_hash: link.properties.hashed_token }));
  assert.equal(data.user.id, user.id);
  assert.ok(data.user.email_confirmed_at);
  return { client, user, token: data.session.access_token };
}
const sample = () => ({ schemaVersion: 1, title: "Selected fixture", subtitle: null, icon: null, cover: null, appearance: {}, media: [],
  content: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Approved writing" }] }] } });
async function create(token, suffix) {
  const publication = await json("publications", { token, method: "POST", status: 201,
    body: { sourceLibraryID: "private-library-" + run, sourceDocumentID: "selected-" + suffix + run } });
  publications.push(publication.id);
  return publication;
}
async function commit(token, publication, document, settings = {}, action = "publish") {
  return json("publications/" + publication.id, { token, method: "PUT", body: { action, expectedVersion: publication.version, document, settings } });
}
async function mutate(token, publication, action, settings) {
  return json(`publications/${publication.id}/${action}`, { token, method: "POST", body: { expectedVersion: publication.version, ...(settings ? { settings } : {}) } });
}

try {
  const audit = JSON.parse(execFileSync("supabase", ["db", "query", "--linked", "--project-ref", ref, "--output", "json", `
    select jsonb_build_object(
      'tables',(select jsonb_agg(jsonb_build_object('rls',c.relrowsecurity,
        'anon',has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
        'authenticated',has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')))
        from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' and c.relname in ('penned_publications','penned_publication_media'))
        or (n.nspname='penned_private' and c.relname in ('publishing_owners','publishing_sessions','publishing_apple_exchanges'))),
      'functions',(select jsonb_agg(jsonb_build_object('anon',has_function_privilege('anon',p.oid,'EXECUTE'),
        'authenticated',has_function_privilege('authenticated',p.oid,'EXECUTE'),'service',has_function_privilege('service_role',p.oid,'EXECUTE')))
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'penned_pub%'),
      'bucket',(select jsonb_build_object('public',public,'limit',file_size_limit) from storage.buckets where id='penned-publications'),
      'restrictivePolicy',(select count(*) from pg_policies where schemaname='storage' and tablename='objects'
        and policyname='penned_publications_private' and permissive='RESTRICTIVE' and roles @> array['anon','authenticated']::name[])
    ) as configuration;`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })).rows[0].configuration;
  assert.equal(audit.tables.length, 5);
  assert.ok(audit.tables.every(table => table.rls && !table.anon && !table.authenticated));
  assert.equal(audit.functions.length, 5);
  assert.ok(audit.functions.every(fn => fn.service && !fn.anon && !fn.authenticated));
  assert.equal(audit.bucket.public, false); assert.equal(audit.bucket.limit, 16777216);
  assert.equal(audit.restrictivePolicy, 1);
  pass("deployed tables, all client grants, RLS, privileged RPCs and private Storage configuration");
  await call("publications", { method: "POST", body: {}, status: 401 });
  await call("publications", { token: "forged.token.signature", method: "POST", body: {}, status: 401 });
  await call("auth/apple", { method: "POST", body: { identityToken: "invalid", nonce: "a".repeat(64) }, status: 401 });
  await call("auth/apple", { method: "POST", body: { identityToken: "invalid", nonce: "wrong" }, status: 400 });
  pass("routing and unauthenticated/forged Apple and email credentials fail closed");

  const a = await emailSession(1), b = await emailSession(2);
  let p = await create(a.token, "email");
  assert.equal((await create(a.token, "email")).id, p.id);
  const refreshed = checked(await a.client.auth.refreshSession());
  a.token = refreshed.session.access_token;
  assert.equal((await json("publications/" + p.id, { token: a.token })).id, p.id);
  pass("real Supabase email OTP exchange, refresh, stable ownership and idempotent drafts");

  for (const [path, method, body] of [[`publications/${p.id}`, "GET"], [`publications/${p.id}`, "PUT", {}],
    [`publications/${p.id}/unpublish`, "POST", { expectedVersion: 0 }], [`publications/${p.id}/regenerate`, "POST", { expectedVersion: 0 }],
    [`publications/${p.id}/media/${randomUUID()}`, "DELETE", { expectedVersion: 0 }]]) {
    await call(path, { token: b.token, method, body, status: 404 });
  }
  for (const token of [anon, a.token]) {
    for (const path of ["penned_publications?select=*", "penned_publication_media?select=*"]) {
      const r = await fetch(url + "/rest/v1/" + path, { headers: { apikey: publicKey, Authorization: "Bearer " + token } });
      assert.ok([401, 403].includes(r.status));
    }
    const r = await fetch(url + "/rest/v1/rpc/penned_publishing_identity", { method: "POST", headers: { apikey: publicKey, Authorization: "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify({ p_provider: "apple", p_subject: subject }) });
    assert.ok([401, 403].includes(r.status));
  }
  pass("cross-account management, direct table access and privileged RPCs denied");

  const mediaID = randomUUID(), png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCxoAAAAASUVORK5CYII=", "base64");
  const mediaPath = `publications/${p.id}/media/${mediaID}`;
  const asset = await json(mediaPath, { token: a.token, method: "PUT", bytes: png, headers: { "Content-Type": "image/png", "X-File-Name": "fixture.png" }, status: 201 });
  const rows = checked(await admin.from("penned_publication_media").select("object_path").eq("publication_id", p.id));
  rows.forEach(row => paths.add(row.object_path));
  assert.equal(asset.sha256, hash(png));
  await call(`public/${p.token}/media/${mediaID}`, { status: 404 });
  await call(mediaPath, { token: b.token, method: "PUT", bytes: png, headers: { "Content-Type": "image/png" }, status: 404 });
  const document = sample();
  document.cover = { mediaID }; document.media = [asset];
  document.parentDocumentID = "PRIVATE PARENT"; document.workspace = "PRIVATE WORKSPACE";
  document.content.attrs = { privateHistory: "PRIVATE HISTORY" };
  document.content.content.push({ type: "pageReference", attrs: { documentID: "PRIVATE CHILD", title: "PRIVATE TITLE" }, content: [{ type: "text", text: "PRIVATE BODY" }] },
    { type: "collection", attrs: { entries: ["PRIVATE SIBLING"], collectionID: "PRIVATE COLLECTION" } });
  p = await commit(a.token, p, document, { authorName: "PRIVATE AUTHOR", showAuthor: false });
  let page = await call("public/" + p.token);
  assert.equal(page.headers.get("cache-control"), "no-store");
  const text = await page.text();
  assert.doesNotMatch(text, /PRIVATE|sourceLibraryID|sourceDocumentID|owner_id|object_path|private-library/);
  assert.match(text, /privateReference/); assert.match(text, /privateCollection/);
  assert.equal((await call("public/" + p.token, { method: "HEAD" })).headers.get("x-robots-tag"), "noindex, nofollow");
  if (reader) {
    const read = await reader.read(p.token);
    assert.equal(read.document.title, document.title);
    assert.equal(reader.mediaURL(p.token, mediaID), `${base}/public/${p.token}/media/${mediaID}`);
  }
  pass("published payload strips hierarchy, nested-page/collection content and private account/workspace metadata");

  const publicMedia = () => `public/${p.token}/media/${mediaID}`;
  let response = await call(publicMedia());
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  assert.equal(response.headers.get("content-security-policy"), "sandbox; default-src 'none'");
  response = await call(publicMedia(), { headers: { Range: "bytes=0-7" }, status: 206 });
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), png.subarray(0, 8));
  await call(publicMedia(), { headers: { Range: "bytes=999999-" }, status: 416 });
  for (const token of [anon, a.token]) {
    const client = createClient(url, publicKey, { ...options, global: { headers: { Authorization: "Bearer " + token } } });
    assert.ok((await client.storage.from("penned-publications").download(rows[0].object_path)).error);
    assert.ok((await client.storage.from("penned-publications").createSignedUrl(rows[0].object_path, 60)).error);
  }
  const direct = await fetch(url + "/storage/v1/object/public/penned-publications/" + rows[0].object_path);
  assert.notEqual(direct.status, 200);
  await call(mediaPath, { token: a.token, method: "DELETE", body: { expectedVersion: p.version }, status: 409 });
  pass("real private Storage: bytes, ranges, unreferenced/in-use protection, no direct or signed client access");

  await call("publications/" + p.id, { token: a.token, method: "PUT", body: { action: "update", expectedVersion: 0, document: sample() }, status: 409 });
  const missing = structuredClone(document); missing.media[0].sha256 = "0".repeat(64);
  await call("publications/" + p.id, { token: a.token, method: "PUT", body: { action: "update", expectedVersion: p.version, document: missing }, status: 400 });
  assert.equal((await json("publications/" + p.id, { token: a.token })).version, p.version);
  p = await commit(a.token, p, { ...document, title: "Updated fixture" }, {}, "update");
  const oldToken = p.token;
  p = await mutate(a.token, p, "regenerate");
  assert.notEqual(p.token, oldToken);
  await call("public/" + oldToken, { status: 404 });
  await call(`public/${oldToken}/media/${mediaID}`, { status: 404 });
  await call(publicMedia());
  p = await mutate(a.token, p, "settings", { showTitle: false, allowIndexing: true });
  page = await call("public/" + p.token);
  assert.equal((await page.json()).document.title, "");
  assert.equal(page.headers.get("x-robots-tag"), "index, follow");
  p = await mutate(a.token, p, "settings", { expiresAt: "2000-01-01T00:00:00Z" });
  await call("public/" + p.token, { status: 404 });
  await call(publicMedia(), { status: 404 });
  p = await mutate(a.token, p, "settings", { expiresAt: null });
  p = await mutate(a.token, p, "unpublish");
  await call("public/" + p.token, { status: 404 }); await call(publicMedia(), { status: 404 });
  if (reader) assert.equal(await reader.read(p.token), null);
  await call("publications/" + p.id, { token: a.token, method: "PUT", body: { action: "update", expectedVersion: p.version, document: sample() }, status: 409 });
  p = await commit(a.token, p, sample());
  await json(mediaPath, { token: a.token, method: "DELETE", body: { expectedVersion: p.version } });
  assert.ok((await admin.storage.from("penned-publications").download(rows[0].object_path)).error);
  pass("updates, atomic conflicts, media mismatch rollback, link rotation, settings, expiry, unpublish and explicit republish");

  // This seeds only a disposable session to exercise real session SQL/HTTP, NOT Apple identity verification.
  const access = "ppa_" + random(), refresh = "ppr_" + random();
  const seed = { p_action: "exchange", p_hash: exchangeHash, p_access: hash(access), p_refresh: hash(refresh), p_subject: subject,
    p_expiry: new Date(Date.now() + 60000).toISOString(), p_issued_at: new Date().toISOString() };
  checked(await admin.rpc("penned_publishing_session", seed));
  assert.ok((await admin.rpc("penned_publishing_session", seed)).error);
  let apple = await create(access, "apple");
  apple = await commit(access, apple, sample());
  const rotated = await json("auth/refresh", { method: "POST", body: { refreshToken: refresh } });
  assert.equal(rotated.subject, subject);
  await call("auth/refresh", { method: "POST", body: { refreshToken: refresh }, status: 401 });
  await call("publications/" + apple.id, { token: access, status: 401 });
  await call("publications/" + apple.id, { token: rotated.accessToken });
  await call("publications/" + p.id, { token: rotated.accessToken, status: 404 });
  await json("auth/revoke", { token: rotated.accessToken, method: "DELETE" });
  await call("auth/refresh", { method: "POST", body: { refreshToken: rotated.refreshToken }, status: 401 });
  const nextAccess = "ppa_" + random();
  checked(await admin.rpc("penned_publishing_session", { ...seed, p_hash: hash(exchangeHash), p_access: hash(nextAccess), p_refresh: random() }));
  await json("owner", { token: nextAccess, method: "DELETE" });
  await call("public/" + apple.token, { status: 404 });
  await call("publications/" + apple.id, { token: nextAccess, status: 401 });
  assert.ok((await admin.rpc("penned_publishing_session", { ...seed, p_hash: hash(hash(exchangeHash)), p_issued_at: "2000-01-01T00:00:00Z" })).error);
  pass("Apple publishing session rotation, replay denial, provider isolation, logout, owner revocation and pre-deletion token cutoff (seeded fixture)");

  const deleted = await fetch(url + "/functions/v1/penned-delete-account", { method: "POST", headers: { apikey: publicKey, Authorization: "Bearer " + a.token, "Content-Type": "application/json" }, body: "{}" });
  assert.equal(deleted.status, 200, "Existing email account-deletion function must be deployed");
  assert.equal((await deleted.json()).deletedUserID, a.user.id);
  await call("public/" + p.token, { status: 404 });
  await call("publications/" + p.id, { token: a.token, status: 401 });
  assert.equal(checked(await admin.from("penned_publications").select("id").eq("id", p.id)).length, 0);
  assert.ok(checked(await admin.auth.admin.getUserById(b.user.id)).user);
  pass("existing email deletion endpoint revokes publications and credentials without deleting the other account");
} finally {
  const remaining = publications.length ? checked(await admin.from("penned_publication_media").select("object_path").in("publication_id", publications)) : [];
  remaining.forEach(row => paths.add(row.object_path));
  if (paths.size) checked(await admin.storage.from("penned-publications").remove([...paths]));
  if (publications.length) checked(await admin.from("penned_publications").delete().in("id", publications));
  for (const id of users) {
    const result = await admin.auth.admin.deleteUser(id);
    if (result.error && result.error.status !== 404) throw new Error("Fixture account cleanup failed");
  }
  // Only generated literals enter this administrative cleanup query.
  execFileSync("supabase", ["db", "query", "--linked", "--project-ref", ref, "--output", "json",
    `delete from penned_private.publishing_owners where provider='apple' and subject='${subject}'; delete from penned_private.publishing_apple_exchanges where token_hash in ('${exchangeHash}','${hash(exchangeHash)}','${hash(hash(exchangeHash))}');`], { stdio: ["ignore", "pipe", "pipe"] });
  console.log("CLEANUP disposable accounts, publications, sessions and files removed");
}
console.log(`${checks} live verification groups passed. Real Continue with Apple and device Keychain authorization still require physical-device testing.`);
