# Indoor building graphs

One JSON file per building, named `<slug>.json`, where `slug` matches
`places.slug` in Supabase (for example `davis-library`). Types live in
[`src/indoor/types.ts`](../src/indoor/types.ts). Run
`bun run validate-buildings` to check every file.

## Granularity (MVP)

Keep it coarse. Per floor, add **one corridor hub** plus **one node per stair
core and per elevator core**. Add every entrance, with real coordinates. That
is enough for directions like "enter by the main entrance, take elevator A to
floor 3", and a building takes about 10 minutes to survey.

## Fields

| Field | Meaning |
|---|---|
| `building`, `name` | Slug (matches Supabase) and display name |
| `verified` | `false` until someone has walked the building and checked everything |
| `floors[]` | `level` (integer used for math), `label` (what the signs say), `height_m` (floor-to-floor, for the barometer) |
| `nodes[]` | `id`, `floor`, `kind` (`entrance`/`corridor`/`elevator`/`stairs`/`ramp`/`room`), `core` for stairs/elevators, `lat`/`lng` required for entrances, `step_free`, `source` |
| `edges[]` | Undirected. `a`, `b`, `type` (`corridor`/`door`/`elevator`/`elevator_wait`/`stairs`/`ramp`), `meters` or `seconds`, `steps` for stairs |

## Rules (enforced by the validator)

- Stairs and elevator edges join two nodes of the same kind and **core**, on
  different floors.
- Only stairs, elevator and ramp edges may change floor.
- Every graph has at least one entrance, and every entrance has coordinates.

## How routing uses it

- Corridor time = `meters / 1.3 m/s`; stairs and elevators use `seconds`.
- `elevator_wait` (hub ↔ elevator) models waiting for and leaving the lift
  (30 s each way).
- Profile `avoid_stairs` removes every stairs edge. `default` adds 10 s per
  flight, and `fastest` adds nothing (see `src/profiles.ts`).

## Surveying a building

1. Note each entrance: tap its spot on a map, and note whether it is step-free.
2. Count floors and write down the labels used on the signs and in the lift.
3. Note each elevator bank and each stairwell (give them letters).
4. Time one stair flight and one elevator floor.
5. Update the JSON, run the validator, and set `"verified": true`.
