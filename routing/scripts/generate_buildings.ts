/**
 * Generates unverified indoor graph templates for UNC buildings from
 * OpenStreetMap: footprint + entrance nodes (entrance=*, door=*), with floor
 * counts taken from supabase/seed.sql (same sources as `places.floors_source`).
 *
 *   bun routing/scripts/generate_buildings.ts
 *
 * Existing files are NOT overwritten (so surveyed/verified graphs are safe);
 * pass --force to regenerate. Map data © OpenStreetMap contributors, ODbL.
 *
 * Template per building (same shape as davis-library.json):
 *   - every OSM entrance -> entrance node on floor 1 (or the OSM `level` if set)
 *   - one corridor hub per floor
 *   - elevator core "A" and stair core "N" serving every floor
 * If OSM has no entrance on the building, one ESTIMATED entrance is placed on
 * the southernmost footprint vertex and flagged
 * `"source": "estimated: no OSM entrance on this building"`.
 */
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

interface Target {
  slug: string;
  name: string;
  osm: { type: "way"; id: number };
  floors: number;
  floorsSource: string;
  /** Typical floor-to-floor height used by the barometer estimator. */
  heightM: number;
}

// Floor counts mirror supabase/scripts/fetch_unc_buildings.ts (see floors_source).
const TARGETS: Target[] = [
  { slug: "undergraduate-library", name: "Undergraduate Library", osm: { type: "way", id: 30677763 }, floors: 3, floorsSource: "osm:building:levels", heightM: 4.0 },
  { slug: "student-union", name: "Student Union", osm: { type: "way", id: 1420775578 }, floors: 3, floorsSource: "osm:building:levels on relation/324644", heightM: 4.2 },
  { slug: "gardner-hall", name: "Gardner Hall", osm: { type: "way", id: 30684055 }, floors: 4, floorsSource: "osm:building:levels", heightM: 3.8 },
  { slug: "phillips-hall", name: "Phillips Hall", osm: { type: "way", id: 44343443 }, floors: 3, floorsSource: "osm:building:levels", heightM: 4.0 },
  { slug: "hamilton-hall", name: "Hamilton Hall", osm: { type: "way", id: 44342840 }, floors: 7, floorsSource: "best guess", heightM: 3.6 },
  { slug: "hinton-james", name: "Hinton James", osm: { type: "way", id: 44344714 }, floors: 10, floorsSource: "osm:building:levels", heightM: 3.0 },
  { slug: "ram-village-1", name: "Ram Village Building 1", osm: { type: "way", id: 96059134 }, floors: 5, floorsSource: "best guess", heightM: 3.0 },
  { slug: "ram-village-2", name: "Ram Village Building 2", osm: { type: "way", id: 96059140 }, floors: 5, floorsSource: "best guess", heightM: 3.0 },
  { slug: "ram-village-3", name: "Ram Village Building 3", osm: { type: "way", id: 96059144 }, floors: 5, floorsSource: "best guess", heightM: 3.0 },
];

const ENDPOINTS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"];

type OsmNode = { type: "node"; id: number; lat: number; lon: number; tags?: Record<string, string> };
type OsmWay = { type: "way"; id: number; geometry: { lat: number; lon: number }[]; nodes: number[] };

async function overpass(query: string): Promise<(OsmNode | OsmWay)[]> {
  let wait = 5_000;
  for (let attempt = 1; attempt <= 6; attempt++) {
    const url = ENDPOINTS[(attempt - 1) % ENDPOINTS.length]!;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "User-Agent": "mapchat-buildings/0.1", "Content-Type": "application/x-www-form-urlencoded" },
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

const ids = TARGETS.map((t) => t.osm.id).join(",");
const elements = await overpass(`[out:json][timeout:60];
way(id:${ids});
out geom;
way(id:${ids});
node(w)[~"^(entrance|door)$"~"."];
out body;`);

const ways = new Map(elements.filter((e): e is OsmWay => e.type === "way").map((w) => [w.id, w]));
const doorNodes = new Map(elements.filter((e): e is OsmNode => e.type === "node").map((n) => [n.id, n]));

const force = process.argv.includes("--force");
const dir = join(import.meta.dir, "..", "buildings");

for (const t of TARGETS) {
  const file = join(dir, `${t.slug}.json`);
  if (existsSync(file) && !force) {
    console.log(`- ${t.slug}: exists, skipped (use --force)`);
    continue;
  }
  const way = ways.get(t.osm.id);
  if (!way) {
    console.log(`✗ ${t.slug}: OSM way ${t.osm.id} not returned`);
    continue;
  }

  // Entrances that are vertices of this building's outline.
  const onWay = new Set(way.nodes);
  let entrances = [...doorNodes.values()]
    .filter((n) => onWay.has(n.id))
    .filter((n) => (n.tags?.entrance ?? n.tags?.door) !== "no" && n.tags?.access !== "private" && n.tags?.entrance !== "emergency")
    .map((n, i) => ({
      id: `ent-${i + 1}`,
      label: n.tags?.entrance === "main" ? "main entrance" : n.tags?.name ?? `entrance ${i + 1}`,
      lat: n.lat,
      lng: n.lon,
      // Treat as step-free only when OSM says so explicitly.
      step_free: n.tags?.wheelchair === "yes" || n.tags?.stairs === "no" ? true : n.tags?.wheelchair === "no" ? false : undefined,
      source: `osm:node/${n.id} (${Object.entries(n.tags ?? {}).map(([k, v]) => `${k}=${v}`).join(", ")})`,
    }));

  if (entrances.length === 0) {
    // No OSM entrance: deterministically pick the southernmost outline vertex
    // as a placeholder. It is labelled as an estimate and must be surveyed.
    const v = [...way.geometry].sort((a, b) => a.lat - b.lat)[0]!;
    entrances = [{ id: "ent-1", label: "entrance (estimated)", lat: v.lat, lng: v.lon, step_free: undefined, source: "estimated: no OSM entrance on this building" }];
  }

  const floors = Array.from({ length: t.floors }, (_, i) => ({ level: i + 1, label: String(i + 1), height_m: t.heightM }));
  const nodes: Record<string, unknown>[] = entrances.map((e) => ({ ...e, floor: 1, kind: "entrance" }));
  const edges: Record<string, unknown>[] = entrances.map((e) => ({ a: e.id, b: "hall-1", type: "door", meters: 20 }));
  for (let f = 1; f <= t.floors; f++) {
    nodes.push(
      { id: `hall-${f}`, floor: f, kind: "corridor", label: `floor ${f} lobby` },
      { id: `elev-A-${f}`, floor: f, kind: "elevator", core: "A" },
      { id: `stair-N-${f}`, floor: f, kind: "stairs", core: "N" },
    );
    edges.push(
      { a: `hall-${f}`, b: `elev-A-${f}`, type: "elevator_wait", seconds: 30 },
      { a: `hall-${f}`, b: `stair-N-${f}`, type: "corridor", meters: 20 },
    );
    if (f < t.floors) {
      edges.push(
        { a: `elev-A-${f}`, b: `elev-A-${f + 1}`, type: "elevator", seconds: 6 },
        { a: `stair-N-${f}`, b: `stair-N-${f + 1}`, type: "stairs", seconds: 15, steps: Math.round((t.heightM / 0.17)) },
      );
    }
  }

  const graph = {
    building: t.slug,
    name: t.name,
    verified: false,
    notes:
      `TEMPLATE, NOT SURVEYED. Footprint and entrances from OSM way/${t.osm.id}` +
      `${entrances[0]!.source.startsWith("estimated") ? " (no entrance mapped in OSM: ent-1 is an ESTIMATE)" : ""}. ` +
      `Floors: ${t.floors} (${t.floorsSource}). Elevator core 'A' and stair core 'N' are ASSUMED to serve every floor; ` +
      `distances, timings and floor heights are placeholders. Entrance floor assumed to be floor 1.`,
    floors,
    nodes,
    edges,
  };
  writeFileSync(file, `${JSON.stringify(graph, null, 2)}\n`);
  console.log(`✓ ${t.slug}: ${entrances.length} entrance(s)${entrances[0]!.source.startsWith("estimated") ? " [estimated]" : ""}, ${t.floors} floors`);
}
