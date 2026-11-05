#!/usr/bin/env bash
# Downloads the Copernicus GLO-30 elevation tiles (1x1 degree, named by their
# south-west corner) that touch the coverage outline plus a margin, from the
# AWS open data bucket. Tiles that are all sea do not exist upstream and are
# skipped. Northern and eastern hemispheres only.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -f "$DATA_DIR/coverage.geojson" ]] || { echo "Missing coverage outline, run scripts/download.sh first" >&2; exit 1; }

mkdir -p "$DEM_DIR"
base=https://copernicus-dem-30m.s3.amazonaws.com

tiles=$(python3 -I -W ignore - "$DATA_DIR/coverage.geojson" <<'PY'
import math, sys
from osgeo import ogr

# The margin matches the one build-terrain.sh keeps around the outline
# Keep the data source and feature alive: GDAL frees the geometry with them
source = ogr.Open(sys.argv[1])
feature = source.GetLayer(0).GetNextFeature()
outline = feature.GetGeometryRef().Buffer(0.15)
min_lon, max_lon, min_lat, max_lat = outline.GetEnvelope()
for lat in range(math.floor(min_lat), math.floor(max_lat) + 1):
    for lon in range(math.floor(min_lon), math.floor(max_lon) + 1):
        tile = ogr.CreateGeometryFromWkt(
            f"POLYGON(({lon} {lat},{lon + 1} {lat},{lon + 1} {lat + 1},{lon} {lat + 1},{lon} {lat}))")
        if tile.Intersects(outline):
            print(f"Copernicus_DSM_COG_10_N{lat:02d}_00_E{lon:03d}_00_DEM")
PY
)

echo "$tiles" | xargs -P 8 -I{} sh -c '
  out="$1/$2.tif"
  [ -s "$out" ] && exit 0
  if wget -q -O "$out.part" "$3/$2/$2.tif"; then mv "$out.part" "$out"
  else rm -f "$out.part"; echo "skipped $2 (not available)"; fi
' _ "$DEM_DIR" {} "$base"

echo "$(ls "$DEM_DIR"/*.tif | wc -l) tiles, $(du -sh "$DEM_DIR" | cut -f1)"
