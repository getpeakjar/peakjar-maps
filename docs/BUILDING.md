# Building Peakjar tiles

This guide takes you from an empty checkout to a working outdoor map served on
your own machine, and explains how to add more countries. Every step is a
script in `scripts/`; this document explains what each one does, how long it
takes and what to check.

Measured numbers below come from the build covering Poland, Czechia, Slovakia,
Austria, Switzerland, Liechtenstein, Slovenia, Hungary and Romania (OSM snapshot
2026-10-28), on a 16-core machine with 14 GB RAM.

## What gets built

```
Geofabrik OSM extracts ──► coverage.osm.pbf ──► osmium + GDAL + Tippecanoe ──► trails.pmtiles
                       │                    └─► cut to the national borders ──► Planetiler ──► basemap.pmtiles
                       ├─► boundary relations ──► national borders (cut the map)
                       └─► .poly boundaries ──► coverage outline (clips contours and terrain)

National borders + OSM water + Natural Earth ──► GDAL + Tippecanoe ──► world.pmtiles

Copernicus GLO-30 ──► GDAL ──► contours.pmtiles
                           └─► terrain.mbtiles

style/ + fonts + sprites ──► build/static/ (style.json with absolute URLs, test page)

build/ ──► Martin (tiles) + Caddy (static files)  ──►  MapLibre in the app or browser
```

| Output | Size | Build time | Zooms | Contents |
| --- | --- | --- | --- | --- |
| `build/world.pmtiles` | 46 MB | 16 min | 0–11 | Mask, sea, lakes and neighbours' borders outside the covered countries, their own land borders, and country labels |
| `data/outline.geojson`, `data/country_outlines.geojson`, `data/borders.geojsonl`, `data/border_water.geojsonl`, `data/outline.osm.pbf` | 5.4 GB | 15 min | — | The real national borders, the water crossing them, and the OSM data cut to them |
| `build/basemap.pmtiles` | 4.2 GB | 20 min | 0–14 | OpenMapTiles schema: roads, paths, water, land use, places, POIs |
| `build/contours.pmtiles` | 2.5 GB | 40 min | 10–14 | Contours every 10 m, layer `contours` |
| `build/terrain.mbtiles` | 1.1 GB | 31 min | 5–11 | 512 px Terrarium PNG for hillshade and 3D terrain |
| `build/trails.pmtiles` | 172 MB | 3 min | 8–14 | Hiking routes with trail colour, layer `trails` |
| `build/data/` | 21 MB | 5 min | — | The app's peak catalogue (`peaks.json`, 17 MB) and mountain regions (`regions.json`, 4 MB) |
| `build/static/` | 4.4 MB | seconds | — | Style, fonts, icon sprites, test page |

About 8 GB in all, and about 2 h 10 min for a full build including downloads.

Vector tiles stop at zoom 14 (the world layer at 11); MapLibre scales them up
for closer zooms.

## Running everything at once

```bash
scripts/build-all.sh
```

Runs steps 2–5 in order and shows the running step, its elapsed time and its
latest output line. Each step's full output goes to `logs/<run>/`. On a
failure it stops, prints the step's last lines and the command that resumes
from that step, for example `scripts/build-all.sh --from contours`.
`--refresh` runs only the steps an OpenStreetMap refresh changes (download,
borders, base map, world, trails, peaks, static files), and a URL argument is passed on to
`build-static.sh`. The sections below explain each step.

## 1. Prepare the machine

Building needs about 50 GB of free disk and 6–8 GB of free RAM. The VPS only
serves the result and never builds.

Tools inside the Debian distrobox (all from Debian's signed repository):

```bash
sudo apt install osmium-tool gdal-bin tippecanoe wget unzip python3
```

Planetiler, Martin and Caddy run as containers through Podman on the host. The
scripts call `distrobox-host-exec podman` automatically when Podman is not
inside the box. Their images are pinned by digest in `scripts/config.sh`.

**Why the split:** Debian packages are trusted through apt's signatures.
Planetiler is a downloaded program, so it runs in a locked-down container that
sees only `data/`, `work/` and `build/`, with no capabilities, a read-only root
filesystem and no network while building. Distrobox alone is not isolation: it
shares your whole home folder.

## 2. Download OpenStreetMap data

```bash
scripts/download.sh
```

- Downloads each country in `COUNTRIES` from Geofabrik with its checksum and
  boundary (`.poly`) file, and checks every checksum.
- Builds the **coverage outline** from the boundary files:
  `data/coverage.poly` (for Planetiler) and `data/coverage.geojson` (for GDAL).
  These shapes run loosely around each country, several kilometres past its
  border in places, so they only limit how much gets built. The map itself is
  cut along the real borders ([step 4](#4-build-the-tile-sets)).
- Merges the extracts into `data/coverage.osm.pbf` (5.5 GB).
- Writes the OSM snapshot time to `data/snapshot.txt`. The peaks step copies
  it next to the app's data, so peaks and map can be matched to one snapshot.

Takes a few minutes, depending on your connection. Rerunning only downloads
files Geofabrik has updated since (it publishes new extracts daily).

## 3. Download elevation data

```bash
scripts/download-dem.sh
```

Downloads the Copernicus GLO-30 elevation tiles (1°×1°, about 30–40 MB each)
that touch the coverage outline plus a 0.15° margin, from AWS open data, into
`data/dem/`. Only tiles touching the outline are fetched, not its whole
bounding box, which matters for spread-out coverage (Switzerland to Romania).
175 tiles, 6.4 GB, a few minutes. Tiles that are all sea do not exist
and are reported as skipped; that is expected. Existing tiles are never
downloaded again; after removing a country, delete the tiles it no longer
needs by hand (the contour build processes every tile in `data/dem/`).

## 4. Build the tile sets

Each script can be run on its own once its inputs exist.

```bash
scripts/build-borders.sh    # ~15 min
scripts/build-basemap.sh    # ~20 min
scripts/build-world.sh      # ~16 min
scripts/build-trails.sh     # ~3 min
scripts/build-peaks.sh      # ~5 min
scripts/build-contours.sh   # ~40 min
scripts/build-terrain.sh    # ~30 min
```

Planetiler empties `work/` when it starts, so write build logs somewhere else.

**Borders** (`build-borders.sh`). Reads each country's `admin_level=2` boundary
relation from its extract, found through its ISO code in `COUNTRY_CODES`
(`scripts/config.sh`), and writes:

- `data/outline.geojson`: the union of the countries, territorial waters and
  enclave holes included. The map is cut along it.
- `data/country_outlines.geojson`: each country on its own, which decides the
  country of each peak and region.
- `data/borders.geojsonl`: the land borders as lines. Ways tagged `maritime=yes`,
  `boundary_type=maritime` or `natural=coastline` are left out, except across
  the Szczecin and Vistula lagoons, which maps draw like land borders.
- `data/border_water.geojsonl`: the lakes and rivers that cross the outline.
- `data/outline.osm.pbf`: the merged OSM file cut to the outline, which the base
  map reads, so that foreign towns and road numbers have no labels on the map. Named rivers
  almost wholly abroad are left out too (`scripts/foreign_rivers.py`); rivers
  along a border keep their names.

**Base map** (`build-basemap.sh`). Planetiler with the OpenMapTiles profile.
First a short step with network downloads water, coastline and border helper
data into `data/sources/` (1.4 GB, kept for later builds), then the build runs
with networking off. `JAVA_HEAP` (default `6g`) must be at least half the
merged input; `CONTAINER_MEMORY` (default `8g`) caps the container.

**World** (`build-world.sh`). Needs the Natural Earth and OSM water files that
the base map step downloads. Cuts everything along `data/outline.geojson` with
GDAL (`scripts/world_layers.py`) and tiles it with Tippecanoe into six layers:

- `mask`: the whole world minus the covered countries. The style fills it with
  the land colour above all detailed layers, which hides everything outside
  them: the base map's edge, the terrain margin, the trails that run on abroad.
- `sea`: the sea outside the covered countries, on top of the mask. It comes
  from OSM's water polygons within 2° of the countries, so that the Baltic and
  Adriatic coasts are as sharp as inside them, and from Natural Earth further away.
- `lakes`: the far side of the lakes and rivers that cross the borders, from OSM
  (Lake Geneva, Lake Constance, the Danube), with rivers stopping about 1.5 km
  past the border, and Natural Earth's large lakes elsewhere. Natural Earth lakes
  that OSM already draws are left out: it counts the Vistula Lagoon as a lake,
  and its rough shape would cover the spit.
- `neighbour_borders`: borders between countries that are not covered, from
  Natural Earth's Polish point of view for disputed ones. A border that stops
  just short of the outline is extended to it.
- `borders`: the covered countries' own land borders, from `data/borders.geojsonl`.
  The style draws them above the mask, so they are never half hidden, and in
  place of the base map's `boundary` layer, which also holds sea borders and
  the ends of the neighbours' borders.
- `labels`: country names outside the covered countries. Countries inside them
  are labelled by the base map.

Tiling takes most of the time: the world at z11 is about 5.6 million tiles,
nearly all of them identical. z11 keeps the mask within about 3 m of the border
line, which the line's width covers at every zoom.

**Trails** (`build-trails.sh`). Planetiler cannot turn route relations into
lines, so this uses osmium to extract `route=hiking`/`foot` relations, GDAL to
read their ways, `scripts/trail_segments.py` to split them into path segments,
and Tippecanoe to tile them.

Each OSM way used by a route becomes one line per trail colour on it. A
route's colour is the trail-mark colour from the first field of
`osmc:symbol` (`red:white:red_bar` → `red`), normalised to `red`, `blue`,
`green`, `yellow`, `black`, `orange`, `purple`, `white`, `brown`, `gray`, or
null when unmarked. Each line carries `colour`, `slot`, `network` (the most
important of `iwn`, `nwn`, `rwn`, `lwn` among its routes) and the routes'
`name` and `ref` joined with " / ".

`slot` places trails sharing a path side by side: one trail gets 0 (on the
path), two get −0.5 and 0.5, three get −1, 0 and 1. Every way is given the same
direction for all its routes, because MapLibre offsets lines relative to their
direction; offsetting whole routes made them jump sides wherever a way was
drawn the other way. An unmarked route is dropped where a marked one uses the
same way. The step prints how many lines each colour got.

**Peaks and regions** (`build-peaks.sh`). The app's own data, from the same
OSM file as the tiles so peaks and map agree. `scripts/peaks_regions.py`
writes `build/data/`:

- `peaks.json`: every `natural=peak`/`volcano` node in the covered countries,
  or within about 50 m of their borders (about 99,000), with
  `id` (`node/123`), `name` (the Polish name when OSM has one, else the local
  name; missing for unnamed peaks, which the app labels by elevation),
  `name_local`, `ele`, `ele_approx`, `wikipedia` and `country` (ISO code).
  Peaks without an OSM height get one sampled from the Copernicus tiles,
  marked `ele_approx` (it can be up to about 20 m high in forest).
- `regions.json`: geomorphological units and mountain ranges in Poland and
  Slovakia (`boundary=geomorphological-unit`, `natural=mountain_range`), with
  `name`, `name_local`, `region_type`, `boundary`, `natural`, `wikidata`,
  `wikipedia` and `country`, outlines simplified to about 30 m. Other
  countries have too few of these in OSM to be useful.
- `snapshot.txt`: the OSM snapshot both come from.

GDAL's default OSM configuration drops the `ele` tag, so the script reads
the data with a copy that keeps it. The step prints peak counts per country.
The app downloads these files from a GitHub release of this repository; see
[step 9](#9-publish-the-app-data).

**Contours** (`build-contours.sh`). `gdal_contour` traces 10 m contours per
elevation tile in parallel. Each line gets `ele` and `level` (100, 50 or 10).
Tiles show 100 m lines from z10, 50 m lines from z11 and all lines from z13.
Lines shorter than 200 m are dropped: Copernicus measures the top surface, so
forests and buildings leave small rings that are noise, not terrain. Temporary
files peak at about 18 GB in `work/` (plus as much again while tiling) and are deleted at the end.

**Terrain** (`build-terrain.sh`). Elevation reprojected to Web Mercator and
encoded as Terrarium RGB (height = R × 256 + G + B / 256 − 32768), in whole
metres. Tiles are lossless PNG and lower zooms use nearest-neighbour
overviews, because anything lossy or averaged corrupts the encoded heights.
Clipped to the outline plus about 10 km; beyond that the data is 0 m, under
the world mask. A last step (`scripts/terrain_fill.py`) rewrites tiles at the
data's edge: GDAL leaves the area outside the data transparent, and MapLibre
ignores alpha in terrain tiles, so those pixels would decode as −32,768 m and
draw a black frame of hillshade (and deep pits in 3D). They are set to 0 m.

Copernicus is 30 m data and rounds off sharp summits: Rysy decodes to 2,459 m
against its real 2,499 m, Śnieżka to 1,601 m against 1,603 m. The app keeps
showing OSM summit heights; only shading and contours are affected.

## 5. Assemble the style and static files

```bash
scripts/build-static.sh                      # for local testing
scripts/build-static.sh https://tiles.example.com   # for a server
```

Writes `build/static/`:

- `style/outdoor.json`: `style/outdoor.json` from the repo with every
  `{BASE_URL}` replaced by the given URL. MapLibre Native needs absolute URLs,
  so the style must be rebuilt for each place it is served from.
- `fonts/`: the three Roboto font stacks the style uses, unpacked from the
  OpenMapTiles font release (checksum-verified).
- `sprites/`: OSM Liberty's icon sprites, copied from `style/sprites/`.
- `index.html`: the test page.

**The style** is a fork of [OSM Liberty](https://github.com/maputnik/osm-liberty)
at commit `40a0d19` (BSD licence, Maki icons CC0, Roboto Apache 2.0) with:

- MapTiler and Natural Earth sources removed;
- `hillshade` above land cover and below water;
- `contour_minor` and `contour_major` lines, and `contour_label_100` /
  `contour_label_50` height labels;
- `trail_casing`, `trail_unmarked` (dashed) and `trail`, coloured by trail
  mark and offset by the segment's `slot`, so routes sharing a path sit side
  by side and a single trail sits on its path. Local routes appear from z11; regional, national and international
  ones from z8;
- `world_mask`, `world_sea`, `world_lakes`, `world_neighbour_border`,
  `world_border` and `world_country_label` from the world tile set, above the
  detailed layers and below the labels. Height labels, road names and road
  shields stay below the mask, because contours and roads run past the border;
- the base map's `boundary_3` without maritime lines, and its national border
  layers replaced by `world_border`;
- point-of-interest icons that fall back to `circle_11` when the sprite has no
  icon for a class (the OpenMapTiles schema has classes such as `office` and
  `atm` that OSM Liberty never drew). The `poi_*` layers list the sprite's
  icon names; regenerate that list if the sprite changes.

OSM Liberty draws no peak labels, so the app's own peak markers have no
duplicates on the map.

Edit `style/outdoor.json` directly. Check it against the MapLibre style
specification after changes; the web client ships the validator:

```bash
node -e "
const spec = require('<peakjar>/client/node_modules/.pnpm/@maplibre+maplibre-gl-style-spec@24.8.1/node_modules/@maplibre/maplibre-gl-style-spec');
const errors = spec.validateStyleMin(require('./build/static/style/outdoor.json'));
console.log(errors.length ? errors.map(e => e.message).join('\n') : 'style valid');"
```

## 6. Serve and check locally

```bash
scripts/serve-local.sh        # start
scripts/serve-local.sh stop   # stop
```

Starts a Podman pod on `http://localhost:8790` (`LOCAL_PORT`) with the same
layout as the VPS:

| Path | Served by | Contents |
| --- | --- | --- |
| `/` | Caddy | Test page, opens on the Tatras |
| `/style/outdoor.json` | Caddy | The style |
| `/fonts/…`, `/sprites/…` | Caddy | Fonts and icons |
| `/tiles/catalog` | Martin | List of tile sources |
| `/tiles/<source>` | Martin | TileJSON for `basemap`, `trails`, `contours`, `terrain` |
| `/tiles/<source>/{z}/{x}/{y}` | Martin | Tiles |

Both containers can only read `build/` and `serve/`, drop all capabilities
(Caddy keeps the one its binary requires) and have read-only root
filesystems.

**What to check on the test page:**

- Tatras around Rysy at z13–15: red trail to the summit from Czarny Staw and
  the Slovak red trail; contour labels on 100 m lines; hillshade visible.
- A path shared by several trails: colours side by side, not on top of each
  other. A trail alone on a path sits on it, without gaps or side jumps.
- Lowland (for example Warsaw at z13): few, clean contours.
- The 3D button (terrain control) raises the mountains.
- The border of the coverage area: the detailed map ends exactly on the border
  line and gives way to the plain land colour, with no straight clip edges,
  hillshade, roads or foreign town labels beyond it.
- The Baltic and the Black Sea: no lines at sea, and coasts outside the coverage
  area as sharp as the ones inside it (Rügen, Bornholm, the Vistula Spit).
- Tripoints such as Poland, Lithuania and Belarus: the neighbours' faint border
  meets the dark one, with no loose ends.
- Zoomed out to the globe: the whole world is drawn, with the covered
  countries in the lighter land colour.

## 7. Test in the Peakjar app

Phones and emulators cannot reach `localhost` on the build machine, and the
style holds absolute URLs, so serve and build the style on the machine's LAN
IP (find it with `ip -4 addr`):

```bash
scripts/build-static.sh http://192.168.1.13:8790
LOCAL_BIND=192.168.1.13 scripts/serve-local.sh
```

This makes the map reachable by any device on the same network. It serves
read-only tiles only; stop it with `scripts/serve-local.sh stop` when done.

In the client's `.env`, set the style URL and restart Expo with a cleared
cache, because `EXPO_PUBLIC_` variables are fixed when the bundle is built:

```bash
EXPO_PUBLIC_MAP_STYLE_URL=http://192.168.1.13:8790/style/outdoor.json
```

The same URL works for web, the Android emulator and a phone on the same
Wi-Fi.

## 8. Deploy

Put the build on the VPS with `scripts/deploy.sh`; see
[DEPLOYING.md](DEPLOYING.md).

## 9. Publish the app data

The app does not use `build/data/` directly: `pnpm data:sync` in the client
downloads `peaks.json` and `regions.json` from a GitHub release of this
repository. Publish a release whenever those files change.

Releases are named `peaks-regions-osm-YYYY-MM-DD`, where the date is the OSM
snapshot in `build/data/snapshot.txt`. Publish from `main` once the changes
behind the data are merged, so the tag points at a commit on `main`.

1. Write the release notes to a file, here `work/release-notes.md`, with the
   counts the peaks step printed. The licence and credit text must stay:

   ```markdown
   Peak catalogue and mountain regions for the Peakjar app, built from the OpenStreetMap snapshot of YYYY-MM-DD (the same snapshot as the map tiles).

   - `peaks.json`: N peaks in <countries> (N named), with OSM id, name, elevation and country.
   - `regions.json`: N geomorphological units and mountain ranges in Poland (N) and Slovakia (N).
   - `snapshot.txt`: the OpenStreetMap snapshot time.

   Built with `scripts/build-peaks.sh`; see `docs/BUILDING.md`.

   ## Licence and credits

   Data © OpenStreetMap contributors, available under the Open Database License (ODbL): https://www.openstreetmap.org/copyright

   Approximate peak heights (`ele_approx`) were produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved. The organisations in charge of the Copernicus programme by law or by delegation do not incur any liability for any use of the Copernicus WorldDEM-30.
   ```

2. Create the release:

   ```bash
   snapshot=$(cut -c1-10 build/data/snapshot.txt)
   gh release create "peaks-regions-osm-$snapshot" \
     build/data/peaks.json build/data/regions.json build/data/snapshot.txt \
     --target main \
     --title "Peaks and regions, OSM snapshot $snapshot" \
     --notes-file work/release-notes.md
   ```

3. In the app repository, set `VERSION` in
   `client/scripts/download-geo-data.mjs` to the new release name and run
   `pnpm data:sync` in `client/`. It downloads the files and rebuilds the
   bundled peaks database.

Leave published releases in place, because older checkouts of the app still
download from them.

## Adding a country

Coverage is set in one file. To add, for example, Austria:

1. In `scripts/config.sh`, add its Geofabrik path (the URL path under
   `https://download.geofabrik.de/` without `-latest.osm.pbf`):

   ```bash
   COUNTRIES=(europe/poland europe/czech-republic europe/slovakia europe/austria)
   ```

   and its ISO code to `COUNTRY_CODES` in the same file (`[austria]=AT`), which
   finds its boundary relation.

2. Check resources. Planetiler needs RAM of at least half the merged input:
   raise `JAVA_HEAP` and `CONTAINER_MEMORY` if the merged file grows past
   about 12 GB. Disk needs roughly 10× the merged input while building.

3. Rerun every step in order:

   ```bash
   scripts/download.sh
   scripts/download-dem.sh
   scripts/build-basemap.sh
   scripts/build-world.sh
   scripts/build-trails.sh
   scripts/build-peaks.sh
   scripts/build-contours.sh
   scripts/build-terrain.sh
   scripts/build-static.sh
   ```

   Nothing is incremental: each output covers the whole area, so all of it is
   rebuilt. Existing elevation tiles are not downloaded again, and existing
   extracts only if Geofabrik has a newer version. Build time grows with area;
   expect a few extra minutes per country the size of Czechia.

4. Check the new country as in step 6, plus:

   - **Trail colours.** The `colour` field assumes the Central European
     convention where `osmc:symbol` starts with the mark colour. Check the
     "Lines per colour" line the trails step prints (in its log under
     `logs/`) and look at the map; a country that tags routes differently
     shows up as many dashed (unmarked) trails.
   - **Elevation coverage.** `download-dem.sh` handles the northern and
     eastern hemispheres only, which covers all of Europe east of Greenwich.
     A country west of Greenwich (for example Spain or the UK) needs the
     tile naming extended to `W` longitudes.

5. Check the peak counts the peaks step prints, and add the country's ISO code
   to `COUNTRY_CODES` in `scripts/peaks_regions.py` (peaks in a country it
   does not know are dropped). Regions are only built for Poland and
   Slovakia (`REGION_COUNTRIES`).

Removing a country works the same way: delete it from the list and rebuild.

## Refreshing the data

To pick up new OpenStreetMap edits, run `scripts/build-all.sh --refresh`, or
rerun the steps from `download.sh` on. The
elevation data does not change, so `download-dem.sh` does nothing on a refresh
and the contour and terrain builds give the same result; they only need
rerunning when coverage changes. New peaks and regions reach the app through
a new release ([step 9](#9-publish-the-app-data)).

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Unable to delete /work` (ERR) during the base map build | Harmless: Planetiler tries to delete its scratch folder, which is a mount. |
| `Failed downloading pre-computed tile weights` | Harmless: only affects Planetiler's size report. |
| `Unable to form closed polygon for OSM relation …` | Neighbouring countries' borders are cut by the outline; they lie outside the coverage area. |
| GDAL: `Too many features have accumulated in points layer` | Route relations must be copied to a GeoPackage before reading them; `build-trails.sh` already does this. |
| Port 8790 already in use | Set `LOCAL_PORT`, then rerun `build-static.sh` and `serve-local.sh`. (On a Steam Deck, 8080 is taken by Steam's browser debugger.) |
| Caddy exits with `Operation not permitted` | The Caddy binary needs `NET_BIND_SERVICE`; `serve-local.sh` already grants only that. |
| Tiles blocked by CORS in the browser | Martin and Caddy both adding `Access-Control-Allow-Origin` doubles the header; the Caddyfile only adds it where missing. |

## Attribution

All sources allow commercial use. Their conditions are credits and notices.

**On the map** (MapLibre's attribution control shows these automatically: the
vector tile sets carry their credits in their TileJSON, and the style adds the
Copernicus credit to the terrain source):

- [© OpenMapTiles](https://openmaptiles.org/) and
  [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
  as links
- [Natural Earth](https://www.naturalearthdata.com/) (public domain; the
  credit is a courtesy and comes from the world tile set's TileJSON)
- produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus
  Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European
  Union and ESA; all rights reserved

The contour tiles store their credit inside the tile set, so a change to it
needs `build-contours.sh` to run again.

**In the app's licences screen** (Settings → About in the Peakjar app):

- Map and peak data from OpenStreetMap, available under the
  [Open Database Licence](https://opendatacommons.org/licenses/odbl/). The
  peak catalogue counts too: approximate peak heights come from Copernicus, so
  its credit belongs with the peak data as well. The
  ODbL requires offering the map data, or how it was made, to anyone who gets
  it from the app (offline packs count). Keep this repository public, or state
  that the data is available on request. Do not encrypt offline packs without
  also offering an unencrypted copy.
- The Copernicus liability sentence, required by the licence: "The
  organisations in charge of the Copernicus programme by law or by delegation
  do not incur any liability for any use of the Copernicus WorldDEM-30". Do
  not suggest that Copernicus, ESA or Airbus endorse the app.
- Map style derived from OSM Liberty (BSD 3-Clause, copyright notice in
  `style/LICENSE-osm-liberty.md`), whose design derives from OSM Bright by
  Mapbox (CC BY 3.0) and uses the OpenMapTiles design (CC BY 4.0).
- Roboto font (Apache License 2.0, copyright Google). Maki icons are CC0 and
  need no notice.

Planetiler, Martin, Caddy, GDAL and Tippecanoe only run on the build machine
and the server; they are not distributed with the app and add no notices.
