# ml/ — floor estimation

Barometer-based floor estimation (Phase 7 groundwork). **The current data is
SYNTHETIC.** See `docs/EVALUATION.md`.

```sh
cd ml
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q                                   # tests
.venv/bin/python -m mapchat_floor.synth --sessions 50 --out synthetic.csv
.venv/bin/python -m mapchat_floor.evaluate --out ../docs/EVALUATION.md
# Export YOUR consented samples (RLS-scoped) as CSV:
SUPABASE_URL=... SUPABASE_ANON_KEY=... ACCESS_TOKEN=... .venv/bin/python -m mapchat_floor.export
```

Data logging is consent-gated in Supabase (`public.floor_samples`, migration
0009). It needs `profiles.data_logging_consent_at` and a matching
`consent_version`. Withdrawing consent deletes the samples, and samples are
purged after 90 days.
