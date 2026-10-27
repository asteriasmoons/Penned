import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.3";
import { digest } from "./handler.ts";
import { PublishingError, uuid } from "./contract.ts";
import type { Media, Publication, PublishingStore } from "./handler.ts";

function checked<T>(result: { data: T; error: { message: string; code?: string } | null }): T {
  if (result.error) {
    const message = result.error.message;
    for (const [name, status] of [["unauthorized", 401], ["not_found", 404], ["conflict", 409], ["inactive", 409], ["media_in_use", 409], ["missing_media", 400], ["invalid_document", 400]] as const) {
      if (message.includes("publishing_" + name)) throw new PublishingError(status, name);
    }
    if (result.error.code === "23505") throw new PublishingError(409, message.includes("custom_path") ? "path_taken" : "conflict");
    throw new PublishingError(503, "publishing_unavailable");
  }
  return result.data;
}

export function createPublishingStore(getEnv: (name: string) => string | undefined, fetchImplementation: typeof fetch = fetch): PublishingStore {
  const url = getEnv("SUPABASE_URL"), secrets = getEnv("SUPABASE_SECRET_KEYS");
  const key = secrets ? JSON.parse(secrets).default : getEnv("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || typeof key !== "string" || !key) throw new Error("Missing Supabase server configuration");
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: (input, init) => fetchImplementation(input, { ...init, signal: AbortSignal.timeout(30000), redirect: "error" }) } });
  return {
    async rpc(name, args) { return checked(await client.rpc(name, args)); },
    async emailIdentity(jwt) {
      const result = await client.auth.getUser(jwt);
      if (result.error || !result.data.user) throw new PublishingError(result.error && result.error.status && result.error.status >= 500 ? 503 : 401, "authentication_required");
      const user = result.data.user;
      if (user.role !== "authenticated" || user.is_anonymous || !user.email_confirmed_at || !user.identities?.some(identity => identity.provider === "email")) throw new PublishingError(403, "verified_email_required");
      return { id: uuid(user.id) };
    },
    async publication(id, owner) { return checked(await client.from("penned_publications").select("*").eq("id", id).eq("owner_id", owner).maybeSingle()) as Publication | null; },
    async publicPublication(token) { return checked(await client.from("penned_publications").select("*").eq(/^[a-f0-9]{64}$/.test(token)?"token":"custom_path", token).eq("active", true).maybeSingle()) as Publication | null; },
    async publications(owner,library) {
      const result: Publication[]=[];
      for(let offset=0;;offset+=1000){
        const rows=checked(await client.from("penned_publications").select("id,owner_id,source_library_id,source_document_id,token,version,active,settings,updated_at,source_fingerprint,published_at,custom_path,access,access_epoch").eq("owner_id",owner).eq("source_library_id",library).order("id").range(offset,offset+999))||[];
        result.push(...rows as Publication[]);if(rows.length<1000)return result;
      }
    },
    async readerEmail(email,code) {
      // Auth verification must never replace the service client's session.
      const visitor=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:fetchImplementation}});
      if(code==null){
        const result=await visitor.auth.signInWithOtp({email,options:{shouldCreateUser:true}});
        if(result.error)throw new PublishingError(result.error.status===429?429:503,"email_unavailable");
        return null;
      }
      const result=await visitor.auth.verifyOtp({email,token:code,type:"email"});
      const user=result.data.user;
      if(result.error||!user?.email_confirmed_at||user.is_anonymous||user.email?.toLowerCase()!==email)throw new PublishingError(403,"access_denied");
      return email;
    },
    async linkedPublications(owner, library, documentIDs) {
      const batches: string[][] = []; let batch: string[] = [], length = 0;
      // Bound encoded query size for large collections, not only the number of IDs.
      for (const id of new Set(documentIDs)) {
        const size = encodeURIComponent(JSON.stringify(id)).length + 3;
        if (batch.length && length + size > 3000) { batches.push(batch); batch = []; length = 0; }
        batch.push(id); length += size;
      }
      if (batch.length) batches.push(batch);
      const links = new Map<string, string>();
      for (const ids of batches) {
        const results = checked(await client.from("penned_publications").select("source_document_id,token,custom_path,settings")
          .eq("owner_id", owner).eq("source_library_id", library).eq("active", true).in("source_document_id", ids));
        for (const row of results ?? []) if (!row.settings?.expiresAt || Date.parse(row.settings.expiresAt) > Date.now()) links.set(row.source_document_id, row.custom_path || row.token);
      }
      return links;
    },
    async media(id, publication) { return checked(await client.from("penned_publication_media").select("*").eq("id", id).eq("publication_id", publication).maybeSingle()) as Media | null; },
    async insertMedia(media) { checked(await client.from("penned_publication_media").insert(media)); },
    async upload(path, bytes, mime) { checked(await client.storage.from("penned-publications").upload(path, bytes, { contentType: mime, upsert: false, cacheControl: "0" })); },
    async remove(path) { checked(await client.storage.from("penned-publications").remove([path])); },
    async download(path, range) {
      return await fetchImplementation(url + "/storage/v1/object/authenticated/penned-publications/" + path.split("/").map(encodeURIComponent).join("/"), {
        headers: { apikey: key, Authorization: "Bearer " + key, ...(range ? { Range: range } : {}) },
        signal: AbortSignal.timeout(30000), redirect: "error",
      });
    },
  };
}

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"), { timeoutDuration: 10000 });

export function appleVerifier(audiences: string[], verificationKey: Parameters<typeof jwtVerify>[1] = appleKeys) {
  if (!audiences.length || audiences.some(audience => !audience)) throw new Error("PENNED_APPLE_AUDIENCES is required");
  return async (token: string, nonce: string) => {
    try {
      const { payload } = await jwtVerify(token, verificationKey, { issuer: "https://appleid.apple.com", audience: audiences, algorithms: ["RS256"], maxTokenAge: "10m", requiredClaims: ["sub", "exp", "iat", "nonce"] });
      if (!payload.sub || payload.nonce !== await digest(nonce)) throw new Error("Invalid Apple nonce");
      return { subject: payload.sub, expiresAt: new Date(payload.exp! * 1000).toISOString(), issuedAt: new Date(payload.iat! * 1000).toISOString() };
    } catch { throw new PublishingError(401, "invalid_apple_credential"); }
  };
}
