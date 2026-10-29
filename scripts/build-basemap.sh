#!/usr/bin/env bash
# Builds the OpenMapTiles base map (z0-14) from the merged OSM file.
#
# Planetiler runs in a locked-down container that sees only this repository's
# data/, work/ and build/ directories: no home directory, no capabilities, a
# read-only root filesystem, and no network during the build itself.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -f "$MERGED_PBF" ]] || { echo "Missing $MERGED_PBF, run scripts/download.sh first" >&2; exit 1; }

# Inside distrobox, podman lives on the host
podman=(podman)
command -v podman >/dev/null || podman=(distrobox-host-exec podman)

mkdir -p "$SOURCES_DIR" "$WORK_DIR" "$BUILD_DIR"

planetiler() {
  "${podman[@]}" run --rm \
    --userns=keep-id \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --read-only --tmpfs /tmp \
    --memory="$CONTAINER_MEMORY" \
    -e JAVA_TOOL_OPTIONS="-Xmx$JAVA_HEAP" \
    "$@"
}

input="/data/$(basename "$MERGED_PBF")"

echo "Step 1/2: downloading water, coastline and border sources"
planetiler \
  -v "$DATA_DIR:/data:ro" \
  -v "$SOURCES_DIR:/data/sources" \
  -v "$WORK_DIR:/work" \
  "$PLANETILER_IMAGE" \
  --osm_path="$input" \
  --download_dir=/data/sources \
  --tmpdir=/work \
  --download --only_download

echo "Step 2/2: building tiles with networking off"
planetiler \
  --network=none \
  -v "$DATA_DIR:/data:ro" \
  -v "$WORK_DIR:/work" \
  -v "$BUILD_DIR:/build" \
  "$PLANETILER_IMAGE" \
  --osm_path="$input" \
  --polygon=/data/coverage.poly \
  --download_dir=/data/sources \
  --tmpdir=/work \
  --output=/build/basemap.pmtiles \
  --force

ls -lh "$BUILD_DIR/basemap.pmtiles"
