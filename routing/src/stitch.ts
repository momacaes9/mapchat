/**
 * Combines an outdoor walking route (Valhalla) with an indoor route (building
 * graph) at the best entrance of the destination building.
 *
 * For each entrance of the target's building:
 *   cost = outdoor time (me -> entrance) + indoor cost (entrance -> target floor)
 * and the cheapest entrance wins. Without a building graph or a known floor,
 * the route simply ends at the target's (possibly coarsened) position.
 */
import { routeIndoor } from "./indoor/route";
import type { BuildingGraph } from "./indoor/types";
import type { Profile } from "./profiles";
import type { LatLng, OutdoorRoute } from "./valhalla";

export type OutdoorRouter = (from: LatLng, to: LatLng, profile: Profile) => Promise<OutdoorRoute>;

export interface Destination extends LatLng {
  placeSlug?: string | null;
  floor?: number | null;
}

export interface CombinedRoute {
  profile: string;
  /** Total travel time estimate in seconds (outdoor + indoor). */
  durationS: number;
  distanceM: number;
  /** Outdoor polyline (precision 6), ending at the chosen entrance or the target. */
  shape: string;
  steps: string[];
  entrance: { id: string; label: string; lat: number; lng: number } | null;
  indoor: { building: string; targetFloor: number; verified: boolean } | null;
}

export async function routeToDestination(
  from: LatLng,
  to: Destination,
  profile: Profile,
  outdoor: OutdoorRouter,
  buildings: Map<string, BuildingGraph>,
): Promise<CombinedRoute> {
  const graph = to.placeSlug ? buildings.get(to.placeSlug) : undefined;
  const floor = to.floor ?? null;

  if (graph && floor !== null && graph.floors.some((f) => f.level === floor)) {
    let best: CombinedRoute | null = null;
    let bestCost = Number.POSITIVE_INFINITY;

    for (const ent of graph.nodes.filter((n) => n.kind === "entrance")) {
      // Under avoid_stairs, skip entrances known to have steps.
      if (!profile.indoorAllowStairs && ent.step_free === false) continue;
      const indoor = routeIndoor(
        graph,
        ent.id,
        (n) => n.floor === floor && n.kind === "corridor",
        profile,
      );
      if (!indoor) continue;
      const out = await outdoor(from, { lat: ent.lat!, lng: ent.lng! }, profile);
      const cost = out.durationS + indoor.cost;
      if (cost < bestCost) {
        bestCost = cost;
        best = {
          profile: profile.name,
          durationS: out.durationS + indoor.seconds,
          distanceM: out.distanceM,
          shape: out.shape,
          steps: [...out.instructions, ...indoor.steps],
          entrance: { id: ent.id, label: ent.label ?? "entrance", lat: ent.lat!, lng: ent.lng! },
          indoor: { building: graph.building, targetFloor: floor, verified: graph.verified },
        };
      }
    }
    if (best) return best;
    // No usable entrance under this profile: fall back to an outdoor route.
  }

  const out = await outdoor(from, { lat: to.lat, lng: to.lng }, profile);
  return {
    profile: profile.name,
    durationS: out.durationS,
    distanceM: out.distanceM,
    shape: out.shape,
    steps: out.instructions,
    entrance: null,
    indoor: null,
  };
}
