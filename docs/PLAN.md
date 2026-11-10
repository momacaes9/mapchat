# MapChat — MVP Plan (v2)

A consent-based friend map. **Core MVP:** show my roommate's real-time
location next to mine on one map, and compute a **stair-aware walking route**
between us, both outdoors and inside UNC Chapel Hill buildings, including
which floor to go to and whether to take the elevator. An iMessage agent texts
**only me** with alerts and answers.

> v2 changes: the agent messages only the owner; real-time map plus routing is
> the core; there is stair-aware outdoor and indoor routing; the campus is UNC
> Chapel Hill; the map is Google Maps; the LLM is Claude; the license is MIT.

---

## 1. Decisions (locked)

| Topic | Decision |
|---|---|
| Map | **Google Maps SDK for iOS.** You create the Google Cloud billing account yourself (guide in §9); I never create it. |
| Text understanding | **Claude** (Anthropic API). You add `ANTHROPIC_API_KEY` to `agent/.env` yourself. |
| License | **MIT** |
| Campus | **UNC Chapel Hill**. Seed buildings: Davis Library, Undergraduate Library, Student Union, Ram Village, Hinton James, Gardner Hall, Phillips Hall, Hamilton Hall. |
| iMessage recipients | **Only the owner's number** (`OWNER_PHONE`). The agent never messages the roommate or anyone else. |

## 2. Hard constraints

| Constraint | Consequence |
|---|---|
| Find My / iMessage expose no API for other people's locations. | Both phones run the MapChat iOS app, which reports to our backend. No scraping of Find My or `chat.db`. |
| Opt-in and revocable. | The roommate explicitly accepts in the app and can **pause** or **stop** at any time. RLS enforces it. |
| iMessage via Photon (Spectrum). | `agent/` uses `spectrum-ts` + `@spectrum-ts/imessage`. Method names come from `agent/.agents/skills/spectrum/`, never guessed. |
| Floor = barometer. | `CMAltimeter` + `CLLocation.floor`. No computer vision. |

---

## 3. Architecture

```
 ┌──────────────── iOS app (both phones) ────────────────┐
 │ Google Maps view: me + roommate (Realtime)            │
 │ Route polyline + step list ("elevator to floor 3")    │
 │ Background location + CMAltimeter → ingest            │
 │ Sharing controls: accept / pause / stop               │
 └───────────┬──────────────────────────────┬────────────┘
             │ Supabase SDK                 │ HTTPS  GET /route
             ▼                              ▼
 ┌───────────────────────────┐   ┌────────────────────────────────┐
 │ Supabase                  │   │ routing/ (Bun + TS service)    │
 │ Postgres + PostGIS + RLS  │◀──│ outdoor: Valhalla pedestrian   │
 │ Auth (phone OTP)          │   │ indoor:  building graphs (A*)  │
 │ Realtime: latest_locations│   │ stitches outdoor + indoor legs │
 └───────────┬───────────────┘   └───────────────┬────────────────┘
             │ Realtime                          │
             ▼                                   │
 ┌───────────────────────────┐                   │
 │ agent/ (Bun + spectrum-ts)│───────────────────┘
 │ texts ONLY OWNER_PHONE    │  ◀── iMessage ──▶ me
 └───────────────────────────┘
        ┌──────────────────────┐
        │ Valhalla (Docker),   │  OSM extract clipped to Chapel Hill
        │ tiles built locally  │
        └──────────────────────┘
```

### Repo layout
```
mapchat/
  agent/      iMessage agent (owner-only)
  routing/    routing service: Valhalla client + indoor graph + stitcher
  routing/buildings/<slug>.json   indoor graphs, one per building
  supabase/   migrations, RLS, seed, pgTAP tests
  ios/        SwiftUI app
  ml/         floor estimator (later)
  infra/valhalla/  docker-compose + tile-build script
  docs/
```

---

## 4. Routing (stair-aware)

### 4.1 Outdoor: comparison

| | **Google Routes API (`WALK`)** | **Valhalla (`pedestrian` costing, self-hosted)** |
|---|---|---|
| Avoid or penalize stairs | **No.** The only walking route option is `avoidIndoor`. Nothing covers stairs or steps. | **Yes:** `step_penalty` (seconds added per transition onto steps); `type: "wheelchair"` raises it further. |
| Elevators | No control | `elevator_penalty` |
| Hills | No | `use_hills` (0 = avoid, 1 = don't care), relevant on UNC's slopes |
| Path preferences | No | `walkway_factor`, `sidewalk_factor`, `alley_factor`, `use_lit` (night walks) |
| Data quality on campus | Google's network is good, but you can't fix it | OSM: UNC paths and `highway=steps` are mapped, and **we can fix OSM ourselves** |
| Indoor integration | Opaque, can't stitch to our graph | Same graph concepts as our indoor model, so stitching is easy |
| Cost | Compute Routes Essentials: 10,000 free requests/month, then **$5.00 per 1,000** | Free (open source). Runs locally in Docker; hosting later is a small VM (§8) |
| Effort | Lowest (one HTTPS call) | Medium (Docker + build tiles for a Chapel Hill clip, ~minutes) |

**Recommendation: Valhalla.** Avoiding stairs is the core requirement, and
Google's walking mode can't do it. Valhalla can, and it can also avoid hills.
We clip OpenStreetMap to Chapel Hill, so the tiles are tiny and fit a ~512 MB
container. Routes are drawn as polylines **on Google Maps**, which keeps the
Google basemap you asked for. A Google Routes fallback can sit behind the same
interface later if Valhalla is down.

Routing profiles exposed by the API:
- `default`: `step_penalty` ≈ 30 s (mild aversion)
- `avoid_stairs`: high `step_penalty` (≈ 3600 s), prefer elevators/ramps; indoor stairs edges disabled
- `fastest`: `step_penalty` 0

### 4.2 Indoor: building graphs

Each building is a JSON graph in `routing/buildings/<slug>.json`:

```jsonc
{
  "building": "davis-library",
  "floors": [{ "level": 1, "label": "1", "height_m": 4.2 }, ...],
  "nodes": [
    { "id": "ent-main",   "floor": 1, "kind": "entrance", "lat": ..., "lng": ..., "osm_entrance": true },
    { "id": "elev-A-1",   "floor": 1, "kind": "elevator", "core": "A" },
    { "id": "stair-N-1",  "floor": 1, "kind": "stairs",   "core": "N" },
    { "id": "hall-1",     "floor": 1, "kind": "corridor" }
  ],
  "edges": [
    { "a": "ent-main", "b": "hall-1",   "type": "corridor", "meters": 20 },
    { "a": "elev-A-1", "b": "elev-A-3", "type": "elevator", "seconds": 45 },
    { "a": "stair-N-1","b": "stair-N-2","type": "stairs",   "seconds": 20, "steps": 22 }
  ]
}
```

- **The MVP granularity is coarse on purpose**: entrances, one corridor hub
  per floor, each stair core and each elevator per floor. That's enough for
  "enter by the main entrance, take elevator A to floor 3".
- Algorithm: A* over the indoor graph with the same profile weights (stairs
  edges cost `step_penalty`, or are removed under `avoid_stairs`; elevator
  edges carry a fixed wait plus a per-floor cost).
- **Stitching:** I'll run Valhalla to *each* entrance of the destination
  building (≤ 4), add the indoor cost from that entrance to the roommate's
  floor, and pick the minimum. Same thing reversed if *I'm* inside a building.
- **Data:** building footprints and entrances come from OSM via Overpass
  (script, no hand-typed coordinates). **Floor counts, elevator and stair cores
  are not in OSM for most of these buildings**, so each graph starts as a
  template marked `"verified": false` and you confirm it on a walk-through.
  Ram Village is several buildings, so it becomes one graph per building.
- Output = a step list: outdoor maneuvers from Valhalla + indoor steps
  (`"Enter Davis Library (main entrance)"`, `"Take elevator A to floor 3"`).

### 4.3 Routing API
`GET /route?from=me&to=roommate&profile=avoid_stairs` →
`{ polyline, duration_s, distance_m, steps[], indoor: {building, target_floor} }`.
Auth uses the caller's Supabase JWT. The service re-checks `can_view` before
reading the roommate's location, so the route endpoint can't leak anything RLS
would hide.

---

## 5. Data model (Postgres)

```sql
profiles      (id → auth.users, display_name, phone_e164, sharing_paused bool, created_at)
share_grants  (id, owner_id, viewer_id, status pending|active|paused|revoked,
               precision exact|building, allow_floor bool, created_at, updated_at,
               unique(owner_id, viewer_id))
locations     (id, user_id, geog Point, accuracy_m, floor_apple, rel_altitude_m,
               pressure_kpa, floor_est, place_id, recorded_at)      -- 7-day retention
latest_locations  -- one row per user, maintained by trigger; Realtime publishes this
places        (id, slug, name, kind building|home, owner_id null, geom Polygon,
               floors int null, floor_height_m, ground_altitude_m, verified bool)
alerts        (id, watcher_id, target_id, kind approaching_me|arrives_place|floor_change,
               place_id, radius_m, one_shot, active, created_at, last_fired_at)
alert_events  (id, alert_id, fired_at, payload jsonb)
floor_eval    (id, user_id, place_id, floor_est, floor_truth, method, recorded_at)
```

`watcher_id` is always the owner in the MVP. Only the agent delivers alerts,
and it sends them only to `OWNER_PHONE`.

---

## 6. Privacy model

1. **Default deny.** RLS everywhere. Reads of another user's location pass
   through `can_view(owner, viewer)`: an active grant, the owner not paused,
   and the grant not paused or revoked.
2. **Opt-in.** A grant starts `pending`. Only the **owner of the location**
   (the roommate) can move it to `active`, and RLS enforces who may update
   which column.
3. **Pause / stop.** A global pause (the app also stops GPS uploads), a
   per-grant pause, or revoked. All take effect on the next read. Revoking also
   deactivates alerts targeting that person.
4. **Alert transparency without messaging the roommate.** The roommate sees
   every alert about them **in the app** (a "Who has alerts on me" screen) and
   can delete any of them. The agent never texts them.
5. **Precision.** `building` precision snaps coordinates to the building
   centroid and hides the floor if `allow_floor = false`.
6. **Agent least privilege.** The agent identifies the sender. **If the sender
   isn't `OWNER_PHONE`, it ignores the message and never replies.** Every send
   goes through one `sendToOwner()` wrapper that asserts the recipient, so
   there is no other send path, and a unit test covers it.
7. **Retention.** Location history is deleted after 7 days (`pg_cron`).
8. **Secrets.** The repo is public. Only `*.example` files are committed, and
   `.env` / `Secrets.xcconfig` are gitignored.

---

## 7. Agent (owner-only)

- Inbound from the owner → Claude parses it into strict JSON
  `{intent: where_is|route_to|alert_approach|alert_arrive|pause_alerts|help, target?, place?, profile?}`.
  A regex fast path handles common phrases. **Facts come from the DB, never
  from the model.**
- `where_is` → "Ana is in Davis Library, floor 3 (1 min ago)" plus a Google
  Maps link.
- `route_to` → "8 min walk, no stairs: … take elevator A to floor 3" plus a
  link to the in-app route.
- Alerts to the owner: approaching (radius around me, hysteresis), arrives at
  a place, floor change (stable ≥ 20 s).
- Photon free/pro shared pool: only the owner must be registered as a project
  user. That keeps the MVP on the free plan.

## 8. Floor estimation
On building entry: zero `CMAltimeter`, seed from `CLLocation.floor` if present,
then `floor = entry_floor + round(Δalt / floor_height_m)` with a ±0.8 m dead
band. Manual "I'm on floor N" confirmations go to `floor_eval`. `ml/` fits
per-building parameters later.

---

## 9. Cost overview and Google Cloud billing guide (you do it)

| Item | Cost |
|---|---|
| Supabase | Free tier (local dev is free; one hosted free project) |
| Photon | Free/Pro shared pool. A dedicated number is the paid Business plan, so I'll ask first |
| Google Maps SDK for iOS | Free for map loads, but **a billing account is required** to get a key |
| Valhalla | Free locally. Hosting is a small VM later; **I'll quote and ask before any hosting** |
| Anthropic API | Pay-per-use. Intent parsing is a few hundred tokens per text, about cents per month for one user |
| Apple Developer Program | $99/year, needed to run on your roommate's phone beyond 7-day dev builds / TestFlight |

**Google Cloud steps (you run them):**
1. console.cloud.google.com → create project `mapchat`.
2. Billing → create a billing account (card required) → link it to the project.
3. Billing → Budgets & alerts → a budget of e.g. **$5/month** with email alerts at 50/90/100 %.
4. APIs & Services → Library → enable **Maps SDK for iOS** only.
5. Credentials → Create API key → restrict it to **iOS apps** with your bundle ID
   (e.g. `edu.unc.mapchat`), API restriction = Maps SDK for iOS.
6. Paste the key into `ios/Secrets.xcconfig` (gitignored), never into code.

---

## 10. Phases

**Phase 1 — Plan** ✅ (v2 awaiting approval)

**Phase 2 — Repo setup**
- [x] Monorepo, root `.gitignore`, agent scaffold
- [ ] README, `LICENSE` (MIT), root `.env.example`

**Phase 3 — Backend (Supabase)** *(next after approval)*
- [ ] `supabase init`, PostGIS, migrations for §5
- [ ] RLS + `can_view()` + precision view; grant state machine (only the location owner can activate)
- [ ] Seed: the 8 UNC buildings (footprints from OSM via Overpass script, `verified=false`)
- [ ] pgTAP tests: a stranger can't read; pending, paused and revoked can't read; the viewer can't self-activate a grant; the viewer can't write others' locations; precision snapping
- [ ] Runs locally via `supabase start`; no hosted resources yet

**Phase 4 — Routing**
- [ ] `infra/valhalla`: docker-compose + script that clips OSM to Chapel Hill and builds tiles
- [ ] `routing/`: Valhalla client with the 3 profiles, indoor A*, stitcher, `/route` endpoint
- [ ] Indoor graph templates for the 8 buildings + JSON schema validation
- [ ] Tests: `avoid_stairs` never yields a stairs edge; elevator chosen for a floor change; outdoor routes avoid `highway=steps` on fixture tiles

**Phase 5 — iOS MVP**
- [ ] Phone-OTP sign-in, invite → roommate accepts, pause/stop, "alerts on me" screen
- [ ] Google Maps with me + roommate (Realtime), route polyline + step list + profile toggle
- [ ] Background location + altimeter upload

**Phase 6 — Agent (owner-only)**
- [ ] `sendToOwner()` guard + tests, ignore all non-owner senders
- [ ] Claude intent parser, `where_is`, `route_to`, proximity/arrival/floor alerts

**Phase 7 — Floor estimation and evaluation**
- [ ] Altimeter pipeline, `floor_eval` logging, `ml/` estimator and accuracy report
