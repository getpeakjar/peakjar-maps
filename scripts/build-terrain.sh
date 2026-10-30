#!/usr/bin/env bash
# Builds terrain tiles (z5-11, 512 px) for MapLibre hillshade and 3D terrain.
#
# Elevation is encoded as Terrarium RGB: height = R * 256 + G + B / 256 - 32768.
# Heights are rounded to whole metres and B is left at 0; the fraction is
# below the data's accuracy and would triple the size. Tiles are lossless PNG,
# because lossy formats corrupt the encoded heights, and the lower zooms use
# nearest-neighbour overviews for the same reason.
#
# The data is clipped to the coverage outline plus about 10 km and is 0 m
# beyond it. The style's world mask covers everything outside the outline,
# so the margin only keeps hillshade from fading at the border.
set -euo pipefail
source "$(dirname "$0")/config.sh"

compgen -G "$DEM_DIR/*.tif" >/dev/null || { echo "No elevation tiles, run scripts/download-dem.sh first" >&2; exit 1; }
[[ -f "$DATA_DIR/coverage.geojson" ]] || { echo "Missing coverage outline, run scripts/download.sh first" >&2; exit 1; }

dir="$WORK_DIR/terrain"
rm -rf "$dir"
mkdir -p "$dir" "$BUILD_DIR"

ogr2ogr -f GeoJSON "$dir/cutline.geojson" "$DATA_DIR/coverage.geojson" -nln cutline \
  -dialect SQLite -sql "SELECT ST_Buffer(geometry, 0.1) AS geometry FROM coverage"
gdalbuildvrt -q "$dir/dem.vrt" "$DEM_DIR"/*.tif

# 38.2185 m is one pixel of a 512 px tile at z11 in Web Mercator
echo "Reprojecting elevation"
gdalwarp -q -t_srs EPSG:3857 -tr 38.21851414258813 38.21851414258813 -tap \
  -r bilinear -ot Float32 -multi -wo NUM_THREADS=ALL_CPUS \
  -cutline "$dir/cutline.geojson" -crop_to_cutline -dstnodata None \
  -co TILED=YES -co COMPRESS=DEFLATE -co BIGTIFF=YES \
  "$dir/dem.vrt" "$dir/dem3857.tif"

echo "Encoding Terrarium RGB"
gdal_calc --quiet -A "$dir/dem3857.tif" --outfile="$dir/rgb.tif" \
  --type=Byte --NoDataValue=none \
  --co TILED=YES --co COMPRESS=DEFLATE --co BIGTIFF=YES \
  --calc="numpy.floor((numpy.round(A) + 32768) / 256)" \
  --calc="(numpy.round(A) + 32768) % 256" \
  --calc="A * 0"

echo "Writing tiles"
rm -f "$BUILD_DIR/terrain.mbtiles"
gdal_translate -q -of MBTiles \
  -co TILE_FORMAT=PNG -co BLOCKSIZE=512 -co RESAMPLING=NEAREST \
  -co NAME="Peakjar terrain" -co DESCRIPTION="Copernicus GLO-30, Terrarium encoding" \
  "$dir/rgb.tif" "$BUILD_DIR/terrain.mbtiles"
gdaladdo -q -r nearest "$BUILD_DIR/terrain.mbtiles" 2 4 8 16 32 64

# Tiles at the data's edge are partly transparent, which MapLibre would read
# as -32768 m (a black hillshade frame, pits in 3D); flatten them to 0 m
echo "Filling tile edges"
python3 -I -W ignore "$ROOT/scripts/terrain_fill.py" "$BUILD_DIR/terrain.mbtiles"

rm -rf "$dir"
ls -lh "$BUILD_DIR/terrain.mbtiles"
