"""Tiny GeoTIFF read/write helpers on top of rasterio."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio
from rasterio.crs import CRS

from marsgeo.grid import SiteGrid


def write_tif(path: Path, arr: np.ndarray, grid: SiteGrid, nodata=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    profile = dict(driver="GTiff", width=grid.width, height=grid.height, count=1, dtype=arr.dtype.name,
                   crs=CRS.from_proj4(grid.crs_proj4), transform=grid.transform, tiled=True,
                   blockxsize=256, blockysize=256, compress="deflate", predictor=3 if arr.dtype.kind == "f" else 2)
    if nodata is not None:
        profile["nodata"] = nodata
    with rasterio.open(path, "w", **profile) as dst:
        dst.write(arr, 1)


def read_tif(path: Path) -> np.ndarray:
    with rasterio.open(path) as src:
        return src.read(1)
