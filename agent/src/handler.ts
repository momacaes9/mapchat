/**
 * Turns an intent into a reply. Every fact comes from LocationData (the
 * database / routing service); if the data isn't there, the reply says so.
 */
import type { ApproachWatcher } from "./alerts";
import type { Friend, LocationData } from "./data";
import type { IntentParser } from "./intent";

export const HELP =
  'Try: "where is Ana?", "route to Ana" (stair-free), "route to Ana fastest", ' +
  '"tell me when Ana is approaching", "stop alerts", or "who is sharing?"';

export function mapsLink(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat.toFixed(5)},${lng.toFixed(5)}`;
}

export function ago(iso: string, now = Date.now()): string {
  const mins = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000));
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  return `${Math.round(mins / 60)} h ago`;
}

/** Case-insensitive match on full name or first name. */
export function findFriend(friends: Friend[], name: string): Friend | undefined {
  const n = name.trim().toLowerCase();
  return (
    friends.find((f) => f.display_name.toLowerCase() === n) ??
    friends.find((f) => f.display_name.toLowerCase().split(/\s+/)[0] === n) ??
    friends.find((f) => f.display_name.toLowerCase().startsWith(n))
  );
}

function describe(f: Friend, now: number): string {
  const where = f.place_name
    ? `${f.share_precision === "building" ? "somewhere in" : "in"} ${f.place_name}`
    : f.share_precision === "building"
      ? "near"
      : "at";
  const floor = f.floor !== null ? `, floor ${f.floor}` : "";
  const stale = now - Date.parse(f.recorded_at) > 15 * 60_000 ? " (this may be out of date)" : "";
  return `${f.display_name} is ${where}${floor} (${ago(f.recorded_at, now)})${stale}: ${mapsLink(f.lat, f.lng)}`;
}

export async function handleText(
  text: string,
  deps: { parser: IntentParser; data: LocationData; watcher?: ApproachWatcher; now?: () => number },
): Promise<string> {
  const now = deps.now?.() ?? Date.now();
  const intent = await deps.parser.parse(text);

  if (intent.intent === "help") return HELP;

  const friends = await deps.data.friends();

  if (intent.intent === "list") {
    if (friends.length === 0) return "Nobody is sharing their location with you right now.";
    return `Sharing with you: ${friends.map((f) => f.display_name).join(", ")}.`;
  }

  if (intent.intent === "alert_off") {
    deps.watcher?.disableAll();
    return "OK, approach alerts are off.";
  }

  if (!intent.target) return `Who do you mean? ${HELP}`;
  const friend = findFriend(friends, intent.target);
  // Same answer whether the person doesn't exist or doesn't share.
  if (!friend) return `I can't see ${intent.target}'s location. They may not be sharing with you right now.`;

  switch (intent.intent) {
    case "where_is":
      return describe(friend, now);

    case "route_to": {
      const profile = intent.profile ?? "avoid_stairs";
      const r = await deps.data.route(friend.user_id, profile);
      if ("error" in r) {
        if (r.error === "no_own_location") return "I don't know where you are yet. Open MapChat so it can update your location.";
        if (r.error === "not_visible") return `I can't see ${friend.display_name}'s location right now.`;
        return "Routing isn't available right now. Try again in a minute.";
      }
      const mins = Math.max(1, Math.round(r.route.durationS / 60));
      const label = profile === "avoid_stairs" ? "no stairs" : profile === "fastest" ? "fastest" : "normal";
      const steps = r.route.steps.slice(-4).map((s) => `• ${s}`).join("\n");
      return `${mins} min walk (${r.route.distanceM} m, ${label}) to ${friend.display_name}:\n${steps}`;
    }

    case "alert_on":
      if (!deps.watcher) return "Alerts aren't running right now.";
      deps.watcher.enable(friend.user_id);
      return `OK, I'll text you when ${friend.display_name} is approaching you or your building.`;
  }
  return HELP;
}
