import { describe, expect, test } from "bun:test";
import { ApproachWatcher, distanceM } from "../src/alerts";
import { loadConfig } from "../src/config";
import { type Friend, type LocationData, mintUserJwt } from "../src/data";
import { findFriend, handleText, HELP } from "../src/handler";
import { fastPath, type IntentParser, RegexOnlyParser } from "../src/intent";
import { runAgent, type Inbound } from "../src/index";
import { normalizePhone, OwnerOnlySender } from "../src/owner";

const OWNER = "+19195550002";
const NOW = Date.parse("2026-11-10T23:00:00Z");

const ana: Friend = {
  user_id: "aaaaaaaa-0000-0000-0000-000000000001",
  display_name: "Ana Souza",
  lat: 35.91094,
  lng: -79.04781,
  floor: 3,
  place_slug: "davis-library",
  place_name: "Davis Library",
  share_precision: "exact",
  recorded_at: new Date(NOW - 2 * 60_000).toISOString(),
};

function fakeData(friends: Friend[] = [ana]): LocationData & { routeCalls: string[] } {
  const routeCalls: string[] = [];
  return {
    routeCalls,
    friends: async () => friends,
    me: async () => ({ lat: 35.90227, lng: -79.04327, floor: null, place_slug: "hinton-james", recorded_at: new Date(NOW).toISOString() }),
    route: async (to, profile) => {
      routeCalls.push(`${to}:${profile}`);
      return {
        route: {
          profile, durationS: 1100, distanceM: 1477, indoor: null,
          steps: ["Walk north on the path.", "Enter Davis Library by the main entrance (floor 1)", "Take elevator A to floor 3", "Arrive on floor 3"],
        },
      };
    },
  };
}

/** A parser that would hallucinate if we let it; replies must not use it. */
const lyingParser: IntentParser = {
  parse: async () => ({ intent: "where_is", target: "Ana", profile: null }),
};

// ---------------------------------------------------------------- owner guard
describe("OwnerOnlySender", () => {
  test("normalizes phone formats", () => {
    expect(normalizePhone("+1 (919) 555-0002")).toBe(OWNER);
    expect(normalizePhone("9195550002")).toBe(OWNER);
    expect(normalizePhone("tel:+19195550002")).toBe(OWNER);
    expect(normalizePhone("ana@icloud.com")).toBeNull();
  });

  test("only ever sends to the owner", async () => {
    const sent: string[] = [];
    const s = new OwnerOnlySender(OWNER, async (to) => void sent.push(to));
    await s.sendToOwner("hi");
    expect(sent).toEqual([OWNER]);
    expect(Object.getOwnPropertyNames(OwnerOnlySender.prototype)).not.toContain("send");
  });

  test("recognizes only the owner as the sender", () => {
    const s = new OwnerOnlySender(OWNER, async () => {});
    expect(s.isOwner("+1 919 555 0002")).toBe(true);
    expect(s.isOwner("+19195550001")).toBe(false);
    expect(s.isOwner(null)).toBe(false);
  });

  test("caps outgoing messages per hour", async () => {
    let n = 0;
    const s = new OwnerOnlySender(OWNER, async () => void n++, 3);
    for (let i = 0; i < 5; i++) await s.sendToOwner("x");
    expect(n).toBe(3);
  });

  test("rejects a non-E.164 owner number at construction", () => {
    expect(() => new OwnerOnlySender("919-555", async () => {})).toThrow();
  });
});

// ---------------------------------------------------------------- run loop
describe("runAgent", () => {
  async function* feed(msgs: Inbound[]) {
    for (const m of msgs) yield m;
  }

  test("ignores everyone except the owner and replies only to the owner", async () => {
    const sent: { to: string; text: string }[] = [];
    const sender = new OwnerOnlySender(OWNER, async (to, text) => void sent.push({ to, text }));
    await runAgent(
      {
        inbound: feed([
          { sender: "+19195550001", text: "where is Ana?" }, // roommate: ignored
          { sender: "stranger@icloud.com", text: "where is Ana?" }, // ignored
          { sender: OWNER, text: "where is Ana?" },
        ]),
        rawSend: async () => {},
      },
      { sender, parser: new RegexOnlyParser(), data: fakeData(), watcher: new ApproachWatcher() },
    );
    expect(sent).toHaveLength(1);
    expect(sent[0]!.to).toBe(OWNER);
    expect(sent[0]!.text).toContain("Davis Library");
  });
});

// ---------------------------------------------------------------- intents
describe("fast-path intent parsing", () => {
  test.each([
    ["where is Ana?", "where_is", "Ana"],
    ["Where's Pedro", "where_is", "Pedro"],
    ["route to Ana", "route_to", "Ana"],
    ["directions to Ana Souza", "route_to", "Ana Souza"],
    ["tell me when Ana is approaching", "alert_on", "Ana"],
    ["alert me when Ana gets close", "alert_on", "Ana"],
    ["stop alerts", "alert_off", null],
    ["who is sharing?", "list", null],
  ])("%s", (text, intent, target) => {
    const r = fastPath(text)!;
    expect(r.intent).toBe(intent as never);
    expect(r.target).toBe(target);
  });

  test("route profiles", () => {
    expect(fastPath("route to Ana")!.profile).toBe("avoid_stairs");
    expect(fastPath("route to Ana fastest")!.profile).toBe("fastest");
  });

  test("unknown text falls through to the LLM (null)", () => {
    expect(fastPath("is my roommate home yet")).toBeNull();
  });
});

// ---------------------------------------------------------------- replies
describe("handleText: answers come from data only", () => {
  test("where is: uses DB place, floor, age and a maps link", async () => {
    const r = await handleText("where is Ana?", { parser: new RegexOnlyParser(), data: fakeData(), now: () => NOW });
    expect(r).toBe(
      "Ana Souza is in Davis Library, floor 3 (2 min ago): https://www.google.com/maps/search/?api=1&query=35.91094,-79.04781",
    );
  });

  test("unknown or non-sharing person: no invented location", async () => {
    const r = await handleText("where is Pedro?", { parser: new RegexOnlyParser(), data: fakeData(), now: () => NOW });
    expect(r).toContain("can't see Pedro");
    expect(r).not.toMatch(/\d+\.\d{3}/);
  });

  test("even if the parser names someone, the answer depends on the DB", async () => {
    const r = await handleText("anything", { parser: lyingParser, data: fakeData([]), now: () => NOW });
    expect(r).toContain("can't see Ana");
  });

  test("building precision is described as 'somewhere in'", async () => {
    const b = { ...ana, share_precision: "building" as const, floor: null };
    const r = await handleText("where is ana", { parser: new RegexOnlyParser(), data: fakeData([b]), now: () => NOW });
    expect(r).toContain("somewhere in Davis Library");
    expect(r).not.toContain("floor");
  });

  test("stale locations are flagged", async () => {
    const old = { ...ana, recorded_at: new Date(NOW - 3 * 3_600_000).toISOString() };
    const r = await handleText("where is Ana", { parser: new RegexOnlyParser(), data: fakeData([old]), now: () => NOW });
    expect(r).toContain("may be out of date");
  });

  test("route to: stair-free by default, steps from the routing service", async () => {
    const data = fakeData();
    const r = await handleText("route to Ana", { parser: new RegexOnlyParser(), data, now: () => NOW });
    expect(data.routeCalls).toEqual([`${ana.user_id}:avoid_stairs`]);
    expect(r).toContain("18 min walk (1477 m, no stairs)");
    expect(r).toContain("Take elevator A to floor 3");
  });

  test("route errors are explained", async () => {
    const data = { ...fakeData(), route: async () => ({ error: "no_own_location" }) };
    const r = await handleText("route to Ana", { parser: new RegexOnlyParser(), data, now: () => NOW });
    expect(r).toContain("don't know where you are");
  });

  test("help for anything else", async () => {
    expect(await handleText("lol", { parser: new RegexOnlyParser(), data: fakeData() })).toBe(HELP);
  });

  test("name matching: first name, case-insensitive", () => {
    expect(findFriend([ana], "ana")?.user_id).toBe(ana.user_id);
    expect(findFriend([ana], "ANA SOUZA")?.user_id).toBe(ana.user_id);
    expect(findFriend([ana], "pedro")).toBeUndefined();
  });
});

// ---------------------------------------------------------------- alerts
describe("ApproachWatcher", () => {
  const me = { lat: 35.90227, lng: -79.04327, floor: null, place_slug: null, recorded_at: "" };
  const at = (lat: number, lng: number): Friend => ({ ...ana, lat, lng });
  const far = at(35.91094, -79.04781); // ~1 km
  const near = at(35.90300, -79.04327); // ~80 m

  test("alerts once when a watched friend crosses into the radius", () => {
    const w = new ApproachWatcher(150, 0);
    w.enable(ana.user_id);
    expect(w.tick([far], me, undefined, NOW)).toEqual([]);
    const alerts = w.tick([near], me, undefined, NOW + 1);
    expect(alerts).toHaveLength(1);
    expect(alerts[0]).toContain("Ana Souza is approaching you");
    expect(w.tick([near], me, undefined, NOW + 2)).toEqual([]); // no repeat while inside
  });

  test("no alert if they were already inside when the alert was set", () => {
    const w = new ApproachWatcher(150, 0);
    w.enable(ana.user_id);
    expect(w.tick([near], me, undefined, NOW)).toEqual([]);
  });

  test("alerts on approaching the owner's building", () => {
    const w = new ApproachWatcher(150, 0);
    w.enable(ana.user_id);
    const dorm = { lat: 35.91094, lng: -79.04781, name: "your dorm" };
    w.tick([at(35.92, -79.06)], null, dorm, NOW);
    const alerts = w.tick([at(35.9112, -79.0479)], null, dorm, NOW + 1);
    expect(alerts[0]).toContain("approaching your dorm");
  });

  test("cooldown suppresses flapping", () => {
    const w = new ApproachWatcher(150, 10 * 60_000);
    w.enable(ana.user_id);
    w.tick([far], me, undefined, NOW);
    expect(w.tick([near], me, undefined, NOW + 1)).toHaveLength(1);
    w.tick([far], me, undefined, NOW + 2);
    expect(w.tick([near], me, undefined, NOW + 3)).toHaveLength(0);
  });

  test("unwatched friends and disableAll", () => {
    const w = new ApproachWatcher(150, 0);
    expect(w.tick([near], me, undefined, NOW)).toEqual([]);
    w.enable(ana.user_id);
    w.disableAll();
    expect(w.isWatching(ana.user_id)).toBe(false);
  });

  test("distance sanity", () => {
    expect(distanceM(me, near)).toBeGreaterThan(70);
    expect(distanceM(me, near)).toBeLessThan(90);
  });
});

// ---------------------------------------------------------------- config & jwt
describe("config and tokens", () => {
  test("reports what is missing instead of crashing", () => {
    const { config, missing } = loadConfig({});
    expect(config).toBeUndefined();
    expect(missing.join(" ")).toContain("OWNER_PHONE");
  });

  test("works without Photon or Anthropic keys (mock + regex)", () => {
    const { config } = loadConfig({
      OWNER_PHONE: "919 555 0002", OWNER_USER_ID: "u", SUPABASE_URL: "http://x",
      SUPABASE_ANON_KEY: "a", SUPABASE_JWT_SECRET: "s",
    });
    expect(config?.ownerPhone).toBe(OWNER);
    expect(config?.photon).toBeUndefined();
    expect(config?.anthropicApiKey).toBeUndefined();
  });

  test("minted token is short-lived and scoped to the owner", async () => {
    const jwt = await mintUserJwt("secret", "owner-id", 300, NOW);
    const payload = JSON.parse(Buffer.from(jwt.split(".")[1]!, "base64url").toString());
    expect(payload.sub).toBe("owner-id");
    expect(payload.role).toBe("authenticated");
    expect(payload.exp - payload.iat).toBe(300);
  });
});
