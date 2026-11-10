/**
 * Integration test against the local Valhalla server (infra/valhalla).
 * Skipped automatically when Valhalla is not running.
 */
import { describe, expect, test } from "bun:test";
import { PROFILES } from "../src/profiles";
import { edgeUses, isValhallaUp, routeOutdoor } from "../src/valhalla";

const up = await isValhallaUp();

// Davis Library main entrance (OSM node 573880869) → Hinton James (seed centroid).
const DAVIS = { lat: 35.9108025, lng: -79.0483783 };
const HINTON_JAMES = { lat: 35.90227, lng: -79.04327 };

describe.skipIf(!up)("outdoor routing (Valhalla, UNC campus)", () => {
  test("Davis Library → Hinton James: avoid_stairs route uses no steps", async () => {
    const avoid = await routeOutdoor(DAVIS, HINTON_JAMES, PROFILES.avoid_stairs);
    const fastest = await routeOutdoor(DAVIS, HINTON_JAMES, PROFILES.fastest);

    const avoidUses = await edgeUses(avoid.shape, PROFILES.avoid_stairs);
    const fastestUses = await edgeUses(fastest.shape, PROFILES.fastest);
    const stepsIn = (uses: string[]) => uses.filter((u) => u === "steps").length;

    console.log(
      `fastest:      ${fastest.distanceM} m, ${Math.round(fastest.durationS / 60)} min, ` +
        `${stepsIn(fastestUses)} stair segments\n` +
        `avoid_stairs: ${avoid.distanceM} m, ${Math.round(avoid.durationS / 60)} min, ` +
        `${stepsIn(avoidUses)} stair segments`,
    );

    // Straight-line distance is ~1.0 km; a sane walking route is 1–3 km.
    expect(avoid.distanceM).toBeGreaterThan(900);
    expect(avoid.distanceM).toBeLessThan(3000);
    expect(avoidUses.length).toBeGreaterThan(0);
    expect(stepsIn(avoidUses)).toBe(0);
    // Avoiding stairs can only make the walk the same length or longer.
    expect(avoid.durationS).toBeGreaterThanOrEqual(fastest.durationS);
  }, 30_000);
});
