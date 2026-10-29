# peakjar-maps

Self-hosted outdoor map for PeakJar. Detailed vector tiles cover Poland,
Czechia, Slovakia, Austria, Switzerland, Liechtenstein, Slovenia, Hungary and
Romania: a base map, hiking trails coloured by trail mark, contours and terrain
for hillshade. The rest of the world is drawn as country silhouettes. The
repository also holds the map style and the server setup.

This repository holds the recipe only. Downloaded data (`data/`), scratch
space (`work/`) and built tiles (`build/`) are never committed.

## Quick start

```bash
scripts/build-all.sh         # every step, with progress, timings and per-step logs in logs/
scripts/serve-local.sh       # http://localhost:8790
scripts/deploy.sh deploy@your-vps https://maps.peakjar.com
```

`build-all.sh --from STEP` resumes after a failure (it prints the command),
`build-all.sh --only trails,static` runs just the listed steps,
and `build-all.sh --refresh` reruns only what an OpenStreetMap refresh
changes. The steps can also be run one by one: `download.sh`,
`download-dem.sh`, then `build-basemap.sh`, `build-world.sh`,
`build-trails.sh`, `build-contours.sh`, `build-terrain.sh` and
`build-static.sh`.

A full build takes about 1 h 35 min and produces about 8 GB. See
[docs/BUILDING.md](docs/BUILDING.md) for requirements, what each step does,
how to check the result, and how to add a country, and
[docs/DEPLOYING.md](docs/DEPLOYING.md) for putting it on the server.

## Layout

| Path | Contents |
| --- | --- |
| `scripts/` | Download, build and serve scripts; settings in `scripts/config.sh` |
| `style/` | The PeakJar Outdoor style (a fork of OSM Liberty) and its icon sprites |
| `serve/` | Martin and Caddy configuration for local serving and the VPS (Docker Compose), and the test page |
| `docs/` | The build and deployment guides |

## Attribution

Maps using these tiles must credit © OpenStreetMap contributors (ODbL),
© OpenMapTiles, Natural Earth, and "produced using Copernicus WorldDEM-30 © DLR e.V.
2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under
COPERNICUS by the European Union and ESA; all rights reserved". See
[docs/BUILDING.md](docs/BUILDING.md#attribution) for the full list of credits
and legal notices. The style is derived from OSM Liberty; see
[style/LICENSE-osm-liberty.md](style/LICENSE-osm-liberty.md).
