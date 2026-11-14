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


LEGEND = {"unit": "metres of water", "stops": [[0, "#7fe3e0"], [10, "#3fb8d9"], [36, "#1f6fb5"], [120, "#0b2a6b"]]}
