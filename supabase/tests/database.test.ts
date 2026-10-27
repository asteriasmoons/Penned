import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { createPublishingHandler, digest } from "../functions/penned-publishing/handler.ts";
import { PublishingError } from "../functions/penned-publishing/contract.ts";
import type { Publication, Media, PublishingStore } from "../functions/penned-publishing/handler.ts";
import { accessPatch, authorizeReader, canRead, readerDigest } from "../functions/penned-publishing/access.ts";

const sample = () => ({ schemaVersion: 1, title: "Selected", subtitle: null, icon: null, cover: null, appearance: {},
  content: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Approved writing" }] }] }, media: [] });

async function database() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create schema storage; create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
    create table storage.objects(id uuid,bucket_id text); alter table storage.objects enable row level security;
    grant usage on schema storage to anon,authenticated; grant select,insert on storage.objects to anon,authenticated;
    create policy existing_permissive on storage.objects for all to anon,authenticated using(true) with check(true);`);
  await db.exec(await readFile(new URL("../migrations/202610250001_publishing.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../migrations/202610250002_publication_media_scope.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../migrations/202610250003_publication_controls.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../migrations/202610250004_reader_grant_races.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../migrations/202610250005_source_baselines.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../migrations/202610260001_short_publication_paths.sql", import.meta.url), "utf8"));
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const keys = Object.keys(args), params = keys.map(key => typeof args[key] === "object" && args[key] !== null ? JSON.stringify(args[key]) : args[key]);
    try {
      return (await db.query(`select public.${name}(${keys.map((key, index) => key + "=>$" + (index + 1)).join(",")}) as value`, params)).rows[0].value;
    } catch (error) {
      const message = String(error);
      for (const [name, status] of [["unauthorized", 401], ["not_found", 404], ["conflict", 409], ["inactive", 409], ["missing_media", 400]] as const) {
        if (message.includes("publishing_" + name)) throw new PublishingError(status, name);
      }
      throw error;
    }
  };
  return { db, rpc };
}

test("identical native media IDs remain independent between publications and accounts", async () => {
  const { db, rpc } = await database();
  try {
    const id = crypto.randomUUID();
    const publications: string[] = [];
    for (const subject of ["first-media-owner", "second-media-owner"]) {
      const owner = await rpc("penned_publishing_identity", { p_provider: "apple", p_subject: subject });
      const publication = await rpc("penned_publication_write", { p_action: "create", p_owner: owner, p_library: "same-local-library", p_document_id: "same-local-document", p_token: (subject.startsWith("first") ? "a" : "b").repeat(64) }) as Publication;
      publications.push(publication.id);
      await db.query("insert into penned_publication_media(id,publication_id,object_path,name,mime_type,size,sha256) values($1,$2,$3,'image.png','image/png',8,$4)", [id, publication.id, subject + "/file", "c".repeat(64)]);
    }
    assert.equal((await db.query("select id from penned_publication_media where id=$1", [id])).rows.length, 2);
    await db.query("delete from penned_publications where id=$1", [publications[0]]);
    assert.equal((await db.query("select publication_id from penned_publication_media where id=$1", [id])).rows[0].publication_id, publications[1]);
  } finally { await db.close(); }
});

test("password/email access, custom paths, reader epochs, source fingerprints and CAS use the migrated database", async () => {
  const {db,rpc}=await database();
  try{
    const owner=await rpc("penned_publishing_identity",{p_provider:"apple",p_subject:"controls-owner"});
    let publication=await rpc("penned_publication_write",{p_action:"create",p_owner:owner,p_library:"library",p_document_id:"doc",p_token:"c".repeat(64)}) as Publication;
    publication=await rpc("penned_publication_write",{p_action:"publish",p_owner:owner,p_id:publication.id,p_expected:0,p_document:sample(),p_source:"a".repeat(64)}) as Publication;
    assert.equal(publication.source_fingerprint,"a".repeat(64));assert.ok(publication.published_at);
    const access=await accessPatch({password:"correct password",emails:["Allowed@Example.com"],emailDomains:["example.org"]});
    assert.notEqual(access.passwordHash,"correct password");assert.equal(String(access.passwordHash).length,64);
    publication=await rpc("penned_publication_write",{p_action:"access",p_owner:owner,p_id:publication.id,p_expected:1,p_access:access,p_path:"saved-reading-page"}) as Publication;
    assert.equal(publication.custom_path,"saved-reading-page");
    const store={rpc,async readerEmail(address:string,code?:string){if(code!=="123456")throw new PublishingError(403,"access_denied");return address;}} as PublishingStore;
    const request=new Request("https://example.com/public/"+publication.token);
    assert.equal(await canRead(store,publication,request),false);
    await assert.rejects(authorizeReader(store,publication,request,{password:"wrong",email:"allowed@example.com",code:"123456"},false),/access_denied/);
    await assert.rejects(authorizeReader(store,publication,request,{password:"correct password",email:"other@private.com",code:"123456"},false),/access_denied/);
    await assert.rejects(authorizeReader(store,publication,request,{password:"correct password",email:"allowed@example.com",code:"wrong"},false),/access_denied/);
    const result=await authorizeReader(store,publication,request,{password:"correct password",email:"allowed@example.com",code:"123456"},false);
    const grant=new Request(request,{headers:{"x-penned-reader":result.readerToken!}});
    assert.equal(await canRead(store,publication,grant),true);
    assert.doesNotMatch(JSON.stringify((await db.query("select * from penned_private.reader_grants")).rows),new RegExp(result.readerToken!));
    await assert.rejects(rpc("penned_publication_write",{p_action:"update",p_owner:owner,p_id:publication.id,p_expected:1,p_document:sample()}),/conflict/);
    const old=publication;
    publication=await rpc("penned_publication_write",{p_action:"regenerate",p_owner:owner,p_id:publication.id,p_expected:2,p_token:"d".repeat(64)}) as Publication;
    assert.match(publication.custom_path!,/^[a-z0-9]{8}$/);assert.notEqual(publication.custom_path,old.custom_path);assert.notEqual(publication.token,old.token);assert.equal(await canRead(store,publication,grant),false);
    await assert.rejects(rpc("penned_reader_session",{p_action:"grant",p_publication:publication.id,p_epoch:old.access_epoch,p_hash:"stale"}),/conflict/);
    publication=await rpc("penned_publication_write",{p_action:"unpublish",p_owner:owner,p_id:publication.id,p_expected:3}) as Publication;
    await assert.rejects(rpc("penned_publication_write",{p_action:"update",p_owner:owner,p_id:publication.id,p_expected:4,p_document:sample()}),/inactive/);
    assert.equal(publication.active,false);
    await db.exec("set role anon");await assert.rejects(db.query("select * from penned_private.reader_grants"),/permission denied/);await db.exec("reset role");
    await db.query("delete from penned_publications where id=$1",[publication.id]);
    assert.equal((await db.query("select * from penned_private.reader_grants")).rows.length,0);
  }finally{await db.close();}
});

test("default public links have unique eight-character paths while existing tokens and custom paths remain valid", async () => {
  const {db,rpc}=await database();
  try {
    const owner=await rpc("penned_publishing_identity",{p_provider:"apple",p_subject:"short-path-owner"});
    const paths=new Set<string>();
    for(let i=0;i<20;i++) {
      const token=i.toString(16).padStart(64,"0");
      let publication=await rpc("penned_publication_write",{p_action:"create",p_owner:owner,p_library:"library",p_document_id:"doc-"+i,p_token:token}) as Publication;
      assert.match(publication.custom_path!,/^[a-z0-9]{8}$/);
      assert.equal(publication.token,token);assert.equal(paths.has(publication.custom_path!),false);paths.add(publication.custom_path!);
      assert.equal((await db.query("select id from penned_publications where custom_path=$1 or token=$1",[publication.custom_path])).rows[0].id,publication.id);
      publication=await rpc("penned_publication_write",{p_action:"access",p_owner:owner,p_id:publication.id,p_expected:0,p_path:"chosen-page-"+i}) as Publication;
      assert.equal(publication.custom_path,"chosen-page-"+i);
      publication=await rpc("penned_publication_write",{p_action:"access",p_owner:owner,p_id:publication.id,p_expected:1,p_path:""}) as Publication;
      assert.match(publication.custom_path!,/^[a-z0-9]{8}$/);assert.equal(publication.token,token);
    }
  } finally { await db.close(); }
});

test("reader rate limits are durable and passwords/domains are validated",async()=>{
  const {db,rpc}=await database();
  try{
    const args={p_action:"limit",p_hash:await readerDigest("client"),p_epoch:2};
    assert.equal((await rpc("penned_reader_session",args) as any).allowed,true);
    assert.equal((await rpc("penned_reader_session",args) as any).allowed,true);
    assert.equal((await rpc("penned_reader_session",args) as any).allowed,false);
    await assert.rejects(accessPatch({password:"short"}),/password_too_short/);
    await assert.rejects(accessPatch({emailDomains:["https://example.com"]}),/invalid_email_domain/);
    await assert.rejects(accessPatch({emails:["not-an-email"]}),/invalid_email/);
  }finally{await db.close();}
});

test("migration enforces RLS, scoped functions, and private storage even with an existing broad policy", async () => {
  const { db } = await database();
  try {
    for (const role of ["anon", "authenticated"]) {
      await db.exec("set role " + role);
      await assert.rejects(db.query("select * from public.penned_publications"), /permission denied/);
      await assert.rejects(db.query("select public.penned_publishing_identity('apple','victim')"), /permission denied/);
      await assert.rejects(db.query("select * from penned_private.publishing_sessions"), /permission denied/);
      await assert.rejects(db.query("insert into storage.objects values(gen_random_uuid(),'penned-publications')"), /row-level security/);
      await db.exec("reset role");
    }
    const policies = await db.query("select relrowsecurity from pg_class where relname in ('penned_publications','penned_publication_media','publishing_owners','publishing_sessions','publishing_apple_exchanges')");
    assert.equal(policies.rows.length, 5);
    assert.ok(policies.rows.every(row => row.relrowsecurity));
    assert.equal((await db.query("select public from storage.buckets")).rows[0].public, false);
    await db.exec("set role service_role");
    assert.ok((await db.query("select public.penned_publishing_identity('apple','service-owner') as id")).rows[0].id);
    await db.exec("reset role");
  } finally { await db.close(); }
});

test("atomic versions retain successful content after conflicts, missing files, unpublish, and link regeneration", async () => {
  const { db, rpc } = await database();
  try {
    const owner = await rpc("penned_publishing_identity", { p_provider: "apple", p_subject: "owner" });
    const stranger = await rpc("penned_publishing_identity", { p_provider: "apple", p_subject: "stranger" });
    let publication = await rpc("penned_publication_write", { p_action: "create", p_owner: owner, p_library: "original-library", p_document_id: "original-document", p_token: "a".repeat(64) }) as Publication;
    const originalID = publication.id;
    publication = await rpc("penned_publication_write", { p_action: "publish", p_owner: owner, p_id: originalID, p_expected: 0, p_document: sample() }) as Publication;
    assert.equal(publication.version, 1);
    await assert.rejects(rpc("penned_publication_write", { p_action: "update", p_owner: stranger, p_id: originalID, p_expected: 1, p_document: sample() }), /not_found/);
    await assert.rejects(rpc("penned_publication_write", { p_action: "update", p_owner: owner, p_id: originalID, p_expected: 0, p_document: sample() }), /conflict/);
    await assert.rejects(rpc("penned_publication_write", { p_action: "update", p_owner: owner, p_id: originalID, p_expected: 1, p_document: { ...sample(), media: [{ id: crypto.randomUUID(), size: 1, sha256: "a".repeat(64), mimeType: "image/png", name: "file" }] } }), /missing_media/);
    assert.equal((await db.query("select version from penned_publications where id=$1", [originalID])).rows[0].version, 1);
    publication = await rpc("penned_publication_write", { p_action: "unpublish", p_owner: owner, p_id: originalID, p_expected: 1 }) as Publication;
    assert.equal(publication.active, false);
    await assert.rejects(rpc("penned_publication_write", { p_action: "update", p_owner: owner, p_id: originalID, p_expected: 2, p_document: sample() }), /inactive/);
    publication = await rpc("penned_publication_write", { p_action: "regenerate", p_owner: owner, p_id: originalID, p_expected: 2, p_token: "b".repeat(64) }) as Publication;
    assert.equal(publication.token, "b".repeat(64));
    assert.equal(publication.active, false);
    assert.equal(publication.source_document_id, "original-document");
    assert.deepEqual(publication.document, sample());
  } finally { await db.close(); }
});

test("Apple subjects never merge with email users; nonce exchanges and refresh tokens cannot be replayed", async () => {
  const { db, rpc } = await database();
  try {
    const user = crypto.randomUUID();
    await db.query("insert into auth.users values($1)", [user]);
    const email = await rpc("penned_publishing_identity", { p_provider: "email", p_subject: user, p_auth_user: user });
    const apple = await rpc("penned_publishing_identity", { p_provider: "apple", p_subject: user });
    assert.notEqual(email, apple);
    const exchange = { p_action: "exchange", p_subject: user, p_hash: "token", p_access: "access", p_refresh: "refresh", p_expiry: new Date(Date.now() + 60000).toISOString() };
    await rpc("penned_publishing_session", exchange);
    await assert.rejects(rpc("penned_publishing_session", exchange), /duplicate key/);
    await rpc("penned_publishing_session", { p_action: "refresh", p_hash: "refresh", p_access: "next-access", p_refresh: "next-refresh" });
    await assert.rejects(rpc("penned_publishing_session", { p_action: "refresh", p_hash: "refresh", p_access: "stolen-access", p_refresh: "stolen-refresh" }), /unauthorized/);
    await assert.rejects(rpc("penned_publishing_session", { p_action: "verify", p_hash: "access" }), /unauthorized/);
    await rpc("penned_publishing_delete_owner", { p_owner: apple });
    await assert.rejects(rpc("penned_publishing_session", { p_action: "verify", p_hash: "next-access" }), /unauthorized/);
    await assert.rejects(rpc("penned_publishing_session", { ...exchange, p_hash: "delayed-before-deletion", p_issued_at: new Date(Date.now() - 60000).toISOString() }), /unauthorized/);
    const publication = await rpc("penned_publication_write", { p_action: "create", p_owner: email, p_library: "library", p_document_id: "document", p_token: "c".repeat(64) }) as Publication;
    await db.query("delete from auth.users where id=$1", [user]);
    assert.equal((await db.query("select * from penned_publications where id=$1", [publication.id])).rows.length, 0);
  } finally { await db.close(); }
});

test("media referenced by the live version cannot be deleted and retired staged files cannot be committed", async () => {
  const { db, rpc } = await database();
  try {
    const owner = await rpc("penned_publishing_identity", { p_provider: "apple", p_subject: "media-owner" });
    let publication = await rpc("penned_publication_write", { p_action: "create", p_owner: owner, p_library: "library", p_document_id: "document", p_token: "d".repeat(64) }) as Publication;
    const id = crypto.randomUUID(), asset = { id, name: "file.png", mimeType: "image/png", size: 8, sha256: "e".repeat(64) };
    await db.query("insert into penned_publication_media(id,publication_id,object_path,name,mime_type,size,sha256) values($1,$2,'private/object','file.png','image/png',8,$3)", [id, publication.id, asset.sha256]);
    const content = { ...sample(), media: [asset], cover: { mediaID: id } };
    publication = await rpc("penned_publication_write", { p_action: "publish", p_owner: owner, p_id: publication.id, p_expected: 0, p_document: content }) as Publication;
    await assert.rejects(rpc("penned_publication_media_delete", { p_owner: owner, p_id: publication.id, p_media: id, p_expected: 1 }), /media_in_use/);
    publication = await rpc("penned_publication_write", { p_action: "update", p_owner: owner, p_id: publication.id, p_expected: 1, p_document: sample() }) as Publication;
    await rpc("penned_publication_media_delete", { p_owner: owner, p_id: publication.id, p_media: id, p_expected: 2 });
    await assert.rejects(rpc("penned_publication_write", { p_action: "update", p_owner: owner, p_id: publication.id, p_expected: 2, p_document: content }), /missing_media/);
    await rpc("penned_publication_media_delete", { p_owner: owner, p_id: publication.id, p_media: id, p_expected: 2, p_finish: true });
    assert.equal((await db.query("select * from penned_publication_media where id=$1", [id])).rows.length, 0);
  } finally { await db.close(); }
});

test("HTTP lifecycle uses the migrated database and never returns private identifiers or staged media", async () => {
  const { db, rpc } = await database(), files = new Map<string, Uint8Array>();
  const session = "ppa_" + "f".repeat(64);
  await rpc("penned_publishing_session", { p_action: "exchange", p_subject: "http-owner", p_hash: "http-apple", p_access: await digest(session), p_refresh: "http-refresh", p_expiry: new Date(Date.now() + 60000).toISOString() });
  const store: PublishingStore = {
    rpc,
    async emailIdentity() { throw new PublishingError(401, "authentication_required"); },
    async publication(id, owner) { return (await db.query("select * from penned_publications where id=$1 and owner_id=$2", [id, owner])).rows[0] as Publication ?? null; },
    async publicPublication(token) { return (await db.query("select * from penned_publications where token=$1 and active", [token])).rows[0] as Publication ?? null; },
    async media(id, publication) { return (await db.query("select * from penned_publication_media where id=$1 and publication_id=$2", [id, publication])).rows[0] as Media ?? null; },
    async insertMedia(asset) { await db.query("insert into penned_publication_media(id,publication_id,object_path,name,mime_type,size,sha256) values($1,$2,$3,$4,$5,$6,$7)", Object.values(asset)); },
    async upload(path, bytes) { files.set(path, bytes); },
    async remove(path) { files.delete(path); },
    async download(path) { return new Response(files.get(path) as BodyInit); },
  };
  const handler = createPublishingHandler({ store, publicBaseURL: "https://penned.example/p", async verifyApple() { throw new Error("unused"); } });
  const call = (path: string, method = "GET", body?: unknown, authenticated = true) => handler(new Request("https://project.supabase.co/functions/v1/penned-publishing/" + path, {
    method, headers: { "Content-Type": "application/json", ...(authenticated ? { Authorization: "Bearer " + session } : {}) }, body: body === undefined ? undefined : JSON.stringify(body),
  }));
  try {
    assert.equal((await call("publications", "POST", {}, false)).status, 401);
    let response = await call("publications", "POST", { sourceLibraryID: "private-library", sourceDocumentID: "private-document" });
    assert.equal(response.status, 201);
    let publication = await response.json();
    assert.equal((await call("public/" + publication.token, "GET", undefined, false)).status, 404);
    response = await call("publications/" + publication.id, "PUT", { action: "publish", expectedVersion: 0, document: sample(), settings: { authorName: "PRIVATE AUTHOR", showAuthor: false } });
    assert.equal(response.status, 200);
    publication = await response.json();
    response = await call("public/" + publication.token, "GET", undefined, false);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.doesNotMatch(await response.text(), /private-library|private-document|owner_id|PRIVATE AUTHOR/);
    assert.equal((await call("public/" + publication.token + "/media/" + crypto.randomUUID(), "GET", undefined, false)).status, 404);
    const mediaID = crypto.randomUUID(), mediaBytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    response = await handler(new Request("https://project.supabase.co/functions/v1/penned-publishing/publications/" + publication.id + "/media/" + mediaID, {
      method: "PUT", headers: { Authorization: "Bearer " + session, "Content-Type": "image/png", "X-File-Name": "image.png" }, body: mediaBytes,
    }));
    assert.equal(response.status, 201);
    const asset = await response.json();
    assert.equal(asset.sha256, await digest(mediaBytes));
    const publicMediaPath = "public/" + publication.token + "/media/" + mediaID;
    assert.equal((await call(publicMediaPath, "GET", undefined, false)).status, 404);
    response = await call("publications/" + publication.id, "PUT", { action: "update", expectedVersion: 1, document: { ...sample(), cover: { mediaID }, media: [asset] } });
    assert.equal(response.status, 200);
    response = await call(publicMediaPath, "GET", undefined, false);
    assert.equal(response.status, 200);
    assert.deepEqual(new Uint8Array(await response.arrayBuffer()), mediaBytes);
    assert.equal(response.headers.get("content-security-policy"), "sandbox; default-src 'none'");
    const strangerToken = "ppa_" + "e".repeat(64);
    await rpc("penned_publishing_session", { p_action: "exchange", p_subject: "http-stranger", p_hash: "stranger-apple", p_access: await digest(strangerToken), p_refresh: "stranger-refresh", p_expiry: new Date(Date.now() + 60000).toISOString() });
    assert.equal((await handler(new Request("https://project.supabase.co/functions/v1/penned-publishing/publications/" + publication.id, { headers: { Authorization: "Bearer " + strangerToken } }))).status, 404);
    assert.equal((await call("publications/" + publication.id, "PUT", { action: "update", expectedVersion: 0, document: sample() })).status, 409);
    response = await call("publications/" + publication.id + "/unpublish", "POST", { expectedVersion: 2 });
    assert.equal(response.status, 200);
    assert.equal((await call("public/" + publication.token, "GET", undefined, false)).status, 404);
    assert.equal((await call(publicMediaPath, "GET", undefined, false)).status, 404);
    response = await call("publications/" + publication.id + "/regenerate", "POST", { expectedVersion: 3 });
    assert.equal(response.status, 200);
    const regenerated = await response.json();
    assert.notEqual(regenerated.token, publication.token);
    assert.equal((await call("public/" + publication.token, "GET", undefined, false)).status, 404);
    response = await call("publications/" + publication.id, "PUT", { action: "publish", expectedVersion: 4, document: sample(), settings: { expiresAt: "2000-01-01T00:00:00Z" } });
    assert.equal(response.status, 200);
    assert.equal((await call("public/" + regenerated.token, "GET", undefined, false)).status, 404);
    assert.equal((await call("owner", "DELETE")).status, 200);
    assert.equal((await db.query("select * from penned_publications where id=$1", [publication.id])).rows.length, 0);
  } finally { await db.close(); }
});
