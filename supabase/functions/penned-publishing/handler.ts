import { maxMediaBytes, mediaTypes, object, publicDocument, PublishingError, sanitizeDocument, sanitizeSettings, string, tokenPattern, uuid, version, equivalentProjection } from "./contract.ts";
import type { JSONObject } from "./contract.ts";
import { validateMedia } from "./media.ts";
import { linkedDocumentIDs } from "./visible-content.ts";
import { accessPatch, authorizeReader, canRead, identifierPattern, restricted } from "./access.ts";
import { readerPayload } from "./reader-payload.ts";

export type Publication = { id: string; owner_id: string; source_library_id: string; source_document_id: string; token: string; version: number; active: boolean; document: ReturnType<typeof sanitizeDocument> | null; settings: JSONObject; updated_at: string;
  source_fingerprint?: string|null; published_at?: string|null; custom_path?: string|null; access?: JSONObject; access_epoch?: number };
export type Media = { id: string; publication_id: string; object_path: string; name: string; mime_type: string; size: number; sha256: string; retired?: boolean };
export interface PublishingStore {
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  emailIdentity(jwt: string): Promise<{ id: string }>;
  publication(id: string, owner: string): Promise<Publication | null>;
  publicPublication(token: string): Promise<Publication | null>;
  media(id: string, publication: string): Promise<Media | null>;
  insertMedia(media: Media): Promise<void>;
  upload(path: string, bytes: Uint8Array, mime: string): Promise<void>;
  remove(path: string): Promise<void>;
  download(path: string, range: string | null): Promise<Response>;
  linkedPublications?(owner: string, library: string, documentIDs: string[]): Promise<ReadonlyMap<string, string>>;
  publications?(owner: string, library: string): Promise<Publication[]>;
  readerEmail?(email: string, code?: string): Promise<string|null>;
}
export type AppleIdentity = { subject: string; expiresAt: string; issuedAt: string };
export type HandlerOptions = { store: PublishingStore; verifyApple(token: string, nonce: string): Promise<AppleIdentity>; publicBaseURL: string };

export async function digest(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource)), byte => byte.toString(16).padStart(2, "0")).join("");
}

export function randomToken(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, "0")).join("");
}

const responseHeaders = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Access-Control-Allow-Origin": "*", "X-Robots-Tag": "noindex, nofollow" };
function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: responseHeaders });
}

async function bytes(request: Request, limit: number): Promise<Uint8Array> {
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > limit)) throw new PublishingError(413, "body_too_large");
  const reader = request.body?.getReader(), chunks: Uint8Array[] = [];
  let count = 0;
  if (reader) {
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        count += next.value.byteLength;
        if (count > limit) { await reader.cancel(); throw new PublishingError(413, "body_too_large"); }
        chunks.push(next.value);
      }
    } finally { reader.releaseLock(); }
  }
  const result = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

async function body(request: Request, limit = 2 * 1024 * 1024): Promise<Record<string, unknown>> {
  if (request.headers.get("content-type")?.split(";")[0].trim() !== "application/json") throw new PublishingError(415, "json_required");
  try { return object(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await bytes(request, limit)))); }
  catch (error) { if (error instanceof PublishingError) throw error; throw new PublishingError(400, "invalid_json"); }
}

function live(publication: Publication | null): publication is Publication & { document: NonNullable<Publication["document"]> } {
  return Boolean(publication?.active && publication.document && (!publication.settings.expiresAt || Date.parse(String(publication.settings.expiresAt)) > Date.now()));
}

export function createPublishingHandler(options: HandlerOptions) {
  const { store } = options;
  function status(publication: Publication) {
    return { id: publication.id, sourceLibraryID: publication.source_library_id, sourceDocumentID: publication.source_document_id,
      version: Number(publication.version), active: publication.active, token: publication.token,
      publicURL: options.publicBaseURL.replace(/\/$/, "") + "/" + (publication.custom_path || publication.token),
      settings: publication.settings, updatedAt: publication.updated_at, sourceFingerprint: publication.source_fingerprint ?? null,
      publishedAt: publication.published_at ?? null, customPath: publication.custom_path ?? null,
      passwordSet: Boolean(publication.access?.passwordHash), emails: publication.access?.emails || [], emailDomains: publication.access?.emailDomains || [], uploadedMedia: publication.document?.media || [] };
  }
  async function owner(request: Request): Promise<string> {
    const header = request.headers.get("authorization");
    if (!header || header.length > 16384 || !header.startsWith("Bearer ")) throw new PublishingError(401, "authentication_required");
    const token = header.slice(7);
    if (/^ppa_[a-f0-9]{64}$/.test(token)) {
      const verified = object(await store.rpc("penned_publishing_session", { p_action: "verify", p_hash: await digest(token) }));
      return uuid(verified.ownerID);
    }
    if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) throw new PublishingError(401, "authentication_required");
    const user = await store.emailIdentity(token);
    return uuid(await store.rpc("penned_publishing_identity", { p_provider: "email", p_subject: user.id, p_auth_user: user.id }));
  }
  return async (request: Request): Promise<Response> => {
    try {
      const url = new URL(request.url);
      // The hosted gateway strips /functions/v1 before forwarding to the worker.
      const prefix = ["/functions/v1/penned-publishing", "/penned-publishing"].find(value => url.pathname.startsWith(value + "/"));
      if (!prefix) throw new PublishingError(404, "not_found");
      const route = url.pathname.slice(prefix.length).split("/").filter(Boolean);
      const snapshots = request.method === "GET" && route[0] === "public" && (route.length === 2 || (route.length === 4 && route[2] === "pages")) && url.search === "?snapshots=1";
      if (url.search && !snapshots) throw new PublishingError(400, "query_not_allowed");
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: { ...responseHeaders,
        "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-file-name, range, x-penned-reader" } });
      if (route[0] === "auth" && request.method === "POST" && route.length === 2) {
        const input = await body(request), action = route[1];
        if (!["apple", "refresh"].includes(action)) throw new PublishingError(404, "not_found");
        const accessToken = "ppa_" + randomToken(), refreshToken = "ppr_" + randomToken();
        const args: Record<string, unknown> = { p_action: action === "apple" ? "exchange" : "refresh", p_access: await digest(accessToken), p_refresh: await digest(refreshToken) };
        if (action === "apple") {
          const token = string(input.identityToken, 16384), nonce = string(input.nonce, 128);
          if (!/^[a-f0-9]{64}$/.test(nonce)) throw new PublishingError(400, "invalid_nonce");
          const identity = await options.verifyApple(token, nonce);
          Object.assign(args, { p_subject: identity.subject, p_expiry: identity.expiresAt, p_issued_at: identity.issuedAt, p_hash: await digest(token) });
        } else {
          const token = string(input.refreshToken, 68);
          if (!/^ppr_[a-f0-9]{64}$/.test(token)) throw new PublishingError(401, "authentication_required");
          args.p_hash = await digest(token);
        }
        const session = object(await store.rpc("penned_publishing_session", args));
        return json({ accessToken, refreshToken, expiresAt: session.expiresAt, subject: session.subject });
      }
      if (route[0] === "public" && ["GET", "HEAD", "POST"].includes(request.method) && [2, 3, 4].includes(route.length)) {
        const token = route[1];
        if (!identifierPattern.test(token)) throw new PublishingError(404, "not_found");
        const publication = await store.publicPublication(token);
        if (!live(publication)) throw new PublishingError(404, "not_found");
        if(request.method === "POST" && route.length === 3 && ["access","email"].includes(route[2])) {
          return json(await authorizeReader(store,publication,request,await body(request),route[2]==="email"));
        }
        if(!["GET","HEAD"].includes(request.method))throw new PublishingError(405,"method_not_allowed");
        if(!await canRead(store,publication,request))return json({error:"access_required",password:Boolean(publication.access?.passwordHash),email:Boolean((publication.access?.emails as unknown[])?.length || (publication.access?.emailDomains as unknown[])?.length)},401);
        if (route.length === 2 || (route.length === 4 && route[2] === "pages")) {
          const payload = readerPayload(publication, route.length === 4 ? route[3] : undefined, snapshots);
          if (restricted(publication)) payload.settings.allowIndexing = false;
          const response = json(payload);
          response.headers.set("ETag",'"'+publication.version+'"');
          if (payload.settings.allowIndexing === true) response.headers.set("X-Robots-Tag", "index, follow");
          if (request.method === "HEAD") return new Response(null, { headers: response.headers });
          return response;
        }
        if (route[2] !== "media") throw new PublishingError(404, "not_found");
        const id = uuid(route[3]);
        if (publication.document.authorAvatar?.mediaID === id && publication.settings.showAuthor !== true) throw new PublishingError(404, "not_found");
        if (!publicDocument(publication.document, publication.settings).media.some(asset => asset.id === id)) throw new PublishingError(404, "not_found");
        const asset = await store.media(id, publication.id);
        if (!asset || asset.retired) throw new PublishingError(404, "not_found");
        const range = request.headers.get("range");
        if (range && !/^bytes=\d*-\d*$/.test(range)) throw new PublishingError(416, "invalid_range");
        const media = await store.download(asset.object_path, range);
        if (![200, 206, 416].includes(media.status)) throw new PublishingError(503, "media_unavailable");
        const headers = new Headers(responseHeaders);
        headers.set("Content-Type", asset.mime_type);
        headers.set("Content-Security-Policy", "sandbox; default-src 'none'");
        headers.set("Content-Disposition", `inline; filename*=UTF-8''${encodeURIComponent(asset.name).replace(/['()*]/g, char => "%" + char.charCodeAt(0).toString(16))}`);
        for (const name of ["content-range", "content-length", "accept-ranges"]) if (media.headers.has(name)) headers.set(name, media.headers.get(name)!);
        if (request.method === "HEAD") { await media.body?.cancel(); return new Response(null, { status: media.status, headers }); }
        return new Response(media.body, { status: media.status, headers });
      }
      const ownerID = await owner(request);
      if (route.join("/") === "auth/revoke" && request.method === "DELETE") {
        const token = request.headers.get("authorization")!.slice(7);
        if (token.startsWith("ppa_")) await store.rpc("penned_publishing_session", { p_action: "revoke", p_hash: await digest(token) });
        return json({ revoked: true });
      }
      if (route.join("/") === "owner" && request.method === "DELETE") {
        await store.rpc("penned_publishing_delete_owner", { p_owner: ownerID });
        return json({ revoked: true });
      }
      if (route[0] !== "publications") throw new PublishingError(404, "not_found");
      if(route.length === 2 && route[1] === "list" && request.method === "POST") {
        const input=await body(request),library=string(input.sourceLibraryID,200);
        if(!store.publications)throw new PublishingError(503,"publishing_unavailable");
        return json((await store.publications(ownerID,library)).map(status));
      }
      if (route.length === 1 && request.method === "POST") {
        const input = await body(request), library = string(input.sourceLibraryID, 200), document = string(input.sourceDocumentID, 200);
        if (!library || !document) throw new PublishingError(400, "source_required");
        const result = await store.rpc("penned_publication_write", { p_action: "create", p_owner: ownerID, p_library: library, p_document_id: document, p_token: randomToken() });
        return json(status(result as Publication), 201);
      }
      const id = uuid(route[1]);
      const publication = await store.publication(id, ownerID);
      if (!publication) throw new PublishingError(404, "not_found");
      if (route.length === 2 && request.method === "GET") return json(status(publication));
      if(route.length===3&&route[2]==="baseline"&&request.method==="POST"){
        const input=await body(request),document=sanitizeDocument(input.document),hash=string(input.sourceFingerprint,64);
        if(!tokenPattern.test(hash)||!publication.document||!equivalentProjection(document,publication.document))throw new PublishingError(409,"conflict");
        const result=await store.rpc("penned_source_baseline",{p_owner:ownerID,p_id:id,p_expected:version(input.expectedVersion),p_source:hash});
        return json(status(result as Publication));
      }
      if (route.length === 4 && route[2] === "media" && request.method === "DELETE") {
        const input = await body(request), args = { p_owner: ownerID, p_id: id, p_media: uuid(route[3]), p_expected: version(input.expectedVersion) };
        const asset = object(await store.rpc("penned_publication_media_delete", args));
        if (typeof asset.object_path === "string") {
          await store.remove(asset.object_path);
          await store.rpc("penned_publication_media_delete", { ...args, p_finish: true });
        }
        return json({ deleted: true });
      }
      if (route.length === 4 && route[2] === "media" && request.method === "PUT") {
        const mediaID = uuid(route[3]), mimeType = request.headers.get("content-type")?.split(";")[0].trim() ?? "";
        if (!mediaTypes.has(mimeType)) throw new PublishingError(415, "unsupported_media_type");
        let name: string;
        try { name = string(decodeURIComponent(request.headers.get("x-file-name") ?? "File"), 255); } catch { throw new PublishingError(400, "invalid_file_name"); }
        const data = await bytes(request, maxMediaBytes);
        if (!data.length) throw new PublishingError(400, "empty_media");
        validateMedia(data, mimeType);
        const sha256 = await digest(data), existing = await store.media(mediaID, id);
        if (existing) {
          if (existing.retired) throw new PublishingError(409, "media_retired");
          if (existing.sha256 !== sha256 || existing.name !== name || existing.mime_type !== mimeType) throw new PublishingError(409, "immutable_media");
          return json({ id: existing.id, name: existing.name, mimeType: existing.mime_type, size: Number(existing.size), sha256: existing.sha256 });
        }
        const path = ownerID + "/" + id + "/" + crypto.randomUUID();
        await store.upload(path, data, mimeType);
        try { await store.insertMedia({ id: mediaID, publication_id: id, object_path: path, name, mime_type: mimeType, size: data.length, sha256 }); }
        catch (error) { await store.remove(path).catch(() => {}); throw error; }
        return json({ id: mediaID, name, mimeType, size: data.length, sha256 }, 201);
      }
      if (route.length === 2 && request.method === "PUT") {
        const input = await body(request, 16 * 1024 * 1024), action = input.action;
        if (!["publish", "update"].includes(String(action))) throw new PublishingError(400, "invalid_action");
        const ids = linkedDocumentIDs(object(input.document).content);
        const links = ids.length && store.linkedPublications ? await store.linkedPublications(ownerID, publication.source_library_id, ids) : new Map<string, string>();
        const document = sanitizeDocument(input.document, links), settings = sanitizeSettings(input.settings ?? {});
        const fingerprint=input.sourceFingerprint == null ? null : string(input.sourceFingerprint,64);
        if(fingerprint!=null && !tokenPattern.test(fingerprint))throw new PublishingError(400,"invalid_fingerprint");
        const result = await store.rpc("penned_publication_write", { p_action: action, p_owner: ownerID, p_id: id,
          p_expected: version(input.expectedVersion), p_document: document, p_settings: settings, p_source: fingerprint });
        return json(status(result as Publication));
      }
      if(route.length===3 && route[2]==="access" && request.method==="POST") {
        const input=await body(request), access=await accessPatch(input);
        const path=input.customPath==null?null:string(input.customPath,80);
        if(path && (!identifierPattern.test(path)||tokenPattern.test(path)))throw new PublishingError(400,"invalid_path");
        const next={...publication,access:{...publication.access,...access}};
        const result=await store.rpc("penned_publication_write",{p_action:"access",p_owner:ownerID,p_id:id,p_expected:version(input.expectedVersion),p_access:access,p_path:path,p_settings:restricted(next)?{allowIndexing:false}:null});
        return json(status(result as Publication));
      }
      if (route.length === 3 && request.method === "POST" && ["settings", "unpublish", "regenerate"].includes(route[2])) {
        const input = await body(request), settings=route[2]==="settings"?sanitizeSettings(input.settings):null;
        if(settings&&restricted(publication))settings.allowIndexing=false;
        const result = await store.rpc("penned_publication_write", { p_action: route[2], p_owner: ownerID, p_id: id,
          p_expected: version(input.expectedVersion), p_settings: settings,
          p_token: route[2] === "regenerate" ? randomToken() : null });
        return json(status(result as Publication));
      }
      throw new PublishingError(405, "method_not_allowed");
    } catch (error) {
      if (error instanceof PublishingError) return json({ error: error.code }, error.status);
      return json({ error: "publishing_unavailable" }, 503);
    }
  };
}
