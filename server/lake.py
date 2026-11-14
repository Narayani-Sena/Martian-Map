"""Flood the crater (feature A4): the ancient lake as a water surface at a chosen level.

Jezero's sample mudstones are there because a lake was: the map shows the hypothesis the samples are meant to
test. Levels for Jezero come from Mangold et al. (LPSC 2024, NTRS 20240000546): the delta-front deposits record a
lake falling from about -2,410 m (fan top, north of Belva crater) to -2,500 m (Kodiak, Eastern Cape) as it dried in
a closed basin below the eastern breach (about -2,400 m). Other sites have no level in the config: the slider is
then a what-if.
"""

from __future__ import annotations

import numpy as np

from .tiles import _hex, lut

DEPTH_LUT = lut([(0.0, _hex("7fe3e0", 110)), (0.08, _hex("3fb8d9", 150)), (0.3, _hex("1f6fb5", 185)), (1.0, _hex("0b2a6b", 215))])
DEPTH_MAX_M = 120.0


def water_rgba(z: np.ndarray, level: float) -> np.ndarray:
    """RGBA (uint8) of the water over a height grid: colour by depth, a bright shoreline, dry ground clear."""
    depth = level - z
    idx = np.clip(depth / DEPTH_MAX_M * 255.0, 0, 255).astype(np.uint8)
    rgba = DEPTH_LUT[idx].copy()
    rgba[depth <= 0] = 0
    shore = np.abs(depth) < 0.6
    rgba[shore] = (240, 252, 255, 235)
    rgba[~np.isfinite(z)] = 0
    return rgba


def stats(site, level: float, points: list[dict]) -> dict:
    z = site.z2
    wet = z < level
    out = {"level": level, "share_under": round(float(wet.mean()), 3), "elev_min": round(float(np.nanmin(z)), 1),
           "elev_max": round(float(np.nanmax(z)), 1), "max_depth_m": round(float(max(0.0, level - np.nanmin(z))), 1), "points": []}
    for p in points:
        e = float(site.sample(p["lon"], p["lat"])["elev"])
        out["points"].append({"name": p.get("name", ""), "elev": round(e, 1), "depth_m": round(level - e, 1)})
    return out


def mask(site, level: float, dilate: int = 2) -> np.ndarray | None:
    """Where a lake at `level` m stands on the 200 m regional DEM, as one body of water: the cells below the level
    that join the water over the site. A low plain outside the crater rim is not part of it (east of Jezero the
    Isidis lowlands lie far below -2,500 m). The site's own footprint is always allowed: the 3D view draws the
    shoreline there from the 1 m terrain. Widened by `dilate` cells so the coarse mask never cuts that shoreline.
    uint8, 255 = water, row 0 = north edge; None without a regional DEM."""
    from scipy import ndimage

    arr, rg = site.regional
    if arr is None:
        return None
    z = arr.astype(np.float32) + float(site.meta.get("regional_offset_m", 0.0))
    lab, _ = ndimage.label(np.isfinite(z) & (z < level))   # 4-connected: no leaks through diagonal gaps in a rim
    g = site.grid
    c0 = max(0, int(np.floor((g.x_min - rg.x_min) / rg.res)))
    c1 = min(rg.width, int(np.ceil((g.x_min + g.width * g.res - rg.x_min) / rg.res)))
    r0 = max(0, int(np.floor((rg.y_max - g.y_max) / rg.res)))
    r1 = min(rg.height, int(np.ceil((rg.y_max - g.y_max + g.height * g.res) / rg.res)))
    ids = np.unique(lab[r0:r1, c0:c1])
    m = np.isin(lab, ids[ids > 0])
    if dilate and m.any():
        m = ndimage.binary_dilation(m, iterations=dilate)
    m[r0:r1, c0:c1] = True
    return m.astype(np.uint8) * 255


LEGEND = {"unit": "metres of water", "stops": [[0, "#7fe3e0"], [10, "#3fb8d9"], [36, "#1f6fb5"], [120, "#0b2a6b"]]}
