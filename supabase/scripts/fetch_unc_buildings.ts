/**
 * Generates supabase/seed.sql with UNC Chapel Hill building footprints from
 * OpenStreetMap (via the public Overpass API, no key required).
 *
 *   bun supabase/scripts/fetch_unc_buildings.ts
 *
 * Every building is inserted with verified = false: floor counts, floor
 * heights and entrances must be checked on site before routing relies on them.
 * Map data © OpenStreetMap contributors, ODbL.
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";

// UNC main campus bounding box (south, west, north, east).
const BBOX = "35.895,-79.065,35.920,-79.035";

// Target buildings: slug, display name, regex matched against the OSM name.
// Ram Village is several buildings in OSM, so every match becomes its own row.
//
// `prefer` pins a specific OSM object when a building is split into parts
// (the Student Union relation is the outline that contains all its parts).
// `floors` overrides the level count; `source` records where it came from.
// Anything not from an official UNC source is a best guess and stays
// verified = false.
type Target = {
  slug: string;
  name: string;
  match: RegExp;
  multi?: boolean;
  prefer?: { type: "way" | "relation"; id: number };
  floors?: { n: number; source: string };
};
const TARGETS: Target[] = [
  {
    slug: "davis-library", name: "Davis Library", match: /davis library/i,
    floors: { n: 8, source: "official: library.unc.edu (Davis floors 1-8)" },
  },
  { slug: "undergraduate-library", name: "Undergraduate Library", match: /undergraduate library/i },
  {
    slug: "student-union", name: "Student Union", match: /(student union|carolina union|frank porter graham)/i,
    // way/1420775578 is the full outline; the parts are separate building:part ways.
    // Its level count lives on the 3D-building relation 324644.
    prefer: { type: "way", id: 1420775578 },
    floors: { n: 3, source: "osm:building:levels on relation/324644" },
  },
  {
    slug: "ram-village", name: "Ram Village", match: /ram village/i, multi: true,
    floors: { n: 5, source: "best guess (no official source found)" },
  },
  { slug: "hinton-james", name: "Hinton James", match: /hinton james/i },
  { slug: "gardner-hall", name: "Gardner Hall", match: /^gardner hall/i },
  { slug: "phillips-hall", name: "Phillips Hall", match: /^phillips hall/i },
  {
    slug: "hamilton-hall", name: "Hamilton Hall", match: /^hamilton hall/i,
    floors: { n: 7, source: "best guess (no official source found)" },
  },
  // Current dorm: waiting for the name (docs/QUESTIONS.md). Add it like:
  // { slug: "my-dorm", name: "My Dorm", match: /^exact osm name/i },
];

const ENDPOINTS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];

type OsmEl = {
  type: "way" | "relation";
  id: number;
  tags: Record<string, string>;
  geometry?: { lat: number; lon: number }[];
  members?: { type: string; role: string; geometry?: { lat: number; lon: number }[] }[];
};

async function overpass(query: string): Promise<OsmEl[]> {
  let wait = 5_000;
  for (let attempt = 1; attempt <= 6; attempt++) {
    const url = ENDPOINTS[(attempt - 1) % ENDPOINTS.length]!;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "User-Agent": "mapchat-seed/0.1", "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ data: query }),
      });
      const text = await res.text();
      if (res.ok && text.trimStart().startsWith("{")) return JSON.parse(text).elements;
      console.error(`attempt ${attempt} (${url}): HTTP ${res.status}`);
    } catch (err) {
      console.error(`attempt ${attempt} (${url}): ${err}`);
    }
    await Bun.sleep(wait);
    wait *= 2;
  }
  throw new Error("Overpass unavailable after 6 attempts");
}

/** Closed rings as WKT "(lon lat, ...)" lists. */
function rings(el: OsmEl): string[] {
  const toRing = (g: { lat: number; lon: number }[]) => {
    const pts = g.map((p) => `${p.lon} ${p.lat}`);
    if (pts[0] !== pts.at(-1)) pts.push(pts[0]!);
    return `(${pts.join(", ")})`;
  };
  if (el.type === "way" && el.geometry) return [toRing(el.geometry)];
  // Relations: use outer members only (good enough for footprints).
  return (el.members ?? [])
    .filter((m) => m.role === "outer" && m.geometry && m.geometry.length >= 3)
    .map((m) => toRing(m.geometry!));
}

/** Rough planar area in degrees², only used to rank candidate outlines. */
function approxArea(el: OsmEl): number {
  const pts = el.type === "way" ? [el.geometry ?? []]
    : (el.members ?? []).filter((m) => m.role === "outer").map((m) => m.geometry ?? []);
  return pts.reduce((sum, ring) => {
    let a = 0;
    for (let i = 0; i < ring.length - 1; i++) a += ring[i]!.lon * ring[i + 1]!.lat - ring[i + 1]!.lon * ring[i]!.lat;
    return sum + Math.abs(a / 2);
  }, 0);
}

const sqlStr = (s: string) => `'${s.replaceAll("'", "''")}'`;

const names = TARGETS.map((t) => t.match.source.replace(/^\^/, "")).join("|");
const query = `[out:json][timeout:60];
(
  way["building"]["name"~"${names}",i](${BBOX});
  relation["building"]["name"~"${names}",i](${BBOX});
);
out geom tags;`;

const elements = await overpass(query);
const rows: string[] = [];
const missing: string[] = [];

for (const t of TARGETS) {
  const hits = elements.filter((e) => t.match.test(e.tags.name ?? "") && rings(e).length > 0);
  if (hits.length === 0) {
    missing.push(t.name);
    continue;
  }
  const pinned = t.prefer && hits.find((e) => e.type === t.prefer!.type && e.id === t.prefer!.id);
  // Otherwise prefer the biggest outline (a whole building over one of its parts).
  const byArea = [...hits].sort((a, b) => approxArea(b) - approxArea(a));
  const chosen = t.multi ? hits : [pinned ?? byArea[0]!];
  chosen.forEach((el, i) => {
    const slug = t.multi && chosen.length > 1 ? `${t.slug}-${i + 1}` : t.slug;
    const name = t.multi ? el.tags.name! : t.name;
    const osmLevels = Number.parseInt(el.tags["building:levels"] ?? "", 10);
    const floors = t.floors?.n ?? (Number.isFinite(osmLevels) ? osmLevels : null);
    const floorsSource = t.floors?.source ?? (floors !== null ? `osm:building:levels on ${el.type}/${el.id}` : null);
    const wkt = `SRID=4326;MULTIPOLYGON(${rings(el).map((r) => `(${r})`).join(", ")})`;
    // st_unaryunion merges overlapping parts into one outline.
    const geom = `extensions.st_multi(extensions.st_unaryunion(extensions.st_makevalid(${sqlStr(wkt)}::extensions.geometry)))::extensions.geography`;
    rows.push(
      `  (${sqlStr(slug)}, ${sqlStr(name)}, 'building', ${geom}, ` +
        `${floors ?? "null"}, ${floorsSource ? sqlStr(floorsSource) : "null"}, ${sqlStr(el.type)}, ${el.id}, false)`,
    );
    console.log(`✓ ${slug.padEnd(24)} ← OSM ${el.type}/${el.id} "${el.tags.name}"` +
      (floors !== null ? ` (${floors} floors: ${floorsSource})` : " (floors unknown)"));
  });
}

const out = `-- GENERATED by supabase/scripts/fetch_unc_buildings.ts — do not edit by hand.
-- Building footprints © OpenStreetMap contributors (ODbL).
-- verified = false: floors/entrances must be checked on site.
${missing.length ? `-- NOT FOUND in OSM: ${missing.join(", ")}\n` : ""}
insert into public.places (slug, name, kind, geom, floors, floors_source, osm_type, osm_id, verified) values
${rows.join(",\n")}
on conflict (slug) do nothing;
`;

writeFileSync(join(import.meta.dir, "..", "seed.sql"), out);
console.log(`\nWrote ${rows.length} rows to supabase/seed.sql`);
if (missing.length) console.log(`Missing: ${missing.join(", ")}`);
