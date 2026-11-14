"""Horizon angles and terrain radiation shielding.

Galactic cosmic rays reach the surface from the whole sky. Terrain that rises
above the horizon blocks part of it. Curiosity's RAD measured ~4-5 % less dose
beside a butte (Rafkin et al.); a 2026 study modelled up to ~19 % in confined
spots. We model the flux per unit solid angle as I(theta) ~ cos^n(theta) (zenith
angle theta; the atmosphere is thicker towards the horizon). Integrating, the
fraction of dose blocked by a horizon at elevation h in one azimuth slice is
sin^(n+1)(h); averaging over azimuths gives the shielded fraction.

Near field (< ~1 km) uses the HiRISE DTM; far field (1-45 km, e.g. Mount
Sharp) uses the 200 m HRSC-MOLA blend.
"""

from __future__ import annotations

import math

import numpy as np

from marsgeo.constants import MARS_RADIUS_M
from marsgeo.grid import SiteGrid, sample_bilinear


def _distances(res: float, max_dist: float, fine_until: float = 120.0, growth: float = 1.035):
    d, out = res, []
    while d <= max_dist:
        out.append(d)
        d = d + res if d < fine_until else d * growth
    return out


def near_field_tan_horizon(ext_dem: np.ndarray, margin_px: int, site_shape, res: float,
                           n_az: int = 24, max_dist: float = 1000.0, observer_height: float = 1.0) -> np.ndarray:
    """tan(horizon elevation) for each azimuth, shape (n_az, H, W), from a DEM with a margin.

    ext_dem covers the site plus margin_px cells on every side (same resolution).
    For every azimuth we march outwards in steps, comparing a shifted copy of the
    DEM with the original - fully vectorised, no per-pixel Python loops.
    observer_height: the dose that matters is at an astronaut's chest, so we look
    from ~1 m above the ground (sub-metre bumps a few metres away don't count).
    """
    H, W = site_shape
    z0 = ext_dem[margin_px:margin_px + H, margin_px:margin_px + W] + observer_height
    out = np.zeros((n_az, H, W), np.float32)
    dists = _distances(res, max_dist)
    for k in range(n_az):
        az = 2 * math.pi * k / n_az
        best = np.full((H, W), -np.inf, np.float32)
        seen = set()
        for d in dists:
            dr = int(round(-d * math.cos(az) / res))
            dc = int(round(d * math.sin(az) / res))
            if (dr, dc) in seen or (dr == 0 and dc == 0):
                continue
            seen.add((dr, dc))
            if abs(dr) > margin_px or abs(dc) > margin_px:
                break
            dd = res * math.hypot(dr, dc)
            drop = dd * dd / (2 * MARS_RADIUS_M)  # planet curvature
            shifted = ext_dem[margin_px + dr:margin_px + dr + H, margin_px + dc:margin_px + dc + W]
            np.maximum(best, (shifted - z0 - drop) * (1.0 / dd), out=best)
        out[k] = best
    return out


def far_field_tan_horizon(regional: np.ndarray, regional_grid: SiteGrid, site_grid: SiteGrid,
                          site_z: np.ndarray, n_az: int = 24, min_dist: float = 1000.0,
                          max_dist: float = 45000.0, step: float = 150.0, n_pts: int = 9,
                          observer_height: float = 1.0) -> np.ndarray:
    """Far-field horizon on a coarse n_pts x n_pts lattice, interpolated to the site grid."""
    H, W = site_z.shape
    rows = np.linspace(0, H - 1, n_pts)
    cols = np.linspace(0, W - 1, n_pts)
    rr, cc = np.meshgrid(rows, cols, indexing="ij")
    px, py = site_grid.rowcol_to_xy(rr, cc)
    pz = sample_bilinear(site_z, rr, cc) + observer_height
    dists = np.arange(min_dist, max_dist, step)
    lattice = np.zeros((n_az, n_pts, n_pts), np.float32)
    for k in range(n_az):
        az = 2 * math.pi * k / n_az
        sx = px[..., None] + np.sin(az) * dists
        sy = py[..., None] + np.cos(az) * dists
        r2, c2 = regional_grid.xy_to_rowcol(sx, sy)
        zz = sample_bilinear(regional, r2, c2, fill=-1e9)
        tan = (zz - pz[..., None] - dists ** 2 / (2 * MARS_RADIUS_M)) / dists
        lattice[k] = np.max(tan, axis=-1)
    # bilinear interpolation of the lattice up to the full grid
    fr = np.linspace(0, n_pts - 1, H)
    fc = np.linspace(0, n_pts - 1, W)
    FR, FC = np.meshgrid(fr, fc, indexing="ij")
    out = np.empty((n_az, H, W), np.float32)
    for k in range(n_az):
        out[k] = sample_bilinear(lattice[k], FR, FC)
    return out


def shielded_fraction(tan_h: np.ndarray, n: float = 1.0) -> np.ndarray:
    """Fraction (0..1) of sky dose blocked by terrain, averaged over azimuths."""
    h = np.arctan(np.clip(tan_h, 0.0, None))
    return np.mean(np.sin(h) ** (n + 1.0), axis=0).astype(np.float32)


def sky_view_factor(tan_h: np.ndarray) -> np.ndarray:
    """Classic sky-view factor (fraction of the visible sky hemisphere, cos^2 weighting)."""
    h = np.arctan(np.clip(tan_h, 0.0, None))
    return np.mean(np.cos(h) ** 2, axis=0).astype(np.float32)
