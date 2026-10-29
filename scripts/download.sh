#!/usr/bin/env bash
# Downloads the country extracts from Geofabrik, verifies them and merges
# them into a single OSM file. Also builds the coverage outline from the
# extracts' boundary files.
set -euo pipefail
source "$(dirname "$0")/config.sh"

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

names=()
for country in "${COUNTRIES[@]}"; do
  name=$(basename "$country")
  names+=("$name")
  base="https://download.geofabrik.de/$country"
  echo "Downloading $name"
  wget -q --show-progress -N "$base-latest.osm.pbf" "$base-latest.osm.pbf.md5" "$base.poly"
  md5sum -c "$name-latest.osm.pbf.md5"
done

# The coverage outline is the union of Geofabrik's extract boundaries. It
# limits the base map (as .poly for Planetiler) and clips contours (as GeoJSON).
echo "Building coverage outline"
{
  echo coverage
  for name in "${names[@]}"; do sed '1d;$d' "$name.poly"; done
  echo END
} > coverage.poly
python3 -I "$ROOT/scripts/poly_to_geojson.py" countries.geojson "${names[@]/%/.poly}"
rm -f coverage.geojson
ogr2ogr -f GeoJSON coverage.geojson countries.geojson -nln coverage \
  -dialect SQLite -sql "SELECT ST_Union(geometry) AS geometry FROM countries"

echo "Merging into $(basename "$MERGED_PBF")"
osmium merge --overwrite "${names[@]/%/-latest.osm.pbf}" -o "$MERGED_PBF"

# The extract timestamp is the OSM snapshot the tiles are built from; keep it
# in step with the peakjar-data release. Merging drops it from the header, so
# read it from the first extract (Geofabrik cuts all of them from one snapshot).
osmium fileinfo -g header.option.osmosis_replication_timestamp \
  "${names[0]}-latest.osm.pbf" > "$DATA_DIR/snapshot.txt"
echo "OSM snapshot: $(cat "$DATA_DIR/snapshot.txt")"
