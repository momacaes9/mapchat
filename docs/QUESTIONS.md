# Open questions and decisions for you

Answer inline or in chat. Nothing here blocks the local work.

## Answered (2026-11-10)
1. Docker: **keep Colima** (setup steps are in the README).
2. Student Union: the seed now uses the full outline, OSM way/1420775578
   (about 5,000 m², up from 1,006 m² for one wing), with the floor count (3)
   taken from OSM relation/324644. It is still unverified.
3. Ram Village: kept (buildings 1–3) for Fall 2027.
4. Floor counts: Davis Library = 8 (official, UNC Libraries). Undergraduate
   Library 3, Hinton James 10, Gardner 4, Phillips 3 and Student Union 3 come
   from OSM. Hamilton Hall 7 and Ram Village 5 are **best guesses**. The source
   is stored per building in `places.floors_source`, and every building stays
   `verified = false`.

## Open
5. **Your current dorm.** Your message said "My current dorm is [your current
   dorm]", which is a template placeholder, so I couldn't tell which building
   to add. Reply with the name and I'll add it to `TARGETS` in
   `supabase/scripts/fetch_unc_buildings.ts` (there's a commented slot) and
   regenerate the seed.
6. **Agent settings still empty in `agent/.env`.** Photon `PROJECT_ID` and
   `PROJECT_SECRET` are set. Still missing:
   - `OWNER_PHONE`: your number in E.164 format, the only number the agent
     will ever text
   - `OWNER_USER_ID`: your Supabase user id, available after you sign in once
     in the app
   - `ANTHROPIC_API_KEY`: you said you'd add it. Without it, the agent
     understands fixed phrasings only ("where is Ana?", "route to Ana",
     "tell me when Ana is approaching").
   - `SUPABASE_ANON_KEY` and `SUPABASE_JWT_SECRET` (local values come from
     `supabase status`)
   Without Photon credentials the agent runs with a terminal mock messenger.
   I did **not** start it against real iMessage this session.
7. **Photon free plan:** your number must be registered as a project user in
   the Photon dashboard before the agent can text you. Only your number is
   needed, since the agent never messages anyone else.
8. **Home building for alerts:** set `OWNER_HOME_LAT`, `OWNER_HOME_LNG` and
   `OWNER_HOME_NAME` (your dorm) for "approaching your building" alerts when
   you're not there.
