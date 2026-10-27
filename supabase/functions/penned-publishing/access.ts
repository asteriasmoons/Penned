import { object, string, PublishingError } from "./contract.ts";
import type { JSONObject } from "./contract.ts";
import type { Publication, PublishingStore } from "./handler.ts";

const hex = (bytes: Uint8Array) => Array.from(bytes, byte => byte.toString(16).padStart(2,"0")).join("");
export const readerDigest = async (value: string) => hex(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value))));
export const identifierPattern = /^(?:[a-f0-9]{64}|[a-z0-9][a-z0-9-]{1,78}[a-z0-9])$/;
export function restricted(publication: Publication): boolean {
  const access = publication.access || {};
  return Boolean(access.passwordHash || (Array.isArray(access.emails) && access.emails.length) || (Array.isArray(access.emailDomains) && access.emailDomains.length));
}
async function passwordHash(password: string,salt: string) {
  const key = await crypto.subtle.importKey("raw",new TextEncoder().encode(password),"PBKDF2",false,["deriveBits"]);
  return hex(new Uint8Array(await crypto.subtle.deriveBits({name:"PBKDF2",salt:new TextEncoder().encode(salt),iterations:600000,hash:"SHA-256"},key,256)));
}
export function email(value: unknown): string {
  const result=string(value,254).trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(result))throw new PublishingError(400,"invalid_email");
  return result;
}
export async function accessPatch(input: Record<string,unknown>): Promise<JSONObject> {
  const result: JSONObject={};
  if(input.password!=null){
    const password=string(input.password,256);
    if(password && password.length<8)throw new PublishingError(400,"password_too_short");
    const salt=hex(crypto.getRandomValues(new Uint8Array(32)));
    result.passwordSalt=password?salt:null;result.passwordHash=password?await passwordHash(password,salt):null;
  }
  for(const key of ["emails","emailDomains"]){
    if(input[key]==null)continue;
    if(!Array.isArray(input[key])||input[key].length>100)throw new PublishingError(400,"invalid_email_access");
    result[key]=[...new Set((input[key] as unknown[]).map(value=>{
      if(key==="emails")return email(value);
      const domain=string(value,253).trim().toLowerCase();
      if(!/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$/.test(domain))throw new PublishingError(400,"invalid_email_domain");
      return domain;
    }))];
  }
  return result;
}
export async function canRead(store: PublishingStore, publication: Publication, request: Request) {
  if(!restricted(publication))return true;
  const token=request.headers.get("x-penned-reader")||"";
  if(!/^prg_[a-f0-9]{64}$/.test(token))return false;
  return object(await store.rpc("penned_reader_session",{p_action:"verify",p_publication:publication.id,p_epoch:publication.access_epoch||0,p_hash:await readerDigest(token)})).allowed===true;
}
export async function authorizeReader(store: PublishingStore, publication: Publication, request: Request, input: Record<string,unknown>, sendEmail: boolean) {
  if(!restricted(publication))throw new PublishingError(400,"access_not_required");
  // A persisted limit survives worker restarts. Both per-publication and per-client
  // limits run before expensive password verification or email delivery.
  for(const scope of ["publication",request.headers.get("x-forwarded-for")?.split(",")[0]||"unknown"]){
    const allowed=object(await store.rpc("penned_reader_session",{p_action:"limit",p_epoch:scope==="publication"?500:20,p_hash:await readerDigest(publication.id+":"+scope)})).allowed;
    if(!allowed)throw new PublishingError(429,"too_many_attempts");
  }
  const access=publication.access||{};
  if(access.passwordHash){
    const actual=await passwordHash(string(input.password??"",256),String(access.passwordSalt));
    let difference=actual.length^String(access.passwordHash).length;
    for(let i=0;i<actual.length;i++)difference|=actual.charCodeAt(i)^String(access.passwordHash).charCodeAt(i);
    if(difference)throw new PublishingError(403,"access_denied");
  }
  const emails=Array.isArray(access.emails)?access.emails:[],domains=Array.isArray(access.emailDomains)?access.emailDomains:[];
  if(emails.length||domains.length){
    const address=email(input.email);
    if(!emails.includes(address)&&!domains.includes(address.split("@")[1]))throw new PublishingError(403,"access_denied");
    if(!store.readerEmail)throw new PublishingError(503,"email_unavailable");
    if(sendEmail){await store.readerEmail(address);return {sent:true};}
    const verified=await store.readerEmail(address,string(input.code,12));
    if(verified!==address)throw new PublishingError(403,"access_denied");
  }else if(sendEmail)throw new PublishingError(400,"email_not_required");
  const token="prg_"+hex(crypto.getRandomValues(new Uint8Array(32)));
  await store.rpc("penned_reader_session",{p_action:"grant",p_publication:publication.id,p_epoch:publication.access_epoch||0,p_hash:await readerDigest(token)});
  return {readerToken:token};
}
