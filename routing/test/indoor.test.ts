import { describe, expect, test } from "bun:test";
import davis from "../buildings/davis-library.json";
import { PROFILES } from "../src/profiles";
import { routeIndoor } from "../src/indoor/route";
import type { BuildingGraph } from "../src/indoor/types";
import { validateBuilding } from "../src/indoor/validate";

const g = davis as BuildingGraph;
const onFloor = (f: number) => (n: { floor: number; kind: string }) => n.floor === f && n.kind === "corridor";

describe("building graph format", () => {
  test("Davis Library example is valid and marked unverified", () => {
    expect(validateBuilding(g)).toEqual([]);
    expect(g.verified).toBe(false);
  });

  test("validator catches a stairs edge that jumps between cores", () => {
    const bad: BuildingGraph = structuredClone(g);
    bad.edges.push({ a: "stair-N-1", b: "elev-A-2", type: "stairs", seconds: 10 });
    expect(validateBuilding(bad).join("\n")).toContain("stairs edge must join two stairs nodes");
  });

  test("validator requires coordinates on entrances", () => {
    const bad: BuildingGraph = structuredClone(g);
    delete bad.nodes[0]!.lat;
    expect(validateBuilding(bad).join("\n")).toContain("needs lat/lng");
  });
});

describe("indoor routing", () => {
  test("avoid_stairs never uses a stairs edge", () => {
    const r = routeIndoor(g, "ent-main", onFloor(3), PROFILES.avoid_stairs)!;
    expect(r).not.toBeNull();
    expect(r.edgeTypes).not.toContain("stairs");
    expect(r.steps).toContain("Take elevator A to floor 3");
  });

  test("fastest takes the stairs for one floor", () => {
    const r = routeIndoor(g, "ent-main", onFloor(2), PROFILES.fastest)!;
    expect(r.edgeTypes).toContain("stairs");
    expect(r.steps).toContain("Take stairs N up to floor 2");
  });

  test("a big floor change prefers the elevator even when stairs are allowed", () => {
    const r = routeIndoor(g, "ent-main", onFloor(8), PROFILES.default)!;
    expect(r.edgeTypes).not.toContain("stairs");
    expect(r.steps).toEqual([
      "Enter Davis Library by the main entrance (floor 1)",
      "Take elevator A to floor 8",
      "Arrive on floor 8",
    ]);
  });

  test("same floor needs no vertical travel", () => {
    const r = routeIndoor(g, "ent-main", onFloor(1), PROFILES.default)!;
    expect(r.edgeTypes).toEqual(["door"]);
  });

  test("returns null when the target is unreachable under the profile", () => {
    const noLift: BuildingGraph = structuredClone(g);
    noLift.edges = noLift.edges.filter((e) => e.type !== "elevator");
    expect(routeIndoor(noLift, "ent-main", onFloor(3), PROFILES.avoid_stairs)).toBeNull();
  });
});
