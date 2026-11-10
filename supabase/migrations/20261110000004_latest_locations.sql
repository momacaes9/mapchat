-- 0004: latest location per user, place assignment, the precision-aware read
-- path for friends, the share-request RPC, and 7-day retention.

-- ---------------------------------------------------------------------------
-- latest_locations: one row per user, maintained by trigger.
-- ---------------------------------------------------------------------------
create table public.latest_locations (
  user_id        uuid primary key references public.profiles (id) on delete cascade,
  location_id    bigint not null,
  geog           extensions.geography (Point, 4326) not null,
  accuracy_m     real,
  floor_apple    int,
  floor_est      int,
  place_id       uuid references public.places (id) on delete set null,
  recorded_at    timestamptz not null
);
alter table public.latest_locations enable row level security;
revoke all on public.latest_locations from anon;

-- Same rule as locations: only your own row through the table.
create policy latest_select_self on public.latest_locations
  for select to authenticated
  using (user_id = (select auth.uid()));
-- No insert/update/delete policies: only the trigger below writes here.

-- Before insert: attach the building/home that contains the point.
create function private.locations_assign_place()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.place_id is null then
    select p.id into new.place_id
      from public.places p
     where extensions.st_covers(p.geom, new.geog)
       and (p.kind = 'building' or p.owner_id = new.user_id)
     order by p.kind = 'home' desc, extensions.st_area(p.geom) asc
     limit 1;
  end if;
  return new;
end;
$$;

create trigger locations_assign_place
  before insert on public.locations
  for each row execute function private.locations_assign_place();

-- After insert: upsert into latest_locations if this point is the newest.
create function private.locations_update_latest()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.latest_locations as l
    (user_id, location_id, geog, accuracy_m, floor_apple, floor_est, place_id, recorded_at)
  values
    (new.user_id, new.id, new.geog, new.accuracy_m, new.floor_apple, new.floor_est,
     new.place_id, new.recorded_at)
  on conflict (user_id) do update
    set location_id = excluded.location_id,
        geog        = excluded.geog,
        accuracy_m  = excluded.accuracy_m,
        floor_apple = excluded.floor_apple,
        floor_est   = excluded.floor_est,
        place_id    = excluded.place_id,
        recorded_at = excluded.recorded_at
    where l.recorded_at <= excluded.recorded_at;
  return null;
end;
$$;

create trigger locations_update_latest
  after insert on public.locations
  for each row execute function private.locations_update_latest();

-- ---------------------------------------------------------------------------
-- visible_friends(): the ONLY way to read someone else's location.
-- Applies can_view() and the grant's precision:
--   exact    -> real coordinates (+ floor if allow_floor)
--   building -> centroid of the containing place, or coordinates rounded to
--               ~110 m when outside any place; accuracy is hidden
-- ---------------------------------------------------------------------------
create function public.visible_friends()
returns table (
  user_id      uuid,
  display_name text,
  lat          double precision,
  lng          double precision,
  accuracy_m   real,
  floor        int,
  place_id     uuid,
  place_name   text,
  share_precision text,
  recorded_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select auth.uid() as id)
  select
    l.user_id,
    p.display_name,
    case when g.precision = 'exact' then extensions.st_y(l.geog::extensions.geometry)
         when pl.id is not null then extensions.st_y(extensions.st_centroid(pl.geom)::extensions.geometry)
         else round(extensions.st_y(l.geog::extensions.geometry)::numeric, 3)::double precision end,
    case when g.precision = 'exact' then extensions.st_x(l.geog::extensions.geometry)
         when pl.id is not null then extensions.st_x(extensions.st_centroid(pl.geom)::extensions.geometry)
         else round(extensions.st_x(l.geog::extensions.geometry)::numeric, 3)::double precision end,
    case when g.precision = 'exact' then l.accuracy_m end,
    case when g.allow_floor then coalesce(l.floor_est, l.floor_apple) end,
    pl.id,
    pl.name,
    g.precision,
    l.recorded_at
  from me
  join public.share_grants g on g.viewer_id = me.id and g.status = 'active'
  join public.profiles p on p.id = g.owner_id and not p.sharing_paused
  join public.latest_locations l on l.user_id = g.owner_id
  left join public.places pl on pl.id = l.place_id
                             and (pl.kind = 'building' or g.precision = 'exact');
$$;

revoke all on function public.visible_friends() from public, anon;
grant execute on function public.visible_friends() to authenticated;

-- ---------------------------------------------------------------------------
-- request_share(phone): the caller asks the person with that phone number to
-- share with them. Creates a PENDING grant; the other person must accept.
-- Returns null (not an error) when no such user exists, so the API cannot be
-- used to enumerate which phone numbers have accounts.
-- ---------------------------------------------------------------------------
create function public.request_share(phone text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
  grant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select id into target from public.profiles where phone_e164 = phone;
  if target is null or target = auth.uid() then
    return null;
  end if;

  insert into public.share_grants (owner_id, viewer_id, status)
  values (target, auth.uid(), 'pending')
  on conflict (owner_id, viewer_id) do nothing
  returning id into grant_id;

  return grant_id;
end;
$$;

revoke all on function public.request_share(text) from public, anon;
grant execute on function public.request_share(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Retention: delete raw history older than 7 days, every hour.
-- latest_locations keeps only the newest point per user.
-- ---------------------------------------------------------------------------
select cron.schedule(
  'mapchat-locations-retention',
  '17 * * * *',
  $$delete from public.locations where recorded_at < now() - interval '7 days'$$
);
