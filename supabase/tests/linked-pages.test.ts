import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeDocument, publicDocument } from "../functions/penned-publishing/contract.ts";
import { createPublishingHandler } from "../functions/penned-publishing/handler.ts";
import type { PublishingStore } from "../functions/penned-publishing/handler.ts";

const child="page-"+"a".repeat(32),grandchild="page-"+"b".repeat(32);
const paragraph=(text:string)=>({type:"paragraph",content:[{type:"text",text}]});
const link=(targetPage:string)=>({type:"publishedPage",attrs:{preview:{title:"Visible page",excerpt:"Preview",targetPage}}});
const doc=(content:unknown[],media:unknown[]=[])=>({schemaVersion:1,title:"Saved page",appearance:{},content:{type:"doc",content},media});
function bundle(){
  const asset={id:crypto.randomUUID(),name:"child.txt",mimeType:"text/plain",size:5,sha256:"a".repeat(64)};
  return {...doc([link(child)],[asset]),linkedPages:[
    {key:child,parentKey:"root",document:doc([paragraph("Full child body"),link(grandchild),link("root")])},
    {key:grandchild,parentKey:child,document:doc([paragraph("Full grandchild body"),{type:"attachment",attrs:{file:{mediaID:asset.id,kind:"file"}}}],[asset])}]};
}
test("a single publication approves full linked pages and shared media without exposing bodies while following is off",()=>{
  const value=sanitizeDocument(bundle());assert.equal(value.linkedPages!.length,2);
  const hidden=publicDocument(value,{allowFollowLinkedContent:false});
  assert.equal(hidden.linkedPages,undefined);assert.equal(hidden.media.length,0);
  assert.doesNotMatch(JSON.stringify(hidden),/Full child body|Full grandchild body|targetPage/);
  assert.match(JSON.stringify(publicDocument(value,{allowFollowLinkedContent:true})),/Full grandchild body/);
  assert.equal(value.linkedPages![1].parentKey,child);
});
test("unapproved destinations, unreachable pages, hierarchy cycles and media outside the parent manifest fail closed",()=>{
  const unknown=bundle();(unknown.content.content[0] as any).attrs.preview.targetPage="page-"+"f".repeat(32);
  assert.throws(()=>sanitizeDocument(unknown),/invalid_linked_page/);
  const orphan=bundle();orphan.content.content=[];assert.throws(()=>sanitizeDocument(orphan),/unreferenced_linked_page/);
  const cycle=bundle();cycle.linkedPages[0].parentKey=grandchild;assert.throws(()=>sanitizeDocument(cycle),/invalid_linked_page/);
  const media=bundle();media.media=[];assert.throws(()=>sanitizeDocument(media),/missing_media/);
  const forged=bundle();forged.linkedPages[1].document.media[0].sha256="f".repeat(64);
  // Use a separate object because root and child descriptors can share an in-memory reference.
  forged.media=forged.media.map(asset=>({...asset,sha256:"a".repeat(64)}));assert.throws(()=>sanitizeDocument(forged),/missing_media/);
  const nested=bundle();(nested.linkedPages[0].document as any).linkedPages=[];assert.throws(()=>sanitizeDocument(nested),/invalid_linked_page/);
});
test("child reads inherit one parent gate, expiration, link identity and revocation; disabling following also blocks child-only media",async()=>{
  const document=sanitizeDocument(bundle()),id=crypto.randomUUID();
  const publication={id,active:true,version:7,settings:{allowFollowLinkedContent:true},document,access:{} as Record<string,unknown>};
  let downloads=0,reads=0;
  const store={async publicPublication(token:string){reads++;return token==="a1b2c3d4"?publication:null;},async media(){return {id:document.media[0].id,publication_id:id,mime_type:"text/plain",name:"child.txt",object_path:"parent/child",retired:false};},async download(){downloads++;return new Response("bytes");},async rpc(_name:string,args:Record<string,unknown>){assert.equal(args.p_publication,id);return {allowed:true};}} as unknown as PublishingStore;
  const handler=createPublishingHandler({store,publicBaseURL:"https://penned.im/p",async verifyApple(){throw new Error("unused");}});
  const read=(path="",headers:Record<string,string>={})=>handler(new Request("https://project.supabase.co/penned-publishing/public/a1b2c3d4"+path,{headers}));
  const root=await (await read()).json();assert.equal(root.document.linkedPages,undefined);
  const frames=await (await read("?snapshots=1")).json();assert.equal(frames.snapshots.length,2);
  assert.equal((await read("?snapshots=1&private=true")).status,400);
  const selected=await (await read("/pages/"+grandchild)).json();assert.equal(selected.document.content.content[0].content[0].text,"Full grandchild body");
  assert.equal(selected.navigation.parentPage,child);assert.equal(selected.version,7);
  const media="/media/"+document.media[0].id;assert.equal((await read(media)).status,200);
  publication.settings.allowFollowLinkedContent=false;assert.equal((await read("/pages/"+child)).status,404);assert.equal((await read(media)).status,404);assert.equal(downloads,1);
  publication.settings.allowFollowLinkedContent=true;publication.access={passwordHash:"protected"};assert.equal((await read("/pages/"+child)).status,401);
  assert.equal((await read("?snapshots=1")).status,401);
  const headers={"x-penned-reader":"prg_"+"d".repeat(64)};assert.equal((await read("/pages/"+child,headers)).status,200);
  publication.active=false;assert.equal((await read("/pages/"+child,headers)).status,404);assert.equal((await read(media,headers)).status,404);
  publication.active=true;(publication.settings as any).expiresAt="2000-01-01T00:00:00Z";assert.equal((await read("/pages/"+child,headers)).status,404);
  assert.ok(reads>5);
});
