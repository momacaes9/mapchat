-- A user with no grant cannot read anything about someone else's location.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- Fixtures (as postgres). Ana shares exactly with Me. Stranger has no grant.
insert into auth.users (id, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '19195550002', '{"display_name":"Me"}'),
  ('00000000-0000-0000-0000-0000000000c3', '19195550003', '{"display_name":"Stranger"}');

insert into public.share_grants (owner_id, viewer_id, status)
values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 'active');

insert into public.locations (user_id, geog, accuracy_m)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10.0003 10.0004)', 5);

-- ---- act as Stranger ----
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
set local role authenticated;

select is((select count(*)::int from public.locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
          'stranger cannot read Ana''s location history');
select is((select count(*)::int from public.latest_locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
          'stranger cannot read Ana''s latest location');
select is((select count(*)::int from public.visible_friends()), 0,
          'visible_friends() returns nothing for a stranger');
select is((select count(*)::int from public.profiles
            where id = '00000000-0000-0000-0000-0000000000a1'), 0,
          'stranger cannot see Ana''s profile');
select is((select count(*)::int from public.share_grants), 0,
          'stranger cannot see other people''s grants');
select throws_ok(
  $$insert into public.alerts (watcher_id, target_id, kind)
    values ('00000000-0000-0000-0000-0000000000c3',
            '00000000-0000-0000-0000-0000000000a1', 'approaching_me')$$,
  '42501', null, 'stranger cannot set an alert on Ana');

-- ---- act as Me (has an active grant) ----
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select is((select count(*)::int from public.visible_friends()
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 1,
          'a viewer with an active grant sees Ana via visible_friends()');
select is((select count(*)::int from public.locations
            where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
          'even a granted viewer cannot read the raw locations table');

select * from finish();
rollback;
