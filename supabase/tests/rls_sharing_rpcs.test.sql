-- request_share() / share_with() by phone or email.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.test', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'me@example.test',  '19195550002', '{"display_name":"Me"}');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select isnt(public.request_share('ANA@example.test'), null, 'request by email (case-insensitive) works');
select is(public.request_share('nobody@example.test'), null, 'unknown email returns null');
select is(public.request_share('me@example.test'), null, 'cannot request from yourself');
select isnt(public.share_with('+19195550001', 'building'), null, 'share my location by phone');
select throws_ok($$select public.share_with('+19195550001', 'gps')$$, '22023', null, 'precision is validated');

reset role;
select is((select status || '/' || precision from public.share_grants
            where owner_id = '00000000-0000-0000-0000-0000000000b2'), 'active/building',
          'share_with creates an ACTIVE grant owned by the caller');
select is((select status from public.share_grants
            where owner_id = '00000000-0000-0000-0000-0000000000a1'), 'pending',
          'request_share creates a PENDING grant owned by the other person');

select * from finish();
rollback;
