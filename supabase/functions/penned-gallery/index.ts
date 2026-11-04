import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const headers = { "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS" };
const reply = (data: unknown, status = 200) => Response.json(data, { status, headers });
Deno.serve(async request => {
  try {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    const url = Deno.env.get("SUPABASE_URL")!;
    const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
    const key = keys ? JSON.parse(keys).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!url || !key) return reply({ error: "server_unavailable" }, 503);
    const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
    const path = new URL(request.url).pathname.split("/").filter(Boolean);
    const segment = path.indexOf("penned-gallery");
    const route = path.slice(segment + 1);
    if (segment < 0 || !["categories", "templates"].includes(route[0]) || route.length > 2) return reply({ error: "not_found" }, 404);
    const table = route[0] === "categories" ? "penned_gallery_categories" : "penned_gallery_templates";
    const id = route[1];
    if (id && !/^[0-9a-f-]{36}$/i.test(id)) return reply({ error: "invalid_id" }, 400);
    if (request.method === "GET") {
      const query = db.from(table).select(route[0] === "templates" && !id ? "id,category_id,title,description,revision,sort_order,created_at,updated_at" : "*");
      const result = id ? await query.eq("id", id).maybeSingle() : await query.order("sort_order");
      return result.error ? reply({ error: "catalog_unavailable" }, 503) : reply(result.data);
    }
    const bearer = request.headers.get("authorization")?.replace(/^Bearer /, "");
    if (!bearer || !/^ppa_[a-f0-9]{64}$/.test(bearer)) return reply({ error: "authentication_required" }, 401);
    const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(bearer))), x => x.toString(16).padStart(2, "0")).join("");
    const session = await db.rpc("penned_publishing_session", { p_action: "verify", p_hash: digest });
    // This session was issued only after Penned verified Sign in with Apple.
    // Authorize against the verified Apple subject itself; no gallery login
    // or second account authorization system is required.
    if (session.error || !session.data?.subject) return reply({ error: "authentication_required" }, 401);
    const adminSubject = Deno.env.get("PENNED_GALLERY_ADMIN_APPLE_SUBJECT");
    if (!adminSubject || session.data.subject !== adminSubject) return reply({ error: "forbidden" }, 403);
    if (request.method === "DELETE") {
      if (!id) return reply({ error: "invalid_id" }, 400);
      const result = await db.from(table).delete().eq("id", id);
      return result.error ? reply({ error: "delete_failed" }, 409) : reply({ deleted: true });
    }
    if (!["POST", "PUT"].includes(request.method) || (request.method === "PUT" && !id)) return reply({ error: "method_not_allowed" }, 405);
    const size = Number(request.headers.get("content-length") ?? "0");
    if (size > 20_000_000) return reply({ error: "body_too_large" }, 413);
    const input = await request.json();
    if (!input || typeof input !== "object") return reply({ error: "invalid_body" }, 400);
    const title = String(input.title ?? "").trim();
    if (!title || title.length > 160) return reply({ error: "invalid_title" }, 400);
    const values: Record<string, unknown> = { title, updated_at: new Date().toISOString() };
    if (route[0] === "templates") {
      if (typeof input.category_id !== "string" || !input.package || typeof input.package !== "object") return reply({ error: "invalid_package" }, 400);
      values.category_id = input.category_id;
      values.description = String(input.description ?? "").slice(0, 2000);
      values.package = input.package;
      if (request.method === "POST") {
        const templateID = String((input.package as Record<string, unknown>).galleryTemplateID ?? "");
        if (!/^[0-9a-f-]{36}$/i.test(templateID)) return reply({ error: "invalid_template_id" }, 400);
        values.id = templateID;
      }
      values.revision = Number(input.revision ?? 1);
      values.sort_order = Number(input.sort_order ?? 0);
    } else values.sort_order = Number(input.sort_order ?? 0);
    if (request.method === "PUT" && route[0] === "templates" &&
        (!Number.isInteger(input.expectedRevision) || Number(input.revision) !== Number(input.expectedRevision) + 1)) {
      return reply({ error: "revision_conflict" }, 409);
    }
    const result = request.method === "POST"
      ? await db.from(table).insert(values).select("*").single()
      : await (route[0] === "templates"
          ? db.from(table).update(values).eq("id", id!).eq("revision", input.expectedRevision)
          : db.from(table).update(values).eq("id", id!)).select("*").single();
    return result.error ? reply({ error: "write_failed" }, 409) : reply(result.data);
  } catch {
    return reply({ error: "gallery_unavailable" }, 503);
  }
});
