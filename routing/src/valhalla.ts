/**
 * Minimal client for a local Valhalla server (see infra/valhalla).
 * API reference: https://valhalla.github.io/valhalla/api/route/api-reference/
 */
import type { Profile } from "./profiles";

export const VALHALLA_URL = process.env.VALHALLA_URL ?? "http://localhost:8002";

export interface LatLng {
  lat: number;
  lng: number;
}

export interface OutdoorRoute {
  /** Encoded polyline, precision 6 (Valhalla's default). */
  shape: string;
  distanceM: number;
  durationS: number;
  instructions: string[];
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${VALHALLA_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as T & { error?: string; error_code?: number };
  if (!res.ok) {
    throw new Error(`Valhalla ${path} failed (${res.status}): ${json.error ?? "unknown error"}`);
  }
  return json;
}

function costing(profile: Profile) {
  return { costing: "pedestrian", costing_options: { pedestrian: profile.valhalla } };
}

/** Outdoor walking route between two points using the profile's costing. */
export async function routeOutdoor(from: LatLng, to: LatLng, profile: Profile): Promise<OutdoorRoute> {
  type Resp = {
    trip: {
      legs: { shape: string; maneuvers: { instruction: string }[] }[];
      summary: { length: number; time: number };
    };
  };
  const resp = await post<Resp>("/route", {
    locations: [
      { lat: from.lat, lon: from.lng },
      { lat: to.lat, lon: to.lng },
    ],
    ...costing(profile),
    units: "kilometers",
  });
  const leg = resp.trip.legs[0]!;
  return {
    shape: leg.shape,
    distanceM: Math.round(resp.trip.summary.length * 1000),
    durationS: Math.round(resp.trip.summary.time),
    instructions: leg.maneuvers.map((m) => m.instruction),
  };
}

/**
 * The OSM "use" of every edge along a route shape (e.g. "footway", "steps",
 * "elevator"). Used to verify that a route really avoids stairs.
 */
export async function edgeUses(shape: string, profile: Profile): Promise<string[]> {
  type Resp = { edges?: { use?: string }[] };
  const resp = await post<Resp>("/trace_attributes", {
    encoded_polyline: shape,
    shape_match: "edge_walk",
    ...costing(profile),
    filters: { attributes: ["edge.use"], action: "include" },
  });
  return (resp.edges ?? []).map((e) => e.use ?? "unknown");
}

export async function isValhallaUp(): Promise<boolean> {
  try {
    const res = await fetch(`${VALHALLA_URL}/status`, { signal: AbortSignal.timeout(2000) });
    return res.ok;
  } catch {
    return false;
  }
}
