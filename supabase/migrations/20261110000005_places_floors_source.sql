-- 0005: record where each building's floor count came from
-- ("official: …", "osm:building:levels …" or "best guess …").
alter table public.places add column floors_source text;
