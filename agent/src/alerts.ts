/**
 * "X is approaching you / your building" alerts, sent only to the owner.
 *
 * A friend triggers an alert when they cross INTO the radius around the
 * owner's current position, or around the owner's current building, from
 * outside it. Hysteresis (re-arm only beyond 1.5x radius) plus a cooldown
 * prevents flapping alerts when GPS jitters at the edge.
 */
import type { Friend, MyLocation } from "./data";

export function distanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const R = 6_371_000;
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

interface WatchState {
  armed: boolean;
  lastFired: number;
}

export class ApproachWatcher {
  private watched = new Map<string, WatchState>();

  constructor(
    private readonly radiusM = 150,
    private readonly cooldownMs = 10 * 60_000,
  ) {}

  enable(userId: string) {
    // Start disarmed if we don't know yet; first tick decides.
    this.watched.set(userId, { armed: false, lastFired: 0 });
  }

  disableAll() {
    this.watched.clear();
  }

  isWatching(userId: string) {
    return this.watched.has(userId);
  }

  /**
   * Evaluate new positions. `buildingCentroid` is the centroid of the
   * building the owner is in (or their home building), if known.
   * Returns alert texts for the owner.
   */
  tick(friends: Friend[], me: MyLocation | null, buildingCentroid?: { lat: number; lng: number; name: string }, now = Date.now()): string[] {
    const out: string[] = [];
    for (const f of friends) {
      const st = this.watched.get(f.user_id);
      if (!st) continue;
      // Building-level sharing near the owner's own building is too coarse
      // to measure "approaching" precisely, but distance to the centroid
      // still works for the building target.
      const targets: { label: string; d: number }[] = [];
      if (me) targets.push({ label: "you", d: distanceM(f, me) });
      if (buildingCentroid) targets.push({ label: buildingCentroid.name, d: distanceM(f, buildingCentroid) });
      if (targets.length === 0) continue;

      const closest = targets.reduce((a, b) => (b.d < a.d ? b : a));
      if (closest.d > this.radiusM * 1.5) {
        st.armed = true; // far away: next entry will alert
        continue;
      }
      if (closest.d <= this.radiusM && st.armed && now - st.lastFired >= this.cooldownMs) {
        st.armed = false;
        st.lastFired = now;
        out.push(
          closest.label === "you"
            ? `${f.display_name} is approaching you (about ${Math.round(closest.d)} m away).`
            : `${f.display_name} is approaching ${closest.label} (about ${Math.round(closest.d)} m away).`,
        );
      }
    }
    return out;
  }
}
