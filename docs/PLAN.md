# MapChat — MVP Plan

A consent-based friend map for roommates and close friends on a college campus.
One map shows everyone who has chosen to share with you, and an iMessage agent
sends alerts ("Ana is approaching your building", "Ana went up 2 floors") and
answers questions ("where is Pedro?").

---

## 1. Hard constraints (and what they rule out)

| Constraint | Consequence |
|---|---|
| Apple Find My / iMessage expose **no** API for other people's locations. | Every sharer installs the MapChat iOS app, which reports to our backend. We never scrape Find My, the Messages database, or `chat.db`. |
| Sharing is opt-in and revocable. | Grants are explicit, per-viewer, pausable, deletable. The sharer is notified when someone sets an alert on them. |
| iMessage goes through Photon (Spectrum). | `agent/` uses `spectrum-ts` + `@spectrum-ts/imessage` (cloud provider). Method names come from the bundled skill docs in `agent/.agents/skills/spectrum/`, never guessed. |
| Floor = barometer, not vision. | `CMAltimeter` relative altitude + `CLLocation.floor` when Apple provides it. |

**Pins shared in iMessage (optional, to verify).** When someone taps "Send My
Current Location" in iMessage, the recipient gets a one-time location pin, not
live tracking. If Spectrum delivers that pin to the agent as an `attachment`
(a `.loc.vcf` file), the agent could treat it as an explicit one-time check-in.
We will test this in Phase 5; until then it is an unverified stretch goal.

---

## 2. Architecture

```
 ┌──────────────────────┐        ┌───────────────────────────────┐
 │ iOS app (SwiftUI)    │  HTTPS │ Supabase                      │
 │ - Sign in (phone OTP)│───────▶│ Postgres + PostGIS + RLS      │
 │ - Google Maps map    │◀───────│ Auth (phone OTP)              │
 │ - Sharing controls   │ Realtime│ Realtime (locations channel) │
 │ - Background loc +   │        │ Edge Function: ingest_location│
 │   CMAltimeter        │        └──────────────┬────────────────┘
 └──────────────────────┘                       │ DB webhook / Realtime
                                                ▼
                               ┌────────────────────────────────┐
   iMessage  ◀──── Photon ────▶│ agent/ (Bun + spectrum-ts)     │
   (user)       Spectrum Cloud │ - proximity + floor alerts     │
                               │ - NL query → LLM → JSON intent │
                               │ - answers from DB only         │
                               │ - Google Maps links in replies │
                               └────────────────────────────────┘
                                                │
                               ┌────────────────────────────────┐
                               │ ml/ (Python, later phase)      │
                               │ pressure → floor estimator     │
                               └────────────────────────────────┘
```

### Map: Google Maps (as you asked), with MapKit as the fallback
- **iOS map:** Google Maps SDK for iOS (via Swift Package Manager). It needs an
  API key restricted to the app's bundle ID. Dynamic maps in the mobile SDK
  have no per-load charge, but Google still requires a billing account on the
  Cloud project. **I will ask before you enable billing.**
- **iMessage replies:** universal Google Maps links
  (`https://www.google.com/maps/search/?api=1&query=LAT,LNG`). They need no key
  and cost nothing, and they open in the Google Maps app.
- **Place names ("near Butler Library"):** we start with our own `places` table
  (campus buildings plus each user's saved "home"), which is free and exact.
  Google Geocoding/Places is optional later because it is billed per request.
- MapKit stays a one-file swap if you'd rather avoid a Google Cloud billing
  account.

### Repo layout (monorepo)
```
mapchat/
  agent/      Bun + spectrum-ts iMessage agent (scaffolded by create-spectrum-project)
  supabase/   migrations, RLS policies, seed, pgTAP tests, edge functions
  ios/        Xcode project (SwiftUI)
  ml/         Python floor estimator (later)
  docs/       PLAN.md, PRIVACY.md
```

---

## 3. Data model (Postgres, `public` schema)

```sql
profiles (
  id uuid pk references auth.users,
  display_name text not null,
  phone_e164 text unique,            -- links iMessage sender to account
  home_place_id uuid null references places,
  sharing_paused boolean default false,
  created_at timestamptz default now()
)

share_grants (                         -- one row = "owner lets viewer see me"
  id uuid pk,
  owner_id uuid references profiles,   -- the person being located
  viewer_id uuid references profiles,
  status text check (status in ('pending','active','paused','revoked')),
  precision text check (precision in ('exact','building','campus')) default 'exact',
  allow_floor boolean default true,
  created_at, updated_at,
  unique (owner_id, viewer_id)
)

locations (                            -- append-only history, short retention
  id bigint identity pk,
  user_id uuid references profiles,
  geog geography(Point,4326) not null,
  accuracy_m real,
  floor_apple int null,                -- CLLocation.floor.level
  rel_altitude_m real null,            -- CMAltimeter since building entry
  pressure_kpa real null,
  floor_est int null,                  -- our estimate
  place_id uuid null references places,
  recorded_at timestamptz not null
)
latest_locations  -- view (or table kept fresh by trigger): one row per user

places (                               -- campus buildings + user homes
  id uuid pk, name text, kind text check (kind in ('building','home')),
  owner_id uuid null,                  -- set for 'home'
  geom geography(Polygon,4326), floors int null, floor_height_m real null,
  ground_altitude_m real null
)

alerts (                               -- "tell me when Ana gets home"
  id uuid pk,
  watcher_id uuid references profiles,
  target_id  uuid references profiles,
  kind text check (kind in ('approaching_me','arrives_place','floor_change')),
  place_id uuid null, radius_m int default 150,
  one_shot boolean default true,
  active boolean default true,
  target_notified_at timestamptz null, -- sharer was told this alert exists
  created_at, last_fired_at
)

alert_events (id, alert_id, fired_at, payload jsonb)   -- audit and dedupe
floor_eval   (id, user_id, place_id, floor_est, floor_truth, method, recorded_at)
```

---

## 4. Privacy model

1. **Default deny.** RLS on every table. A viewer can read a `locations` row
   only if an `active` grant `owner → viewer` exists **and** the owner has not
   paused sharing. This runs in one `security definer` function,
   `can_view(owner, viewer)`, which every policy uses.
2. **Precision downgrade.** If the grant is `building` or `campus`, the
   viewer reads through a view that snaps coordinates to the place centroid or
   to null. The raw table is never exposed to them.
3. **Pause / stop.** Pause = `profiles.sharing_paused` (global) or
   `share_grants.status='paused'` (per person). Stop = `revoked`. Both take
   effect immediately in RLS, and the app also stops sending GPS while globally
   paused.
4. **Alert transparency.** An insert into `alerts` triggers an iMessage to the
   target: "Pedro set an alert for when you get home. Reply STOP-ALERTS to
   block." The target can block alerts per watcher.
5. **Agent is not a superuser.** The agent uses the service role only to
   resolve the sender's phone to a profile. Every location read then goes
   through `get_visible_location(viewer_id, target_name)`, which applies the
   same `can_view` check. The LLM only produces a JSON intent and never sees raw
   data it shouldn't relay.
6. **Retention.** History older than 7 days is deleted by a `pg_cron` job, and
   floor-eval data is kept anonymized.
7. **Secrets.** `.env` and `Secrets.xcconfig` are gitignored, and only
   `*.example` files are committed. **This repo is public**, so this rule
   is critical.

---

## 5. Agent (iMessage) behavior

- **Inbound text → intent.** A small LLM call with a strict JSON schema:
  `{intent: "where_is"|"alert_arrive"|"alert_approach"|"list_friends"|"pause"|"resume"|"help", target?: string, place?: string}`.
  Unknown → help text. A regex fast path handles "where is X" without an LLM call.
- **Answers come from the DB only:** "Ana is in Butler Library, 3rd floor (2 min ago) → <maps link>".
  When the data is stale (>15 min), the reply says so.
- **Proximity:** on each new location, find active `approaching_me` alerts and
  grants where the distance to the watcher's latest location crosses the radius
  inward (hysteresis: enter at R, re-arm at 1.5R, 10 min cooldown).
- **Floor change:** fires when `floor_est` changes by ≥1 while inside the same
  place and is stable for 20 s.
- Photon Free/Pro uses a **shared line pool** and requires recipients to be
  registered as project users in the Photon dashboard. That is fine for the
  MVP (you plus roommates). A dedicated number is a paid Business plan, and
  **I will ask before using one**.

---

## 6. Floor estimation

- On building entry (geofence enter or GPS accuracy degrading inside a
  `places` polygon), call `CMAltimeter.startRelativeAltitudeUpdates` and zero
  the baseline. Seed it with `CLLocation.floor` if present, otherwise ground
  floor = the entry floor.
- `floor = entry_floor + round(Δaltitude / floor_height_m)` with a ±0.8 m dead
  band to absorb weather drift. The baseline is reset on each exit.
- Every estimate, plus a user-confirmed "I'm on floor N" tap, goes to
  `floor_eval`. That logged ground truth is what measures accuracy.
- Phase 6+: the Python `ml/` module fits per-building floor heights and
  ground-floor reference pressure from the logged data.

---

## 7. Phase-by-phase tasks

**Phase 1 — Plan** *(this doc)* ✅ → waiting for your review.

**Phase 2 — Repo setup**
- [x] Use the existing `momacaes9/mapchat` repo (public), monorepo layout
- [x] Root `.gitignore` covering `.env`, keys, `Secrets.xcconfig`
- [x] Scaffold `agent/` with `create-spectrum-project` (iMessage provider)
- [ ] README, LICENSE (MIT unless you prefer otherwise), root `.env.example`

**Phase 3 — Backend (Supabase)**
- [ ] `supabase init`, migrations for the tables above + PostGIS
- [ ] RLS policies + `can_view()` + precision views
- [ ] pgTAP tests: a stranger can't read; a revoked or paused grant can't read; precision is enforced; a viewer can't write someone else's location
- [ ] Edge function `ingest_location` (validates, sets `place_id`)
- [ ] Runs locally with `supabase start` (free). Creating a hosted project uses the free tier; **I'll confirm before any paid tier.**

**Phase 4 — iOS MVP**
- [ ] SwiftUI app, Supabase Swift SDK, phone-OTP sign-in
- [ ] Invite by phone → pending grant → accept / decline
- [ ] Google Maps view with all visible friends (Realtime updates)
- [ ] Background location (significant-change + region monitoring to save battery), pause/stop controls
- [ ] `Secrets.example.xcconfig` for the Supabase URL/anon key and Google Maps key

**Phase 5 — Photon agent**
- [ ] Replace the echo loop: sender phone → profile lookup
- [ ] "where is X?" → DB → reply with a Google Maps link
- [ ] Proximity alert worker (Realtime subscription on `locations`)
- [ ] Alert-created notice to the target, plus STOP-ALERTS
- [ ] Test whether iMessage "Send My Current Location" pins reach the agent

**Phase 6 — Floor estimation**
- [ ] `CMAltimeter` pipeline in iOS, floor fields in the ingest payload
- [ ] "X went up 2 floors" alerts
- [ ] `floor_eval` logging + accuracy report script in `ml/`

---

## 8. Open questions for you

1. **Map:** Google Maps SDK (needs a Google Cloud billing account, but mobile dynamic maps are free) or MapKit (no key)? The iMessage replies use Google Maps links either way.
2. **LLM for intent parsing:** Claude (Anthropic API key) is what I'd default to. Any preference?
3. **License:** MIT OK?
4. **Campus:** which campus? I'll seed `places` with its buildings.
