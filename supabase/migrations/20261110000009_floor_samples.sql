-- 0009: consented data logging for floor estimation.
--
-- A user must explicitly opt in (profiles.data_logging_consent_at) before
-- the app may store raw barometer samples. Samples are private to the user,
-- exportable as CSV by the user, deleted when consent is withdrawn, and
-- purged after 90 days.

alter table public.profiles
  add column data_logging_consent_at timestamptz,
  add column data_logging_consent_version text;

-- Users may give or withdraw consent themselves.
grant update (data_logging_consent_at, data_logging_consent_version) on public.profiles to authenticated;

create table public.floor_samples (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  -- Groups samples from one logging run (e.g. one walk through a building).
  session_id       uuid not null,
  recorded_at      timestamptz not null,
  pressure_kpa     real not null check (pressure_kpa between 50 and 120),
  rel_altitude_m   real check (rel_altitude_m between -500 and 500),
  gps_accuracy_m   real check (gps_accuracy_m is null or gps_accuracy_m between 0 and 10000),
  place_id         uuid references public.places (id) on delete set null,
  -- Ground truth: the floor the user confirmed ("I'm on floor N"), if any.
  confirmed_floor  int check (confirmed_floor between -10 and 200),
  -- How the user moved, if they told us (for evaluation).
  movement         text check (movement in ('idle', 'stairs', 'elevator', 'walking')),
  consent_version  text not null,
  created_at       timestamptz not null default now()
);
create index floor_samples_user_session_idx on public.floor_samples (user_id, session_id, recorded_at);

alter table public.floor_samples enable row level security;
revoke all on public.floor_samples from anon;

-- Only the owner can read their samples (this is also the CSV export path:
-- GET /rest/v1/floor_samples with "Accept: text/csv").
create policy floor_samples_select_self on public.floor_samples
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Insert only for yourself, only with consent on file, and the consent
-- version recorded on the row must match the one you agreed to.
create policy floor_samples_insert_with_consent on public.floor_samples
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.profiles p
       where p.id = (select auth.uid())
         and p.data_logging_consent_at is not null
         and p.data_logging_consent_version = consent_version
    )
  );

create policy floor_samples_delete_self on public.floor_samples
  for delete to authenticated
  using (user_id = (select auth.uid()));

-- Withdrawing consent deletes everything logged so far.
create function private.on_logging_consent_withdrawn()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.data_logging_consent_at is not null and new.data_logging_consent_at is null then
    delete from public.floor_samples where user_id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function private.on_logging_consent_withdrawn() from public;

create trigger profiles_logging_consent_withdrawn
  after update of data_logging_consent_at on public.profiles
  for each row execute function private.on_logging_consent_withdrawn();

-- Retention: research samples are kept at most 90 days.
create or replace function private.purge_old_locations()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.locations        where recorded_at < now() - interval '7 days';
  delete from public.latest_locations where recorded_at < now() - interval '7 days';
  delete from public.alert_events     where fired_at    < now() - interval '7 days';
  delete from public.floor_samples    where recorded_at < now() - interval '90 days';
$$;
