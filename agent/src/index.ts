/**
 * MapChat iMessage agent.
 *
 * Rules enforced here:
 *   * Messages from anyone other than OWNER_PHONE are ignored (no reply).
 *   * Every outgoing message goes through OwnerOnlySender, which can only
 *     send to OWNER_PHONE (it never replies into the inbound conversation).
 *   * Replies are built from the database/routing service, never the LLM.
 *
 * Without Photon credentials it runs with a mock messenger on stdin/stdout.
 */
import { createInterface } from "node:readline";
import { ApproachWatcher } from "./alerts";
import { loadConfig } from "./config";
import { SupabaseOwnerData } from "./data";
import { handleText } from "./handler";
import { ClaudeIntentParser, type IntentParser, RegexOnlyParser } from "./intent";
import { OwnerOnlySender, type RawSend } from "./owner";
import { RateLimiter } from "./ratelimit";

export interface Inbound {
  sender: string | null;
  text: string;
}

export interface Transport {
  inbound: AsyncIterable<Inbound>;
  rawSend: RawSend;
}

async function spectrumTransport(projectId: string, projectSecret: string): Promise<Transport> {
  const { Spectrum } = await import("spectrum-ts");
  const { imessage } = await import("@spectrum-ts/imessage");
  const app = await Spectrum({ projectId, projectSecret, providers: [imessage.config()] });
  const im = imessage(app);

  async function* inbound(): AsyncIterable<Inbound> {
    for await (const [, message] of app.messages) {
      if (message.platform !== "imessage" || message.content.type !== "text") continue;
      yield { sender: message.sender?.id ?? null, text: message.content.text };
    }
  }

  return {
    inbound: inbound(),
    // Always opens the owner's own 1:1 conversation; never the inbound space.
    rawSend: async (phone, text) => {
      const owner = await im.user(phone);
      const dm = await im.space.create(owner);
      await dm.send(text);
    },
  };
}

function mockTransport(ownerPhone: string): Transport {
  const rl = createInterface({ input: process.stdin });
  async function* inbound(): AsyncIterable<Inbound> {
    console.log(`[mock] Type messages as the owner (${ownerPhone}). Prefix with "from:+1555... " to simulate someone else.`);
    for await (const line of rl) {
      const m = line.match(/^from:(\S+)\s+(.*)$/);
      yield m ? { sender: m[1]!, text: m[2]! } : { sender: ownerPhone, text: line };
    }
  }
  return { inbound: inbound(), rawSend: async (phone, text) => console.log(`[mock → ${phone}] ${text}`) };
}

export async function runAgent(
  transport: Transport,
  deps: {
    sender: OwnerOnlySender;
    parser: IntentParser;
    data: SupabaseOwnerData | import("./data").LocationData;
    watcher: ApproachWatcher;
    inboundLimiter?: RateLimiter;
  },
) {
  const limiter = deps.inboundLimiter ?? new RateLimiter(10, 10 / 60); // 10 per minute
  for await (const msg of transport.inbound) {
    if (!deps.sender.isOwner(msg.sender)) continue; // never answer non-owners
    if (!limiter.take("owner")) continue; // drop floods silently
    const text = msg.text.trim().slice(0, 500);
    if (!text) continue;
    try {
      await deps.sender.sendToOwner(await handleText(text, deps));
    } catch (err) {
      console.error("handler error:", err instanceof Error ? err.message : err);
      await deps.sender.sendToOwner("Something went wrong looking that up. Try again in a minute.");
    }
  }
}

if (import.meta.main) {
  const { config, missing } = loadConfig();
  if (missing.length) console.warn(`Missing/optional settings: ${missing.join(", ")} (see docs/QUESTIONS.md)`);
  if (!config) {
    console.error("Cannot start: required settings are missing. Copy agent/.env.example to agent/.env.");
    process.exit(1);
  }

  const transport = config.photon
    ? await spectrumTransport(config.photon.projectId, config.photon.projectSecret)
    : mockTransport(config.ownerPhone);
  const sender = new OwnerOnlySender(config.ownerPhone, transport.rawSend);
  const parser = config.anthropicApiKey ? new ClaudeIntentParser(config.anthropicApiKey) : new RegexOnlyParser();
  const data = new SupabaseOwnerData(config);
  const watcher = new ApproachWatcher(config.alertRadiusM);
  const home =
    process.env.OWNER_HOME_LAT && process.env.OWNER_HOME_LNG
      ? { lat: Number(process.env.OWNER_HOME_LAT), lng: Number(process.env.OWNER_HOME_LNG), name: process.env.OWNER_HOME_NAME ?? "your building" }
      : undefined;

  // Alert loop: poll every POLL_SECONDS (cheap: two RPCs).
  setInterval(async () => {
    try {
      const [friends, me] = await Promise.all([data.friends(), data.me()]);
      for (const text of watcher.tick(friends, me, home)) await sender.sendToOwner(text);
    } catch (err) {
      console.error("alert tick failed:", err instanceof Error ? err.message : err);
    }
  }, config.pollSeconds * 1000);

  console.log(`MapChat agent running (${config.photon ? "iMessage via Photon" : "mock messenger"}).`);
  await runAgent(transport, { sender, parser, data, watcher });
}
