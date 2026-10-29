#!/usr/bin/env bash
# Uploads the built tiles to the VPS as a new release and switches to it.
#
# Usage: scripts/deploy.sh SSH_TARGET PUBLIC_URL
#   e.g. scripts/deploy.sh deploy@vps.example.com https://maps.peakjar.com
#
# Each release is a folder in $REMOTE_ROOT/releases. Files that did not change
# since the current release are hard-linked instead of uploaded again, so a
# style-only release uploads a few MB. The "current" symlink is switched only
# after the upload is complete, then the containers are recreated to pick it
# up. The two newest releases are kept for a quick rollback.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 SSH_TARGET PUBLIC_URL" >&2; exit 1; }
target=$1
public_url=${2%/}
remote_root=${REMOTE_ROOT:-/srv/peakjar-maps}

for file in world.pmtiles basemap.pmtiles trails.pmtiles contours.pmtiles terrain.mbtiles; do
  [[ -f "$BUILD_DIR/$file" ]] || { echo "Missing build/$file, build every tile set first" >&2; exit 1; }
done

release=$(date -u +%Y%m%dT%H%M%SZ)
echo "Release $release for $public_url"

# The style needs absolute URLs, so build it for the public address and put
# the local one back afterwards
scripts_dir="$ROOT/scripts"
"$scripts_dir/build-static.sh" "$public_url"
trap '"$scripts_dir/build-static.sh" >/dev/null' EXIT

ssh "$target" "mkdir -p '$remote_root/releases/$release' '$remote_root/serve'"

echo "Uploading tiles"
rsync -a --info=progress2 --chmod=D755,F644 \
  --link-dest="$remote_root/current/" \
  "$BUILD_DIR"/{world,basemap,trails,contours}.pmtiles "$BUILD_DIR/terrain.mbtiles" "$BUILD_DIR/static" \
  "$target:$remote_root/releases/$release/"

# compose settings for the server (SITE_ADDRESS, COMPOSE_FILE) live in
# serve/.env on the server and are never overwritten
rsync -a --chmod=D755,F644 \
  "$ROOT/serve/compose.yaml" "$ROOT/serve/compose.tls.yaml" "$ROOT/serve/martin.yaml" "$ROOT/serve/Caddyfile" \
  "$target:$remote_root/serve/"

echo "Switching to the new release"
ssh "$target" "set -e
  cd '$remote_root'
  ln -sfn 'releases/$release' current.new
  mv -T current.new current
  cd serve
  docker compose up -d --force-recreate --remove-orphans
  ls -1d ../releases/*/ | head -n -2 | xargs -r rm -rf"

echo "Checking $public_url"
sleep 3
curl -fsS -o /dev/null "$public_url/style/outdoor.json"
curl -fsS "$public_url/tiles/catalog" | python3 -I -c "import json, sys; print('Tile sets:', ', '.join(sorted(json.load(sys.stdin)['tiles'])))"
echo "Deployed $release"
