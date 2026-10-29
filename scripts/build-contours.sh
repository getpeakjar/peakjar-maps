#!/usr/bin/env bash
# Builds the contour layer (z10-14) from the Copernicus elevation tiles.
#
# Contours are traced every 10 m, one elevation tile per job in parallel.
# Each line gets a level: 100 for multiples of 100 m, 50 for other multiples
# of 50 m and 10 otherwise. Tiles show 100 m lines from z10, 50 m lines from
# z11 and every line from z13.
#
# Lines are clipped to the coverage outline. Lines shorter than 200 m are
# dropped: Copernicus is a surface model, so forests and buildings leave small
# rings that are noise rather than terrain.
set -euo pipefail
source "$(dirname "$0")/config.sh"

compgen -G "$DEM_DIR/*.tif" >/dev/null || { echo "No elevation tiles, run scripts/download-dem.sh first" >&2; exit 1; }
[[ -f "$DATA_DIR/coverage.geojson" ]] || { echo "Missing coverage outline, run scripts/download.sh first" >&2; exit 1; }

out_dir="$WORK_DIR/contours"
rm -rf "$out_dir"
mkdir -p "$out_dir" "$BUILD_DIR"

echo "Tracing contours"
ls "$DEM_DIR"/*.tif | xargs -P "$(nproc)" -I{} sh -c '
  name=$(basename "$1" .tif)
  gdal_contour -q -i 10 -a ele -f GPKG -nln contours "$1" "$2/$name.gpkg"
  ogr2ogr -f GeoJSONSeq "$2/$name.geojsonl" "$2/$name.gpkg" -clipsrc "$3" -dialect SQLite -sql "
    SELECT CAST(ele AS INTEGER) AS ele,
      CASE
        WHEN CAST(ele AS INTEGER) % 100 = 0 THEN 100
        WHEN CAST(ele AS INTEGER) % 50 = 0 THEN 50
        ELSE 10
      END AS level,
      geom
    FROM contours
    WHERE ST_Length(geom, 1) >= 200"
  rm "$2/$name.gpkg"
' _ {} "$out_dir" "$DATA_DIR/coverage.geojson"

echo "Tiling"
tippecanoe --force --quiet --temporary-directory="$WORK_DIR" \
  -o "$BUILD_DIR/contours.pmtiles" \
  --layer=contours \
  --minimum-zoom=10 --maximum-zoom=14 \
  --read-parallel \
  -j '{"*": ["any", [">=", "$zoom", 13], ["all", [">=", "$zoom", 11], [">=", "level", 50]], ["==", "level", 100]]}' \
  --no-feature-limit --no-tile-size-limit \
  --attribution='produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved' \
  "$out_dir"/*.geojsonl

rm -rf "$out_dir"
ls -lh "$BUILD_DIR/contours.pmtiles"
