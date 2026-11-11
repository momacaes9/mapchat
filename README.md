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
| `routing/` | `/route` service: Valhalla outdoor + indoor building graphs |
| `infra/valhalla/` | Local Valhalla (Docker) for pedestrian routing |
| `ios/` | SwiftUI app (MapKit now, Google Maps later via one file) |
| `ml/` | Floor-estimation experiments (later) |
| `docs/` | Plan, evaluation, session notes |

## Quick start (local, free)

### 1. One-time setup (macOS)

MapChat uses **Colima**, a free, open-source Docker engine, instead of
Docker Desktop.

```sh
brew install colima docker docker-compose supabase/tap/supabase xcodegen
curl -fsSL https://bun.sh/install | bash       # Bun runtime

# Start the Docker engine (4 CPUs, 8 GB RAM, 60 GB disk is enough for
# Supabase + Valhalla). Run `colima start` again after every reboot.
colima start --cpu 4 --memory 8 --disk 60
docker context use colima
```

Notes:
- Use `docker-compose` (with a hyphen); the `docker compose` plugin form is
  not installed with Homebrew's Docker CLI.
- Supabase analytics is disabled in `supabase/config.toml` because it needs
  Docker Desktop's socket.
- If `xcodebuild` says the developer directory is the Command Line Tools, run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or
  `sudo xcode-select -s /Applications/Xcode.app`).

### 2. Run the stack

```sh
supabase start && supabase db reset && supabase test db   # DB + RLS tests

./infra/valhalla/fetch_osm.sh                              # NC map extract (~430 MB, once)
docker-compose -f infra/valhalla/docker-compose.yml up -d  # routing engine on :8002

cd routing && bun install && bun test                      # routing + /route tests
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<from supabase status> bun src/server.ts

cd ../agent && cp .env.example .env && bun install && bun test
```

### Demo mode

```sh
./scripts/demo.sh            # starts everything, seeds 2 demo accounts, Ana walks to you
./scripts/demo.sh --check    # 20-second smoke test
```

Sign in to the Simulator app as `demo-you@example.test` (the code is in Mailpit,
http://127.0.0.1:54324) to watch Ana move from Davis Library (floor 3 → 1) to
Hinton James along a stair-free route. The script prints how to run the agent
with a mock iMessage, which sends "Ana is approaching you" as she gets close.
For a UI-only demo without any backend, launch the app with the
`-mockBackend` argument (Xcode → Scheme → Arguments).

### 3. Stop everything

```sh
supabase stop
docker-compose -f infra/valhalla/docker-compose.yml down
colima stop
```

## Secrets

This repo is **public**. Real values live only in gitignored files (`.env`,
`ios/Config/Secrets.xcconfig`). Only `*.example` files are committed.

## License

[MIT](LICENSE)
