"""Writes the app's peak catalogue and mountain regions as GeoJSON.

Usage: peaks_regions.py PEAKS_REGIONS_PBF COUNTRY_OUTLINES_GEOJSON DEM_DIR OUT_DIR

peaks.json: every natural=peak/volcano node in the covered countries, with
  id ("node/123"), name (the Polish name when OSM has one, else the local
  name, null when unnamed), name_local (the local name when it differs),
  ele (metres), ele_approx (true when ele comes from the terrain data because
  OSM has none), wikipedia and country (ISO code). The app labels unnamed peaks
  itself, in the user's language.
regions.json: geomorphological units and mountain ranges in Poland and
  Slovakia (boundary=geomorphological-unit, natural=mountain_range), with
  name, name_local, region_type, boundary, natural, wikidata, wikipedia and
  country, outlines simplified to about 30 m.
"""
import json
import math
import os
import re
import sys

from osgeo import gdal, ogr

gdal.UseExceptions()
ogr.UseExceptions()
gdal.SetConfigOption("OGR_INTERLEAVED_READING", "YES")

REGION_COUNTRIES = {"PL", "SK"}
SIMPLIFY_DEGREES = 0.0003
# Summits sit on or right next to a border line, whose mapping is not exact to
# the metre, so a peak this close to a country counts as in it (about 50 m)
BORDER_TOLERANCE_DEGREES = 0.0005

pbf_path, countries_path, dem_dir, out_dir = sys.argv[1:5]

countries_source = ogr.Open(countries_path)
countries = [
    (feature.GetField("name"), feature.GetGeometryRef().Clone())
    for feature in countries_source.GetLayer(0)
]


def country_of(geometry):
    for code, outline in countries:
        if outline.Intersects(geometry):
            return code
    for code, outline in countries:
        if outline.Distance(geometry) <= BORDER_TOLERANCE_DEGREES:
            return code
    return None


def tags_of(feature):
    """All tags of an OSM feature: the GDAL columns plus its other_tags."""
    tags = {}
    definition = feature.GetDefnRef()
    for i in range(definition.GetFieldCount()):
        key = definition.GetFieldDefn(i).GetName()
        if key not in ("osm_id", "osm_way_id", "other_tags") and feature.GetField(i) is not None:
            tags[key] = feature.GetField(i)
    other = feature.GetField("other_tags") if definition.GetFieldIndex("other_tags") >= 0 else None
    for key, value in re.findall(r'"((?:[^"\\]|\\.)*)"=>"((?:[^"\\]|\\.)*)"', other or ""):
        tags[key.replace('\\"', '"')] = value.replace('\\"', '"')
    return tags


def elevation(value):
    """Metres from an OSM ele tag ("1603", "1603.3 m", "1603,3"), else None."""
    match = re.match(r"\s*(-?\d+(?:[.,]\d+)?)", value or "")
    return round(float(match.group(1).replace(",", "."))) if match else None


def names(tags):
    local = tags.get("name")
    name = tags.get("name:pl") or local
    return name, local if local and local != name else None


class TerrainSampler:
    """Heights from the Copernicus tiles in DEM_DIR, one open tile at a time."""

    def __init__(self, directory):
        self.directory = directory
        self.cache = {}

    def height(self, lon, lat):
        key = (math.floor(lat), math.floor(lon))
        if key not in self.cache:
            self.cache.clear()
            name = f"Copernicus_DSM_COG_10_N{key[0]:02d}_00_E{key[1]:03d}_00_DEM.tif"
            path = os.path.join(self.directory, name)
            dataset = gdal.Open(path) if os.path.exists(path) else None
            self.cache[key] = (dataset, dataset.GetGeoTransform() if dataset else None)
        dataset, transform = self.cache[key]
        if dataset is None:
            return None
        col = int((lon - transform[0]) / transform[1])
        row = int((lat - transform[3]) / transform[5])
        col = min(max(col, 0), dataset.RasterXSize - 1)
        row = min(max(row, 0), dataset.RasterYSize - 1)
        value = float(dataset.GetRasterBand(1).ReadAsArray(col, row, 1, 1)[0][0])
        return round(value) if value > -1000 else None


def write(path, features):
    with open(path, "w") as out:
        out.write('{"type":"FeatureCollection","features":[\n')
        out.write(",\n".join(json.dumps(f, ensure_ascii=False, separators=(",", ":")) for f in features))
        out.write("\n]}\n")


peaks, regions = [], []
source = ogr.Open(pbf_path)
while True:
    feature, layer = source.GetNextFeature()
    if feature is None:
        break
    geometry = feature.GetGeometryRef()
    if geometry is None:
        continue
    tags = tags_of(feature)
    layer_name = layer.GetName()

    if layer_name == "points" and tags.get("natural") in ("peak", "volcano"):
        country = country_of(geometry)
        if country is None:
            continue
        name, name_local = names(tags)
        peaks.append({
            "type": "Feature",
            "id": f"node/{feature.GetField('osm_id')}",
            "properties": {
                "name": name, "name_local": name_local, "ele": elevation(tags.get("ele")),
                "wikipedia": tags.get("wikipedia"), "country": country,
            },
            "geometry": {"type": "Point", "coordinates": [round(geometry.GetX(), 7), round(geometry.GetY(), 7)]},
        })

    elif layer_name in ("multipolygons", "lines") and (
        tags.get("boundary") in ("geomorphological-unit", "geomorphological_unit")
        or tags.get("natural") == "mountain_range"
    ):
        country = country_of(geometry.PointOnSurface() if layer_name == "multipolygons" else geometry.Centroid())
        name, name_local = names(tags)
        if country not in REGION_COUNTRIES or not name:
            continue
        osm_id = feature.GetField("osm_id") if layer_name == "lines" else None
        osm_id = f"way/{osm_id}" if osm_id else (
            f"relation/{feature.GetField('osm_id')}" if feature.GetField("osm_id") else f"way/{feature.GetField('osm_way_id')}")
        simplified = geometry.SimplifyPreserveTopology(SIMPLIFY_DEGREES)
        regions.append({
            "type": "Feature",
            "id": osm_id,
            "properties": {
                "name": name, "name_local": name_local, "region_type": tags.get("region_type"),
                "boundary": tags.get("boundary"), "natural": tags.get("natural"),
                "wikidata": tags.get("wikidata"), "wikipedia": tags.get("wikipedia"), "country": country,
            },
            "geometry": json.loads(simplified.ExportToJson(options=["COORDINATE_PRECISION=6"])),
        })

# Peaks without an OSM height get one from the terrain, marked approximate;
# sorted by position so neighbouring peaks share a terrain tile
sampler = TerrainSampler(dem_dir)
missing = sorted((p for p in peaks if p["properties"]["ele"] is None),
                 key=lambda p: (math.floor(p["geometry"]["coordinates"][1]), math.floor(p["geometry"]["coordinates"][0])))
for peak in missing:
    height = sampler.height(*peak["geometry"]["coordinates"])
    if height is not None:
        peak["properties"]["ele"] = height
        peak["properties"]["ele_approx"] = True

for feature in peaks + regions:
    feature["properties"] = {k: v for k, v in feature["properties"].items() if v is not None}
peaks.sort(key=lambda f: f["id"])
regions.sort(key=lambda f: f["id"])

os.makedirs(out_dir, exist_ok=True)
write(os.path.join(out_dir, "peaks.json"), peaks)
write(os.path.join(out_dir, "regions.json"), regions)

by_country = {}
for peak in peaks:
    by_country.setdefault(peak["properties"]["country"], [0, 0])[0] += 1
    if "name" in peak["properties"]:
        by_country[peak["properties"]["country"]][1] += 1
print(f"{len(peaks)} peaks ({sum(1 for p in peaks if 'name' in p['properties'])} named, "
      f"{len(missing)} without OSM height, {sum(1 for p in missing if 'ele' in p['properties'])} filled from terrain)")
print("Peaks per country (named):", ", ".join(f"{c} {n} ({k})" for c, (n, k) in sorted(by_country.items())))
print(f"{len(regions)} regions:", ", ".join(
    f"{c} {sum(1 for r in regions if r['properties']['country'] == c)}" for c in sorted(REGION_COUNTRIES)))
