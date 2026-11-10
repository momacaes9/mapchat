-- 0001: extensions and private helper schema.

-- PostGIS for geography types and spatial predicates.
create extension if not exists postgis with schema extensions;

-- pg_cron for the location retention job (see 0004).
create extension if not exists pg_cron with schema pg_catalog;

-- Helper functions that RLS policies call live in a schema that PostgREST does
-- not expose, so clients cannot call them directly over the API.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;
