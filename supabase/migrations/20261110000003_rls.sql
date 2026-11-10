-- 0003: privacy model. Default deny, then explicit policies.
--
-- Rules (see docs/PLAN.md §6):
--   * Another user's location is readable only through public.visible_friends()
--     (0004), which applies can_view() and the grant's precision.
--   * A grant starts 'pending'. Only the OWNER of the location (the person
--     being located) can make it 'active'.
--   * Pause (global or per grant) and revoke take effect immediately.

-- Nobody uses the anon role for app data.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

alter table public.profiles     enable row level security;
alter table public.places       enable row level security;
alter table public.share_grants enable row level security;
alter table public.locations    enable row level security;
alter table public.alerts       enable row level security;
alter table public.alert_events enable row level security;
alter table public.floor_eval   enable row level security;

-- ---------------------------------------------------------------------------
-- Helpers (security definer so they can read share_grants/profiles without
-- recursing into RLS; they live in the unexposed `private` schema).
-- ---------------------------------------------------------------------------

-- True when `viewer` may currently see `owner`'s location.
create function private.can_view(owner uuid, viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select owner = viewer
      or exists (
           select 1
             from public.share_grants g
             join public.profiles p on p.id = g.owner_id
            where g.owner_id = owner
              and g.viewer_id = viewer
              and g.status = 'active'
              and not p.sharing_paused
         );
$$;

-- True when two users have any grant between them (any status), so each can
-- see the other's display name in the sharing screens.
create function private.is_connected(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select a = b
      or exists (
           select 1 from public.share_grants g
            where (g.owner_id = a and g.viewer_id = b)
               or (g.owner_id = b and g.viewer_id = a)
         );
$$;

revoke all on function private.can_view(uuid, uuid) from public;
revoke all on function private.is_connected(uuid, uuid) from public;
grant execute on function private.can_view(uuid, uuid) to authenticated, service_role;
grant execute on function private.is_connected(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create policy profiles_select on public.profiles
  for select to authenticated
  using (private.is_connected(id, (select auth.uid())));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- places: buildings are public to signed-in users; homes are visible to their
-- owner and to people who can currently see that owner.
-- ---------------------------------------------------------------------------
create policy places_select on public.places
  for select to authenticated
  using (kind = 'building' or private.can_view(owner_id, (select auth.uid())));

create policy places_insert_home on public.places
  for insert to authenticated
  with check (kind = 'home' and owner_id = (select auth.uid()));

create policy places_update_home on public.places
  for update to authenticated
  using (kind = 'home' and owner_id = (select auth.uid()))
  with check (kind = 'home' and owner_id = (select auth.uid()));

create policy places_delete_home on public.places
  for delete to authenticated
  using (kind = 'home' and owner_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- share_grants
-- ---------------------------------------------------------------------------
create policy grants_select on public.share_grants
  for select to authenticated
  using ((select auth.uid()) in (owner_id, viewer_id));

-- A viewer may only *request* access (pending). An owner may share directly.
create policy grants_insert_viewer_request on public.share_grants
  for insert to authenticated
  with check (viewer_id = (select auth.uid()) and status = 'pending');

create policy grants_insert_owner_share on public.share_grants
  for insert to authenticated
  with check (owner_id = (select auth.uid()) and status in ('active', 'paused', 'pending'));

-- Only the owner changes status, precision and floor visibility.
create policy grants_update_owner on public.share_grants
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- Either side can delete the grant (the viewer can "stop following").
create policy grants_delete_either on public.share_grants
  for delete to authenticated
  using ((select auth.uid()) in (owner_id, viewer_id));

-- owner_id / viewer_id are immutable; keep updated_at fresh.
create function private.share_grants_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.owner_id <> old.owner_id or new.viewer_id <> old.viewer_id then
    raise exception 'owner_id and viewer_id cannot be changed' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger share_grants_guard
  before update on public.share_grants
  for each row execute function private.share_grants_guard();

-- When access ends, alerts the viewer had on the owner stop too.
create function private.share_grants_end_alerts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  g public.share_grants := coalesce(new, old);
begin
  if tg_op = 'DELETE' or new.status in ('revoked', 'paused') then
    update public.alerts
       set active = false
     where watcher_id = g.viewer_id and target_id = g.owner_id and active;
  end if;
  return null;
end;
$$;

create trigger share_grants_end_alerts
  after update or delete on public.share_grants
  for each row execute function private.share_grants_end_alerts();

-- ---------------------------------------------------------------------------
-- locations: a user writes and reads only their own rows. Other people read
-- through public.visible_friends() (0004), never the raw table.
-- ---------------------------------------------------------------------------
create policy locations_select_self on public.locations
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy locations_insert_self on public.locations
  for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy locations_delete_self on public.locations
  for delete to authenticated
  using (user_id = (select auth.uid()));
-- No UPDATE policy: history is append-only.

-- ---------------------------------------------------------------------------
-- alerts: the watcher manages them; the target can see and delete every alert
-- about them (transparency without messaging them).
-- ---------------------------------------------------------------------------
create policy alerts_select on public.alerts
  for select to authenticated
  using ((select auth.uid()) in (watcher_id, target_id));

create policy alerts_insert_watcher on public.alerts
  for insert to authenticated
  with check (watcher_id = (select auth.uid())
              and private.can_view(target_id, (select auth.uid())));

create policy alerts_update_watcher on public.alerts
  for update to authenticated
  using (watcher_id = (select auth.uid()))
  with check (watcher_id = (select auth.uid()));

create policy alerts_delete_either on public.alerts
  for delete to authenticated
  using ((select auth.uid()) in (watcher_id, target_id));

create policy alert_events_select on public.alert_events
  for select to authenticated
  using (exists (select 1 from public.alerts a
                  where a.id = alert_id
                    and (select auth.uid()) in (a.watcher_id, a.target_id)));

-- ---------------------------------------------------------------------------
-- floor_eval: private to the user.
-- ---------------------------------------------------------------------------
create policy floor_eval_self on public.floor_eval
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
