#!/usr/bin/env bash
# Builds the world layers (z0-11) drawn around the covered countries: a mask in
# the land colour, the sea, large lakes, the neighbours' borders, the covered
# countries' own land borders and country labels. The sea near them comes from
# OSM's water polygons and the rest from Natural Earth, all cut along the real
# national borders. MapLibre scales the layers up past z11, which is detailed
# enough to keep the mask under the border line at every zoom.
#
# Both sources come from what Planetiler downloads in build-basemap.sh
# (data/sources/) and the outline from build-borders.sh.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ne_zip="$SOURCES_DIR/natural_earth_vector.sqlite.zip"
water_zip="$SOURCES_DIR/water-polygons-split-3857.zip"
[[ -f "$ne_zip" && -f "$water_zip" ]] || { echo "Missing Natural Earth or water polygons, run scripts/build-basemap.sh first" >&2; exit 1; }
[[ -f "$OUTLINE" && -f "$BORDERS" && -f "$BORDER_WATER" ]] || { echo "Missing borders, run scripts/build-borders.sh first" >&2; exit 1; }

dir="$WORK_DIR/world"
rm -rf "$dir"
mkdir -p "$dir" "$BUILD_DIR"

# SQLite and shapefiles need random access, which is slow straight from a zip
unzip -q -j "$ne_zip" packages/natural_earth_vector.sqlite -d "$dir"
unzip -q -j "$water_zip" -d "$dir"

echo "Cutting along the national borders"
python3 -I -W ignore "$ROOT/scripts/world_layers.py" \
  "$dir/natural_earth_vector.sqlite" "$dir/water_polygons.shp" "$OUTLINE" "$BORDER_WATER" "$dir"

echo "Tiling"
tippecanoe --force --quiet --temporary-directory="$WORK_DIR" \
  -o "$BUILD_DIR/world.pmtiles" \
  --minimum-zoom=0 --maximum-zoom=11 \
  --no-feature-limit --no-tile-size-limit --no-tiny-polygon-reduction \
  --attribution='<a href="https://www.naturalearthdata.com/">Natural Earth</a> <a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors</a>' \
  -L mask:"$dir/mask.geojsonl" \
  -L sea:"$dir/sea.geojsonl" \
  -L lakes:"$dir/lakes.geojsonl" \
  -L neighbour_borders:"$dir/neighbour_borders.geojsonl" \
  -L borders:"$BORDERS" \
  -L labels:"$dir/labels.geojsonl"

rm -rf "$dir"
ls -lh "$BUILD_DIR/world.pmtiles"
