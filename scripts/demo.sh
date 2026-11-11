#!/usr/bin/env bash
# MapChat local demo: starts the whole stack, seeds two demo accounts and
# simulates the roommate walking from Davis Library to Hinton James.
#
#   ./scripts/demo.sh            # full demo (Ctrl-C to stop)
#   ./scripts/demo.sh --check    # quick smoke test, exits when done
#
# Local only and free. It does NOT reset your local database; it only applies
# pending migrations and adds two demo accounts (demo-*@example.test).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH="$HOME/.bun/bin:$PATH"
LOGS="$ROOT/.demo-logs"; mkdir -p "$LOGS"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Docker engine (Colima)"
colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 8 --disk 60

step "Supabase (local)"
supabase status >/dev/null 2>&1 || supabase start
supabase migration up --local >/dev/null
eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY|JWT_SECRET)=')"

step "Valhalla routing engine"
if [ -f infra/valhalla/custom_files/north-carolina-latest.osm.pbf ] || ls infra/valhalla/custom_files/valhalla_tiles* >/dev/null 2>&1; then
  docker-compose -f infra/valhalla/docker-compose.yml up -d >/dev/null
  printf 'waiting for Valhalla'; for _ in $(seq 1 120); do curl -sf localhost:8002/status >/dev/null && break; printf '.'; sleep 5; done; echo
else
  echo "No OSM extract yet (run ./infra/valhalla/fetch_osm.sh). Continuing with straight-line walking."
fi

step "Routing service on :8787"
pkill -f "bun src/server.ts" 2>/dev/null || true
(cd routing && bun install --frozen-lockfile >/dev/null && SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY bun src/server.ts >"$LOGS/routing.log" 2>&1 &)
for _ in $(seq 1 20); do curl -sf localhost:8787/health >/dev/null && break; sleep 0.5; done
curl -sf localhost:8787/health >/dev/null && echo "routing OK" || { echo "routing failed, see $LOGS/routing.log"; exit 1; }

cleanup() { pkill -f "bun src/server.ts" 2>/dev/null || true; pkill -f "bun --no-env-file src/index.ts" 2>/dev/null || true; }
trap cleanup EXIT

if [ "${1:-}" = "--check" ]; then
  step "Smoke test: simulate 6 updates and verify you see Ana move"
  bun scripts/demo/simulate.ts --interval 1 --steps 6 --check
  exit 0
fi

step "Simulating Ana (Ctrl-C to stop)"
cat <<EOF
Optional, in another terminal, the agent with a mock iMessage (texts appear in the terminal):
  cd agent && OWNER_PHONE=+19195550000 OWNER_USER_ID=<You id printed below> \\
    SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=<ANON_KEY> SUPABASE_JWT_SECRET=<JWT_SECRET> \\
    POLL_SECONDS=5 bun --no-env-file src/index.ts
  then type: tell me when Ana is approaching
(ANON_KEY and JWT_SECRET: \`supabase status\`. They are local dev values.)
EOF
bun scripts/demo/simulate.ts --interval "${INTERVAL:-3}"
