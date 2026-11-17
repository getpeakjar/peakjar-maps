# Changelog

Notable changes to the Peakjar map and the app's peak data. This repository
has no version numbers: changes are listed under the date they were merged
into `main`, newest first. What reaches users is marked by tags:

- `map-YYYYMMDDTHHMMSSZ`: a deploy of the tiles, style and server
  configuration to the VPS, named like its release folder on the server.
  `scripts/deploy.sh` creates it.
- `peaks-regions-osm-YYYY-MM-DD`: a GitHub release of the app's peak and region
  data. The app picks it up when its `client/scripts/download-geo-data.mjs`
  points at it.

The style is served live, so a deployed style change reaches every installed
version of the app at once. Say so when a change needs a minimum app version.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
with the merge date in place of a version number and the links to pull
requests at the end of each date.

## 2026-11-17

### Changed

- **Attribution**: Shortened the credits shown on the map to "© OpenMapTiles © OpenStreetMap contributors | Copernicus WorldDEM-30", with Copernicus as a link instead of its full notice, so they no longer cover much of a phone screen. The full Copernicus notice is in the app under Settings → About (app 0.3.0 or later). Natural Earth, which is public domain, is no longer credited on the map. Only the style changed; the tiles do not need rebuilding. [#3]

### Security

- **Browser Access**: The map answers browsers only on Peakjar sites (`peakjar.com`, `app.peakjar.com`) and local development addresses, so other websites can no longer show it and load the server. The native apps send no `Origin` and are not affected. [#2]

[#2]: https://github.com/getpeakjar/peakjar-maps/pull/2
[#3]: https://github.com/getpeakjar/peakjar-maps/pull/3

## 2026-11-05

### Added

- **Outdoor Map**: Added Peakjar's own outdoor map, used by the app from 0.3.0: vector tiles for Poland, Czechia, Slovakia, Austria, Switzerland, Liechtenstein, Slovenia, Hungary and Romania with a base map, hiking trails coloured by their trail marks, contours and terrain for hill shading, and the rest of the world as country silhouettes, drawn with the Peakjar Outdoor style (a fork of OSM Liberty). Built from the OpenStreetMap snapshot of 2026-10-28. [#1]
- **Peaks and Regions**: Published `peaks-regions-osm-2026-10-28`, built from the same snapshot as the map: 98,856 peaks in the nine covered countries (78,760 named), with heights missing in OpenStreetMap filled from terrain data, and 666 mountain ranges and units in Poland and Slovakia. [#1]

[#1]: https://github.com/getpeakjar/peakjar-maps/pull/1
