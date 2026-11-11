"""Export YOUR OWN consented barometer samples from Supabase as CSV.

Uses your access token (from the app or `supabase` sign-in), so Row Level
Security only returns your rows. PostgREST renders CSV when asked with
`Accept: text/csv`.

    SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... ACCESS_TOKEN=... \\
      python -m mapchat_floor.export --out my_samples.csv
"""
from __future__ import annotations

import argparse
import os
import urllib.request

COLUMNS = [
    "session_id", "recorded_at", "pressure_kpa", "rel_altitude_m", "gps_accuracy_m",
    "place_id", "confirmed_floor", "movement", "consent_version",
]


def build_request(base_url: str, anon_key: str, access_token: str) -> urllib.request.Request:
    url = f"{base_url.rstrip('/')}/rest/v1/floor_samples?select={','.join(COLUMNS)}&order=session_id,recorded_at"
    return urllib.request.Request(
        url,
        headers={"apikey": anon_key, "Authorization": f"Bearer {access_token}", "Accept": "text/csv"},
    )


def export_csv(base_url: str, anon_key: str, access_token: str, out_path: str, opener=urllib.request.urlopen) -> int:
    with opener(build_request(base_url, anon_key, access_token), timeout=30) as resp:
        body = resp.read().decode("utf-8")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(body)
    # Data rows = non-empty lines minus the header.
    return max(0, len(body.strip().splitlines()) - 1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="floor_samples.csv")
    args = ap.parse_args()
    n = export_csv(os.environ["SUPABASE_URL"], os.environ["SUPABASE_ANON_KEY"], os.environ["ACCESS_TOKEN"], args.out)
    print(f"wrote {n} rows to {args.out}")
