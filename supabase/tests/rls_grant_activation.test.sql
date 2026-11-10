-- Only the person being located can turn sharing on. A viewer can only ask.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '19195550002', '{"display_name":"Me"}'),
  ('00000000-0000-0000-0000-0000000000c3', '19195550003', '{"display_name":"Stranger"}');

-- ---- act as Me (viewer) ----
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;

select lives_ok(
  $$insert into public.share_grants (owner_id, viewer_id, status)
    values ('00000000-0000-0000-0000-0000000000a1',
            '00000000-0000-0000-0000-0000000000b2', 'pending')$$,
  'viewer can request access (pending)');

select throws_ok(
  $$insert into public.share_grants (owner_id, viewer_id, status)
    values ('00000000-0000-0000-0000-0000000000c3',
            '00000000-0000-0000-0000-0000000000b2', 'active')$$,
  '42501', null, 'viewer cannot create an active grant for someone else');

-- Try to self-activate and widen the grant (silently matches 0 rows).
update public.share_grants
   set status = 'active', precision = 'exact', allow_floor = true
 where owner_id = '00000000-0000-0000-0000-0000000000a1';

select lives_ok($$select public.request_share('+19195550003')$$,
                'request_share() accepts a known phone');
select lives_ok($$select public.request_share('+19990000000')$$,
                'request_share() behaves the same for an unknown phone (no enumeration)');

reset role;
select is((select status from public.share_grants
            where owner_id = '00000000-0000-0000-0000-0000000000a1'), 'pending',
          'viewer''s attempt to activate the grant had no effect');
select is((select status from public.share_grants
            where owner_id = '00000000-0000-0000-0000-0000000000c3'), 'pending',
          'request_share() grant is pending, not active');

-- ---- act as Ana (owner) ----
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
set local role authenticated;

update public.share_grants set status = 'active'
 where viewer_id = '00000000-0000-0000-0000-0000000000b2';
select is((select status from public.share_grants
            where viewer_id = '00000000-0000-0000-0000-0000000000b2'), 'active',
          'owner can accept (activate) the grant');

select throws_ok(
  $$update public.share_grants
       set viewer_id = '00000000-0000-0000-0000-0000000000c3'
     where viewer_id = '00000000-0000-0000-0000-0000000000b2'$$,
  '42501', null, 'owner cannot re-point a grant to a different viewer');

update public.share_grants set status = 'revoked'
 where viewer_id = '00000000-0000-0000-0000-0000000000b2';
select is((select status from public.share_grants
            where viewer_id = '00000000-0000-0000-0000-0000000000b2'), 'revoked',
          'owner can stop sharing at any time');

select * from finish();
rollback;
