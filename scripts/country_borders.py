"""Builds the real national borders from the countries' OSM boundary relations.

Usage: country_borders.py OUT_DIR WORK_DIR MERGED_PBF EXTRACT:CODE [EXTRACT:CODE ...]

Each extract holds the admin_level=2 relation of its country (found through
its ISO code), complete with its ways. Writes:

- outline.geojson: the union of the countries, territorial waters included.
  The world layers cut the map along it, and the base map input is trimmed to
  it. Enclaves such as Busingen stay holes.
- country_outlines.geojson: each country on its own, named by its ISO code.
- borders.geojsonl: the land borders of the countries as single lines, each
  way once. Maritime and coastline ways are left out, except across the inner
  waters below, as are the borders between the neighbours themselves, which
  belong to no relation read here.
- border_water.geojsonl: the lakes and rivers that cross the outline, whole.
  The extracts hold them completely, so the world layers can draw their far
  shores too.
"""
import json
import subprocess
import sys

from osgeo import ogr

ogr.UseExceptions()

out_dir, work_dir, merged, *inputs = sys.argv[1:]

GRID_DEGREES = 0.05
RIVER_KINDS = ("river", "canal", "stream", "oxbow", "lock")
# Lagoons whose borders OSM tags as maritime but maps draw like land borders,
# as (west, south, east, north). The boxes stop short of the open sea.
INNER_WATERS = {
    "Szczecin Lagoon": (13.8, 53.6, 14.7, 53.88),
    "Vistula Lagoon": (19.645, 54.3, 20.5, 54.6),
}


def osmium(*args):
    subprocess.run(["osmium", *args], check=True)


def read_relation(extract, code):
    """The relation's OPL line, with only its outline ways as members."""
    opl = f"{work_dir}/{code}-relation.opl"
    osmium("tags-filter", "--overwrite", "-R", "-o", opl, "-f", "opl", extract,
           f"r/ISO3166-1={code}", f"r/ISO3166-1:alpha2={code}")
    with open(opl) as lines:
        for line in lines:
            fields = line.rstrip("\n").split(" ")
            tags = next(field[1:] for field in fields if field.startswith("T"))
            if "admin_level=2" not in tags.split(","):
                continue
            members = next(field[1:] for field in fields if field.startswith("M")).split(",")
            ways = [m for m in members if m.startswith("w") and m.split("@")[1] in ("outer", "inner")]
            keep = [f"M{','.join(ways)}" if field.startswith("M") else field for field in fields]
            return " ".join(keep), [m.split("@")[0] for m in ways]
    raise SystemExit(f"No admin_level=2 relation for {code} in {extract}")


def in_inner_waters(line):
    """Whether all of a line lies in one of the inner waters."""
    return any(all(west <= lon <= east and south <= lat <= north for lon, lat in line)
               for west, south, east, north in INNER_WATERS.values())


def export(path, output, config):
    config_path = f"{work_dir}/export.json"
    with open(config_path, "w") as out:
        json.dump(config, out)
    osmium("export", "--overwrite", "-c", config_path, "--keep-untagged", "--geometry-types=linestring,polygon",
           "-f", "geojsonseq", "-o", output, path)
    with open(output) as lines:
        return [json.loads(line.lstrip("\x1e")) for line in lines]


outline = None
country_outlines = []
borders = {}
maritime = 0
for item in inputs:
    extract, code = item.rsplit(":", 1)
    relation, way_ids = read_relation(extract, code)

    ids_path = f"{work_dir}/{code}-ways.txt"
    with open(ids_path, "w") as out:
        out.write("\n".join(way_ids) + "\n")
    ways_pbf = f"{work_dir}/{code}-ways.osm.pbf"
    osmium("getid", "--overwrite", "-r", "-i", ids_path, "-o", ways_pbf, extract)

    # The stripped relation, as a file of its own, makes one area of the ways
    relation_opl = f"{work_dir}/{code}-stripped.opl"
    with open(relation_opl, "w") as out:
        out.write(relation + "\n")
    area_pbf = f"{work_dir}/{code}-area.osm.pbf"
    osmium("merge", "--overwrite", "-o", area_pbf, ways_pbf, relation_opl)

    areas = export(area_pbf, f"{work_dir}/{code}-area.geojsonl",
                   {"attributes": {"type": True, "id": True}, "linear_tags": False, "area_tags": True})
    area = next((a for a in areas if a["properties"].get("@type") == "relation"), None)
    if area is None:
        raise SystemExit(f"The ways of {code} do not close into an area")
    geometry = ogr.CreateGeometryFromJson(json.dumps(area["geometry"]))
    outline = geometry if outline is None else outline.Union(geometry)
    country_outlines.append({"type": "Feature", "properties": {"name": code}, "geometry": area["geometry"]})

    ways = export(ways_pbf, f"{work_dir}/{code}-ways.geojsonl",
                  {"attributes": {"type": True, "id": True}, "linear_tags": True, "area_tags": False})
    if len(ways) != len(way_ids):
        raise SystemExit(f"{code}: {len(way_ids)} ways in the relation, {len(ways)} exported")
    for way in ways:
        tags = way["properties"]
        if ((tags.get("maritime") == "yes" or tags.get("boundary_type") == "maritime"
             or tags.get("natural") == "coastline") and not in_inner_waters(way["geometry"]["coordinates"])):
            maritime += 1
            continue
        borders[tags["@id"]] = way["geometry"]
    print(f"{code}: {len(way_ids)} ways, {geometry.GetGeometryCount()} parts", flush=True)

with open(f"{out_dir}/outline.geojson", "w") as out:
    json.dump({"type": "FeatureCollection", "name": "outline", "features": [
        {"type": "Feature", "properties": {}, "geometry": json.loads(outline.ExportToJson())}]}, out)
with open(f"{out_dir}/country_outlines.geojson", "w") as out:
    json.dump({"type": "FeatureCollection", "name": "country_outlines", "features": country_outlines}, out)
with open(f"{out_dir}/borders.geojsonl", "w") as out:
    for geometry in borders.values():
        out.write(json.dumps({"type": "Feature", "properties": {}, "geometry": geometry}, separators=(",", ":")) + "\n")
print(f"{len(borders)} land border ways, {maritime} maritime ways left out")

water_pbf = f"{work_dir}/water.osm.pbf"
water_path = f"{work_dir}/water.geojsonl"
osmium("tags-filter", "--overwrite", "-o", water_pbf, merged, "a/natural=water")
osmium("export", "--overwrite", "--geometry-types=polygon", "-f", "geojsonseq",
       "--format-option=print_record_separator=false", "-o", water_path, water_pbf)

outline_edge = outline.Boundary()

# Grid cells the outline runs through, so that only water near it needs the
# exact and much slower test against the outline
edge_cells = set()
dense_edge = outline_edge.Clone()
dense_edge.Segmentize(GRID_DEGREES / 2)
for i in range(dense_edge.GetGeometryCount() or 1):
    ring = dense_edge.GetGeometryRef(i) if dense_edge.GetGeometryCount() else dense_edge
    edge_cells.update((int(lon // GRID_DEGREES), int(lat // GRID_DEGREES)) for lon, lat, *_ in ring.GetPoints())


def near_edge(geometry):
    west, east, south, north = geometry.GetEnvelope()
    return any((x, y) in edge_cells
               for x in range(int(west // GRID_DEGREES), int(east // GRID_DEGREES) + 1)
               for y in range(int(south // GRID_DEGREES), int(north // GRID_DEGREES) + 1))


crossing = 0
with open(water_path, newline="\n") as lines, open(f"{out_dir}/border_water.geojsonl", "w") as out:
    for line in lines:
        water = json.loads(line)
        geometry = ogr.CreateGeometryFromJson(json.dumps(water["geometry"]))
        if near_edge(geometry) and geometry.Intersects(outline_edge):
            river = water["properties"].get("water") in RIVER_KINDS
            out.write(json.dumps({"type": "Feature", "properties": {"river": river}, "geometry": water["geometry"]},
                                 separators=(",", ":")) + "\n")
            crossing += 1
print(f"{crossing} lakes and rivers cross the borders")
