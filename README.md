# MapChat

A consent-based friend map for roommates on the UNC Chapel Hill campus. It
shows your roommate's real-time location next to yours, computes a
**stair-aware walking route** between you (outdoors and inside buildings, e.g.
"take elevator A to floor 3"), and includes an iMessage agent that texts
**only you** with alerts and answers.

Both people run the MapChat app. Sharing is opt-in, and it can be paused or
stopped at any time. MapChat never reads Find My or the Messages database.

See [`docs/PLAN.md`](docs/PLAN.md) for the architecture, data model, privacy
model and phases.

## Repo layout

| Path | What |
|---|---|
| `agent/` | iMessage agent (Bun + [Spectrum](https://photon.codes/docs/spectrum-ts)), owner-only |
| `supabase/` | Postgres schema, RLS policies, seed data, pgTAP tests |
| `routing/` | Routing: Valhalla client and indoor building graphs |
| `infra/valhalla/` | Local Valhalla (Docker) for pedestrian routing |
| `ios/` | SwiftUI app (Google Maps SDK) |
| `ml/` | Floor-estimation experiments (later) |
| `docs/` | Plan, evaluation, session notes |

## Quick start (local, free)

Requirements: Homebrew, a Docker runtime (Docker Desktop or Colima),
[Bun](https://bun.sh), and the Supabase CLI.

```sh
# Backend
supabase start          # local Postgres/Auth/Realtime in Docker
supabase db reset       # apply migrations + seed
supabase test db        # run the RLS tests

# Agent
cd agent && cp .env.example .env   # fill in values; .env is gitignored
bun install && bun start
```

## Secrets

This repo is **public**. Real values live only in gitignored files (`.env`,
`ios/Secrets.xcconfig`). Only `*.example` files are committed.

## License

[MIT](LICENSE)
