#!/usr/bin/env bash
# Publishes the app's peak and region data (build/data) as a release of the
# public data repository ($DATA_REPO in config.sh).
#
# Usage: scripts/publish-data.sh [RELEASE_NAME]
#   RELEASE_NAME defaults to peaks-regions-osm-<snapshot date>. Give another
#   name only to publish a second build of the same snapshot, for example
#   peaks-regions-osm-2026-10-28-2.
#
# Releases are never replaced: an existing name is refused. The release notes
# carry the counts, the commit of this repository that built the data, and the
# licence and credit texts. The same commit is tagged with the release name
# here and the tag pushed, so every data release maps to the code that made it.
# The script therefore runs only from a clean checkout of origin/main.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ $# -le 1 ]] || { echo "Usage: $0 [RELEASE_NAME]" >&2; exit 1; }

cd "$ROOT"
git fetch --quiet origin main
if ! git diff --quiet HEAD; then
  echo "Uncommitted changes; publish from a clean checkout of main" >&2; exit 1
fi
if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  echo "HEAD is not origin/main; check out and pull main first" >&2; exit 1
fi

files=(peaks.json regions.json snapshot.txt)
for file in "${files[@]}"; do
  [[ -f "$DATA_OUT_DIR/$file" ]] || { echo "Missing build/data/$file, run scripts/build-all.sh --only peaks first" >&2; exit 1; }
done

snapshot=$(cut -c1-10 "$DATA_OUT_DIR/snapshot.txt")
release=${1:-peaks-regions-osm-$snapshot}
[[ $release =~ ^peaks-regions-osm-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$ ]] || {
  echo "Release names look like peaks-regions-osm-YYYY-MM-DD or peaks-regions-osm-YYYY-MM-DD-N" >&2; exit 1; }
if gh release view "$release" --repo "$DATA_REPO" >/dev/null 2>&1; then
  echo "$DATA_REPO already has release $release, and releases are never replaced." >&2
  echo "Publish a new build of the same snapshot as $release-2 (and so on)." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$release" >/dev/null || git ls-remote --exit-code --tags origin "$release" >/dev/null; then
  echo "Tag $release already exists in this repository; choose another release name" >&2; exit 1
fi

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp "${files[@]/#/$DATA_OUT_DIR/}" "$staging/"
(cd "$staging" && sha256sum "${files[@]}" > SHA256SUMS)
commit=$(git rev-parse --short=12 HEAD)

# Counts for the notes, in the same wording as earlier releases
summary=$(python3 -I - "$staging" <<'EOF'
import json, os, sys

names = {"PL": "Poland", "CZ": "Czechia", "SK": "Slovakia", "AT": "Austria", "CH": "Switzerland",
         "LI": "Liechtenstein", "SI": "Slovenia", "HU": "Hungary", "RO": "Romania"}
order = list(names)
folder = sys.argv[1]
peaks = json.load(open(os.path.join(folder, "peaks.json")))["features"]
regions = json.load(open(os.path.join(folder, "regions.json")))["features"]

def country_list(codes):
    codes = sorted(set(codes), key=lambda c: (order.index(c) if c in order else len(order), c))
    named = [names.get(c, c) for c in codes]
    return named[0] if len(named) == 1 else ", ".join(named[:-1]) + " and " + named[-1]

named = sum(1 for p in peaks if p["properties"].get("name"))
approx = sum(1 for p in peaks if p["properties"].get("ele_approx"))
region_counts = {}
for r in regions:
    code = r["properties"]["country"]
    region_counts[code] = region_counts.get(code, 0) + 1
region_parts = [f"{names.get(c, c)} ({n:,})" for c, n in
                sorted(region_counts.items(), key=lambda i: order.index(i[0]) if i[0] in order else len(order))]
region_text = region_parts[0] if len(region_parts) == 1 else ", ".join(region_parts[:-1]) + " and " + region_parts[-1]

print(f"- `peaks.json`: {len(peaks):,} peaks in {country_list(p['properties']['country'] for p in peaks)} "
      f"({named:,} named), with OSM id, name, elevation and country. "
      f"{approx:,} heights missing in OSM are filled from terrain data.")
print(f"- `regions.json`: {len(regions):,} geomorphological units and mountain ranges in {region_text}.")
EOF
)

notes="$staging/notes.md"
cat > "$notes" <<EOF
Peak catalogue and mountain regions for the Peakjar app, built from the OpenStreetMap snapshot of $snapshot (the same snapshot as the map tiles).

$summary
- \`snapshot.txt\`: the OpenStreetMap snapshot time.
- \`SHA256SUMS\`: checksums of the files above (\`sha256sum -c SHA256SUMS\`).

Built from commit \`$commit\` of the map repository. How the data is made: see the [README](https://github.com/$DATA_REPO#how-the-data-is-made).

## Licence and credits

Data © OpenStreetMap contributors, available under the Open Database License (ODbL): https://www.openstreetmap.org/copyright

Approximate peak heights (\`ele_approx\`) were produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved. The organisations in charge of the Copernicus programme by law or by delegation do not incur any liability for any use of the Copernicus WorldDEM-30.
EOF

echo "Release $release for $DATA_REPO, built from $commit:"
echo
cat "$notes"
echo
read -r -p "Publish it? Releases are public and never replaced. [y/N] " answer
[[ $answer == [yY] ]] || { echo "Nothing was published."; exit 0; }

gh release create "$release" --repo "$DATA_REPO" --target main \
  --title "Peaks and regions, OSM snapshot $snapshot" \
  --notes-file "$notes" \
  "${files[@]/#/$staging/}" "$staging/SHA256SUMS"

git tag -a "$release" -m "Peak and region data published as $DATA_REPO release $release"
git push --quiet origin "$release" || echo "Could not push $release; push it with: git push origin $release" >&2

echo
echo "Published $release. In the app repository, set VERSION and the checksums in"
echo "client/scripts/download-geo-data.mjs to:"
echo "  VERSION = '$release'"
sed 's/^/  /' "$staging/SHA256SUMS"
