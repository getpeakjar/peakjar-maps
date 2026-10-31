#!/usr/bin/env bash
# Assembles the static files served next to the tiles into build/static:
# the style (with its tile, font and sprite URLs pointing at BASE_URL), the
# fonts, the icon sprites and the test page.
#
# Usage: scripts/build-static.sh [BASE_URL]   (default http://localhost:$LOCAL_PORT)
set -euo pipefail
source "$(dirname "$0")/config.sh"

base_url=${1:-http://localhost:$LOCAL_PORT}
base_url=${base_url%/}

fonts_zip="$DATA_DIR/fonts-$(basename "$FONTS_URL")"
if [[ ! -f "$fonts_zip" ]]; then
  wget -q --show-progress -O "$fonts_zip" "$FONTS_URL"
fi
echo "$FONTS_SHA256  $fonts_zip" | sha256sum -c --quiet

# Empty the folder rather than replacing it, so a running local server, which
# has it mounted, sees the new files
mkdir -p "$STATIC_DIR"
find "$STATIC_DIR" -mindepth 1 -delete
mkdir -p "$STATIC_DIR/style" "$STATIC_DIR/fonts"

unzip -q "$fonts_zip" "${FONT_STACKS[@]/%//*}" -d "$STATIC_DIR/fonts"
cp -r "$ROOT/style/sprites" "$STATIC_DIR/sprites"
sed "s|{BASE_URL}|$base_url|g" "$ROOT/style/outdoor.json" > "$STATIC_DIR/style/outdoor.json"
cp "$ROOT/serve/index.html" "$STATIC_DIR/index.html"

echo "Style: $base_url/style/outdoor.json"
