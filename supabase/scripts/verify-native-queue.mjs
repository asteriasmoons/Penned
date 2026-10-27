import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";
const args=process.argv.slice(2),ref=args[args.indexOf("--project-ref")+1];
assert.ok(args.includes("--confirm-live")&&/^[a-z]{20}$/.test(ref||""));
const keys=JSON.parse(execFileSync("supabase",["projects","api-keys","--project-ref",ref,"--reveal","--output","json"],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}));
const url=`https://${ref}.supabase.co`,key=keys.find(key=>key.type==="publishable")?.api_key,secret=keys.find(key=>key.name==="service_role")?.api_key;
assert.ok(key&&secret);
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}},admin=createClient(url,secret,options);
function checked(value){if(value.error)throw new Error(value.error.code||"Live fixture setup failed");return value.data;}
let user;
try{
  user=checked(await admin.auth.admin.createUser({email:`penned-native-queue-${crypto.randomUUID()}@example.com`,email_confirm:true,password:crypto.randomUUID()})).user;
  const link=checked(await admin.auth.admin.generateLink({type:"magiclink",email:user.email}));
  const auth=checked(await createClient(url,key,options).auth.verifyOtp({type:"magiclink",token_hash:link.properties.hashed_token}));
  const child=spawn("node",["Scripts/test-collections.mjs"],{cwd:fileURLToPath(new URL("../../",import.meta.url)),stdio:"inherit",env:{...process.env,PENNED_PUBLISHING_TESTS:"1",PENNED_LIVE_QUEUE_TOKEN:auth.session.access_token,PENNED_LIVE_QUEUE_USER:user.id,PENNED_LIVE_QUEUE_URL:url,PENNED_LIVE_QUEUE_KEY:key}});
  const code=await new Promise((resolve,reject)=>{child.on("error",reject);child.on("exit",resolve);});
  assert.equal(code,0,"Native live queue verification failed");
  console.log("PASS actual Swift publishing queue -> real Supabase -> public document/media -> saved automatic update -> revocation");
}finally{
  if(user){
    const owner=checked(await admin.rpc("penned_publishing_identity",{p_provider:"email",p_subject:user.id,p_auth_user:user.id}));
    const publications=checked(await admin.from("penned_publications").select("id").eq("owner_id",owner));
    if(publications.length){
      const media=checked(await admin.from("penned_publication_media").select("object_path").in("publication_id",publications.map(p=>p.id)));
      if(media.length)checked(await admin.storage.from("penned-publications").remove(media.map(m=>m.object_path)));
      checked(await admin.from("penned_publications").delete().eq("owner_id",owner));
    }
    checked(await admin.auth.admin.deleteUser(user.id));
    console.log("CLEANUP native live queue fixture account/publication/media removed");
  }
}
