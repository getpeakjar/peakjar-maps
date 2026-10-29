"""Splits hiking routes into shared path segments with side-by-side slots.

Usage: trail_segments.py ROUTES_GPKG OUT_GEOJSONL

A route relation is a chain of OSM ways, each drawn in whatever direction its
mapper chose. MapLibre offsets lines to the left or right of their direction,
so offsetting whole routes makes them jump sides wherever a way runs the other
way. Instead, every way becomes one segment with a fixed direction (the same
for every route using it), and the colours of all routes on that segment get
slots around the path's centre: one trail sits on the path (slot 0), two take
-0.5 and 0.5, three take -1, 0 and 1, and so on. The style multiplies the slot
by the spacing for the zoom.

Each segment carries colour, slot, the most important network of its routes
(iwn > nwn > rwn > lwn) and the routes' names and refs. Unmarked routes are
dropped where a marked one uses the same way.
"""
import json
import sys

from osgeo import ogr

ogr.UseExceptions()

COLOURS = ["red", "blue", "green", "yellow", "black", "orange", "purple", "white", "brown", "gray"]
NETWORK_RANK = {"iwn": 0, "nwn": 1, "rwn": 2, "lwn": 3}


def trail_colour(osmc_symbol, colour):
    """The way colour from osmc:symbol (its first field), else the colour tag."""
    raw = osmc_symbol.split(":", 1)[0] if osmc_symbol else colour
    raw = (raw or "").strip().lower()
    if raw == "#000000":
        return "black"
    return raw if raw in COLOURS else None


def oriented(points):
    """The way's points in a fixed direction, whichever way it was drawn."""
    reverse = points[::-1]
    return reverse if reverse < points else points


routes_path, out_path = sys.argv[1:3]
source = ogr.Open(routes_path)
segments = {}

for route in source.GetLayerByName("routes"):
    if route.GetField("route") not in ("hiking", "foot"):
        continue
    geometry = route.GetGeometryRef()
    if geometry is None:
        continue
    colour = trail_colour(route.GetField("osmc_symbol"), route.GetField("colour"))
    network = route.GetField("network")
    name = route.GetField("name")
    ref = route.GetField("ref")
    for i in range(geometry.GetGeometryCount()):
        points = tuple((round(x, 7), round(y, 7)) for x, y, *_ in geometry.GetGeometryRef(i).GetPoints())
        if len(points) < 2:
            continue
        segment = segments.setdefault(oriented(points), {"colours": set(), "networks": set(), "names": [], "refs": []})
        segment["colours"].add(colour)
        segment["networks"].add(network)
        if name and name not in segment["names"]:
            segment["names"].append(name)
        if ref and ref not in segment["refs"]:
            segment["refs"].append(ref)

features = 0
colour_counts = {}
with open(out_path, "w") as out:
    for points, segment in segments.items():
        marked = [c for c in COLOURS if c in segment["colours"]]
        networks = [n for n in segment["networks"] if n in NETWORK_RANK]
        properties = {
            "network": min(networks, key=NETWORK_RANK.get) if networks else None,
            "name": " / ".join(segment["names"]) or None,
            "ref": " / ".join(segment["refs"]) or None,
        }
        geometry = {"type": "LineString", "coordinates": points}
        for slot, colour in enumerate(marked or [None]):
            feature = {
                "type": "Feature",
                "properties": {**properties, "colour": colour, "slot": slot - (len(marked) - 1) / 2 if marked else 0},
                "geometry": geometry,
            }
            out.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")
            features += 1
            colour_counts[colour] = colour_counts.get(colour, 0) + 1

print(f"{len(segments)} path segments, {features} trail lines")
# Many unmarked lines after adding a country mean it tags trail colours
# differently from the osmc:symbol convention
print("Lines per colour:", ", ".join(f"{c or 'unmarked'} {n}" for c, n in sorted(colour_counts.items(), key=lambda i: -i[1])))
