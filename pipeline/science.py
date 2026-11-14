"""Where a field geologist would want to stop: a 0..1 science-opportunity score on the 2 m grid, with its parts.

Clues (each 0..1), combined like independent reasons ("noisy OR": any strong reason makes a place interesting),
then scaled down where loose sand hides the rock:

    mineral   CRISM signal in the top part of the site's range: hydrated minerals and sulfates, clays (water-made,
              best for habitability and organics), iron oxides, mafic minerals (mostly sand, least interesting)
    contact   near a boundary between two USGS map units: one stop samples both sides and the story between them
    relief    a ridge crest or hollow floor (TPI, 15 m radius), stronger where ridges and hollows alternate
              (Gale's boxwork: mineral-cemented ridges, softer hollows)
    sample    near a rover sample site (Jezero): compare with what Perseverance cored
    track     on the rover's track: its close-up images exist for comparison
    exposure  1 - 0.7 x sand likelihood: a stop needs rock you can hammer

score = (1 - prod(1 - w_i c_i)) * exposure, weights below. The server picks suggested stops from this score
inside the safe walk-back range and explains each one from the parts.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from marsgeo.grid import SiteGrid

log = logging.getLogger("pipeline.science")

KINDS = ("hyd", "phy", "fem", "maf")
MINERAL_WEIGHT = {"hyd": 1.0, "phy": 1.0, "fem": 0.6, "maf": 0.25}
WEIGHTS = {"mineral": 0.85, "contact": 0.6, "relief": 0.55, "sample": 0.6, "track": 0.25}
CONTACT_M = 40.0
SAMPLE_M = 30.0
TRACK_M = 15.0


def _up(a: np.ndarray, shape) -> np.ndarray:
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize((shape[1], shape[0]), Image.BILINEAR), np.float32)


def mineral(site_dir: Path, shape) -> tuple[np.ndarray, np.ndarray]:
    """(clue 0..1, dominant kind index into KINDS, 255 = none) from the CRISM composites.

    A composite's alpha is 0 without data, 35 for typical pixels and up to 255 for the site's strongest signals
    (pipeline/crism.py), so (alpha - 35) / 220 is the signal relative to the rest of the site.
    """
    best = np.zeros(shape, np.float32)
    kind = np.full(shape, 255, np.uint8)
    for i, k in enumerate(KINDS):
        p = site_dir / f"crism_{k}.png"
        if not p.exists():
            continue
        a = np.asarray(Image.open(p).convert("RGBA"))[..., 3].astype(np.float32)
        # only the upper half of the site's own stretch counts: the top ~2 % of the site scores 1
        rel = np.where(a > 0, np.clip(((a - 35.0) / 220.0 - 0.5) / 0.5, 0.0, 1.0), 0.0)
        v = _up(rel, shape) * MINERAL_WEIGHT[k]
        better = v > best
        best = np.where(better, v, best)
        kind = np.where(better & (v > 0.05), i, kind).astype(np.uint8)
    return best, kind


def contact(geology: np.ndarray | None, res: float, min_share: float = 0.01) -> np.ndarray:
    """exp(-distance to the nearest boundary between two mapped units / CONTACT_M); zero for a one-unit site."""
    if geology is None:
        return None
    units, counts = np.unique(geology[geology > 0], return_counts=True)
    if (counts / geology.size >= min_share).sum() < 2:
        return np.zeros(geology.shape, np.float32)
    g = geology.astype(np.int16)
    edge = np.zeros(g.shape, bool)
    edge[:, 1:] |= (g[:, 1:] != g[:, :-1]) & (g[:, 1:] > 0) & (g[:, :-1] > 0)
    edge[1:, :] |= (g[1:, :] != g[:-1, :]) & (g[1:, :] > 0) & (g[:-1, :] > 0)
    if not edge.any():
        return np.zeros(g.shape, np.float32)
    d = ndimage.distance_transform_edt(~edge) * res
    return np.exp(-d / CONTACT_M).astype(np.float32)


def relief(tpi: np.ndarray, window_px: int = 31) -> tuple[np.ndarray, np.ndarray]:
    """(clue 0..1, sign: +1 ridge crest, -1 hollow floor, 0 neither)."""
    ridge = np.clip((tpi - 0.4) / 0.8, 0.0, 1.0)
    hollow = np.clip((-tpi - 0.4) / 0.8, 0.0, 1.0)
    m = ndimage.uniform_filter(tpi, window_px)
    sd = np.sqrt(np.clip(ndimage.uniform_filter(tpi * tpi, window_px) - m * m, 0.0, None))
    lo, hi = np.percentile(sd, [50, 95])
    tex = np.clip((sd - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    clue = np.maximum(ridge, hollow) * (0.4 + 0.6 * tex)
    sign = np.where(ridge >= hollow, 1, -1) * (np.maximum(ridge, hollow) > 0.05)
    return clue.astype(np.float32), sign.astype(np.int8)


def proximity(points_lonlat: list[tuple[float, float]], grid: SiteGrid, scale_m: float) -> np.ndarray:
    """exp(-distance to the nearest point / scale) on the grid."""
    out = np.zeros((grid.height, grid.width), bool)
    for lon, lat in points_lonlat:
        r, c = (int(round(float(v))) for v in grid.lonlat_to_rowcol(lon, lat))
        if 0 <= r < grid.height and 0 <= c < grid.width:
            out[r, c] = True
    if not out.any():
        return np.zeros(out.shape, np.float32)
    d = ndimage.distance_transform_edt(~out) * grid.res
    return np.exp(-d / scale_m).astype(np.float32)


def _geojson_points(p: Path) -> list[tuple[float, float]]:
    if not p.exists():
        return []
    fc = json.loads(p.read_text(encoding="utf-8"))
    out = []
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") == "Point":
            out.append(tuple(g["coordinates"][:2]))
        elif g.get("type") == "LineString":
            out.extend(tuple(c[:2]) for c in g["coordinates"])
        elif g.get("type") == "MultiLineString":
            out.extend(tuple(c[:2]) for part in g["coordinates"] for c in part)
    return out


def _densify(pts: list[tuple[float, float]], grid: SiteGrid, step_m: float = 2.0) -> list[tuple[float, float]]:
    """Points every step_m along a polyline given as consecutive points (tracks are stored sparsely)."""
    if len(pts) < 2:
        return pts
    out = []
    xy = np.column_stack(grid.lonlat_to_xy(np.array([p[0] for p in pts]), np.array([p[1] for p in pts])))
    for (x0, y0), (x1, y1) in zip(xy[:-1], xy[1:]):
        n = max(1, int(np.hypot(x1 - x0, y1 - y0) / step_m))
        if n > 400:  # a jump between separate line parts: don't draw across it
            continue
        for t in np.linspace(0, 1, n, endpoint=False):
            out.append(tuple(float(v) for v in grid.xy_to_lonlat(x0 + t * (x1 - x0), y0 + t * (y1 - y0))))
    return out


def build(site_dir: Path, grid2: SiteGrid, tpi: np.ndarray, sand: np.ndarray, geology: np.ndarray | None) -> dict:
    shape = tpi.shape
    parts = {}
    parts["mineral"], kind = mineral(site_dir, shape)
    c = contact(geology, grid2.res)
    parts["contact"] = c if c is not None else np.zeros(shape, np.float32)
    parts["relief"], sign = relief(tpi)
    parts["sample"] = proximity(_geojson_points(site_dir / "extra_samples.geojson"), grid2, SAMPLE_M)
    parts["track"] = proximity(_densify(_geojson_points(site_dir / "rover_traverse.geojson"), grid2), grid2, TRACK_M)
    keep = np.ones(shape, np.float32)
    for k, v in parts.items():
        keep *= 1.0 - WEIGHTS[k] * v
    exposure = 1.0 - 0.7 * np.clip(sand, 0.0, 1.0)
    score = (1.0 - keep) * exposure
    np.savez_compressed(site_dir / "science_2m.npz", score=score.astype(np.float16),
                        **{k: v.astype(np.float16) for k, v in parts.items()},
                        mineral_kind=kind, relief_sign=sign, exposure=exposure.astype(np.float16))
    stats = {k: round(float((v > 0.5).mean()), 4) for k, v in parts.items()}
    meta = {"weights": WEIGHTS, "mineral_weight": MINERAL_WEIGHT, "kinds": list(KINDS),
            "share_over_half": stats, "score_p50_p95_p99": [round(float(v), 3) for v in np.percentile(score, [50, 95, 99])]}
    log.info("science: parts over 0.5 %s, score p50/p95/p99 %s", stats, meta["score_p50_p95_p99"])
    return meta
