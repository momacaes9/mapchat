/**
 * MapChat demo: seeds two LOCAL demo accounts and simulates the roommate
 * ("Ana") walking across UNC so the app, /route and the agent update live.
 *
 *   bun scripts/demo/simulate.ts [--interval 3] [--steps 0] [--check]
 *
 * --steps N   stop after N location updates (0 = walk the whole route)
 * --check     after a few steps, verify "you" see Ana moving through
 *             visible_friends() and exit non-zero if not (used as a smoke test)
 *
 * Local stack only: it reads keys from `supabase status` and refuses to run
 * against anything that is not localhost.
 */
const args = process.argv.slice(2);
const opt = (name: string, dflt: number) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? Number(args[i + 1]) : dflt;
};
const INTERVAL_S = opt("interval", 3);
const MAX_STEPS = opt("steps", 0);
const CHECK = args.includes("--check");

// ---------------------------------------------------------------- env
function supabaseEnv(): Record<string, string> {
  const out = Bun.spawnSync(["supabase", "status", "-o", "env"], { cwd: `${import.meta.dir}/../..` });
  const env: Record<string, string> = {};
  for (const line of out.stdout.toString().split("\n")) {
    const m = line.match(/^([A-Z_]+)="?(.*?)"?$/);
    if (m) env[m[1]!] = m[2]!;
  }
  return env;
}
const env = supabaseEnv();
const API = env.API_URL ?? "";
const ANON = env.ANON_KEY ?? "";
const SERVICE = env.SERVICE_ROLE_KEY ?? "";
const VALHALLA = process.env.VALHALLA_URL ?? "http://localhost:8002";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(API) || !ANON || !SERVICE) {
  console.error("Local Supabase is not running (or not on localhost). Run `supabase start` first.");
  process.exit(1);
}

// ---------------------------------------------------------------- helpers
const svc = (path: string, init: RequestInit = {}) =>
  fetch(`${API}${path}`, {
    ...init,
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
const asUser = (token: string, path: string, init: RequestInit = {}) =>
  fetch(`${API}${path}`, {
    ...init,
    headers: { apikey: ANON, Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });

const DEMO_PASSWORD = "mapchat-local-demo-only";

async function ensureUser(email: string, name: string): Promise<string> {
  const list = (await (await svc(`/auth/v1/admin/users?per_page=1000`)).json()) as { users: { id: string; email: string }[] };
  const existing = list.users.find((u) => u.email === email);
  if (existing) return existing.id;
  const res = await svc("/auth/v1/admin/users", {
    method: "POST",
    body: JSON.stringify({ email, password: DEMO_PASSWORD, email_confirm: true, user_metadata: { display_name: name } }),
  });
  if (!res.ok) throw new Error(`create ${email}: ${await res.text()}`);
  return ((await res.json()) as { id: string }).id;
}

async function signIn(email: string): Promise<string> {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: DEMO_PASSWORD }),
  });
  if (!res.ok) throw new Error(`sign in ${email}: ${await res.text()}`);
  return ((await res.json()) as { access_token: string }).access_token;
}

async function upload(token: string, userId: string, lat: number, lng: number, floor: number | null) {
  const body: Record<string, unknown> = { user_id: userId, geog: `SRID=4326;POINT(${lng} ${lat})`, accuracy_m: 6 };
  if (floor !== null) body.floor_est = floor;
  const res = await asUser(token, "/rest/v1/locations", { method: "POST", body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`upload: ${await res.text()}`);
}

function decodePolyline6(s: string): { lat: number; lng: number }[] {
  const pts: { lat: number; lng: number }[] = [];
  let i = 0, lat = 0, lng = 0;
  const next = () => {
    let r = 0, shift = 0, b: number;
    do {
      b = s.charCodeAt(i++) - 63;
      r |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return r & 1 ? ~(r >> 1) : r >> 1;
  };
  while (i < s.length) {
    lat += next();
    lng += next();
    pts.push({ lat: lat / 1e6, lng: lng / 1e6 });
  }
  return pts;
}

/** Stair-free walking path from Valhalla, or a straight line if it isn't running. */
async function walkPath(from: { lat: number; lng: number }, to: { lat: number; lng: number }) {
  try {
    const res = await fetch(`${VALHALLA}/route`, {
      method: "POST",
      body: JSON.stringify({
        locations: [{ lat: from.lat, lon: from.lng }, { lat: to.lat, lon: to.lng }],
        costing: "pedestrian",
        costing_options: { pedestrian: { step_penalty: 3600 } },
      }),
      signal: AbortSignal.timeout(5000),
    });
    const json = (await res.json()) as { trip: { legs: { shape: string }[] } };
    return { pts: decodePolyline6(json.trip.legs[0]!.shape), source: "Valhalla (stair-free)" };
  } catch {
    const pts = Array.from({ length: 25 }, (_, k) => ({
      lat: from.lat + ((to.lat - from.lat) * k) / 24,
      lng: from.lng + ((to.lng - from.lng) * k) / 24,
    }));
    return { pts, source: "straight line (Valhalla not running)" };
  }
}

/** Resample a path so consecutive points are ~`stepM` metres apart. */
function resample(pts: { lat: number; lng: number }[], stepM: number) {
  const out = [pts[0]!];
  let carry = 0;
  for (let k = 1; k < pts.length; k++) {
    const a = pts[k - 1]!, b = pts[k]!;
    const d = Math.hypot((b.lat - a.lat) * 111_320, (b.lng - a.lng) * 111_320 * Math.cos((a.lat * Math.PI) / 180));
    let pos = stepM - carry;
    while (pos <= d) {
      out.push({ lat: a.lat + ((b.lat - a.lat) * pos) / d, lng: a.lng + ((b.lng - a.lng) * pos) / d });
      pos += stepM;
    }
    carry = (carry + d) % stepM;
  }
  out.push(pts.at(-1)!);
  return out;
}

// ---------------------------------------------------------------- scenario
const DAVIS_INSIDE = { lat: 35.91105, lng: -79.04795 }; // inside Davis Library
const DAVIS_DOOR = { lat: 35.9108025, lng: -79.0483783 }; // OSM main entrance
const HINTON_JAMES = { lat: 35.90227, lng: -79.04327 }; // "you"

const youId = await ensureUser("demo-you@example.test", "You (demo)");
const anaId = await ensureUser("demo-ana@example.test", "Ana (demo)");
const youTok = await signIn("demo-you@example.test");
const anaTok = await signIn("demo-ana@example.test");

// Ana shares with you by her own choice; you share back at building level.
await asUser(anaTok, "/rest/v1/rpc/share_with", { method: "POST", body: JSON.stringify({ contact: "demo-you@example.test", share_precision: "exact" }) });
await asUser(youTok, "/rest/v1/rpc/share_with", { method: "POST", body: JSON.stringify({ contact: "demo-ana@example.test", share_precision: "building" }) });
await upload(youTok, youId, HINTON_JAMES.lat, HINTON_JAMES.lng, null);

console.log(`
MapChat demo (local only)
  You : demo-you@example.test   (${youId})
  Ana : demo-ana@example.test   (${anaId})
  Sign in to the app in the Simulator as demo-you@example.test: tap "Send code",
  then read the 6-digit code at http://127.0.0.1:54324 (Mailpit).
  Agent (mock iMessage):  OWNER_USER_ID=${youId}  (see scripts/demo.sh output)
`);

// 1) Ana in Davis Library: floor 3 -> 2 -> 1 (elevator), 2) walks to Hinton James.
const steps: { lat: number; lng: number; floor: number | null; note: string }[] = [
  { ...DAVIS_INSIDE, floor: 3, note: "in Davis Library, floor 3" },
  { ...DAVIS_INSIDE, floor: 3, note: "in Davis Library, floor 3" },
  { ...DAVIS_INSIDE, floor: 2, note: "elevator down: floor 2" },
  { ...DAVIS_INSIDE, floor: 1, note: "floor 1, leaving" },
];
const { pts, source } = await walkPath(DAVIS_DOOR, HINTON_JAMES);
for (const p of resample(pts, 40)) steps.push({ ...p, floor: null, note: "walking" });
console.log(`Walking path: ${source}, ${steps.length} updates every ${INTERVAL_S}s.\n`);

const limit = MAX_STEPS > 0 ? Math.min(MAX_STEPS, steps.length) : steps.length;
const seen: string[] = [];
for (let k = 0; k < limit; k++) {
  const s = steps[k]!;
  await upload(anaTok, anaId, s.lat, s.lng, s.floor);
  const dist = Math.round(Math.hypot((s.lat - HINTON_JAMES.lat) * 111_320, (s.lng - HINTON_JAMES.lng) * 90_000));
  console.log(`[${String(k + 1).padStart(3)}/${limit}] Ana ${s.note.padEnd(26)} ${s.lat.toFixed(5)},${s.lng.toFixed(5)}  ~${dist} m from you`);

  if (CHECK) {
    const vf = (await (await asUser(youTok, "/rest/v1/rpc/visible_friends", { method: "POST", body: "{}" })).json()) as { user_id: string; lat: number; lng: number }[];
    const a = vf.find((f) => f.user_id === anaId);
    if (a) seen.push(`${a.lat.toFixed(5)},${a.lng.toFixed(5)}`);
  }
  if (k < limit - 1) await Bun.sleep(INTERVAL_S * 1000);
}

if (CHECK) {
  const distinct = new Set(seen).size;
  if (seen.length < limit || distinct < 2) {
    console.error(`CHECK FAILED: you saw Ana ${seen.length}/${limit} times at ${distinct} distinct positions`);
    process.exit(1);
  }
  console.log(`CHECK OK: you saw Ana move through ${distinct} positions via visible_friends().`);
}
