-- 0002: core tables. RLS is enabled in 0003, but every table is created here.

-- ---------------------------------------------------------------------------
-- profiles: one row per auth user.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  display_name   text not null check (length(display_name) between 1 and 80),
  phone_e164     text unique check (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
  -- Global pause: while true, nobody can see this user's location.
  sharing_paused boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Create a profile automatically when a user signs up.
create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, phone_e164)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), new.phone, 'New user'),
    case when new.phone is null or new.phone = '' then null
         when left(new.phone, 1) = '+' then new.phone
         else '+' || new.phone end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- places: campus buildings (seeded from OpenStreetMap) and private homes.
-- ---------------------------------------------------------------------------
create table public.places (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  kind              text not null check (kind in ('building', 'home')),
  owner_id          uuid references public.profiles (id) on delete cascade,
  geom              extensions.geography (MultiPolygon, 4326) not null,
  floors            int check (floors between 1 and 50),
  floor_height_m    real not null default 3.5 check (floor_height_m > 0),
  ground_altitude_m real,
  osm_type          text,
  osm_id            bigint,
  -- false until a human has checked floors, entrances and cores on site.
  verified          boolean not null default false,
  created_at        timestamptz not null default now(),
  check ((kind = 'home') = (owner_id is not null))
);
create index places_geom_idx on public.places using gist (geom);

-- ---------------------------------------------------------------------------
-- share_grants: one row means "owner lets viewer see owner's location".
-- ---------------------------------------------------------------------------
create table public.share_grants (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  viewer_id   uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending'
              check (status in ('pending', 'active', 'paused', 'revoked')),
  precision   text not null default 'exact' check (precision in ('exact', 'building')),
  allow_floor boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (owner_id, viewer_id),
  check (owner_id <> viewer_id)
);
create index share_grants_viewer_idx on public.share_grants (viewer_id);

-- ---------------------------------------------------------------------------
-- locations: append-only history (7-day retention, see 0004).
-- ---------------------------------------------------------------------------
create table public.locations (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  geog           extensions.geography (Point, 4326) not null,
  accuracy_m     real check (accuracy_m >= 0),
  floor_apple    int,            -- CLLocation.floor.level when Apple provides it
  rel_altitude_m real,           -- CMAltimeter relative altitude since building entry
  pressure_kpa   real,
  floor_est      int,            -- our barometer-based estimate
  place_id       uuid references public.places (id) on delete set null,
  recorded_at    timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index locations_user_time_idx on public.locations (user_id, recorded_at desc);
create index locations_recorded_idx on public.locations (recorded_at);

-- ---------------------------------------------------------------------------
-- alerts: "tell me when Ana gets home". The watcher is always the person who
-- receives the iMessage (the owner of the agent in the MVP).
-- ---------------------------------------------------------------------------
create table public.alerts (
  id            uuid primary key default gen_random_uuid(),
  watcher_id    uuid not null references public.profiles (id) on delete cascade,
  target_id     uuid not null references public.profiles (id) on delete cascade,
  kind          text not null check (kind in ('approaching_me', 'arrives_place', 'floor_change')),
  place_id      uuid references public.places (id) on delete cascade,
  radius_m      int not null default 150 check (radius_m between 10 and 5000),
  one_shot      boolean not null default true,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  last_fired_at timestamptz,
  check (watcher_id <> target_id),
  check ((kind = 'arrives_place') = (place_id is not null))
);
create index alerts_target_idx on public.alerts (target_id) where active;

create table public.alert_events (
  id       bigint generated always as identity primary key,
  alert_id uuid not null references public.alerts (id) on delete cascade,
  fired_at timestamptz not null default now(),
  payload  jsonb not null default '{}'::jsonb
);

-- ---------------------------------------------------------------------------
-- floor_eval: ground truth for measuring floor-estimation accuracy.
-- ---------------------------------------------------------------------------
create table public.floor_eval (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  place_id    uuid references public.places (id) on delete set null,
  floor_est   int,
  floor_truth int not null,
  method      text not null default 'barometer_v1',
  recorded_at timestamptz not null default now()
);
