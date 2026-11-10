#!/usr/bin/env bash
# Download the North Carolina OpenStreetMap extract for local Valhalla.
# Map data © OpenStreetMap contributors, ODbL. Source: Geofabrik.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p custom_files
curl -fSL --retry 3 \
  -o custom_files/north-carolina-latest.osm.pbf \
  https://download.geofabrik.de/north-america/us/north-carolina-latest.osm.pbf
ls -lh custom_files/north-carolina-latest.osm.pbf
