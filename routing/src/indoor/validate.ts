import type { BuildingGraph, EdgeType, NodeKind } from "./types";

const NODE_KINDS: NodeKind[] = ["entrance", "corridor", "elevator", "stairs", "ramp", "room"];
const EDGE_TYPES: EdgeType[] = ["corridor", "elevator", "elevator_wait", "stairs", "ramp", "door"];

/** Returns a list of problems; an empty list means the graph is valid. */
export function validateBuilding(g: BuildingGraph): string[] {
  const errors: string[] = [];
  const err = (m: string) => errors.push(`${g.building ?? "?"}: ${m}`);

  if (!/^[a-z0-9-]+$/.test(g.building ?? "")) err("building must be a lowercase slug");
  if (typeof g.verified !== "boolean") err("verified must be true or false");
  if (!Array.isArray(g.floors) || g.floors.length === 0) err("needs at least one floor");

  const levels = new Set(g.floors.map((f) => f.level));
  if (levels.size !== g.floors.length) err("duplicate floor levels");

  const nodes = new Map<string, BuildingGraph["nodes"][number]>();
  for (const n of g.nodes) {
    if (nodes.has(n.id)) err(`duplicate node id ${n.id}`);
    nodes.set(n.id, n);
    if (!NODE_KINDS.includes(n.kind)) err(`node ${n.id}: unknown kind ${n.kind}`);
    if (!levels.has(n.floor)) err(`node ${n.id}: floor ${n.floor} not declared`);
    if (n.kind === "entrance" && (typeof n.lat !== "number" || typeof n.lng !== "number")) {
      err(`entrance ${n.id} needs lat/lng`);
    }
    if ((n.kind === "elevator" || n.kind === "stairs") && !n.core) err(`node ${n.id}: ${n.kind} needs a core`);
  }
  if (![...nodes.values()].some((n) => n.kind === "entrance")) err("needs at least one entrance");

  for (const e of g.edges) {
    const a = nodes.get(e.a);
    const b = nodes.get(e.b);
    const tag = `edge ${e.a}↔${e.b}`;
    if (!a || !b) {
      err(`${tag}: unknown node`);
      continue;
    }
    if (!EDGE_TYPES.includes(e.type)) err(`${tag}: unknown type ${e.type}`);
    if (e.meters === undefined && e.seconds === undefined) err(`${tag}: needs meters or seconds`);
    if (e.type === "stairs" || e.type === "elevator") {
      if (a.kind !== e.type || b.kind !== e.type) err(`${tag}: ${e.type} edge must join two ${e.type} nodes`);
      if (a.core !== b.core) err(`${tag}: must stay within one core`);
      if (a.floor === b.floor) err(`${tag}: must change floor`);
    } else if (a.floor !== b.floor && e.type !== "ramp") {
      err(`${tag}: only stairs, elevator or ramp edges may change floor`);
    }
  }
  return errors;
}
