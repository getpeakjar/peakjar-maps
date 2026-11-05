#!/usr/bin/env bash
# Builds the real national borders from the countries' OSM boundary relations
# (data/outline.geojson, data/borders.geojsonl and data/border_water.geojsonl) and cuts the merged OSM file
# to them (data/outline.osm.pbf), so that the map ends at the border itself and
# not at the looser shape of Geofabrik's extracts.
#
# The smart strategy keeps ways that cross a border whole, and multipolygons
# such as border lakes complete; the world mask hides what lies beyond.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -f "$MERGED_PBF" ]] || { echo "Missing $MERGED_PBF, run scripts/download.sh first" >&2; exit 1; }

dir="$WORK_DIR/borders"
rm -rf "$dir"
mkdir -p "$dir"

inputs=()
for country in "${COUNTRIES[@]}"; do
  name=$(basename "$country")
  inputs+=("$DATA_DIR/$name-latest.osm.pbf:${COUNTRY_CODES[$name]}")
done

echo "Reading the boundary relations"
python3 -I -W ignore "$ROOT/scripts/country_borders.py" "$DATA_DIR" "$dir" "$MERGED_PBF" "${inputs[@]}"

echo "Cutting the OSM data to the borders"
osmium extract --overwrite --strategy=smart -p "$OUTLINE" -o "$dir/trimmed.osm.pbf" "$MERGED_PBF"

echo "Leaving out rivers that lie almost wholly abroad"
osmium tags-filter --overwrite "$dir/trimmed.osm.pbf" w/waterway=river,canal -o "$dir/waterways.osm.pbf"
osmium export --overwrite --geometry-types=linestring -a id -f geojsonseq \
  --format-option=print_record_separator=false -o "$dir/waterways.geojsonl" "$dir/waterways.osm.pbf"
python3 -I -W ignore "$ROOT/scripts/foreign_rivers.py" "$OUTLINE" "$dir/waterways.geojsonl" > "$dir/foreign-rivers.txt"
osmium removeid --overwrite -i "$dir/foreign-rivers.txt" -o "$TRIMMED_PBF" "$dir/trimmed.osm.pbf"

rm -rf "$dir"
ls -lh "$OUTLINE" "$BORDERS" "$BORDER_WATER" "$TRIMMED_PBF"
