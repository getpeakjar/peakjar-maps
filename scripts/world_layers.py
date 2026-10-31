"""Writes the world layers around the covered countries as GeoJSONSeq files.

Usage: world_layers.py NATURAL_EARTH_SQLITE WATER_POLYGONS OUTLINE_GEOJSON BORDER_WATER OUT_DIR

- mask.geojsonl: the whole Web Mercator world with the covered countries cut
  out, drawn in the land colour above the detailed layers to hide everything
  outside them. Being one shape, it leaves no gaps along the land borders.
- sea.geojsonl: the sea outside the covered countries, drawn on the mask. OSM's
  detailed water polygons near them, so that coasts stay as sharp as inside
  them, and Natural Earth's further away.
- lakes.geojsonl: outside the covered countries, the far side of the lakes and
  rivers that cross their borders, from OSM, and Natural Earth's large lakes.
  Rivers stop near the border, which is all it takes to draw their far bank.
  Natural Earth's lakes that OSM draws better are left out; it counts some
  lagoons as lakes, and their rough shapes would cover the OSM coast.
- neighbour_borders.geojsonl: land borders between countries that are not
  covered, from Natural Earth's Polish point of view. Each one that stops short
  of the outline is extended to it.
- labels.geojsonl: country label points outside the covered countries

Each feature carries a "tippecanoe" member with its first zoom.
"""
import json
import math
import sys

import numpy
from osgeo import ogr, osr

ogr.UseExceptions()

ne_path, water_path, outline_path, border_water_path, out_dir = sys.argv[1:6]

# How far around the covered countries the sea comes from OSM, in degrees
DETAILED_SEA_MARGIN = 2
# How far a border that stops short of the outline may be extended, in degrees
BORDER_SNAP_DISTANCE = 0.15
# How far past the border a river is drawn, in degrees
RIVER_MARGIN = 0.015

# Keep data sources and features alive: GDAL frees geometries with them
outline_source = ogr.Open(outline_path)
outline_feature = outline_source.GetLayer(0).GetNextFeature()
outline = outline_feature.GetGeometryRef().Clone()
ne = ogr.Open(ne_path)


def write(name, features):
    with open(f"{out_dir}/{name}.geojsonl", "w") as out:
        for feature in features:
            out.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")


def outside(geometry):
    """The part of a geometry outside the covered countries, or None."""
    geometry = geometry.MakeValid()
    if geometry.Intersects(outline):
        geometry = geometry.Difference(outline)
    return None if geometry.IsEmpty() else geometry


def feature(geometry, properties, minzoom=0):
    return {
        "type": "Feature",
        "tippecanoe": {"minzoom": minzoom},
        "properties": properties,
        "geometry": json.loads(geometry.ExportToJson()),
    }


def box(west, south, east, north):
    return ogr.CreateGeometryFromWkt(
        f"POLYGON(({west} {south},{east} {south},{east} {north},{west} {north},{west} {south}))")


# Web Mercator stops at about 85.05 degrees
write("mask", [feature(box(-180, -85.0511, 180, 85.0511).Difference(outline), {})])

west, east, south, north = outline.GetEnvelope()
detailed = box(west - DETAILED_SEA_MARGIN, south - DETAILED_SEA_MARGIN,
               east + DETAILED_SEA_MARGIN, north + DETAILED_SEA_MARGIN)

sea = []
for ocean in ne.GetLayerByName("ne_10m_ocean"):
    geometry = ocean.GetGeometryRef().MakeValid().Difference(detailed)
    if not geometry.IsEmpty():
        sea.append(feature(geometry, {}))

mercator = osr.SpatialReference()
mercator.ImportFromEPSG(3857)
wgs84 = osr.SpatialReference()
wgs84.ImportFromEPSG(4326)
wgs84.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
to_wgs84 = osr.CoordinateTransformation(mercator, wgs84)
to_mercator = osr.CoordinateTransformation(wgs84, mercator)
water_source = ogr.Open(water_path)
water_layer = water_source.GetLayer(0)
detailed_mercator = detailed.Clone()
detailed_mercator.Transform(to_mercator)
water_layer.SetSpatialFilter(detailed_mercator)
osm_water = []
for water in water_layer:
    geometry = water.GetGeometryRef().Clone()
    geometry.Transform(to_wgs84)
    geometry = geometry.MakeValid().Intersection(detailed)
    if not geometry.IsEmpty():
        osm_water.append(geometry)
    geometry = outside(geometry) if not geometry.IsEmpty() else None
    if geometry:
        sea.append(feature(geometry, {}))
write("sea", sea)

countries, labels = [], []
for country in ne.GetLayerByName("ne_10m_admin_0_countries_pol"):
    names = {
        "name": country.GetField("name"),
        "name_en": country.GetField("name_en"),
        "name_pl": country.GetField("name_pl"),
    }
    point = ogr.CreateGeometryFromWkt(
        f"POINT({country.GetField('label_x')} {country.GetField('label_y')})")
    if point.Within(outline):
        continue
    countries.append(country.GetGeometryRef().MakeValid())
    min_label = country.GetField("min_label") or 5
    labels.append(feature(point, {**names, "rank": country.GetField("labelrank")},
                          max(0, math.floor(min_label) - 1)))
write("labels", labels)


def lines_of(geometry):
    """The line strings of any geometry, as lists of (lon, lat)."""
    kind = ogr.GT_Flatten(geometry.GetGeometryType())
    if kind == ogr.wkbLineString:
        return [geometry.GetPoints()] if geometry.GetPointCount() else []
    if kind in (ogr.wkbMultiLineString, ogr.wkbGeometryCollection):
        return [line for i in range(geometry.GetGeometryCount()) for line in lines_of(geometry.GetGeometryRef(i))]
    return []


def rings_of(geometry):
    kind = ogr.GT_Flatten(geometry.GetGeometryType())
    if kind == ogr.wkbMultiPolygon:
        return [ring for i in range(geometry.GetGeometryCount()) for ring in rings_of(geometry.GetGeometryRef(i))]
    return [geometry.GetGeometryRef(i).GetPoints() for i in range(geometry.GetGeometryCount())]


outline_points = numpy.array([point[:2] for ring in rings_of(outline) for point in ring])
outline_edge = outline.Boundary()


def snapped(end):
    """The outline vertex to extend a border ending at end to, or None."""
    point = ogr.CreateGeometryFromWkt(f"POINT({end[0]} {end[1]})")
    if point.Distance(outline_edge) > BORDER_SNAP_DISTANCE or point.Distance(outline_edge) < 1e-9:
        return None
    return tuple(outline_points[((outline_points - end[:2]) ** 2).sum(axis=1).argmin()])


neighbour_lines = []
envelopes = [country.GetEnvelope() for country in countries]
for i, a in enumerate(countries):
    for j in range(i + 1, len(countries)):
        ea, eb = envelopes[i], envelopes[j]
        if ea[1] < eb[0] or eb[1] < ea[0] or ea[3] < eb[2] or eb[3] < ea[2]:
            continue
        shared = a.Boundary().Intersection(countries[j].Boundary())
        shared = shared.Difference(outline) if shared.Intersects(outline) else shared
        neighbour_lines.extend(lines_of(shared))

# Two line ends at one point are a junction inside a border, not a loose end
ends = {}
for line in neighbour_lines:
    for end in (line[0], line[-1]):
        key = (round(end[0], 7), round(end[1], 7))
        ends[key] = ends.get(key, 0) + 1


def extended(line):
    points = [point[:2] for point in line]
    if ends[(round(points[0][0], 7), round(points[0][1], 7))] == 1:
        target = snapped(numpy.array(points[0]))
        if target is not None:
            points.insert(0, target)
    if ends[(round(points[-1][0], 7), round(points[-1][1], 7))] == 1:
        target = snapped(numpy.array(points[-1]))
        if target is not None:
            points.append(target)
    return points


write("neighbour_borders", [
    {"type": "Feature", "tippecanoe": {"minzoom": 0}, "properties": {},
     "geometry": {"type": "LineString", "coordinates": [list(map(float, point)) for point in extended(line)]}}
    for line in neighbour_lines
])

lakes, across_borders = [], []
river_zone = outline.Boundary().Simplify(0.001).Buffer(RIVER_MARGIN)
with open(border_water_path) as lines:
    for line in lines:
        water = json.loads(line)
        geometry = ogr.CreateGeometryFromJson(json.dumps(water["geometry"])).MakeValid()
        across_borders.append(geometry)
        if water["properties"]["river"]:
            geometry = geometry.Intersection(river_zone)
        geometry = outside(geometry)
        if geometry:
            lakes.append(feature(geometry, {}))


def drawn_by_osm(lake):
    """Whether OSM already draws this Natural Earth lake."""
    if not lake.Intersects(detailed):
        return False
    west, east, south, north = lake.GetEnvelope()
    if any(west < e[1] and e[0] < east and south < e[3] and e[2] < north and lake.Intersects(water)
           for water, e in ((water, water.GetEnvelope()) for water in across_borders)):
        return True
    in_sea = 0
    for water in osm_water:
        e = water.GetEnvelope()
        if west < e[1] and e[0] < east and south < e[3] and e[2] < north:
            in_sea += lake.Intersection(water).GetArea()
    return in_sea > lake.GetArea() / 2


for lake in ne.GetLayerByName("ne_10m_lakes"):
    geometry = lake.GetGeometryRef().MakeValid()
    if drawn_by_osm(geometry):
        continue
    geometry = outside(geometry)
    if geometry:
        lakes.append(feature(geometry, {}, max(0, math.floor(lake.GetField("min_zoom") or 0))))
write("lakes", lakes)

print(f"{len(sea)} sea parts, {len(neighbour_lines)} neighbour border lines, "
      f"{len(labels)} labels, {len(lakes)} lakes")
