#!/usr/bin/env bash
# Builds the app's peak catalogue and mountain regions from the same OSM file
# as the tiles, so peaks and map agree: build/data/peaks.json and
# build/data/regions.json (see scripts/peaks_regions.py for their contents).
# Peaks without an OSM height get one from the Copernicus terrain tiles.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -f "$MERGED_PBF" ]] || { echo "Missing $MERGED_PBF, run scripts/download.sh first" >&2; exit 1; }
compgen -G "$DEM_DIR/*.tif" >/dev/null || { echo "No elevation tiles, run scripts/download-dem.sh first" >&2; exit 1; }

filtered="$WORK_DIR/peaks-regions.osm.pbf"
osmconf="$WORK_DIR/osmconf-peaks.ini"
mkdir -p "$WORK_DIR" "$DATA_OUT_DIR"

echo "Extracting peaks, geomorphological units and mountain ranges"
osmium tags-filter --overwrite "$MERGED_PBF" \
  n/natural=peak,volcano nwr/natural=mountain_range \
  r/boundary=geomorphological-unit,geomorphological_unit \
  -o "$filtered"

# GDAL's default OSM config drops the ele tag; keep it
sed 's/^ignore=\(.*\),ele,/ignore=\1,/' /usr/share/gdal/osmconf.ini > "$osmconf"

echo "Writing peaks and regions"
OSM_CONFIG_FILE="$osmconf" python3 -I -W ignore "$ROOT/scripts/peaks_regions.py" \
  "$filtered" "$DATA_DIR/countries.geojson" "$DEM_DIR" "$DATA_OUT_DIR"
cp "$DATA_DIR/snapshot.txt" "$DATA_OUT_DIR/snapshot.txt"

rm -f "$filtered" "$osmconf"
ls -lh "$DATA_OUT_DIR"
