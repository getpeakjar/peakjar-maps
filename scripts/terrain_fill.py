"""Fills the transparent pixels of Terrarium terrain tiles with sea level.

Usage: terrain_fill.py TERRAIN_MBTILES

GDAL leaves the part of a tile outside the elevation data transparent. MapLibre
ignores alpha in terrain tiles and decodes those pixels as -32768 m, which
draws a black frame of hillshade and deep pits in 3D. Writing 0 m there keeps
them flat. Tiles are rewritten as RGB PNG, still lossless.
"""
import sqlite3
import sys

from osgeo import gdal

gdal.UseExceptions()

SEA_LEVEL = (128, 0, 0)  # (0 + 32768) / 256 = 128, remainder 0


def read_mem(path):
    size = gdal.VSIStatL(path).size
    handle = gdal.VSIFOpenL(path, "rb")
    try:
        return gdal.VSIFReadL(1, size, handle)
    finally:
        gdal.VSIFCloseL(handle)


db = sqlite3.connect(sys.argv[1])
filled = 0
rows = db.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles").fetchall()
for zoom, column, row, data in rows:
    gdal.FileFromMemBuffer("/vsimem/in.png", data)
    tile = gdal.Open("/vsimem/in.png")
    if tile.RasterCount < 4:
        continue
    transparent = tile.GetRasterBand(4).ReadAsArray() == 0
    if not transparent.any():
        continue
    out = gdal.GetDriverByName("MEM").Create("", tile.RasterXSize, tile.RasterYSize, 3, gdal.GDT_Byte)
    for band, value in enumerate(SEA_LEVEL, start=1):
        pixels = tile.GetRasterBand(band).ReadAsArray()
        pixels[transparent] = value
        out.GetRasterBand(band).WriteArray(pixels)
    gdal.GetDriverByName("PNG").CreateCopy("/vsimem/out.png", out, options=["ZLEVEL=9"])
    db.execute(
        "UPDATE tiles SET tile_data = ? WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
        (read_mem("/vsimem/out.png"), zoom, column, row))
    filled += 1
db.commit()
db.execute("VACUUM")
print(f"Filled {filled} of {len(rows)} tiles")
