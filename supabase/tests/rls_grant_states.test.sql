-- Only an ACTIVE grant from a non-paused owner exposes a location.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '19195550001', '{"display_name":"Ana"}'),
  ('00000000-0000-0000-0000-0000000000b2', '19195550002', '{"display_name":"Me"}');

insert into public.share_grants (owner_id, viewer_id, status)
values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 'pending');

insert into public.locations (user_id, geog)
values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(10.0003 10.0004)');

-- Each block switches to Me, checks what Me sees, then switches back to
-- postgres to change the grant. The JWT claim stays set for the transaction.

-- pending
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 0, 'pending grant: hidden');
reset role;

-- paused (per grant)
update public.share_grants set status = 'paused';
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 0, 'paused grant: hidden');
reset role;

-- revoked
update public.share_grants set status = 'revoked';
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 0, 'revoked grant: hidden');
reset role;

-- active (control)
update public.share_grants set status = 'active';
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 1, 'active grant: visible');
reset role;

-- active grant but owner paused sharing globally
update public.profiles set sharing_paused = true
 where id = '00000000-0000-0000-0000-0000000000a1';
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 0, 'global pause: hidden');
reset role;

-- grant deleted ("stop sharing")
update public.profiles set sharing_paused = false
 where id = '00000000-0000-0000-0000-0000000000a1';
delete from public.share_grants;
set local role authenticated;
select is((select count(*)::int from public.visible_friends()), 0, 'deleted grant: hidden');

select * from finish();
rollback;
