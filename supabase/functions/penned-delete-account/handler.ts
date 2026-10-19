type AuthError = { status?: number };
type AuthUser = { id: string; role?: string; is_anonymous?: boolean };

export interface AccountAuth {
  getUser(jwt: string): Promise<{
    data: { user: AuthUser | null };
    error: AuthError | null;
  }>;
  deleteUser(id: string): Promise<{
    error: AuthError | null;
  }>;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const bearerJWT = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/i;
const maxBodyBytes = 1024;

function json(status: number, body: object, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
}

function unauthorized(): Response {
  return json(401, { error: "authentication_required" }, {
    "WWW-Authenticate": "Bearer",
  });
}

async function validateBody(request: Request): Promise<Response | null> {
  if (new URL(request.url).search) {
    return json(400, { error: "query_parameters_not_allowed" });
  }

  const length = request.headers.get("content-length");
  if (length !== null && !/^\d+$/.test(length)) {
    return json(400, { error: "invalid_body" });
  }
  if (length !== null && Number(length) > maxBodyBytes) {
    return json(413, { error: "body_too_large" });
  }

  let body = "";
  const reader = request.body?.getReader();
  if (reader) {
    let bytes = 0;
    const decoder = new TextDecoder("utf-8", { fatal: true });
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > maxBodyBytes) {
          void reader.cancel().catch(() => {});
          return json(413, { error: "body_too_large" });
        }
        body += decoder.decode(value, { stream: true });
      }
      body += decoder.decode();
    } catch {
      return json(400, { error: "invalid_body" });
    } finally {
      reader.releaseLock();
    }
  }

  if (!body.trim()) return null;
  const mediaType = request.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
  if (mediaType !== "application/json") {
    return json(415, { error: "json_body_required" });
  }
  try {
    const value: unknown = JSON.parse(body);
    if (value !== null && typeof value === "object" && !Array.isArray(value) &&
      Object.keys(value).length === 0) {
      return null;
    }
  } catch {
    // Only an absent body or an empty JSON object is part of this contract.
  }
  return json(400, { error: "empty_object_required" });
}

export function createDeleteAccountHandler(createAuth: () => AccountAuth) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json(405, { error: "method_not_allowed" }, { Allow: "POST" });
    }

    const authorization = request.headers.get("authorization");
    const token = authorization && authorization.length <= 16384
      ? bearerJWT.exec(authorization)?.[1]
      : undefined;
    if (!token) return unauthorized();

    let auth: AccountAuth;
    try {
      auth = createAuth();
    } catch {
      return json(500, { error: "server_configuration_error" });
    }

    let verified: Awaited<ReturnType<AccountAuth["getUser"]>>;
    try {
      // Token shape above is not verification. Auth must validate it on every POST.
      verified = await auth.getUser(token);
    } catch {
      return json(503, { error: "authentication_unavailable" });
    }
    if (verified.error) {
      const status = verified.error.status;
      if (status !== undefined && [400, 401, 403, 404, 422].includes(status)) {
        return unauthorized();
      }
      return json(503, { error: "authentication_unavailable" });
    }
    const user = verified.data.user;
    if (!user) return unauthorized();
    if (!uuid.test(user.id)) {
      return json(502, { error: "invalid_auth_response" });
    }
    if (user.role !== "authenticated" || user.is_anonymous === true) {
      return json(403, { error: "registered_user_required" });
    }

    const bodyError = await validateBody(request);
    if (bodyError) return bodyError;

    try {
      const deleted = await auth.deleteUser(user.id);
      if (deleted.error) return json(502, { error: "deletion_failed" });
    } catch {
      return json(502, { error: "deletion_failed" });
    }
    return json(200, { deletedUserID: user.id });
  };
}
