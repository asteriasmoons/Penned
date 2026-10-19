import { createDeleteAccountHandler } from "./handler.ts";
import { createSupabaseAuth } from "./supabase.ts";

Deno.serve(createDeleteAccountHandler(() =>
  createSupabaseAuth((name) => Deno.env.get(name))
));
