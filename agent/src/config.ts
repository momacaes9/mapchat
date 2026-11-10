/** Agent configuration from environment variables (agent/.env, gitignored). */
import { normalizePhone } from "./owner";

export interface AgentConfig {
  ownerPhone: string;
  ownerUserId: string;
  supabaseUrl: string;
  supabaseAnonKey: string;
  /** Used ONLY to mint short-lived tokens for the owner (never a service role). */
  supabaseJwtSecret: string;
  routingUrl: string;
  anthropicApiKey?: string;
  photon?: { projectId: string; projectSecret: string };
  alertRadiusM: number;
  pollSeconds: number;
}

export function loadConfig(env: Record<string, string | undefined> = process.env): {
  config?: AgentConfig;
  missing: string[];
} {
  const required = [
    "OWNER_PHONE",
    "OWNER_USER_ID",
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_JWT_SECRET",
  ] as const;
  const missing: string[] = required.filter((k) => !env[k]);
  if (!env.ANTHROPIC_API_KEY) missing.push("ANTHROPIC_API_KEY (optional: regex fallback is used)");
  if (!env.PROJECT_ID || !env.PROJECT_SECRET) missing.push("PROJECT_ID/PROJECT_SECRET (optional: mock messenger is used)");

  const hard = required.filter((k) => !env[k]);
  if (hard.length) return { missing };

  const ownerPhone = normalizePhone(env.OWNER_PHONE!);
  if (!ownerPhone) return { missing: ["OWNER_PHONE (must be E.164, e.g. +19195551234)", ...missing] };

  return {
    missing,
    config: {
      ownerPhone,
      ownerUserId: env.OWNER_USER_ID!,
      supabaseUrl: env.SUPABASE_URL!,
      supabaseAnonKey: env.SUPABASE_ANON_KEY!,
      supabaseJwtSecret: env.SUPABASE_JWT_SECRET!,
      routingUrl: env.ROUTING_URL ?? "http://localhost:8787",
      anthropicApiKey: env.ANTHROPIC_API_KEY || undefined,
      photon:
        env.PROJECT_ID && env.PROJECT_SECRET
          ? { projectId: env.PROJECT_ID, projectSecret: env.PROJECT_SECRET }
          : undefined,
      alertRadiusM: Number(env.ALERT_RADIUS_M ?? 150),
      pollSeconds: Number(env.POLL_SECONDS ?? 30),
    },
  };
}
