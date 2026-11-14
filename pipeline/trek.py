"""NASA Mars Trek tiles (https://trek.nasa.gov/mars/) resampled onto a site grid.

Mars Trek serves its mosaics as WMTS tiles in an equirectangular tile matrix on the Mars 2000 sphere
("EQ", urn:ogc:def:crs:EPSG::104905): level n is 2^(n+1) x 2^n tiles of 256 px starting at (-180, 90).
Its catalogue can be searched at TrekServices/ws/index/eq/searchItems (see find_layer).
"""

from __future__ import annotations

import io
import logging
import math
from pathlib import Path

import numpy as np
from PIL import Image

from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import session

log = logging.getLogger("pipeline.trek")

BASE = "https://trek.nasa.gov/tiles/Mars/EQ"
SEARCH = "https://trek.nasa.gov/mars/TrekServices/ws/index/eq/searchItems"
TILE = 256


def tile_url(layer: str, z: int, row: int, col: int, ext: str = "png") -> str:
    return f"{BASE}/{layer}/1.0.0//default/default028mm/{z}/{row}/{col}.{ext}"


def find_layer(key: str, rows: int = 40) -> list[dict]:
    """Search the Mars Trek catalogue (title, productLabel = WMTS layer name, description)."""
    r = session().get(SEARCH, params={"start": 0, "rows": rows, "proj": "urn:ogc:def:crs:EPSG::104905", "key": key}, timeout=60)
    r.raise_for_status()
    return r.json().get("response", {}).get("docs", [])


def deg_per_px(z: int) -> float:
    return 180.0 / (TILE * 2 ** z)


def _fetch(layer: str, z: int, row: int, col: int, cache: Path, ext: str) -> np.ndarray | None:
    p = cache / layer / str(z) / str(row) / f"{col}.{ext}"
    if not p.exists():
        r = session().get(tile_url(layer, z, row, col, ext), timeout=60)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(r.content)
    im = Image.open(io.BytesIO(p.read_bytes()))
    if im.mode in ("RGBA", "LA", "P"):
        a = np.asarray(im.convert("RGBA"), dtype=np.float32)
        lum = a[..., :3].mean(axis=2)
        lum[a[..., 3] < 8] = np.nan
        return lum
    return np.asarray(im.convert("L"), dtype=np.float32)


def mosaic(layer: str, bbox, z: int, cache: Path, ext: str = "png", pad: int = 2):
    """Tiles covering bbox (+pad px) at level z: (array, lon of the left edge, lat of the top edge)."""
    d = deg_per_px(z)
    lon0, lat0, lon1, lat1 = bbox
    x0 = int(math.floor((lon0 + 180.0) / d)) - pad
    x1 = int(math.ceil((lon1 + 180.0) / d)) + pad
    y0 = int(math.floor((90.0 - lat1) / d)) - pad
    y1 = int(math.ceil((90.0 - lat0) / d)) + pad
    c0, c1, r0, r1 = x0 // TILE, x1 // TILE, y0 // TILE, y1 // TILE
    out = np.full(((r1 - r0 + 1) * TILE, (c1 - c0 + 1) * TILE), np.nan, np.float32)
    got = 0
    for row in range(r0, r1 + 1):
        for col in range(c0, c1 + 1):
            t = _fetch(layer, z, row, col, cache, ext)
            if t is None:
                continue
            out[(row - r0) * TILE:(row - r0 + 1) * TILE, (col - c0) * TILE:(col - c0 + 1) * TILE] = t
            got += 1
    if not got:
        return None, 0.0, 0.0
    return out, c0 * TILE * d - 180.0, 90.0 - r0 * TILE * d


def read_to_grid(layer: str, grid: SiteGrid, z: int, cache: Path, ext: str = "png") -> np.ndarray | None:
    """The layer resampled (bilinear) onto grid cell centres; NaN where Trek has no data."""
    lon_min, lat_min, lon_max, lat_max = grid.bounds_lonlat()
    arr, left, top = mosaic(layer, (lon_min, lat_min, lon_max, lat_max), z, cache, ext)
    if arr is None:
        return None
    d = deg_per_px(z)
    rr, cc = np.meshgrid(np.arange(grid.height), np.arange(grid.width), indexing="ij")
    lon, lat = grid.rowcol_to_lonlat(rr, cc)
    # pixel centres sit at half-pixel offsets from the tile matrix's top-left corner
    px = (np.asarray(lon) - left) / d - 0.5
    py = (top - np.asarray(lat)) / d - 0.5
    out = sample_bilinear(arr, py, px)
    return np.asarray(out, np.float32).reshape(grid.height, grid.width)


PORTAL = "https://trek.nasa.gov/mars/"


def open_url(lon: float, lat: float) -> str:
    """The Mars Trek portal. (Trek ignores position links as of 2026-11, so clients show the coordinates
    next to the link for Trek's own search box.)"""
    return PORTAL
