# Open questions and decisions for you

Answer inline or in chat. Nothing here blocks the local work.

1. **Docker runtime.** Docker Desktop was not found on this Mac (no app in
   `/Applications`, no `docker` binary). To keep going I installed the free,
   open-source **Colima** (`brew install colima docker docker-compose`) as the
   Docker engine. Do you want to keep Colima, or install Docker Desktop? Both
   are free for personal and education use, and the repo works with either.

2. **Student Union footprint looks small.** OSM matched way/772275983
   "Frank Porter Graham Student Union" at about 1,006 m², which seems small for
   that building and may be only one wing. Can you confirm on
   openstreetmap.org, or tell me which entrance/wing you use? It's easy to
   swap the OSM id in the seed script.
3. **Ram Village.** OSM has Ram Village Buildings 1–3 inside the campus
   bounding box. If you live in a building that isn't listed (e.g. 4 or 5),
   tell me which one and I'll add it.
4. **Floor counts.** OSM only lists levels for some buildings (Undergraduate
   Library 3, Hinton James 10, Gardner 4, Phillips 3). Davis Library, Student
   Union, Hamilton and Ram Village have no level count. All buildings are
   `verified = false` until you check them.
