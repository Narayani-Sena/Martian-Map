"""Fetch elevation data and resample it onto the site grid.

Only the window we need is read from each cloud-optimised GeoTIFF, using HTTP
range requests, so a 3 km site costs a few MB instead of the 1 GB strip.
"""

from __future__ import annotations

import logging

import numpy as np
import rasterio
from rasterio.crs import CRS
from rasterio.warp import Resampling, reproject, transform_bounds
from rasterio.windows import Window

from marsgeo import stac
from marsgeo.grid import SiteGrid
from marsgeo.net import gdal_http_env

from .derive import fill_nodata

log = logging.getLogger("pipeline.terrain")

HRSC_MOLA_BLEND = "https://planetarymaps.usgs.gov/mosaic/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif"


def _crs(grid: SiteGrid) -> CRS:
    return CRS.from_proj4(grid.crs_proj4)


def read_to_grid(href: str, grid: SiteGrid, resampling=Resampling.bilinear, band: int = 1,
                 margin_px: int = 8) -> np.ndarray:
    """Read the part of a (remote) raster that covers grid and warp it onto grid. NaN = no data."""
    path = href if href.startswith("/vsi") or not href.startswith("http") else "/vsicurl/" + href
    with rasterio.Env(**gdal_http_env()):
        with rasterio.open(path) as src:
            l, b, r, t = transform_bounds(_crs(grid), src.crs, *grid.bounds_xy, densify_pts=21)
            win = src.window(l, b, r, t)
            col0 = max(0, int(np.floor(win.col_off)) - margin_px)
            row0 = max(0, int(np.floor(win.row_off)) - margin_px)
            col1 = min(src.width, int(np.ceil(win.col_off + win.width)) + margin_px)
            row1 = min(src.height, int(np.ceil(win.row_off + win.height)) + margin_px)
            out = np.full((grid.height, grid.width), np.nan, np.float32)
            if col1 <= col0 or row1 <= row0:
                return out
            win = Window(col0, row0, col1 - col0, row1 - row0)
            data = src.read(band, window=win).astype(np.float32)
            nod = src.nodata
            if nod is not None:
                data[np.isclose(data, nod) | (data < -1e30)] = np.nan
            data[~np.isfinite(data)] = np.nan
            reproject(data, out, src_transform=src.window_transform(win), src_crs=src.crs,
                      src_nodata=np.nan, dst_transform=grid.transform, dst_crs=_crs(grid),
                      dst_nodata=np.nan, resampling=resampling)
    return out


def find_dtms(grid: SiteGrid, preferred: list[str] | None = None, collection: str = "mro_hirise_socet_dtms"):
    items = stac.search([collection], bbox=grid.bounds_lonlat(), limit=50)
    preferred = preferred or []
    rank = {pid: i for i, pid in enumerate(preferred)}
    items.sort(key=lambda it: (rank.get(it["id"], len(rank)), it["properties"].get("gsd", 99)))
    return items


def build_dem(grid: SiteGrid, preferred: list[str] | None = None, collection="mro_hirise_socet_dtms",
              resampling=Resampling.bilinear, fill: bool = True):
    """Mosaic HiRISE DTMs onto the grid, aligning each extra DTM's vertical datum to the first."""
    items = find_dtms(grid, preferred, collection)
    if not items:
        raise RuntimeError("No DTM in the STAC catalog covers this site")
    dem, used = None, []
    for it in items:
        href = stac.asset_href(it, "dtm")
        if not href:
            continue
        log.info("reading DTM %s", it["id"])
        try:
            arr = read_to_grid(href, grid, resampling=resampling)
        except Exception as e:  # some catalog hrefs 404
            log.warning("  skipped %s: %s", it["id"], e)
            continue
        valid = np.isfinite(arr)
        if not valid.any():
            continue
        if dem is None:
            dem, offset = arr, 0.0
        else:
            both = np.isfinite(dem) & valid
            offset = float(np.nanmedian(dem[both] - arr[both])) if both.sum() > 500 else 0.0
            gap = ~np.isfinite(dem) & valid  # (not `fill`: that name is the fill-nodata flag)
            dem[gap] = arr[gap] + offset
        used.append({"id": it["id"], "href": href, "gsd": it["properties"].get("gsd"),
                     "vertical_offset_m": round(offset, 3),
                     "coverage": round(float(valid.mean()), 4)})
        if np.isfinite(dem).all():
            break
    if dem is None:
        raise RuntimeError("DTMs found but none had data over the site")
    missing = float((~np.isfinite(dem)).mean())
    if missing > 0 and fill:
        log.info("filling %.3f%% missing cells", missing * 100)
        dem = fill_nodata(dem)
    return dem.astype(np.float32), used, missing


def build_regional_dem(grid: SiteGrid, url: str = HRSC_MOLA_BLEND) -> np.ndarray:
    """200 m HRSC-MOLA blend onto a (large, coarse) grid. The source is striped, so this
    reads full rows - a one-off download of ~100 MB for +-0.8 deg."""
    log.info("reading regional DEM (HRSC-MOLA blend 200 m) - this is the slow step")
    arr = read_to_grid(url, grid, resampling=Resampling.bilinear, margin_px=2)
    if not np.isfinite(arr).all():
        arr = fill_nodata(arr)
    return arr
