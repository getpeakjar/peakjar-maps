# Deploying Peakjar maps

This guide puts a finished build (see [BUILDING.md](BUILDING.md)) on the VPS
and keeps it running. The VPS only serves: Martin for tiles and Caddy for the
style, fonts and sprites, both in locked-down containers under Docker Compose.
Tiles are never built on the server.

## What the server needs

- Debian with Docker Engine and the Compose plugin.
- Disk for two releases, because a new release is uploaded next to the
  current one before switching. Unchanged files are hard-linked, so only the
  first upload costs the full size (see the sizes in BUILDING.md).
- RAM: Martin is capped at 768 MB (its tile cache is 256 MB) and Caddy at
  256 MB.
- A DNS record for the maps domain (for example `maps.peakjar.com`) pointing
  at the VPS.
- SSH access for a user in the `docker` group.

Two ways to put the service on the internet:

- **A. Behind your existing reverse proxy** (the default). The VPS already
  serves the app and the API over HTTPS, so its proxy owns ports 80 and 443.
  Caddy listens only on `127.0.0.1:8790`; no firewall change is needed.
- **B. Caddy faces the internet** and gets its certificate itself. Use this only
  when nothing else listens on ports 80 and 443.

## One-time setup

On the VPS:

```bash
sudo mkdir -p /srv/peakjar-maps/serve
sudo chown -R "$USER": /srv/peakjar-maps
```

For option B only, create `/srv/peakjar-maps/serve/.env` (Compose reads it;
deploys never overwrite it):

```bash
COMPOSE_FILE=compose.yaml:compose.tls.yaml
SITE_ADDRESS=maps.peakjar.com
```

### Option A: proxy configuration

Point the maps domain at `http://127.0.0.1:8790` and rate-limit by client IP.
Map views fetch many tiles at once (five tile sets per screen), and offline
packs download thousands, so allow large bursts.

nginx:

```nginx
# In the http block
limit_req_zone $binary_remote_addr zone=maps:10m rate=50r/s;

server {
    server_name maps.peakjar.com;
    # listen 443 ssl; certificates as for the other sites

    location / {
        limit_req zone=maps burst=500 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8790;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy on the host (rate limiting needs the `caddy-ratelimit` plugin; without
it, rate-limit at a CDN instead):

```caddyfile
maps.peakjar.com {
    reverse_proxy 127.0.0.1:8790
}
```

### A CDN in front (recommended)

Tiles, fonts and sprites are sent with `Cache-Control` headers (one day for
tiles, a week for fonts, five minutes for the style). Putting a CDN such as
Cloudflare in front of the maps domain lets it serve most requests from its
cache, which cuts the VPS's traffic and keeps maps loading during short
outages. Add a cache rule for `/tiles/*`, `/fonts/*` and `/sprites/*`, and a
rate-limiting rule there if the proxy cannot do it (option B).

## Deploying a release

From the build machine, on an up-to-date `main`, after building every tile set:

```bash
scripts/deploy.sh deploy@your-vps https://maps.peakjar.com
```

The script:

1. builds the style for the public URL (and restores the local one at the end);
2. uploads the tiles and static files to `/srv/peakjar-maps/releases/<time>/`,
   hard-linking files that have not changed since the current release;
3. uploads the Compose, Martin and Caddy configuration to `serve/`;
4. switches the `current` symlink and recreates the containers;
5. keeps the two newest releases and deletes older ones;
6. checks that the style and the tile catalogue answer on the public URL.

Set `REMOTE_ROOT` to use a folder other than `/srv/peakjar-maps`.

The first upload is the whole build. Later uploads after an OpenStreetMap
refresh send the base map, world layer and trails again; contours and terrain only change
when coverage does.

## Rolling back

```bash
cd /srv/peakjar-maps
ls releases/                       # the previous release is still there
ln -sfn releases/<previous> current.new && mv -T current.new current
cd serve && docker compose up -d --force-recreate
```

## Keeping it running

- Both containers restart automatically (`restart: unless-stopped`),
  including after a reboot.
- Add an external uptime check on `https://maps.peakjar.com/tiles/catalog` and
  `https://maps.peakjar.com/style/outdoor.json`.
- Logs: `docker compose logs -f` in `/srv/peakjar-maps/serve`. Set log
  rotation for Docker (`/etc/docker/daemon.json`, `"log-opts": {"max-size":
  "10m", "max-file": "3"}`) if it is not set already.
- Updating Martin or Caddy: change the digest in `serve/compose.yaml` (and in
  `scripts/config.sh` for local serving), test locally, then deploy.

## If the server is down

Offline packs on phones keep working without the server. For online use, the
app's planned fallback is a copy of the same tiles as PMTiles files on static
object storage, read with HTTP range requests and needing no tile server.
The Peakjar app repository's ADR-039 describes that plan.
