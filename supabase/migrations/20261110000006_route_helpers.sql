-- 0006: helpers for the routing service.
--   * visible_friends() also returns place_slug (to find the indoor graph)
--   * my_latest_location() returns the caller's own latest point as lat/lng

drop function public.visible_friends();

create function public.visible_friends()
returns table (
  user_id         uuid,
  display_name    text,
  lat             double precision,
  lng             double precision,
  accuracy_m      real,
  floor           int,
  place_id        uuid,
  place_slug      text,
  place_name      text,
  share_precision text,
  recorded_at     timestamptz
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
    pl.slug,
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

-- The caller's own latest location. Security invoker: RLS on
-- latest_locations already limits it to the caller's row.
create function public.my_latest_location()
returns table (
  lat         double precision,
  lng         double precision,
  floor       int,
  place_slug  text,
  recorded_at timestamptz
)
language sql
stable
set search_path = ''
as $$
  select extensions.st_y(l.geog::extensions.geometry),
         extensions.st_x(l.geog::extensions.geometry),
         coalesce(l.floor_est, l.floor_apple),
         pl.slug,
         l.recorded_at
    from public.latest_locations l
    left join public.places pl on pl.id = l.place_id
   where l.user_id = auth.uid();
$$;

revoke all on function public.my_latest_location() from public, anon;
grant execute on function public.my_latest_location() to authenticated;
