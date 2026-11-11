/**
 * Every building graph in routing/buildings/ must pass the checker and be
 * routable: from every entrance to every floor, with and without stairs.
 */
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { PROFILES } from "../src/profiles";
import { routeIndoor } from "../src/indoor/route";
import type { BuildingGraph } from "../src/indoor/types";
import { validateBuilding } from "../src/indoor/validate";

const dir = join(import.meta.dir, "..", "buildings");
const graphs = readdirSync(dir)
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")) as BuildingGraph);
const seed = readFileSync(join(import.meta.dir, "..", "..", "supabase", "seed.sql"), "utf8");

const EXPECTED = [
  "davis-library", "undergraduate-library", "student-union", "gardner-hall", "phillips-hall",
  "hamilton-hall", "hinton-james", "ram-village-1", "ram-village-2", "ram-village-3",
];

test("every seeded building has an indoor graph", () => {
  expect(graphs.map((g) => g.building).sort()).toEqual([...EXPECTED].sort());
});

describe.each(graphs.map((g) => [g.building, g] as const))("%s", (_, g) => {
  test("passes the checker", () => {
    expect(validateBuilding(g)).toEqual([]);
  });

  test("matches a seeded place and is honest about being unverified", () => {
    expect(seed).toContain(`'${g.building}'`);
    if (!g.verified) expect(g.notes ?? "").toMatch(/NOT SURVEYED/);
  });

  test("entrances have real-looking campus coordinates", () => {
    for (const n of g.nodes.filter((n) => n.kind === "entrance")) {
      expect(n.lat!).toBeGreaterThan(35.89);
      expect(n.lat!).toBeLessThan(35.93);
      expect(n.lng!).toBeGreaterThan(-79.07);
      expect(n.lng!).toBeLessThan(-79.03);
    }
  });

  test("every floor is reachable from every entrance, stair-free", () => {
    for (const ent of g.nodes.filter((n) => n.kind === "entrance")) {
      for (const f of g.floors) {
        const r = routeIndoor(g, ent.id, (n) => n.floor === f.level && n.kind === "corridor", PROFILES.avoid_stairs);
        expect(r).not.toBeNull();
        expect(r!.edgeTypes).not.toContain("stairs");
      }
    }
  });

  test("top floor route gives elevator directions", () => {
    const top = Math.max(...g.floors.map((f) => f.level));
    const ent = g.nodes.find((n) => n.kind === "entrance")!;
    const r = routeIndoor(g, ent.id, (n) => n.floor === top && n.kind === "corridor", PROFILES.avoid_stairs)!;
    if (top > 1) expect(r.steps.some((s) => s.startsWith("Take elevator"))).toBe(true);
    expect(r.steps.at(-1)).toBe(`Arrive on floor ${top}`);
  });
});

describe("stitching respects step-free entrances", () => {
  test("Gardner Hall: avoid_stairs only enters through step-free entrances", async () => {
    const { routeToDestination } = await import("../src/stitch");
    const gardner = graphs.find((g) => g.building === "gardner-hall")!;
    const buildings = new Map(graphs.map((g) => [g.building, g]));
    const tried: string[] = [];
    // Fake outdoor router: every entrance costs the same, so only the
    // step-free filter decides which entrances are considered.
    const outdoor = async (_f: unknown, to: { lat: number; lng: number }) => {
      const ent = gardner.nodes.find((n) => n.lat === to.lat && n.lng === to.lng);
      if (ent) tried.push(ent.id);
      return { shape: "", distanceM: 300, durationS: 240, instructions: [] };
    };
    const r = await routeToDestination(
      { lat: 35.9, lng: -79.05 },
      { lat: 35.9103, lng: -79.051, placeSlug: "gardner-hall", floor: 3 },
      PROFILES.avoid_stairs, outdoor, buildings,
    );
    const stepped = gardner.nodes.filter((n) => n.kind === "entrance" && n.step_free === false).map((n) => n.id);
    expect(stepped.length).toBeGreaterThan(0);
    for (const id of stepped) expect(tried).not.toContain(id);
    expect(r.indoor?.targetFloor).toBe(3);
    expect(r.steps).toContain("Take elevator A to floor 3");
  });
});
