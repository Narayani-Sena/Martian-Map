"""Download basemap tiles once and resample them onto the site grid (3D textures).

Tiles are stored in XYZ layout (data/tiles/<layer>/<z>/<x>/<y>.png) so the
backend can serve them offline; the upstream MMGIS server is TMS.
"""

from __future__ import annotations

import io
import logging
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

from marsgeo import tiles as T
from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import session

log = logging.getLogger("pipeline.imagery")


def tile_url(template: str, x: int, y: int, z: int, tms: bool) -> str:
    return template.format(z=z, x=x, y=T.tms_y(y, z) if tms else y)


def fetch_tile(template: str, tms: bool, cache_dir: Path, x: int, y: int, z: int) -> Path | None:
    dest = cache_dir / str(z) / str(x) / f"{y}.png"
    missing = dest.with_suffix(".404")
    if dest.exists():
        return dest
    if missing.exists():
        return None
    for attempt in range(3):
        r = session().get(tile_url(template, x, y, z, tms), timeout=60)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if r.status_code in (403, 404) or not r.content or r.headers.get("content-type", "").startswith("text"):
            missing.touch()
            return None
        r.raise_for_status()
        if _decodes(r.content):  # servers occasionally send truncated bodies
            tmp = dest.with_suffix(".part")
            tmp.write_bytes(r.content)
            tmp.replace(dest)
            return dest
        log.warning("truncated tile z%d/%d/%d (attempt %d)", z, x, y, attempt + 1)
    return None


def _decodes(data: bytes) -> bool:
    try:
        Image.open(io.BytesIO(data)).load()
        return True
    except Exception:
        return False


def fetch_tiles(template: str, tms: bool, cache_dir: Path, bbox, zooms, workers: int = 8) -> int:
    jobs = [(x, y, z) for z in zooms for (x, y) in T.tiles_covering(bbox, z)]
    log.info("tiles: %d to check for zooms %s", len(jobs), list(zooms))
    ok = 0
    with ThreadPoolExecutor(workers) as ex:
        for res in ex.map(lambda j: fetch_tile(template, tms, cache_dir, *j), jobs):
            ok += res is not None
    return ok


def mosaic(cache_dir: Path, bbox, z: int):
    """Stitch cached tiles into one RGB array. Returns (array, x0, y0) with tile origin."""
    cover = T.tiles_covering(bbox, z)
    xs = [c[0] for c in cover]
    ys = [c[1] for c in cover]
    x0, y0 = min(xs), min(ys)
    nx, ny = max(xs) - x0 + 1, max(ys) - y0 + 1
    img = np.zeros((ny * 256, nx * 256, 3), np.uint8)
    for x, y in cover:
        p = cache_dir / str(z) / str(x) / f"{y}.png"
        if not p.exists():
            continue
        try:
            t = Image.open(io.BytesIO(p.read_bytes())).convert("RGB")
        except Exception:
            log.warning("unreadable tile %s - deleting so it is fetched again next run", p)
            p.unlink(missing_ok=True)
            continue
        img[(y - y0) * 256:(y - y0 + 1) * 256, (x - x0) * 256:(x - x0 + 1) * 256] = np.asarray(t)
    return img, x0, y0


def resample_to_grid(mos: np.ndarray, x0: int, y0: int, z: int, grid: SiteGrid, out_w: int, out_h: int,
                     offset_m: tuple[float, float] = (0.0, 0.0)) -> np.ndarray:
    """Inverse mapping: for every output pixel find its lon/lat, then its mosaic pixel.

    offset_m: where the mosaic shows a feature relative to our DTM (the rover team's frame, measured by
    pipeline/team_dem.py). Each pixel is read at its own position + offset, so the drape lines up with the relief.
    """
    cols = (np.arange(out_w) + 0.5) / out_w * grid.width - 0.5
    rows = (np.arange(out_h) + 0.5) / out_h * grid.height - 0.5
    C, R = np.meshgrid(cols, rows)
    x, y = grid.rowcol_to_xy(R, C)
    lon, lat = grid.xy_to_lonlat(x + float(offset_m[0]), y + float(offset_m[1]))
    tx, ty = T.lonlat_to_tile(lon, lat, z)
    mc = (tx - x0) * 256 - 0.5
    mr = (ty - y0) * 256 - 0.5
    out = np.zeros((out_h, out_w, 3), np.uint8)
    for ch in range(3):
        out[..., ch] = np.clip(sample_bilinear(mos[..., ch].astype(np.float32), mr, mc, fill=0), 0, 255)
    return out


def build_texture(template: str, tms: bool, cache_dir: Path, grid: SiteGrid, z: int, size: int,
                  offset_m: tuple[float, float] = (0.0, 0.0)) -> np.ndarray:
    margin = 20.0 + max(abs(float(offset_m[0])), abs(float(offset_m[1])))
    bbox = grid.with_margin(margin).bounds_lonlat()
    fetch_tiles(template, tms, cache_dir, bbox, [z])
    mos, x0, y0 = mosaic(cache_dir, bbox, z)
    return resample_to_grid(mos, x0, y0, z, grid, size, size, offset_m)
