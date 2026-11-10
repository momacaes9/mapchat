/**
 * MapChat routing service.
 *
 *   GET /route?to=<user uuid>&profile=avoid_stairs[&fromLat=..&fromLng=..]
 *   Authorization: Bearer <Supabase access token>
 *
 * Privacy: the target is looked up ONLY through visible_friends(), called with
 * the caller's own JWT. If sharing is pending, paused, stopped or never
 * existed, the target is simply not in that list and the request is refused
 * with 404 (same answer in every case, so nothing about the grant leaks).
 * Building-level sharing returns the building centroid, never raw coordinates.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { BuildingGraph } from "./indoor/types";
import { type ProfileName, PROFILES } from "./profiles";
import { RateLimiter } from "./ratelimit";
import { type OutdoorRouter, routeToDestination } from "./stitch";
import { AuthError, SupabaseAsUser } from "./supabase";
import { routeOutdoor } from "./valhalla";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

export interface AppDeps {
  supabaseUrl: string;
  supabaseAnonKey: string;
  outdoor?: OutdoorRouter;
  buildings?: Map<string, BuildingGraph>;
  /** Per-IP limit (before auth) and per-user limit (after auth). */
  ipLimiter?: RateLimiter;
  userLimiter?: RateLimiter;
}

export function loadBuildings(dir = join(import.meta.dir, "..", "buildings")): Map<string, BuildingGraph> {
  const map = new Map<string, BuildingGraph>();
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
    const g = JSON.parse(readFileSync(join(dir, f), "utf8")) as BuildingGraph;
    map.set(g.building, g);
  }
  return map;
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });

/** Reads the `sub` claim WITHOUT verifying; used only as a rate-limit key. */
function unverifiedSub(token: string): string | null {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1]!, "base64url").toString("utf8"));
    return typeof payload.sub === "string" && UUID.test(payload.sub) ? payload.sub : null;
  } catch {
    return null;
  }
}

function parseCoord(v: string | null, min: number, max: number): number | null | "invalid" {
  if (v === null) return null;
  if (!/^-?\d{1,3}(\.\d{1,10})?$/.test(v)) return "invalid";
  const n = Number(v);
  return n >= min && n <= max ? n : "invalid";
}

export function createApp(deps: AppDeps) {
  const outdoor = deps.outdoor ?? routeOutdoor;
  const buildings = deps.buildings ?? loadBuildings();
  const ipLimiter = deps.ipLimiter ?? new RateLimiter(60, 1); // 60 burst, 1/s
  const userLimiter = deps.userLimiter ?? new RateLimiter(20, 20 / 60); // 20 burst, 20/min

  return async function handle(req: Request, ip = "unknown"): Promise<Response> {
    const url = new URL(req.url);

    if (url.pathname === "/health") return json(200, { ok: true });
    if (url.pathname !== "/route") return json(404, { error: "not_found" });
    if (req.method !== "GET") return json(405, { error: "method_not_allowed" }, { Allow: "GET" });

    if (!ipLimiter.take(ip)) {
      return json(429, { error: "rate_limited" }, { "Retry-After": String(ipLimiter.retryAfter(ip)) });
    }

    // --- auth ---
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    if (!token || token.length > 4096 || !JWT.test(token)) return json(401, { error: "unauthorized" });

    const userKey = unverifiedSub(token) ?? `ip:${ip}`;
    if (!userLimiter.take(userKey)) {
      return json(429, { error: "rate_limited" }, { "Retry-After": String(userLimiter.retryAfter(userKey)) });
    }

    // --- input validation ---
    const allowed = new Set(["to", "profile", "fromLat", "fromLng"]);
    for (const k of url.searchParams.keys()) {
      if (!allowed.has(k)) return json(400, { error: "invalid_request", detail: `unknown parameter ${k}` });
    }
    const to = url.searchParams.get("to") ?? "";
    if (!UUID.test(to)) return json(400, { error: "invalid_request", detail: "to must be a user id (uuid)" });

    const profileName = (url.searchParams.get("profile") ?? "avoid_stairs") as ProfileName;
    if (!(profileName in PROFILES)) {
      return json(400, { error: "invalid_request", detail: "profile must be default, avoid_stairs or fastest" });
    }
    const profile = PROFILES[profileName];

    const fromLat = parseCoord(url.searchParams.get("fromLat"), -90, 90);
    const fromLng = parseCoord(url.searchParams.get("fromLng"), -180, 180);
    if (fromLat === "invalid" || fromLng === "invalid" || (fromLat === null) !== (fromLng === null)) {
      return json(400, { error: "invalid_request", detail: "fromLat and fromLng must both be valid coordinates" });
    }

    // --- data, as the caller ---
    const db = new SupabaseAsUser(deps.supabaseUrl, deps.supabaseAnonKey, token);
    try {
      const friends = await db.visibleFriends();
      const friend = friends.find((f) => f.user_id === to);
      if (!friend) return json(404, { error: "not_visible" });

      let from: { lat: number; lng: number };
      if (fromLat !== null && fromLng !== null) {
        from = { lat: fromLat, lng: fromLng };
      } else {
        const me = await db.myLatestLocation();
        if (!me) return json(409, { error: "no_own_location", detail: "send fromLat/fromLng or upload a location first" });
        from = { lat: me.lat, lng: me.lng };
      }

      const route = await routeToDestination(
        from,
        { lat: friend.lat, lng: friend.lng, placeSlug: friend.place_slug, floor: friend.floor },
        profile,
        outdoor,
        buildings,
      );

      return json(200, {
        to: {
          user_id: friend.user_id,
          display_name: friend.display_name,
          // Exactly what visible_friends() returned: centroid/rounded for
          // building-level sharing, real position only for exact sharing.
          lat: friend.lat,
          lng: friend.lng,
          floor: friend.floor,
          place_name: friend.place_name,
          precision: friend.share_precision,
          recorded_at: friend.recorded_at,
        },
        route,
      });
    } catch (err) {
      if (err instanceof AuthError) return json(401, { error: "unauthorized" });
      console.error("route error:", err instanceof Error ? err.message : err);
      return json(502, { error: "upstream_error" });
    }
  };
}

if (import.meta.main) {
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("Set SUPABASE_URL and SUPABASE_ANON_KEY (see .env.example).");
    process.exit(1);
  }
  const handle = createApp({ supabaseUrl, supabaseAnonKey });
  const port = Number(process.env.PORT ?? 8787);
  Bun.serve({
    port,
    fetch: (req, server) => handle(req, server.requestIP(req)?.address ?? "unknown"),
  });
  console.log(`routing service on http://localhost:${port}`);
}
