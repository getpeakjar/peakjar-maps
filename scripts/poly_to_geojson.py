"""Converts Osmosis .poly files to one GeoJSON FeatureCollection.

Usage: poly_to_geojson.py OUT.geojson IN.poly [IN.poly ...]

Each .poly file becomes one MultiPolygon feature named after the file.
Sections starting with "!" are holes in the polygon before them.
"""
import json
import sys
from pathlib import Path


def read_poly(path):
    lines = [line.strip() for line in Path(path).read_text().splitlines()]
    polygons = []
    i = 1  # first line is the file's name
    while i < len(lines) and lines[i] != "END":
        hole = lines[i].startswith("!")
        i += 1
        ring = []
        while lines[i] != "END":
            lon, lat = map(float, lines[i].split())
            ring.append([lon, lat])
            i += 1
        i += 1
        if ring[0] != ring[-1]:
            ring.append(ring[0])
        if hole:
            polygons[-1].append(ring)
        else:
            polygons.append([ring])
    return polygons


def main():
    out, *inputs = sys.argv[1:]
    features = [
        {
            "type": "Feature",
            "properties": {"name": Path(path).stem},
            "geometry": {"type": "MultiPolygon", "coordinates": read_poly(path)},
        }
        for path in inputs
    ]
    Path(out).write_text(json.dumps({"type": "FeatureCollection", "features": features}))


if __name__ == "__main__":
    main()
