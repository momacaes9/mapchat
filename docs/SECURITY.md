# Security review — 2026-11-10

Scope: Supabase schema and RLS, the `/route` service, the iMessage agent, the
iOS app, the repository and its history, dependencies, and CI. Everything ran
locally.

## Summary

| Area | Result |
|---|---|
| RLS on every table | ✅ RLS enabled on all 8 `public` tables, each with explicit policies; `anon` has **no** table privileges |
| Secrets in git history | ✅ None. Checked with gitleaks (19 commits) plus a targeted scan for the Photon secret, `sk-ant-…`, `sb_secret_…`, JWTs, private keys and Google API keys. No `.env` / `Secrets.xcconfig` was ever committed |
| Input validation | ✅ `/route`: strict params, UUID/enum/coordinate checks, unknown params rejected. DB: CHECK constraints plus RPC argument checks. Agent: owner-only, length caps |
| Rate limiting | ✅ `/route` per IP (60 burst, 1/s) and per user (20/min). Agent: 10 inbound/min, 30 outbound/hour. Invites: 20/hour per user in the DB |
| 7-day retention | ✅ Hourly `pg_cron` job purges `locations`, `latest_locations` and `alert_events` older than 7 days (tested) |
| Dependency audit | ✅ `bun audit` is clean for `routing` and `agent` after fixing 1 moderate issue (below) |

## Fixed in this review (migration `0008_security_hardening`)

1. **Phone-number takeover (high).** Users could set `profiles.phone_e164`
   to someone else's number. A friend who then used "share my location with
   +1…" would have shared with the impostor. Users can now update only
   `display_name` and `sharing_paused`. The phone comes only from the
   OTP-verified `auth.users.phone`, via a trigger.
2. **Account enumeration (medium).** `request_share()` / `share_with()`
   returned a grant id only when the contact had an account. Both now return
   nothing in every case, and the app shows one neutral message.
3. **Invite spam (low).** At most 20 invites/shares per user per hour
   (`54000` error after that).
4. **Retention bypass (medium).** A client could upload a far-future
   `recorded_at`, which would never age out and would pin a fake "latest"
   point. Timestamps must now fall between 1 day ago and 5 minutes ahead.
   Retention now also covers `latest_locations` and `alert_events`.
5. **Client-controlled `place_id` (low).** The server always recomputes it
   from the point.
6. **Sanity constraints** on accuracy, floors and pressure.
7. **Default privileges.** Future `public` tables and functions are not
   granted to `anon`, and internal trigger functions are not executable by
   `PUBLIC`.
8. **Vulnerable transitive dependency.** `@opentelemetry/core` < 2.8.0
   (GHSA-8988-4f7v-96qf, moderate) came in via `spectrum-ts`. It is pinned to
   `^2.8.0` with an `overrides` entry in `agent/package.json`.

Tests: `supabase/tests/rls_security.test.sql` (10 assertions) covers 1, 3, 4,
5 and 6. Earlier suites cover RLS (strangers; pending, paused, revoked and
deleted grants; owner-only activation; no cross-user writes; precision).

## Design properties worth keeping

- **One read path for other people's locations:** `visible_friends()`. Raw
  `locations` / `latest_locations` are self-only. `/route` and the agent call
  it with the user's own token (the agent mints a 5-minute owner token), so
  neither service ever holds a service-role key.
- **Realtime pings carry no coordinates.** Clients refetch through
  `visible_friends()`, and the private topic is RLS-protected
  (`realtime.messages`).
- **Building precision** never leaves the database with exact coordinates,
  accuracy, or a hidden floor. `/route` tests confirm the exact point is not
  even passed to the outdoor router.
- **The agent cannot message anyone but the owner.** `OwnerOnlySender` is the
  only send path, and it always opens the owner's own DM, never the inbound
  conversation.

## Remaining items (not fixed; need a decision or hosting)

| # | Item | Risk | Suggested fix |
|---|---|---|---|
| R1 | `SUPABASE_JWT_SECRET` in the agent's `.env` can mint a token for **any** user, not only the owner. | Medium if the agent host is compromised | In production, create a dedicated "agent" auth user that the owner shares with, and sign in as it with a refresh token; or use Supabase's asymmetric JWT signing keys plus a narrowly scoped edge function. |
| R2 | The rate limiters are in-memory (per process). | Low for one instance | Use a shared store (Postgres table or Redis) before running more than one instance. |
| R3 | `/route` has no TLS locally. | Low locally | Terminate TLS at the host (Fly/Render/Cloudflare) when deployed. |
| R4 | GitHub Actions are pinned to major tags (`@v4`), not commit SHAs. | Low | Pin to SHAs and enable Dependabot for `github-actions`. |
| R5 | Supabase Auth email OTP rate limits use the defaults in `supabase/config.toml`. | Low | Review `[auth.rate_limit]` before going public; add CAPTCHA if abuse appears. |
| R6 | A requester picks `precision`/`allow_floor` on a *pending* request, and the owner accepts them as they are. | Low (UX) | The owner sees and can change both in the Sharing tab; consider forcing `building` until the owner chooses. |
| R7 | The local stack uses well-known dev keys (`supabase status`). | None locally | Never reuse them; a hosted project gets its own keys (in GitHub secrets and gitignored files only). |
| R8 | The iOS `NSAllowsLocalNetworking` exception allows http to localhost. | None in production builds talking to https | Keep it (it doesn't relax ATS for the internet). |
| R9 | Branch protection on `main` is not enabled. | Medium (process) | Settings → Branches: require PRs and the `CI` checks (`backend`, `agent`, `ios`) to pass. |
