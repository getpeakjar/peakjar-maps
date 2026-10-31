"""Prints the ids of named rivers and canals that lie almost wholly abroad.

Usage: foreign_rivers.py OUTLINE_GEOJSON WATERWAYS_GEOJSONSEQ > IDS

Cutting the OSM data to the borders keeps a way whole if any of it is inside,
so a foreign river that touches a border would have its name drawn far abroad.
Rivers that run along a border stay: they are within the margin of it.
"""
import json
import sys

from osgeo import ogr

ogr.UseExceptions()

outline_path, waterways_path = sys.argv[1:3]

# How far past the border a river still counts as on it (about 1.5 km), and
# the share of the sampled points that must be within that
MARGIN_DEGREES = 0.015
MINIMUM_SHARE = 0.1
SAMPLES = 12

outline_source = ogr.Open(outline_path)
outline_feature = outline_source.GetLayer(0).GetNextFeature()
home = outline_feature.GetGeometryRef().Simplify(0.001).Buffer(MARGIN_DEGREES)
west, east, south, north = home.GetEnvelope()

kept = removed = 0
with open(waterways_path, newline="\n") as lines:
    for line in lines:
        way = json.loads(line)
        if not way["properties"].get("name"):
            continue
        points = way["geometry"]["coordinates"]
        points = points[::max(1, len(points) // SAMPLES)]
        inside = sum(home.Contains(ogr.CreateGeometryFromWkt(f"POINT({lon} {lat})")) for lon, lat in points)
        if inside / len(points) < MINIMUM_SHARE:
            print(f"w{way['properties']['@id']}")
            removed += 1
        else:
            kept += 1
print(f"{removed} foreign rivers left out, {kept} kept", file=sys.stderr)
