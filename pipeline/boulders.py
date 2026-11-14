"""Boulder map from HiRISE shadows (own algorithm, no ML).

1. Read the controlled HiRISE orthoimage that comes with the site's DTM (so it lines up with the
   terrain) at 0.5 m from its COG overview.
2. Fit the sun direction from the data: shade the DTM for candidate sun positions and keep the one
   whose shading correlates best with the image brightness. (Catalog sun angles for HiRISE are
   measured from the image's 3 o'clock direction and easy to misread; the fit needs no metadata.)
3. Shadows of boulders are compact patches much darker than their surroundings, elongated along
   the shadow direction, with the boulder itself (not dark) on their sun-ward end.
4. Size each boulder from its shadow: width across the shadow ~ diameter, length along it times
   tan(sun elevation) ~ height.

Only boulders >= ~0.75 m are reliable at 0.5 m/px; smaller stones are below what orbit can see.
"""

from __future__ import annotations

import logging
import math

import numpy as np
import rasterio
from rasterio.warp import Resampling, reproject, transform_bounds
from rasterio.windows import Window
from scipy import ndimage

from marsgeo.grid import SiteGrid
from marsgeo.net import gdal_http_env

from . import derive
from .terrain import _crs

log = logging.getLogger(__name__)

PIX = 0.5  # m: working resolution (first COG overview of a 25 cm orthoimage)


def half_metre_grid(g1: SiteGrid) -> SiteGrid:
    return SiteGrid(g1.lon0, g1.lat0, g1.x_min, g1.y_max, PIX, int(round(g1.width * g1.res / PIX)),
                    int(round(g1.height * g1.res / PIX)))


def read_ortho(href: str, grid: SiteGrid, overview_level: int = 0) -> np.ndarray:
    """Warp the orthoimage (one overview level down) onto grid. NaN = no data."""
    path = href if not href.startswith("http") else "/vsicurl/" + href
    out = np.full((grid.height, grid.width), np.nan, np.float32)
    with rasterio.Env(**gdal_http_env()):
        with rasterio.open(path, OVERVIEW_LEVEL=overview_level) as src:
            l, b, r, t = transform_bounds(_crs(grid), src.crs, *grid.bounds_xy, densify_pts=21)
            win = src.window(l, b, r, t)
            c0 = max(0, int(np.floor(win.col_off)) - 4)
            r0 = max(0, int(np.floor(win.row_off)) - 4)
            c1 = min(src.width, int(np.ceil(win.col_off + win.width)) + 4)
            r1 = min(src.height, int(np.ceil(win.row_off + win.height)) + 4)
            if c1 <= c0 or r1 <= r0:
                return out
            w = Window(c0, r0, c1 - c0, r1 - r0)
            data = src.read(1, window=w).astype(np.float32)
            data[data <= 0] = np.nan
            reproject(data, out, src_transform=src.window_transform(w), src_crs=src.crs, src_nodata=np.nan,
                      dst_transform=grid.transform, dst_crs=_crs(grid), dst_nodata=np.nan, resampling=Resampling.bilinear)
    return out


def _block_mean(a: np.ndarray, k: int) -> np.ndarray:
    h, w = (a.shape[0] // k) * k, (a.shape[1] // k) * k
    return np.nanmean(a[:h, :w].reshape(h // k, k, w // k, k), axis=(1, 3))


def fit_sun(img: np.ndarray, z: np.ndarray, z_res: float) -> tuple[float, float, float]:
    """(azimuth from north clockwise, elevation, correlation) that best explains the image's shading."""
    k = int(round(4.0 / PIX))
    im4 = _block_mean(img, k)
    zk = int(round(4.0 / z_res))
    z4 = _block_mean(z, zk) if zk > 1 else z
    h, w = min(im4.shape[0], z4.shape[0]), min(im4.shape[1], z4.shape[1])
    im4, z4 = im4[:h, :w], z4[:h, :w]
    ok = np.isfinite(im4) & np.isfinite(z4)
    if ok.sum() < 1000:
        return 270.0, 45.0, 0.0
    a = im4[ok] - im4[ok].mean()

    def score(az, el):
        hs = derive.hillshade(np.nan_to_num(z4, nan=float(np.nanmean(z4))), 4.0, az, el)[ok]
        b = hs - hs.mean()
        return float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum() + 1e-12))

    best = max(((score(az, el), az, el) for el in range(10, 85, 5) for az in range(0, 360, 10)))
    _, az0, el0 = best
    best = max(((score(az % 360, el), az % 360, el) for el in range(max(5, el0 - 5), min(86, el0 + 6))
                for az in range(az0 - 9, az0 + 10, 1)))
    return float(best[1]), float(best[2]), float(best[0])


def detect(img: np.ndarray, sun_az: float, sun_el: float, dark_thresh: float = 0.30) -> list[dict]:
    """Boulders as dicts with fractional row/col on the 0.5 m grid, diameter_m and height_m."""
    valid = np.isfinite(img)
    fill = np.where(valid, img, np.nanmedian(img))
    bg = ndimage.gaussian_filter(fill, 12.0)
    c = fill / np.maximum(bg, 1e-3) - 1.0
    # context: mean contrast over ~10 m. Wide dark bands (sand, ridge-shadow strips) are not boulder fields.
    context = ndimage.uniform_filter(c, 21)
    bright = ndimage.maximum_filter(c, 3)
    dark = (c < -dark_thresh) & valid
    lab, n = ndimage.label(dark, structure=np.ones((3, 3), bool))
    if n == 0:
        return []
    objs = ndimage.find_objects(lab)
    # unit vector of the shadow in image coordinates (col to the east, row to the south)
    s = math.radians(sun_az + 180.0)
    sx, sy = math.sin(s), -math.cos(s)
    tan_el = math.tan(math.radians(max(5.0, sun_el)))
    H, W = img.shape
    out = []
    for i, sl in enumerate(objs):
        if sl is None:
            continue
        hh, ww = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
        if max(hh, ww) > 16 or hh * ww < 3:
            continue
        sub = lab[sl] == i + 1
        area = int(sub.sum())
        if area < 3 or area > 90:
            continue
        rr, cc = np.nonzero(sub)
        rr = rr + sl[0].start
        cc = cc + sl[1].start
        cy, cx = rr.mean(), cc.mean()
        if context[int(round(cy)), int(round(cx))] < -0.10:
            continue                       # inside a wide dark band
        along = (cc - cx) * sx + (rr - cy) * sy
        across = -(cc - cx) * sy + (rr - cy) * sx
        length = float(along.max() - along.min() + 1.0)
        width = float(across.max() - across.min() + 1.0)
        if length / width > 4.0 or area / (length * width) < 0.45:
            continue                       # thin lines and ragged patches are fractures or sand, not boulder shadows
        # the boulder sits on the sun-ward end of its shadow, and its sunlit face is bright
        back = float(along.min()) - width * 0.5
        bx, by = cx + back * sx, cy + back * sy
        ix, iy = int(round(bx)), int(round(by))
        if not (0 <= ix < W and 0 <= iy < H) or bright[iy, ix] < 0.03:
            continue
        diameter = width * PIX
        if diameter < 0.75 or diameter > 4.0:
            continue
        out.append({"row": by, "col": bx, "diameter_m": round(diameter, 2),
                    "height_m": round(length * PIX * tan_el, 2), "contrast": round(float(c[rr, cc].mean()), 3)})
    return out


def build(ortho_href: str, g1: SiteGrid, g2: SiteGrid, z1: np.ndarray) -> dict:
    gh = half_metre_grid(g1)
    log.info("boulders: reading orthoimage at %.1f m (%d x %d)", PIX, gh.width, gh.height)
    img = read_ortho(ortho_href, gh)
    cover = float(np.isfinite(img).mean())
    az, el, r = fit_sun(img, z1, g1.res)
    log.info("boulders: fitted sun azimuth %.0f deg, elevation %.0f deg (r = %.2f), image covers %.0f %%", az, el, r, cover * 100)
    found = detect(img, az, el)
    x, y = gh.rowcol_to_xy(np.array([b["row"] for b in found]), np.array([b["col"] for b in found])) if found else (np.array([]), np.array([]))
    boulders = [{"x": round(float(xx), 2), "y": round(float(yy), 2), "d": b["diameter_m"], "h": b["height_m"]}
                for xx, yy, b in zip(np.atleast_1d(x), np.atleast_1d(y), found)]
    # 2 m cost grid: largest boulder whose footprint touches each cell
    big = np.zeros((g2.height, g2.width), np.float32)
    for b in boulders:
        r2, c2 = g2.xy_to_rowcol(b["x"], b["y"])
        rad = int(math.ceil((b["d"] * 0.5 + 0.5) / g2.res))
        r0, c0 = int(round(float(r2))), int(round(float(c2)))
        rs, re_ = max(0, r0 - rad), min(g2.height, r0 + rad + 1)
        cs, ce = max(0, c0 - rad), min(g2.width, c0 + rad + 1)
        if rs < re_ and cs < ce:
            big[rs:re_, cs:ce] = np.maximum(big[rs:re_, cs:ce], b["d"])
    d = np.array([b["d"] for b in boulders]) if boulders else np.zeros(0)
    stats = {"count": len(boulders), "sun_fit": {"azimuth": az, "elevation": el, "r": round(r, 3)}, "image_coverage": round(cover, 3),
             "ge_1m": int((d >= 1.0).sum()), "ge_2m": int((d >= 2.0).sum()),
             "density_per_ha": round(len(boulders) / (g1.width * g1.res * g1.height * g1.res / 1e4), 2)}
    return {"boulders": boulders, "grid2": big, "stats": stats}
