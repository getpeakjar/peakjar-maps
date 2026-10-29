#!/usr/bin/env bash
# Serves build/ on http://localhost:$LOCAL_PORT the same way the VPS does: Martin for
# tiles behind Caddy for everything else, both in one Podman pod that can only
# read build/ and serve/.
#
# Usage: scripts/serve-local.sh [stop]
set -euo pipefail
source "$(dirname "$0")/config.sh"

# Inside distrobox, podman lives on the host
podman=(podman)
command -v podman >/dev/null || podman=(distrobox-host-exec podman)

pod=peakjar-maps
"${podman[@]}" pod rm -f "$pod" >/dev/null 2>&1 || true
[[ ${1:-} == stop ]] && { echo "Stopped"; exit 0; }

[[ -f "$STATIC_DIR/style/outdoor.json" ]] || { echo "Missing build/static, run scripts/build-static.sh first" >&2; exit 1; }

hardening=(--cap-drop=all --security-opt=no-new-privileges --read-only)

"${podman[@]}" pod create --name "$pod" --userns=keep-id -p "$LOCAL_BIND:$LOCAL_PORT:8080" >/dev/null
"${podman[@]}" run -d --pod "$pod" --name "$pod-martin" "${hardening[@]}" \
  -v "$BUILD_DIR:/tiles:ro" \
  -v "$ROOT/serve/martin.yaml:/etc/martin.yaml:ro" \
  "$MARTIN_IMAGE" --config /etc/martin.yaml >/dev/null
# The Caddy binary carries the bind-low-ports file capability and will not
# start without it, even though it listens on 8080 here
"${podman[@]}" run -d --pod "$pod" --name "$pod-caddy" "${hardening[@]}" \
  --cap-add=NET_BIND_SERVICE \
  --tmpfs /data --tmpfs /config \
  -v "$STATIC_DIR:/srv:ro" \
  -v "$ROOT/serve/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$CADDY_IMAGE" >/dev/null

host=$([[ $LOCAL_BIND == 127.0.0.1 ]] && echo localhost || echo "$LOCAL_BIND")
echo "Serving on http://$host:$LOCAL_PORT (stop with: scripts/serve-local.sh stop)"
