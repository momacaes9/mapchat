-- Consent-gated barometer logging.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '{"display_name":"Me"}');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$insert into public.floor_samples (user_id, session_id, recorded_at, pressure_kpa, consent_version)
    values ('00000000-0000-0000-0000-0000000000b2', gen_random_uuid(), now(), 99.5, 'v1')$$,
  '42501', null, 'no logging without consent');

update public.profiles set data_logging_consent_at = now(), data_logging_consent_version = 'v1'
 where id = '00000000-0000-0000-0000-0000000000b2';

select lives_ok(
  $$insert into public.floor_samples (user_id, session_id, recorded_at, pressure_kpa, confirmed_floor, consent_version)
    values ('00000000-0000-0000-0000-0000000000b2', gen_random_uuid(), now(), 99.5, 2, 'v1')$$,
  'logging works after consent');

select throws_ok(
  $$insert into public.floor_samples (user_id, session_id, recorded_at, pressure_kpa, consent_version)
    values ('00000000-0000-0000-0000-0000000000b2', gen_random_uuid(), now(), 99.5, 'v0')$$,
  '42501', null, 'a sample must carry the consent version the user agreed to');

select throws_ok(
  $$insert into public.floor_samples (user_id, session_id, recorded_at, pressure_kpa, consent_version)
    values ('00000000-0000-0000-0000-0000000000a1', gen_random_uuid(), now(), 99.5, 'v1')$$,
  '42501', null, 'cannot log samples for someone else');

select is((select count(*)::int from public.floor_samples), 1, 'I can read (export) my own samples');

-- Ana cannot read mine.
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*)::int from public.floor_samples), 0, 'others cannot read my samples');

-- Withdrawing consent deletes my data.
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;
update public.profiles set data_logging_consent_at = null
 where id = '00000000-0000-0000-0000-0000000000b2';
reset role;
select is((select count(*)::int from public.floor_samples), 0, 'withdrawing consent deletes logged samples');

select * from finish();
rollback;
