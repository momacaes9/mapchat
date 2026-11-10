-- request_share() / share_with() by phone or email.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.test', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'me@example.test',  '19195550002', '{"display_name":"Me"}');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select lives_ok($$select public.request_share('ANA@example.test')$$, 'request by email (case-insensitive)');
select lives_ok($$select public.request_share('nobody@example.test')$$, 'unknown email: same result, nothing revealed');
select lives_ok($$select public.request_share('me@example.test')$$, 'requesting from yourself is a no-op');
select lives_ok($$select public.share_with('+19195550001', 'building')$$, 'share my location by phone');
select is((select count(*)::int from public.share_grants), 2, 'exactly two grants were created');
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
