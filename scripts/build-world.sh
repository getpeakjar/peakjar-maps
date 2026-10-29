#!/usr/bin/env bash
# Builds the world layers (z0-8) drawn around the coverage area: a mask in the
# sea colour, country silhouettes, large lakes and country labels, all from
# Natural Earth with the coverage area cut out. MapLibre scales them up past
# z8, so the map outside the coverage area stays a simple world map.
#
# Natural Earth comes from the sources Planetiler downloads in
# build-basemap.sh (data/sources/natural_earth_vector.sqlite.zip).
set -euo pipefail
source "$(dirname "$0")/config.sh"

ne_zip="$SOURCES_DIR/natural_earth_vector.sqlite.zip"
[[ -f "$ne_zip" ]] || { echo "Missing $ne_zip, run scripts/build-basemap.sh first" >&2; exit 1; }
[[ -f "$DATA_DIR/coverage.geojson" ]] || { echo "Missing coverage outline, run scripts/download.sh first" >&2; exit 1; }

dir="$WORK_DIR/world"
rm -rf "$dir"
mkdir -p "$dir" "$BUILD_DIR"

# SQLite needs random access, which is slow straight from the zip
unzip -q -j "$ne_zip" packages/natural_earth_vector.sqlite -d "$dir"

echo "Cutting out the coverage area"
python3 -I -W ignore "$ROOT/scripts/world_layers.py" \
  "$dir/natural_earth_vector.sqlite" "$DATA_DIR/coverage.geojson" "$dir"

echo "Tiling"
tippecanoe --force --quiet --temporary-directory="$WORK_DIR" \
  -o "$BUILD_DIR/world.pmtiles" \
  --minimum-zoom=0 --maximum-zoom=8 \
  --no-feature-limit --no-tile-size-limit --no-tiny-polygon-reduction \
  --attribution='<a href="https://www.naturalearthdata.com/">Natural Earth</a>' \
  -L mask:"$dir/mask.geojsonl" \
  -L land:"$dir/land.geojsonl" \
  -L lakes:"$dir/lakes.geojsonl" \
  -L labels:"$dir/labels.geojsonl"

rm -rf "$dir"
ls -lh "$BUILD_DIR/world.pmtiles"
