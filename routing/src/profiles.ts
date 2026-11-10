/**
 * Routing profiles shared by the outdoor (Valhalla) and indoor (building
 * graph) routers, so "avoid stairs" means the same thing on both legs.
 */
export type ProfileName = "default" | "avoid_stairs" | "fastest";

export interface Profile {
  name: ProfileName;
  /** Valhalla `costing_options.pedestrian` for the outdoor leg. */
  valhalla: Record<string, number | string>;
  /** Indoor: extra seconds added per flight of stairs. */
  indoorStairPenaltyS: number;
  /** Indoor: if false, stairs edges are removed from the graph entirely. */
  indoorAllowStairs: boolean;
}

export const PROFILES: Record<ProfileName, Profile> = {
  // Mild aversion to steps, like a normal walker.
  default: {
    name: "default",
    valhalla: { step_penalty: 30 },
    indoorStairPenaltyS: 10,
    indoorAllowStairs: true,
  },
  // Strongly avoid outdoor steps (one hour per transition makes any detour
  // cheaper) and never use indoor stairs: elevators/ramps only.
  avoid_stairs: {
    name: "avoid_stairs",
    valhalla: { step_penalty: 3600 },
    indoorStairPenaltyS: Number.POSITIVE_INFINITY,
    indoorAllowStairs: false,
  },
  // Pure travel time.
  fastest: {
    name: "fastest",
    valhalla: { step_penalty: 0 },
    indoorStairPenaltyS: 0,
    indoorAllowStairs: true,
  },
};

export function getProfile(name: string | undefined): Profile {
  if (name && name in PROFILES) return PROFILES[name as ProfileName];
  return PROFILES.default;
}
