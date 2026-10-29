"""Writes the world layers around the coverage area as GeoJSONSeq files.

Usage: world_layers.py NATURAL_EARTH_SQLITE COVERAGE_GEOJSON OUT_DIR

- mask.geojsonl: the whole Web Mercator world with the coverage area cut out,
  drawn in the sea colour above the detailed layers to hide everything
  outside the coverage area (base map edges, the hillshade margin)
- land.geojsonl: country polygons outside the coverage area, from Natural
  Earth's Polish point of view
- lakes.geojsonl: large lakes outside the coverage area
- labels.geojsonl: country label points outside the coverage area

Each feature carries a "tippecanoe" member with its first zoom.
"""
import json
import math
import sys

from osgeo import ogr

ogr.UseExceptions()

ne_path, coverage_path, out_dir = sys.argv[1:4]

# Keep data sources and features alive: GDAL frees geometries with them
coverage_source = ogr.Open(coverage_path)
coverage_feature = coverage_source.GetLayer(0).GetNextFeature()
coverage = coverage_feature.GetGeometryRef().Clone()
ne = ogr.Open(ne_path)


def write(name, features):
    with open(f"{out_dir}/{name}.geojsonl", "w") as out:
        for feature in features:
            out.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")


def outside(geometry):
    """The part of a geometry outside the coverage area, or None."""
    geometry = geometry.MakeValid()
    if geometry.Intersects(coverage):
        geometry = geometry.Difference(coverage)
    return None if geometry.IsEmpty() else geometry


def feature(geometry, properties, minzoom=0):
    return {
        "type": "Feature",
        "tippecanoe": {"minzoom": minzoom},
        "properties": properties,
        "geometry": json.loads(geometry.ExportToJson()),
    }


# Web Mercator stops at about 85.05 degrees
world = ogr.CreateGeometryFromWkt(
    "POLYGON((-180 -85.0511,180 -85.0511,180 85.0511,-180 85.0511,-180 -85.0511))")
write("mask", [feature(world.Difference(coverage), {})])

land, labels = [], []
for country in ne.GetLayerByName("ne_10m_admin_0_countries_pol"):
    names = {
        "name": country.GetField("name"),
        "name_en": country.GetField("name_en"),
        "name_pl": country.GetField("name_pl"),
    }
    geometry = outside(country.GetGeometryRef())
    if geometry:
        land.append(feature(geometry, names))
    point = ogr.CreateGeometryFromWkt(
        f"POINT({country.GetField('label_x')} {country.GetField('label_y')})")
    if not point.Within(coverage):
        min_label = country.GetField("min_label") or 5
        labels.append(feature(point, {**names, "rank": country.GetField("labelrank")},
                              max(0, math.floor(min_label) - 1)))
write("land", land)
write("labels", labels)

lakes = []
for lake in ne.GetLayerByName("ne_10m_lakes"):
    geometry = outside(lake.GetGeometryRef())
    if geometry:
        lakes.append(feature(geometry, {}, max(0, math.floor(lake.GetField("min_zoom") or 0))))
write("lakes", lakes)

print(f"{len(land)} countries, {len(labels)} labels, {len(lakes)} lakes")
