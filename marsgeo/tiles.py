"""Slippy-map tile math for Mars basemaps.

JPL's MMGIS serves Mars imagery in the usual spherical (Web) Mercator tiling,
with longitude/latitude in planetocentric degrees. Mercator is angle-based, so
the formulas are identical to Earth's; only *distances* need the Mars radius.

MMGIS uses TMS row numbering (row 0 at the south). Leaflet's default is XYZ
(row 0 at the north); convert with tms_y().
"""

from __future__ import annotations

import math

import numpy as np

TILE_SIZE = 256


def tms_y(y: int, z: int) -> int:
    """Convert between XYZ and TMS row numbers (the mapping is its own inverse)."""
    return (1 << z) - 1 - y


def lonlat_to_tile(lon, lat, z):
    """Fractional XYZ tile coordinates for lon/lat (degrees)."""
    n = float(1 << z)
    lon = np.asarray(lon, dtype=float)
    lat = np.radians(np.asarray(lat, dtype=float))
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - np.log(np.tan(lat) + 1.0 / np.cos(lat)) / math.pi) / 2.0 * n
    return x, y


def tile_to_lonlat(x, y, z):
    """Lon/lat of fractional XYZ tile coordinates (tile corner at integers)."""
    n = float(1 << z)
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    lon = x / n * 360.0 - 180.0
    lat = np.degrees(np.arctan(np.sinh(math.pi * (1.0 - 2.0 * y / n))))
    return lon, lat


def tile_bounds(x: int, y: int, z: int):
    """(lon_w, lat_s, lon_e, lat_n) of XYZ tile (x, y, z)."""
    lon_w, lat_n = tile_to_lonlat(x, y, z)
    lon_e, lat_s = tile_to_lonlat(x + 1, y + 1, z)
    return float(lon_w), float(lat_s), float(lon_e), float(lat_n)


def tile_pixel_lonlat(x: int, y: int, z: int, size: int = TILE_SIZE):
    """Lon/lat grids (size x size) of the pixel centres of an XYZ tile."""
    t = (np.arange(size) + 0.5) / size
    lon, _ = tile_to_lonlat(x + t, np.full(size, y + 0.5), z)
    _, lat = tile_to_lonlat(np.full(size, x + 0.5), y + t, z)
    return np.meshgrid(lon, lat)


def tiles_covering(bbox, z: int):
    """All XYZ tiles at zoom z touching bbox = (lon_min, lat_min, lon_max, lat_max)."""
    lon_min, lat_min, lon_max, lat_max = bbox
    x0, y0 = lonlat_to_tile(lon_min, lat_max, z)
    x1, y1 = lonlat_to_tile(lon_max, lat_min, z)
    return [(x, y) for x in range(int(x0), int(x1) + 1) for y in range(int(y0), int(y1) + 1)]


def tile_intersects(x: int, y: int, z: int, bbox) -> bool:
    w, s, e, n = tile_bounds(x, y, z)
    lon_min, lat_min, lon_max, lat_max = bbox
    return not (e < lon_min or w > lon_max or n < lat_min or s > lat_max)
