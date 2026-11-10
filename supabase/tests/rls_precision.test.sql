-- Building-level grants never expose exact coordinates, accuracy or (if
-- disallowed) the floor. Exact grants do.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '19195550002', '{"display_name":"Me"}'),
  ('00000000-0000-0000-0000-0000000000c3', '19195550003', '{"display_name":"Exact viewer"}');

-- A test building far from campus so seed data cannot interfere.
-- Square 10.000..10.002; centroid is (10.001, 10.001).
insert into public.places (slug, name, kind, geom)
values ('test-hall', 'Test Hall', 'building',
        'SRID=4326;MULTIPOLYGON(((10.000 10.000, 10.002 10.000, 10.002 10.002, 10.000 10.002, 10.000 10.000)))');

insert into public.share_grants (owner_id, viewer_id, status, precision, allow_floor) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 'active', 'building', false),
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c3', 'active', 'exact', true);

-- Ana is inside Test Hall, off-centre, on floor 3.
insert into public.locations (user_id, geog, accuracy_m, floor_est, recorded_at)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10.0003 10.0004)', 4, 3,
        now() - interval '1 minute');

-- ---- Me: building precision, no floor ----
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select is((select round(lat::numeric, 5) || ',' || round(lng::numeric, 5) from public.visible_friends()),
          '10.00100,10.00100', 'building precision returns the building centroid');
select is((select accuracy_m from public.visible_friends()), null, 'building precision hides accuracy');
select is((select floor from public.visible_friends()), null, 'allow_floor=false hides the floor');
select is((select place_name from public.visible_friends()), 'Test Hall', 'building name is shown');

-- ---- Exact viewer ----
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
set local role authenticated;

select is((select round(lat::numeric, 5) || ',' || round(lng::numeric, 5) from public.visible_friends()),
          '10.00040,10.00030', 'exact precision returns real coordinates');
select is((select floor from public.visible_friends()), 3, 'exact + allow_floor shows the floor');
select is((select share_precision from public.visible_friends()), 'exact', 'reports exact precision');

-- ---- Ana moves outside any place: building viewer gets ~110 m rounding ----
reset role;
insert into public.locations (user_id, geog, recorded_at)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10.12345 10.54321)', now());

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;
select is((select lat || ',' || lng from public.visible_friends()),
          '10.543,10.123', 'outside a building, coordinates are rounded to 3 decimals');
select is((select place_name from public.visible_friends()), null, 'no place when outside');

select * from finish();
rollback;
