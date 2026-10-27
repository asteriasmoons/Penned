import assert from "node:assert/strict";
import test from "node:test";
import { createPublishingHandler } from "../functions/penned-publishing/handler.ts";
import type { PublishingStore } from "../functions/penned-publishing/handler.ts";
import { PublishingError } from "../functions/penned-publishing/contract.ts";
import { sanitizeDocument } from "../functions/penned-publishing/contract.ts";

test("hosted gateway and external URLs reach the same authenticated routes", async () => {
  let exchanges = 0;
  const handler = createPublishingHandler({
    store: {} as PublishingStore, publicBaseURL: "https://example.com/public",
    async verifyApple() { exchanges++; throw new PublishingError(401, "invalid_apple_credential"); },
  });
  for (const prefix of ["/penned-publishing", "/functions/v1/penned-publishing"]) {
    const response = await handler(new Request("https://project.supabase.co" + prefix + "/auth/apple", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identityToken: "invalid", nonce: "a".repeat(64) }),
    }));
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error, "invalid_apple_credential");
    assert.equal((await handler(new Request("https://project.supabase.co" + prefix + "/publications", { method: "POST" }))).status, 401);
  }
  assert.equal(exchanges, 2);
  for (const path of ["/other/penned-publishing/auth/apple", "/penned-publishing-evil/auth/apple", "/auth/apple"]) {
    assert.equal((await handler(new Request("https://project.supabase.co" + path))).status, 404);
  }
});
test("avatar bytes require an active publication, visible author and the same reader access gate",async()=>{
  const id=crypto.randomUUID(),asset={id,name:"author-avatar.png",mimeType:"image/png",size:8,sha256:"a".repeat(64)};
  const document=sanitizeDocument({schemaVersion:1,title:"Selected",appearance:{},content:{type:"doc",content:[]},media:[asset],authorAvatar:{mediaID:id}});
  const publication={id:crypto.randomUUID(),active:true,version:1,settings:{showAuthor:true},access:{},document};let downloads=0;
  const handler=createPublishingHandler({store:{async publicPublication(){return publication;},async media(){return {id,publication_id:publication.id,mime_type:"image/png",name:asset.name,object_path:"scoped/avatar",retired:false};},async download(){downloads++;return new Response(new Uint8Array([137,80,78,71,13,10,26,10]));}} as unknown as PublishingStore,publicBaseURL:"https://penned.im/p",async verifyApple(){throw new Error("unused");}});
  const request=()=>handler(new Request('https://project.supabase.co/penned-publishing/public/a1b2c3d4/media/'+id));
  assert.equal((await request()).status,200);assert.equal(downloads,1);
  publication.settings.showAuthor=false;assert.equal((await request()).status,404);assert.equal(downloads,1);
  publication.settings.showAuthor=true;publication.active=false;assert.equal((await request()).status,404);
  publication.active=true;publication.access={passwordHash:"protected"} as any;assert.equal((await request()).status,401);assert.equal(downloads,1);
});
