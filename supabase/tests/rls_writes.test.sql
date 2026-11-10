-- Nobody can write, change or delete someone else's location data.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '19195550002', '{"display_name":"Me"}');

-- Me even has an active grant: viewing must never imply writing.
insert into public.share_grants (owner_id, viewer_id, status)
values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 'active');

insert into public.locations (user_id, geog)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10.0003 10.0004)');

-- ---- act as Me ----
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$insert into public.locations (user_id, geog)
    values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(0 0)')$$,
  '42501', null, 'cannot insert a location for another user');

select throws_ok(
  $$insert into public.latest_locations (user_id, location_id, geog, recorded_at)
    values ('00000000-0000-0000-0000-0000000000a1', 1, 'SRID=4326;POINT(0 0)', now())$$,
  '42501', null, 'cannot write latest_locations directly');

select throws_ok(
  $$insert into public.floor_eval (user_id, floor_truth)
    values ('00000000-0000-0000-0000-0000000000a1', 2)$$,
  '42501', null, 'cannot write floor ground truth for another user');

-- These match 0 rows under RLS (no error, no effect); verified below.
update public.locations set geog = 'SRID=4326;POINT(0 0)'
 where user_id = '00000000-0000-0000-0000-0000000000a1';
delete from public.locations where user_id = '00000000-0000-0000-0000-0000000000a1';
delete from public.latest_locations where user_id = '00000000-0000-0000-0000-0000000000a1';

select lives_ok(
  $$insert into public.locations (user_id, geog)
    values ('00000000-0000-0000-0000-0000000000b2', 'SRID=4326;POINT(10.001 10.001)')$$,
  'can insert my own location');
select is((select count(*)::int from public.latest_locations), 1,
          'my latest location is maintained by the trigger');

reset role;
select is((select count(*)::int from public.locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 1,
          'Ana''s history was not deleted by Me');
select is((select extensions.st_astext(geog::extensions.geometry) from public.locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'),
          'POINT(10.0003 10.0004)', 'Ana''s location was not modified by Me');
select is((select count(*)::int from public.latest_locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 1,
          'Ana''s latest location was not deleted by Me');

select * from finish();
rollback;
