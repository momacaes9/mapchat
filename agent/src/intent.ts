/**
 * Turns the owner's text into a structured intent. Claude ONLY classifies the
 * request and extracts a name; every fact in a reply comes from the database.
 */
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";

export const IntentSchema = z.object({
  intent: z.enum(["where_is", "route_to", "alert_on", "alert_off", "list", "help"]),
  /** Person's name exactly as the user wrote it, or null. */
  target: z.string().nullable(),
  /** Route preference; avoid_stairs unless the user asks otherwise. */
  profile: z.enum(["avoid_stairs", "default", "fastest"]).nullable(),
});
export type Intent = z.infer<typeof IntentSchema>;

export interface IntentParser {
  parse(text: string): Promise<Intent>;
}

const NAME = "([A-Za-zÀ-ÿ' -]{1,40}?)";

/** Deterministic parser for common phrasings (no API call, no cost). */
export function fastPath(text: string): Intent | null {
  const t = text.trim().replace(/[?!.]+$/, "");
  let m: RegExpMatchArray | null;
  if ((m = t.match(new RegExp(`^(?:where(?:'s| is)|where's|find|locate)\\s+${NAME}$`, "i")))) {
    return { intent: "where_is", target: m[1]!.trim(), profile: null };
  }
  if ((m = t.match(new RegExp(`^(?:route|directions|walk|take me)\\s+to\\s+${NAME}(\\s+fastest|\\s+with stairs)?$`, "i")))) {
    const profile = m[2] ? (/fastest/i.test(m[2]) ? "fastest" : "default") : "avoid_stairs";
    return { intent: "route_to", target: m[1]!.trim(), profile };
  }
  if ((m = t.match(new RegExp(`^(?:alert|tell|notify) me when\\s+${NAME}\\s+(?:is )?(?:approaching|close|near|gets? (?:here|close|near))(?: me| my building)?$`, "i")))) {
    return { intent: "alert_on", target: m[1]!.trim(), profile: null };
  }
  if (/^(stop|cancel|turn off) (alerts?|notifications?)$/i.test(t)) return { intent: "alert_off", target: null, profile: null };
  if (/^(who|list|friends|who'?s sharing)/i.test(t)) return { intent: "list", target: null, profile: null };
  if (/^(help|\?|commands)$/i.test(t)) return { intent: "help", target: null, profile: null };
  return null;
}

const SYSTEM = `You classify a short text message sent to a friend-location assistant.
Return the user's intent:
- where_is: they ask where a person is.
- route_to: they want walking directions to a person. profile is "avoid_stairs" unless they ask for stairs or the fastest way.
- alert_on: they want to be notified when a person approaches them or their building.
- alert_off: they want such alerts stopped.
- list: they ask who is sharing or who they can see.
- help: anything else.
target is the person's name exactly as written (null if none). Never invent locations or names.`;

export class ClaudeIntentParser implements IntentParser {
  private readonly client: Anthropic;

  constructor(apiKey: string) {
    this.client = new Anthropic({ apiKey, maxRetries: 2, timeout: 20_000 });
  }

  async parse(text: string): Promise<Intent> {
    const fast = fastPath(text);
    if (fast) return fast;
    const response = await this.client.messages.parse({
      model: "claude-opus-5-5",
      max_tokens: 1024,
      system: SYSTEM,
      // Simple classification: low effort keeps latency and cost down.
      output_config: { effort: "low", format: zodOutputFormat(IntentSchema) },
      messages: [{ role: "user", content: text.slice(0, 500) }],
    });
    if (response.stop_reason === "refusal" || !response.parsed_output) {
      return { intent: "help", target: null, profile: null };
    }
    return response.parsed_output;
  }
}

/** Used when no ANTHROPIC_API_KEY is configured. */
export class RegexOnlyParser implements IntentParser {
  async parse(text: string): Promise<Intent> {
    return fastPath(text) ?? { intent: "help", target: null, profile: null };
  }
}
