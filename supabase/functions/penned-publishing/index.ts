import { createPublishingHandler } from "./handler.ts";
import { appleVerifier, createPublishingStore } from "./supabase.ts";

Deno.serve(async request => {
  try {
    const project = Deno.env.get("SUPABASE_URL")!;
    return await createPublishingHandler({
      store: createPublishingStore(name => Deno.env.get(name)),
      verifyApple: (token, nonce) => appleVerifier((Deno.env.get("PENNED_APPLE_AUDIENCES") ?? "").split(",").map(value => value.trim()).filter(Boolean))(token, nonce),
      publicBaseURL: Deno.env.get("PENNED_PUBLISH_BASE_URL") ?? "https://penned.im/p",
    })(request);
  } catch {
    return Response.json({ error: "server_configuration_error" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
});
