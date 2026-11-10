/**
 * Database and routing access AS THE OWNER. The agent mints a short-lived
 * (5 minute) Supabase access token for the owner's user id, so Row Level
 * Security and visible_friends() apply exactly as in the app. The agent never
 * uses the service-role key.
 */
export interface Friend {
  user_id: string;
  display_name: string;
  lat: number;
  lng: number;
  floor: number | null;
  place_slug: string | null;
  place_name: string | null;
  share_precision: "exact" | "building";
  recorded_at: string;
}

export interface MyLocation {
  lat: number;
  lng: number;
  floor: number | null;
  place_slug: string | null;
  recorded_at: string;
}

export interface RouteResult {
  route: { profile: string; durationS: number; distanceM: number; steps: string[]; indoor: unknown };
}

export interface LocationData {
  friends(): Promise<Friend[]>;
  me(): Promise<MyLocation | null>;
  route(toUserId: string, profile: string): Promise<RouteResult | { error: string }>;
}

const b64url = (data: string | ArrayBuffer) =>
  Buffer.from(typeof data === "string" ? data : new Uint8Array(data)).toString("base64url");

/** HS256 JWT for `sub`, role authenticated, valid for `ttlS` seconds. */
export async function mintUserJwt(secret: string, sub: string, ttlS = 300, now = Date.now()): Promise<string> {
  const iat = Math.floor(now / 1000);
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64url(
    JSON.stringify({ sub, role: "authenticated", aud: "authenticated", iat, exp: iat + ttlS, iss: "mapchat-agent" }),
  );
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64url(sig)}`;
}

export class SupabaseOwnerData implements LocationData {
  constructor(
    private readonly cfg: {
      supabaseUrl: string;
      supabaseAnonKey: string;
      supabaseJwtSecret: string;
      ownerUserId: string;
      routingUrl: string;
    },
  ) {}

  private token() {
    return mintUserJwt(this.cfg.supabaseJwtSecret, this.cfg.ownerUserId);
  }

  private async rpc<T>(fn: string): Promise<T> {
    const res = await fetch(`${this.cfg.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: this.cfg.supabaseAnonKey,
        Authorization: `Bearer ${await this.token()}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (!res.ok) throw new Error(`rpc ${fn}: HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  friends() {
    return this.rpc<Friend[]>("visible_friends");
  }

  async me() {
    return (await this.rpc<MyLocation[]>("my_latest_location"))[0] ?? null;
  }

  async route(toUserId: string, profile: string) {
    const url = new URL("/route", this.cfg.routingUrl);
    url.searchParams.set("to", toUserId);
    url.searchParams.set("profile", profile);
    const res = await fetch(url, { headers: { Authorization: `Bearer ${await this.token()}` } });
    const body = (await res.json()) as RouteResult | { error: string };
    return res.ok ? body : { error: "error" in body ? body.error : `HTTP ${res.status}` };
  }
}
