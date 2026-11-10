-- 0007: invite/share by phone OR email, and private Realtime "refetch" pings.

-- ---------------------------------------------------------------------------
-- Resolve a phone (E.164) or email to a user id. Internal only.
-- ---------------------------------------------------------------------------
create function private.resolve_contact(contact text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select id from public.profiles where phone_e164 = btrim(contact)),
    (select id from auth.users where lower(email) = lower(btrim(contact)) limit 1)
  );
$$;
revoke all on function private.resolve_contact(text) from public;

-- request_share(contact): ask someone to share THEIR location with me.
-- Creates a PENDING grant they must accept. Returns null for unknown contacts
-- (no account enumeration). Replaces the phone-only version from 0004.
drop function public.request_share(text);
create function public.request_share(contact text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
  grant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if contact is null or length(contact) > 254 then
    return null;
  end if;
  target := private.resolve_contact(contact);
  if target is null or target = auth.uid() then
    return null;
  end if;
  insert into public.share_grants (owner_id, viewer_id, status)
  values (target, auth.uid(), 'pending')
  on conflict (owner_id, viewer_id) do nothing
  returning id into grant_id;
  return grant_id;
end;
$$;
revoke all on function public.request_share(text) from public, anon;
grant execute on function public.request_share(text) to authenticated;

-- share_with(contact, precision): I share MY location with someone, active
-- immediately (it is my own consent). Re-sharing updates the existing grant.
create function public.share_with(contact text, share_precision text default 'exact')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
  grant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if share_precision not in ('exact', 'building') then
    raise exception 'invalid precision' using errcode = '22023';
  end if;
  if contact is null or length(contact) > 254 then
    return null;
  end if;
  target := private.resolve_contact(contact);
  if target is null or target = auth.uid() then
    return null;
  end if;
  insert into public.share_grants (owner_id, viewer_id, status, precision)
  values (auth.uid(), target, 'active', share_precision)
  on conflict (owner_id, viewer_id)
    do update set status = 'active', precision = excluded.precision
  returning id into grant_id;
  return grant_id;
end;
$$;
revoke all on function public.share_with(text, text) from public, anon;
grant execute on function public.share_with(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: when someone's latest location changes, send a private broadcast
-- to topic "friends:<viewer_id>" for every viewer who can currently see them.
-- The payload carries NO coordinates, only who moved; the app then calls
-- visible_friends(), which applies precision rules.
-- ---------------------------------------------------------------------------
create function private.notify_viewers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v uuid;
begin
  for v in
    select g.viewer_id
      from public.share_grants g
      join public.profiles p on p.id = g.owner_id
     where g.owner_id = new.user_id and g.status = 'active' and not p.sharing_paused
  loop
    perform realtime.send(
      jsonb_build_object('user_id', new.user_id),
      'friend_moved',
      'friends:' || v::text,
      true
    );
  end loop;
  return null;
end;
$$;

create trigger latest_locations_notify
  after insert or update on public.latest_locations
  for each row execute function private.notify_viewers();

-- Only the viewer may subscribe to their own private topic.
create policy "viewer receives own friend pings"
  on realtime.messages
  for select to authenticated
  using (realtime.topic() = 'friends:' || (select auth.uid())::text);
