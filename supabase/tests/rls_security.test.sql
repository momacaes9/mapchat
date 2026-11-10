-- Hardening from the security review (migration 0008).
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.test', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'me@example.test',  null,          '{"display_name":"Me"}');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

-- Identity: phone numbers come only from verified auth.
select throws_ok($$update public.profiles set phone_e164 = '+19195559999'
                    where id = '00000000-0000-0000-0000-0000000000b2'$$,
                 '42501', null, 'users cannot set their own phone number');
select lives_ok($$update public.profiles set display_name = 'Monica', sharing_paused = true
                   where id = '00000000-0000-0000-0000-0000000000b2'$$,
                'users can still edit display name and pause');

-- Locations: timestamps must be recent; place_id is server-computed.
select throws_ok($$insert into public.locations (user_id, geog, recorded_at)
                   values ('00000000-0000-0000-0000-0000000000b2', 'SRID=4326;POINT(10 10)', now() + interval '1 year')$$,
                 '22007', null, 'future timestamps are rejected (cannot dodge retention)');
select throws_ok($$insert into public.locations (user_id, geog, recorded_at)
                   values ('00000000-0000-0000-0000-0000000000b2', 'SRID=4326;POINT(10 10)', now() - interval '30 days')$$,
                 '22007', null, 'very old timestamps are rejected');
select throws_ok($$insert into public.locations (user_id, geog, accuracy_m)
                   values ('00000000-0000-0000-0000-0000000000b2', 'SRID=4326;POINT(10 10)', 999999)$$,
                 '23514', null, 'absurd accuracy values are rejected');

reset role;
insert into public.places (slug, name, kind, geom)
values ('sec-hall', 'Sec Hall', 'building',
        'SRID=4326;MULTIPOLYGON(((20 20, 20.01 20, 20.01 20.01, 20 20.01, 20 20)))');
set local role authenticated;
insert into public.locations (user_id, geog, place_id)
values ('00000000-0000-0000-0000-0000000000b2', 'SRID=4326;POINT(10 10)',
        (select id from public.places where slug = 'sec-hall'));
select is((select place_id from public.locations order by id desc limit 1), null,
          'a client-supplied place_id is ignored when the point is not in that place');

-- Invite spam limit: 20 per hour.
select lives_ok($$select public.request_share('x' || g || '@example.test') from generate_series(1, 20) g$$,
                '20 invites in an hour are allowed');
select throws_ok($$select public.request_share('one-more@example.test')$$,
                 '54000', null, 'the 21st invite in an hour is refused');

-- Retention: purge removes every copy older than 7 days.
reset role;
alter table public.locations disable trigger locations_assign_place;
insert into public.locations (user_id, geog, recorded_at)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10 10)', now() - interval '8 days');
alter table public.locations enable trigger locations_assign_place;
select private.purge_old_locations();
select is((select count(*)::int from public.locations where recorded_at < now() - interval '7 days'), 0,
          'history older than 7 days is deleted');
select is((select count(*)::int from public.latest_locations where recorded_at < now() - interval '7 days'), 0,
          'latest_locations older than 7 days is deleted too');

select * from finish();
rollback;
