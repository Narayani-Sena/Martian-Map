"""The rover team's own terrain model of the site, lined up with the USGS HiRISE DTM we route on.

Curiosity's and Perseverance's operations teams localise their rovers on their own HiRISE terrain mosaics:

    Gale:   MSL Gale merged DEM mosaic v3, 1 m (Parker & Calef, USGS Astrogeology); Mars Trek "Gale_DEM_SMG_1m"
    Jezero: Mars 2020 Terrain Relative Navigation HiRISE DTM mosaic, 1 m (Fergason et al. 2020); the DTM the
            lander's TRN camera matched against, Mars Trek "JEZ_hirise_soc_006_DTM_..."

Our DTMs are separate USGS-controlled HiRISE stereo models, so anything the teams publish (rover tracks,
waypoints, sample sites, Ingenuity flights, the colour mosaics) sits a few metres off sideways and 5-12 m off
in height. This step measures that offset instead of guessing it:

1. Read the site's window of the team mosaic. USGS serves both files as multi-GB uncompressed GeoTIFFs with
   one image row per strip, so we fetch only our columns of every 2nd row with HTTP range requests
   (4 at a time: more trip HTTP 504s on the server), and cache the window.
2. Put it on our 2 m grid (lon/lat of every cell -> the file's equirectangular metres -> its pixels).
3. Phase correlation (FFT) of the two high-passed terrain models gives the horizontal shift, refined to
   a tenth of a cell by minimising the height residual; a robust plane fit gives the height offset and tilt.

Convention: the team product shows a feature that sits at p on our DTM at p + (dx, dy). A team-frame
position q is therefore q - (dx, dy) on our terrain, and z_ours(p) = z_team(p + d) + plane(p).
"""

from __future__ import annotations

import logging
import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import requests
from scipy import ndimage

from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import USER_AGENT, gdal_http_env

log = logging.getLogger("pipeline.team_dem")

WORKERS = 4
NODATA_BELOW = -1e30


# ------------------------------------------------------------------ reading
def _header(url: str) -> dict:
    """Size, georeference and strip layout of a remote GeoTIFF (GDAL reads just the header)."""
    import rasterio
    with rasterio.Env(**gdal_http_env()):
        with rasterio.open("/vsicurl/" + url) as src:
            if src.compression is not None:
                raise ValueError(f"{url} is compressed; this reader needs uncompressed strips")
            if src.block_shapes[0][0] != 1:
                raise ValueError(f"{url} is not stored one row per strip")
            off0 = int(src.get_tag_item("BLOCK_OFFSET_0_0", "TIFF", bidx=1))
            off1 = int(src.get_tag_item("BLOCK_OFFSET_0_1", "TIFF", bidx=1))
            offn = int(src.get_tag_item(f"BLOCK_OFFSET_0_{src.height - 1}", "TIFF", bidx=1))
            row_bytes = off1 - off0
            if row_bytes != src.width * 4 or offn != off0 + (src.height - 1) * row_bytes:
                raise ValueError("strips are not stored back to back")
            return {"width": src.width, "height": src.height, "transform": tuple(src.transform)[:6],
                    "crs": src.crs.to_wkt(), "nodata": src.nodata, "dtype": src.dtypes[0],
                    "offset0": off0, "row_bytes": row_bytes, "little_endian": True}


def _site_window(hdr: dict, grid: SiteGrid, margin_m: float) -> tuple[int, int, int, int]:
    """File pixel window (row0, row1, col0, col1) covering grid + margin."""
    from affine import Affine
    from rasterio.crs import CRS
    from rasterio.warp import transform as warp
    g = grid.with_margin(margin_m)
    xs = np.r_[np.linspace(g.x_min, g.x_max, 21), np.full(21, g.x_max), np.linspace(g.x_min, g.x_max, 21), np.full(21, g.x_min)]
    ys = np.r_[np.full(21, g.y_max), np.linspace(g.y_min, g.y_max, 21), np.full(21, g.y_min), np.linspace(g.y_min, g.y_max, 21)]
    fx, fy = warp(CRS.from_proj4(grid.crs_proj4), CRS.from_wkt(hdr["crs"]), xs, ys)
    inv = ~Affine(*hdr["transform"])
    cols, rows = zip(*[inv * (x, y) for x, y in zip(fx, fy)])
    r0 = max(0, int(math.floor(min(rows))))
    r1 = min(hdr["height"], int(math.ceil(max(rows))) + 1)
    c0 = max(0, int(math.floor(min(cols))))
    c1 = min(hdr["width"], int(math.ceil(max(cols))) + 1)
    if r1 <= r0 or c1 <= c0:
        raise ValueError("the site is outside the team mosaic")
    return r0, r1, c0, c1


def fetch_window(url: str, grid: SiteGrid, cache: Path, stride: int = 2, margin_m: float = 120.0) -> dict:
    """Every `stride`-th row and column of the file inside the site window, cached as .npz."""
    hdr = _header(url)
    r0, r1, c0, c1 = _site_window(hdr, grid, margin_m)
    name = url.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    path = cache / f"{name}_{r0}_{r1}_{c0}_{c1}_s{stride}.npz"
    if path.exists():
        z = np.load(path)
        return {"z": z["z"], "r0": r0, "c0": c0, "stride": stride, "hdr": hdr, "url": url}
    rows = list(range(r0, r1, stride))
    nbytes = (c1 - c0) * 4
    local = threading.local()
    done = [0]
    lock = threading.Lock()
    t0 = time.time()

    def get(r: int) -> np.ndarray:
        s = getattr(local, "s", None)
        if s is None:
            s = local.s = requests.Session()
            s.headers["User-Agent"] = USER_AGENT
        a = hdr["offset0"] + r * hdr["row_bytes"] + c0 * 4
        last = None
        for attempt in range(8):
            try:
                resp = s.get(url, headers={"Range": f"bytes={a}-{a + nbytes - 1}"}, timeout=90)
                if resp.status_code == 206 and len(resp.content) == nbytes:
                    with lock:
                        done[0] += 1
                        if done[0] % max(1, len(rows) // 10) == 0:
                            log.info("  team DEM rows %d/%d (%.0f s)", done[0], len(rows), time.time() - t0)
                    return np.frombuffer(resp.content, "<f4")[::stride].copy()
                last = f"HTTP {resp.status_code}"
            except requests.RequestException as e:
                last = type(e).__name__
            time.sleep(min(20.0, 1.5 * 2 ** attempt))
        raise RuntimeError(f"row {r}: {last}")

    log.info("team DEM: reading %d rows x %d columns of %s", len(rows), c1 - c0, name)
    with ThreadPoolExecutor(WORKERS) as ex:
        z = np.stack(list(ex.map(get, rows))).astype(np.float32)
    bad = z < NODATA_BELOW
    if hdr["nodata"] is not None and math.isfinite(hdr["nodata"]):
        bad |= np.isclose(z, hdr["nodata"])
    z[bad] = np.nan
    cache.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(path, z=z)
    log.info("team DEM window %s in %.0f s, %.1f %% valid", z.shape, time.time() - t0, 100 * np.isfinite(z).mean())
    return {"z": z, "r0": r0, "c0": c0, "stride": stride, "hdr": hdr, "url": url}


def to_grid(win: dict, grid: SiteGrid) -> np.ndarray:
    """The fetched window resampled (bilinear) onto grid cell centres; NaN outside the mosaic."""
    from affine import Affine
    from rasterio.crs import CRS
    from rasterio.warp import transform as warp
    rr, cc = np.meshgrid(np.arange(grid.height), np.arange(grid.width), indexing="ij")
    x, y = grid.rowcol_to_xy(rr.ravel(), cc.ravel())
    fx, fy = warp(CRS.from_proj4(grid.crs_proj4), CRS.from_wkt(win["hdr"]["crs"]), x, y)
    a = Affine(*win["hdr"]["transform"])
    inv = ~a
    col, row = inv * (np.asarray(fx), np.asarray(fy))
    # rasterio's transform maps pixel corners; pixel (r, c) is centred at (c + 0.5, r + 0.5)
    kr = (np.asarray(row) - 0.5 - win["r0"]) / win["stride"]
    kc = (np.asarray(col) - 0.5 - win["c0"]) / win["stride"]
    out = sample_bilinear(win["z"], kr, kc)
    return np.asarray(out, np.float32).reshape(grid.height, grid.width)


# ------------------------------------------------------------- co-registration
def _highpass(z: np.ndarray, sigma_px: float) -> np.ndarray:
    ok = np.isfinite(z)
    zf = np.where(ok, z, np.nanmedian(z)).astype(np.float64)
    return zf - ndimage.gaussian_filter(zf, sigma_px)


def phase_correlation(a: np.ndarray, b: np.ndarray) -> tuple[float, float, float]:
    """Shift (drow, dcol) in cells such that b(p) ~ a(p - d), with sub-pixel parabola fits; plus the peak height.

    Both inputs: same shape, finite. A Hann window keeps the image edges from dominating the spectrum.
    """
    h, w = a.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    fa = np.fft.fft2((a - a.mean()) * win)
    fb = np.fft.fft2((b - b.mean()) * win)
    r = fa * np.conj(fb)
    r /= np.maximum(np.abs(r), 1e-12)
    c = np.fft.ifft2(r).real
    pr, pc = np.unravel_index(int(np.argmax(c)), c.shape)

    def sub(cm, c0, cp):
        den = cm - 2 * c0 + cp
        return 0.0 if abs(den) < 1e-12 else 0.5 * (cm - cp) / den

    dr = pr + sub(c[(pr - 1) % h, pc], c[pr, pc], c[(pr + 1) % h, pc])
    dc = pc + sub(c[pr, (pc - 1) % w], c[pr, pc], c[pr, (pc + 1) % w])
    # the peak sits at -d (wrapped)
    dr = -(dr if dr <= h / 2 else dr - h)
    dc = -(dc if dc <= w / 2 else dc - w)
    return float(dr), float(dc), float(c[pr, pc])


def _shifted(b: np.ndarray, drow: float, dcol: float) -> np.ndarray:
    """b sampled at p + d (bilinear); NaN outside."""
    rr, cc = np.meshgrid(np.arange(b.shape[0], dtype=float), np.arange(b.shape[1], dtype=float), indexing="ij")
    return np.asarray(sample_bilinear(b, rr + drow, cc + dcol), np.float32)


def _plane_fit(dz: np.ndarray, x: np.ndarray, y: np.ndarray, iters: int = 4):
    """Robust plane dz ~ a + b x + c y (x, y in km): least squares, re-fitted on the inner 90 % of residuals."""
    ok = np.isfinite(dz)
    coef = np.array([float(np.nanmedian(dz)), 0.0, 0.0])
    for _ in range(iters):
        A = np.column_stack([np.ones(ok.sum()), x[ok], y[ok]])
        coef, *_ = np.linalg.lstsq(A, dz[ok], rcond=None)
        res = dz - (coef[0] + coef[1] * x + coef[2] * y)
        lim = np.nanpercentile(np.abs(res[ok]), 90)
        ok = np.isfinite(dz) & (np.abs(res) <= lim)
    return coef


def coregister(ours: np.ndarray, team: np.ndarray, res: float, crop: int = 1024) -> dict:
    """Shift, height offset and tilt of `team` relative to `ours` (both on the same grid, metres).

    Returns dx_m (east), dy_m (north), the plane coefficients and residual statistics.
    """
    h, w = ours.shape
    n = min(crop, h, w)
    r0, c0 = (h - n) // 2, (w - n) // 2
    a = _highpass(ours[r0:r0 + n, c0:c0 + n], 8.0)
    b = _highpass(team[r0:r0 + n, c0:c0 + n], 8.0)
    drow, dcol, peak = phase_correlation(a, b)

    # refine: minimise the high-pass residual over a small neighbourhood (0.1 cell steps)
    hp_a = _highpass(ours, 8.0)
    hp_b = _highpass(team, 8.0)
    inner = (slice(16, h - 16), slice(16, w - 16))
    valid = np.isfinite(ours) & np.isfinite(team)

    def score(dr, dc):
        s = _shifted(hp_b, dr, dc)
        v = valid & np.isfinite(s)
        d = (hp_a - s)[inner][v[inner]]
        return float(np.sqrt(np.mean(d * d))) if d.size else 1e9

    best = (score(drow, dcol), drow, dcol)
    for step in (0.5, 0.2, 0.1):
        improved = True
        while improved:
            improved = False
            for ddr, ddc in ((step, 0), (-step, 0), (0, step), (0, -step)):
                s = score(best[1] + ddr, best[2] + ddc)
                if s < best[0] - 1e-6:
                    best = (s, best[1] + ddr, best[2] + ddc)
                    improved = True
    _, drow, dcol = best

    tb = _shifted(team, drow, dcol)
    dz = ours - tb
    rr, cc = np.meshgrid(np.arange(h, dtype=float), np.arange(w, dtype=float), indexing="ij")
    xk = (cc - (w - 1) / 2) * res / 1000.0
    yk = -(rr - (h - 1) / 2) * res / 1000.0
    coef = _plane_fit(dz, xk, yk)
    plane = coef[0] + coef[1] * xk + coef[2] * yk
    resid = dz - plane
    ok = np.isfinite(resid)
    absr = np.abs(resid[ok])
    return {
        "dx_m": round(dcol * res, 2), "dy_m": round(-drow * res, 2),
        "drow": drow, "dcol": dcol,
        "dz_m": round(float(coef[0]), 2), "tilt_m_per_km": [round(float(coef[1]), 3), round(float(coef[2]), 3)],
        "peak": round(peak, 3),
        "rms_m": round(float(np.sqrt(np.mean(resid[ok] ** 2))), 2),
        "median_abs_m": round(float(np.median(absr)), 2),
        "p95_m": round(float(np.percentile(absr, 95)), 2),
        "coverage": round(float(ok.mean()), 4),
        "aligned": (tb + plane).astype(np.float32),
        "residual": resid.astype(np.float32),
    }


# ------------------------------------------------------------------ apply
def to_site_frame(grid: SiteGrid, lon, lat, team: dict | None):
    """Team-frame lon/lat -> our DTM's frame (subtract the measured shift). No-op without a measurement."""
    if not team:
        return lon, lat
    x, y = grid.lonlat_to_xy(lon, lat)
    return grid.xy_to_lonlat(x - float(team["dx_m"]), y - float(team["dy_m"]))


def plane_at(grid: SiteGrid, lon, lat, team: dict) -> np.ndarray:
    """Height to add to a team-frame elevation to put it on our DTM's datum, at (lon, lat) on our grid."""
    x, y = grid.lonlat_to_xy(lon, lat)
    a, (b, c) = float(team["dz_m"]), team["tilt_m_per_km"]
    return a + float(b) * (np.asarray(x) / 1000.0) + float(c) * (np.asarray(y) / 1000.0)


def build(out_dir: Path, grid2: SiteGrid, z2: np.ndarray, cfg: dict, cache: Path) -> dict:
    """cfg: the site's "team_dem" block (url, name, team, citation, trek_layer)."""
    win = fetch_window(cfg["url"], grid2, cache)
    team = to_grid(win, grid2)
    if not np.isfinite(team).any():
        raise RuntimeError("the team mosaic has no data over the site")
    reg = coregister(z2, team, grid2.res)
    np.save(out_dir / "team_dem_2m.npy", reg.pop("aligned"))
    resid = reg.pop("residual")
    np.save(out_dir / "dem_diff_2m.npy", resid)
    meta = {k: cfg.get(k) for k in ("name", "team", "citation", "url", "trek_layer") if cfg.get(k)}
    meta.update({k: v for k, v in reg.items() if k not in ("drow", "dcol")})
    meta["shift_m"] = round(math.hypot(reg["dx_m"], reg["dy_m"]), 2)
    log.info("team DEM %s: shift dx %.2f m dy %.2f m, dz %.2f m, tilt %s m/km, residual rms %.2f m (p95 %.2f), peak %.2f",
             cfg.get("name"), reg["dx_m"], reg["dy_m"], reg["dz_m"], reg["tilt_m_per_km"], reg["rms_m"], reg["p95_m"], reg["peak"])
    return meta
