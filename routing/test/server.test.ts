/**
 * Integration tests for GET /route against the LOCAL Supabase stack.
 * Users sign in for real (local GoTrue), so RLS and visible_friends() are
 * exercised exactly as in production. Outdoor routing is faked, so Valhalla
 * is not needed. Skipped when local Supabase is not running.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { PROFILES } from "../src/profiles";
import { RateLimiter } from "../src/ratelimit";
import { createApp } from "../src/server";
import type { OutdoorRouter } from "../src/stitch";

// ---- local Supabase credentials (well-known local dev defaults) ----
function localEnv(): Record<string, string> {
  if (process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY && process.env.SUPABASE_SERVICE_ROLE_KEY) {
    return {
      API_URL: process.env.SUPABASE_URL,
      ANON_KEY: process.env.SUPABASE_ANON_KEY,
      SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    };
  }
  try {
    const out = Bun.spawnSync(["supabase", "status", "-o", "env"], { cwd: join(import.meta.dir, "..", "..") });
    const env: Record<string, string> = {};
    for (const line of out.stdout.toString().split("\n")) {
      const m = line.match(/^([A-Z_]+)="?(.*?)"?$/);
      if (m) env[m[1]!] = m[2]!;
    }
    return env;
  } catch {
    return {};
  }
}

const env = localEnv();
const URL_ = env.API_URL ?? "";
const ANON = env.ANON_KEY ?? "";
const SERVICE = env.SERVICE_ROLE_KEY ?? "";
const up = await (async () => {
  if (!URL_ || !ANON || !SERVICE) return false;
  try {
    return (await fetch(`${URL_}/auth/v1/health`, { headers: { apikey: ANON } })).ok;
  } catch {
    return false;
  }
})();

const svc = (path: string, init: RequestInit = {}) =>
  fetch(`${URL_}${path}`, {
    ...init,
    headers: {
      apikey: SERVICE,
      Authorization: `Bearer ${SERVICE}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });

async function createUser(name: string): Promise<{ id: string; token: string }> {
  const email = `${name.toLowerCase()}-${crypto.randomUUID().slice(0, 8)}@example.test`;
  const password = crypto.randomUUID();
  const res = await svc("/auth/v1/admin/users", {
    method: "POST",
    body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { display_name: name } }),
  });
  const user = (await res.json()) as { id: string };
  const login = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const { access_token } = (await login.json()) as { access_token: string };
  return { id: user.id, token: access_token };
}

// Ana is inside Davis Library (seeded from OSM), floor 3, at an exact point
// that is NOT the building centroid.
const ANA_EXACT = { lat: 35.91105, lng: -79.04795 };
const ME_POS = { lat: 35.90227, lng: -79.04327 }; // Hinton James

describe.skipIf(!up)("GET /route (local Supabase)", () => {
  let ana: { id: string; token: string };
  let me: { id: string; token: string };
  let grantId: string;
  const outdoorCalls: { lat: number; lng: number }[] = [];

  const fakeOutdoor: OutdoorRouter = async (from, to) => {
    outdoorCalls.push(to);
    return { shape: "fake", distanceM: 1000, durationS: 720, instructions: [`Walk to ${to.lat},${to.lng}`] };
  };

  const app = createApp({
    supabaseUrl: URL_,
    supabaseAnonKey: ANON,
    outdoor: fakeOutdoor,
    userLimiter: new RateLimiter(1000, 1000),
  });

  const get = (qs: string, token?: string) =>
    app(
      new Request(`http://routing.test/route?${qs}`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      }),
      "127.0.0.1",
    );

  const setGrant = (patch: Record<string, unknown>) =>
    svc(`/rest/v1/share_grants?id=eq.${grantId}`, { method: "PATCH", body: JSON.stringify(patch) });

  beforeAll(async () => {
    ana = await createUser("Ana");
    me = await createUser("Me");
    const g = await svc("/rest/v1/share_grants", {
      method: "POST",
      body: JSON.stringify({ owner_id: ana.id, viewer_id: me.id, status: "pending" }),
    });
    grantId = ((await g.json()) as { id: string }[])[0]!.id;
    // Separate inserts: PostgREST bulk inserts require identical keys per row.
    for (const row of [
      { user_id: ana.id, geog: `SRID=4326;POINT(${ANA_EXACT.lng} ${ANA_EXACT.lat})`, floor_est: 3, accuracy_m: 5 },
      { user_id: me.id, geog: `SRID=4326;POINT(${ME_POS.lng} ${ME_POS.lat})` },
    ]) {
      const res = await svc("/rest/v1/locations", { method: "POST", body: JSON.stringify(row) });
      if (!res.ok) throw new Error(`fixture insert failed: ${await res.text()}`);
    }
  });

  afterAll(async () => {
    for (const u of [ana, me]) if (u) await svc(`/auth/v1/admin/users/${u.id}`, { method: "DELETE" });
  });

  // ---------------- auth & validation ----------------
  test("401 without a token", async () => {
    expect((await get(`to=${crypto.randomUUID()}`)).status).toBe(401);
  });

  test("401 with a forged token", async () => {
    const forged = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl";
    expect((await get(`to=${crypto.randomUUID()}`, forged)).status).toBe(401);
  });

  test.each([
    ["to=not-a-uuid"],
    [`to=${crypto.randomUUID()}&profile=teleport`],
    [`to=${crypto.randomUUID()}&fromLat=91&fromLng=0`],
    [`to=${crypto.randomUUID()}&fromLat=35.9`],
    [`to=${crypto.randomUUID()}&fromLat=1e3&fromLng=0`],
    [`to=${crypto.randomUUID()}&debug=1`],
  ])("400 for invalid input: %s", async (qs) => {
    expect((await get(qs, me.token)).status).toBe(400);
  });

  // ---------------- refusal when not shared ----------------
  test("refuses while the grant is pending", async () => {
    await setGrant({ status: "pending" });
    const res = await get(`to=${ana.id}`, me.token);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_visible" });
  });

  test("refuses while the grant is paused", async () => {
    await setGrant({ status: "paused" });
    expect((await get(`to=${ana.id}`, me.token)).status).toBe(404);
  });

  test("refuses after sharing was stopped (revoked)", async () => {
    await setGrant({ status: "revoked" });
    expect((await get(`to=${ana.id}`, me.token)).status).toBe(404);
  });

  test("refuses while the owner has paused sharing globally", async () => {
    await setGrant({ status: "active" });
    await svc(`/rest/v1/profiles?id=eq.${ana.id}`, { method: "PATCH", body: JSON.stringify({ sharing_paused: true }) });
    expect((await get(`to=${ana.id}`, me.token)).status).toBe(404);
    await svc(`/rest/v1/profiles?id=eq.${ana.id}`, { method: "PATCH", body: JSON.stringify({ sharing_paused: false }) });
  });

  test("refuses a stranger (no grant at all)", async () => {
    const stranger = await createUser("Stranger");
    expect((await get(`to=${ana.id}`, stranger.token)).status).toBe(404);
    await svc(`/auth/v1/admin/users/${stranger.id}`, { method: "DELETE" });
  });

  // ---------------- success paths ----------------
  test("exact sharing: stair-free route to Ana's floor via the best entrance", async () => {
    await setGrant({ status: "active", precision: "exact", allow_floor: true });
    const res = await get(`to=${ana.id}&profile=avoid_stairs`, me.token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.to.precision).toBe("exact");
    expect(body.to.lat).toBeCloseTo(ANA_EXACT.lat, 6);
    expect(body.route.profile).toBe("avoid_stairs");
    expect(body.route.entrance.id).toBe("ent-main");
    expect(body.route.indoor).toEqual({ building: "davis-library", targetFloor: 3, verified: false });
    expect(body.route.steps).toContain("Take elevator A to floor 3");
    expect(body.route.steps.join(" ")).not.toMatch(/stairs/i);
  });

  test("building sharing never leaks exact coordinates (or a hidden floor)", async () => {
    await setGrant({ status: "active", precision: "building", allow_floor: false });
    outdoorCalls.length = 0;
    const res = await get(`to=${ana.id}`, me.token);
    expect(res.status).toBe(200);
    const raw = await res.text();
    const body = JSON.parse(raw);

    expect(body.to.precision).toBe("building");
    expect(body.to.place_name).toBe("Davis Library");
    expect(body.to.floor).toBeNull();
    expect(body.to.accuracy_m).toBeUndefined();
    // Not the exact point: at least ~5 m away from it.
    const dLat = Math.abs(body.to.lat - ANA_EXACT.lat);
    const dLng = Math.abs(body.to.lng - ANA_EXACT.lng);
    expect(dLat + dLng).toBeGreaterThan(0.00005);
    // The exact coordinates appear nowhere in the response...
    expect(raw).not.toContain(String(ANA_EXACT.lat));
    expect(raw).not.toContain(String(ANA_EXACT.lng));
    // ...and were never even handed to the outdoor router.
    for (const c of outdoorCalls) {
      expect(Math.abs(c.lat - ANA_EXACT.lat) + Math.abs(c.lng - ANA_EXACT.lng)).toBeGreaterThan(0.00005);
    }
    // Floor hidden => no indoor leg.
    expect(body.route.indoor).toBeNull();
  });

  test("rate limiting returns 429 with Retry-After", async () => {
    const limited = createApp({
      supabaseUrl: URL_,
      supabaseAnonKey: ANON,
      outdoor: fakeOutdoor,
      userLimiter: new RateLimiter(2, 0.01),
    });
    const call = () =>
      limited(new Request(`http://routing.test/route?to=${ana.id}`, { headers: { Authorization: `Bearer ${me.token}` } }));
    expect((await call()).status).not.toBe(429);
    expect((await call()).status).not.toBe(429);
    const third = await call();
    expect(third.status).toBe(429);
    expect(Number(third.headers.get("Retry-After"))).toBeGreaterThan(0);
  });
});

test("profiles exist for the app's toggle", () => {
  expect(Object.keys(PROFILES).sort()).toEqual(["avoid_stairs", "default", "fastest"]);
});
