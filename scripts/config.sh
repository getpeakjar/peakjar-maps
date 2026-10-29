# Shared settings for the download and build scripts.

# Geofabrik extracts merged into one input, as paths under
# https://download.geofabrik.de/ without the "-latest.osm.pbf" suffix.
# Adding a country here and rerunning every step is all coverage needs.
# Poland and its neighbours' mountains, plus the Alps and the Carpathians that
# Polish hikers travel to most. Germany and Italy are left out: they would
# more than double the build for a few mountain regions.
COUNTRIES=(
  europe/poland europe/czech-republic europe/slovakia
  europe/austria europe/switzerland europe/liechtenstein europe/slovenia
  europe/hungary europe/romania
)

# Planetiler v0.10.2, pinned by digest so the tag cannot be swapped underneath us
PLANETILER_IMAGE=ghcr.io/onthegomap/planetiler@sha256:b5929b624c335c5a558f73f503890aacba3253f8926b1d6fa8c89108ea797f44

# Tile server (Martin) and the web server in front of it (Caddy), pinned by digest
MARTIN_IMAGE=ghcr.io/maplibre/martin@sha256:3b32a18f61c5aeca40b35f665b0f7dc6a0e9459598de23396365ea7e65ccff76
CADDY_IMAGE=docker.io/library/caddy@sha256:04913b1da43339a40ad1ea87827d70a576ac5aa6cf674c6e24fdca675887533a

# Port for scripts/serve-local.sh (8080 is often taken, e.g. by Steam on a Steam Deck)
LOCAL_PORT=${LOCAL_PORT:-8790}
# Address it listens on: 127.0.0.1 for this machine only, or the LAN IP so
# phones and emulators can load the map
LOCAL_BIND=${LOCAL_BIND:-127.0.0.1}

# OpenMapTiles glyph release and the font stacks the style uses
FONTS_URL=https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip
FONTS_SHA256=3a7a6c2dcd940a840aa6ffac8f39758252a667a0b329945b071fb44bf00e7f47
FONT_STACKS=("Roboto Regular" "Roboto Medium" "Roboto Condensed Italic")

# Heap for Planetiler (at least 0.5x the merged input) and the container's hard cap
JAVA_HEAP=${JAVA_HEAP:-6g}
CONTAINER_MEMORY=${CONTAINER_MEMORY:-8g}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT/data"
SOURCES_DIR="$DATA_DIR/sources"
WORK_DIR="$ROOT/work"
BUILD_DIR="$ROOT/build"
STATIC_DIR="$BUILD_DIR/static"
MERGED_PBF="$DATA_DIR/coverage.osm.pbf"
DEM_DIR="$DATA_DIR/dem"
