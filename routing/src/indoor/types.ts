/**
 * Indoor building graph format (routing/buildings/<slug>.json).
 * Full description: routing/buildings/README.md
 */
export type NodeKind = "entrance" | "corridor" | "elevator" | "stairs" | "ramp" | "room";
export type EdgeType = "corridor" | "elevator" | "elevator_wait" | "stairs" | "ramp" | "door";

export interface Floor {
  /** Ordinal used for math (1 = ground floor as labelled in the building). */
  level: number;
  /** What the building's signs say, e.g. "G", "1", "M". */
  label: string;
  /** Floor-to-floor height, used by barometric floor estimation. */
  height_m?: number;
}

export interface IndoorNode {
  id: string;
  floor: number;
  kind: NodeKind;
  /** Stair or elevator core this node belongs to (e.g. "A"). */
  core?: string;
  /** Human label used in directions, e.g. "main entrance". */
  label?: string;
  /** Required for entrances (where the outdoor route ends). */
  lat?: number;
  lng?: number;
  /** For entrances: no steps between sidewalk and door. */
  step_free?: boolean;
  /** Source of the node, e.g. "osm:node/573880869" or "survey:2026-11-10". */
  source?: string;
}

export interface IndoorEdge {
  a: string;
  b: string;
  type: EdgeType;
  /** Walking distance; converted to time at WALK_SPEED_MPS. */
  meters?: number;
  /** Fixed traversal time (used for stairs, elevators). */
  seconds?: number;
  /** Stairs only: number of steps in this flight. */
  steps?: number;
}

export interface BuildingGraph {
  /** Matches places.slug in Supabase. */
  building: string;
  name: string;
  /** false until someone has walked the building and checked the data. */
  verified: boolean;
  notes?: string;
  floors: Floor[];
  nodes: IndoorNode[];
  edges: IndoorEdge[];
}

export const WALK_SPEED_MPS = 1.3;
