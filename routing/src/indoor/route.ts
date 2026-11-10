/**
 * Indoor routing over a building graph: Dijkstra with profile-dependent edge
 * costs, then compression of the edge path into human directions such as
 * "Take elevator A to floor 3".
 */
import type { Profile } from "../profiles";
import { type BuildingGraph, type IndoorEdge, type IndoorNode, WALK_SPEED_MPS } from "./types";

export interface IndoorRoute {
  /** Travel time estimate (excludes profile penalties). */
  seconds: number;
  /** Cost used for choosing the route (includes penalties). */
  cost: number;
  nodeIds: string[];
  edgeTypes: IndoorEdge["type"][];
  steps: string[];
}

function travelSeconds(e: IndoorEdge): number {
  return e.seconds ?? (e.meters ?? 0) / WALK_SPEED_MPS;
}

function edgeCost(e: IndoorEdge, profile: Profile): number {
  const t = travelSeconds(e);
  if (e.type === "stairs") {
    return profile.indoorAllowStairs ? t + profile.indoorStairPenaltyS : Number.POSITIVE_INFINITY;
  }
  return t;
}

/** Cheapest route from `fromId` to any node accepted by `isTarget`. */
export function routeIndoor(
  g: BuildingGraph,
  fromId: string,
  isTarget: (n: IndoorNode) => boolean,
  profile: Profile,
): IndoorRoute | null {
  const nodes = new Map(g.nodes.map((n) => [n.id, n]));
  const adj = new Map<string, { to: string; edge: IndoorEdge }[]>();
  for (const e of g.edges) {
    if (!Number.isFinite(edgeCost(e, profile))) continue; // e.g. stairs under avoid_stairs
    (adj.get(e.a) ?? adj.set(e.a, []).get(e.a)!).push({ to: e.b, edge: e });
    (adj.get(e.b) ?? adj.set(e.b, []).get(e.b)!).push({ to: e.a, edge: e });
  }

  const dist = new Map<string, number>([[fromId, 0]]);
  const prev = new Map<string, { from: string; edge: IndoorEdge }>();
  const done = new Set<string>();

  // Graphs have tens of nodes, so a linear-scan priority queue is fine.
  while (true) {
    let cur: string | undefined;
    let best = Number.POSITIVE_INFINITY;
    for (const [id, d] of dist) if (!done.has(id) && d < best) [cur, best] = [id, d];
    if (cur === undefined) return null;
    done.add(cur);

    const node = nodes.get(cur)!;
    if (cur !== fromId && isTarget(node)) return buildRoute(g, fromId, cur, prev, best);
    if (cur === fromId && isTarget(node)) return buildRoute(g, fromId, cur, prev, 0);

    for (const { to, edge } of adj.get(cur) ?? []) {
      const nd = best + edgeCost(edge, profile);
      if (nd < (dist.get(to) ?? Number.POSITIVE_INFINITY)) {
        dist.set(to, nd);
        prev.set(to, { from: cur, edge });
      }
    }
  }
}

function buildRoute(
  g: BuildingGraph,
  fromId: string,
  toId: string,
  prev: Map<string, { from: string; edge: IndoorEdge }>,
  cost: number,
): IndoorRoute {
  const nodeIds = [toId];
  const edges: IndoorEdge[] = [];
  for (let id = toId; id !== fromId; ) {
    const p = prev.get(id)!;
    edges.unshift(p.edge);
    nodeIds.unshift(p.from);
    id = p.from;
  }
  return {
    seconds: Math.round(edges.reduce((s, e) => s + travelSeconds(e), 0)),
    cost,
    nodeIds,
    edgeTypes: edges.map((e) => e.type),
    steps: describe(g, nodeIds),
  };
}

/** Turn a node path into short directions, merging consecutive lift/stair hops. */
function describe(g: BuildingGraph, path: string[]): string[] {
  const nodes = new Map(g.nodes.map((n) => [n.id, n]));
  const label = (level: number) => g.floors.find((f) => f.level === level)?.label ?? String(level);
  const steps: string[] = [];

  const first = nodes.get(path[0]!)!;
  if (first.kind === "entrance") {
    steps.push(`Enter ${g.name} by the ${first.label ?? "entrance"} (floor ${label(first.floor)})`);
  }

  let i = 0;
  while (i < path.length - 1) {
    const a = nodes.get(path[i]!)!;
    const b = nodes.get(path[i + 1]!)!;
    if ((a.kind === "elevator" || a.kind === "stairs") && b.kind === a.kind && b.core === a.core) {
      let j = i + 1;
      while (j < path.length - 1) {
        const n = nodes.get(path[j + 1]!)!;
        if (n.kind !== a.kind || n.core !== a.core) break;
        j++;
      }
      const end = nodes.get(path[j]!)!;
      if (a.kind === "elevator") {
        steps.push(`Take elevator ${a.core} to floor ${label(end.floor)}`);
      } else {
        const dir = end.floor > a.floor ? "up" : "down";
        steps.push(`Take stairs ${a.core} ${dir} to floor ${label(end.floor)}`);
      }
      i = j;
    } else {
      i++;
    }
  }

  const last = nodes.get(path.at(-1)!)!;
  steps.push(`Arrive on floor ${label(last.floor)}`);
  return steps;
}
