import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import type { AccountAuth } from "./handler.ts";

export function createSupabaseAuth(
  getEnv: (name: string) => string | undefined,
  fetchImplementation: typeof fetch = fetch,
): AccountAuth {
  const url = getEnv("SUPABASE_URL");
  const secretKeys = getEnv("SUPABASE_SECRET_KEYS");
  // Prefer the modern server secret. Legacy hosted/local environments also work.
  const key = secretKeys !== undefined
    ? JSON.parse(secretKeys).default
    : getEnv("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || typeof key !== "string" || !key.trim()) {
    throw new Error("Missing server Auth configuration");
  }

  // A fresh, stateless server client: never install caller headers or sessions.
  const client = createClient(url, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      fetch: (input, init) => fetchImplementation(input, {
        ...init,
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      }),
    },
  });
  return {
    getUser: (jwt) => client.auth.getUser(jwt),
    deleteUser: (id) => client.auth.admin.deleteUser(id, false),
  };
}
