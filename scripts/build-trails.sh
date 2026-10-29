#!/usr/bin/env bash
# Builds the hiking-trail layer (z8-14) from OSM route relations.
#
# Routes are split into their ways, and each way becomes one line per trail
# colour on it, with a slot that places trails sharing a path side by side
# (see scripts/trail_segments.py). The colour comes from the way colour in
# osmc:symbol (the first field, e.g. "red" in "red:white:red_bar"), which is
# how PTTK and KČT trails are marked, with the colour tag as fallback.
# Unknown or missing colours are left null so the style can draw them neutral.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -f "$MERGED_PBF" ]] || { echo "Missing $MERGED_PBF, run scripts/download.sh first" >&2; exit 1; }
mkdir -p "$WORK_DIR" "$BUILD_DIR"

routes_pbf="$WORK_DIR/hiking-routes.osm.pbf"
osmconf="$WORK_DIR/osmconf-trails.ini"
routes_gpkg="$WORK_DIR/hiking-routes.gpkg"
trails="$WORK_DIR/trails.geojsonl"

echo "Extracting hiking route relations and their ways"
osmium tags-filter --overwrite "$MERGED_PBF" r/route=hiking,foot -o "$routes_pbf"

# GDAL's default OSM config, with the route tags we need reported as fields
sed '/^\[multilinestrings\]/,/^\[/ {
  s/^attributes=.*/attributes=name,route,ref,network,osmc:symbol,colour,operator/
  s/^#other_tags=no/other_tags=no/
}' /usr/share/gdal/osmconf.ini > "$osmconf"

echo "Building route lines"
# Copy the route layer out first: the OSM driver cannot read one of its layers
# on its own without buffering every tagged node.
rm -f "$routes_gpkg" "$trails"
ogr2ogr -f GPKG "$routes_gpkg" "$routes_pbf" multilinestrings \
  -oo CONFIG_FILE="$osmconf" -nln routes

echo "Splitting routes into shared path segments"
python3 -I -W ignore "$ROOT/scripts/trail_segments.py" "$routes_gpkg" "$trails"

echo "Tiling"
tippecanoe --force --quiet --temporary-directory="$WORK_DIR" \
  -o "$BUILD_DIR/trails.pmtiles" \
  --layer=trails \
  --minimum-zoom=8 --maximum-zoom=14 \
  --no-feature-limit --no-tile-size-limit --coalesce \
  --attribution='<a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors</a>' \
  "$trails"

rm -f "$routes_pbf" "$osmconf" "$routes_gpkg" "$trails"
ls -lh "$BUILD_DIR/trails.pmtiles"
