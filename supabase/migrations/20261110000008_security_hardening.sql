-- 0008: security hardening from the end-of-session review (docs/SECURITY.md).

-- 1) Phone numbers are identity: only Supabase Auth (OTP-verified) may set
--    them. Users may edit only their display name and pause flag. Otherwise
--    someone could claim another person's number and receive locations that
--    were shared "with" that number.
revoke update on public.profiles from authenticated;
grant update (display_name, sharing_paused) on public.profiles to authenticated;

create function private.sync_phone_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.phone is distinct from old.phone then
    update public.profiles
       set phone_e164 = case when new.phone is null or new.phone = '' then null
                             when left(new.phone, 1) = '+' then new.phone
                             else '+' || new.phone end
     where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_phone_changed
  after update of phone on auth.users
  for each row execute function private.sync_phone_from_auth();

-- 2) No account enumeration and no invite spam: the sharing RPCs return
--    nothing, and each user may create at most 20 invites/shares per hour.
create table private.invite_log (
  user_id    uuid not null,
  created_at timestamptz not null default now()
);
create index on private.invite_log (user_id, created_at);

create function private.check_invite_rate()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from private.invite_log where created_at < now() - interval '1 hour';
  if (select count(*) from private.invite_log where user_id = auth.uid()) >= 20 then
    raise exception 'too many invites, try again later' using errcode = '54000';
  end if;
  insert into private.invite_log (user_id) values (auth.uid());
end;
$$;

drop function public.request_share(text);
create function public.request_share(contact text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  perform private.check_invite_rate();
  if contact is null or length(contact) > 254 then
    return;
  end if;
  target := private.resolve_contact(contact);
  if target is null or target = auth.uid() then
    return;  -- same result as success: nothing to learn
  end if;
  insert into public.share_grants (owner_id, viewer_id, status)
  values (target, auth.uid(), 'pending')
  on conflict (owner_id, viewer_id) do nothing;
end;
$$;
revoke all on function public.request_share(text) from public, anon;
grant execute on function public.request_share(text) to authenticated;

drop function public.share_with(text, text);
create function public.share_with(contact text, share_precision text default 'exact')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if share_precision not in ('exact', 'building') then
    raise exception 'invalid precision' using errcode = '22023';
  end if;
  perform private.check_invite_rate();
  if contact is null or length(contact) > 254 then
    return;
  end if;
  target := private.resolve_contact(contact);
  if target is null or target = auth.uid() then
    return;
  end if;
  insert into public.share_grants (owner_id, viewer_id, status, precision)
  values (auth.uid(), target, 'active', share_precision)
  on conflict (owner_id, viewer_id)
    do update set status = 'active', precision = excluded.precision;
end;
$$;
revoke all on function public.share_with(text, text) from public, anon;
grant execute on function public.share_with(text, text) to authenticated;

-- 3) Locations: timestamps must be recent (a future timestamp would dodge
--    retention and pin a fake "latest" point), and place_id is always
--    computed by the server, never trusted from the client.
create or replace function private.locations_assign_place()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.recorded_at > now() + interval '5 minutes'
     or new.recorded_at < now() - interval '1 day' then
    raise exception 'recorded_at must be within the last day' using errcode = '22007';
  end if;
  new.place_id := null;
  select p.id into new.place_id
    from public.places p
   where extensions.st_covers(p.geom, new.geog)
     and (p.kind = 'building' or p.owner_id = new.user_id)
   order by p.kind = 'home' desc, extensions.st_area(p.geom) asc
   limit 1;
  return new;
end;
$$;

alter table public.locations
  add constraint locations_accuracy_sane check (accuracy_m is null or accuracy_m <= 10000),
  add constraint locations_floor_sane check (
    (floor_apple is null or floor_apple between -10 and 200)
    and (floor_est is null or floor_est between -10 and 200)
  ),
  add constraint locations_pressure_sane check (pressure_kpa is null or pressure_kpa between 50 and 120);

-- 4) Retention covers every copy of location data, not just history.
select cron.unschedule('mapchat-locations-retention');

create function private.purge_old_locations()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.locations        where recorded_at < now() - interval '7 days';
  delete from public.latest_locations where recorded_at < now() - interval '7 days';
  delete from public.alert_events     where fired_at    < now() - interval '7 days';
$$;
revoke all on function private.purge_old_locations() from public;

select cron.schedule('mapchat-locations-retention', '17 * * * *', 'select private.purge_old_locations()');

-- 5) Future tables/functions in public are not exposed to anon by default.
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke execute on functions from anon, public;

-- 6) Internal trigger/helper functions are not callable by anyone directly.
revoke all on function private.handle_new_user() from public;
revoke all on function private.locations_assign_place() from public;
revoke all on function private.locations_update_latest() from public;
revoke all on function private.notify_viewers() from public;
revoke all on function private.share_grants_end_alerts() from public;
revoke all on function private.share_grants_guard() from public;
revoke all on function private.sync_phone_from_auth() from public;
revoke all on function private.check_invite_rate() from public;
