"""Radio line-of-sight ("dead zones") from the habitat mast and any relays.

Vectorised ray casting: a ray from the antenna to every cell on the grid's
edge; along each ray we keep the running maximum of the terrain's elevation
angle. A suit antenna at a cell is in line of sight if it rises above every
earlier terrain point on the ray. Mars curvature (d^2 / 2R) is included;
at 3 km it hides ~1.3 m.

Result per cell: 2 = clear line of sight, 1 = marginal (blocked by < margin_m,
so diffraction may still carry a weak signal), 0 = dead zone.
"""

from __future__ import annotations

import time

import numpy as np

from marsgeo.constants import MARS_RADIUS_M


def viewshed(z: np.ndarray, res: float, obs_rc, obs_height: float, target_height: float,
             margin_m: float = 1.5, chunk: int = 256) -> np.ndarray:
    H, W = z.shape
    r0, c0 = obs_rc
    z0 = float(z[r0, c0]) + obs_height
    per = np.concatenate([
        np.stack([np.zeros(W, int), np.arange(W)], 1),
        np.stack([np.full(W, H - 1), np.arange(W)], 1),
        np.stack([np.arange(H), np.zeros(H, int)], 1),
        np.stack([np.arange(H), np.full(H, W - 1)], 1),
    ])
    clear = np.zeros((H, W), bool)
    marginal = np.zeros((H, W), bool)
    for k in range(0, len(per), chunk):
        p = per[k:k + chunk]
        dr = (p[:, 0] - r0).astype(float)
        dc = (p[:, 1] - c0).astype(float)
        L = np.maximum(np.abs(dr), np.abs(dc))
        L[L == 0] = 1
        T = int(L.max())
        t = np.arange(1, T + 1, dtype=float)
        frac = t[None, :] / L[:, None]
        valid = frac <= 1.0
        rr = r0 + frac * dr[:, None]
        cc = c0 + frac * dc[:, None]
        ri = np.clip(np.rint(rr).astype(int), 0, H - 1)
        ci = np.clip(np.rint(cc).astype(int), 0, W - 1)
        dist = res * np.hypot(rr - r0, cc - c0)
        zt = z[ri, ci] - dist * dist / (2 * MARS_RADIUS_M)
        ang_ground = np.where(valid, (zt - z0) / dist, -np.inf)
        run = np.maximum.accumulate(ang_ground, axis=1)
        prev = np.concatenate([np.full((len(p), 1), -np.inf), run[:, :-1]], axis=1)
        clearance = (zt + target_height - z0) / dist - prev  # angle units
        clearance_m = clearance * dist
        v = valid & (clearance_m >= 0)
        mg = valid & (clearance_m >= -margin_m)
        clear[ri[v], ci[v]] = True
        marginal[ri[mg], ci[mg]] = True
    out = np.where(clear, 2, np.where(marginal, 1, 0)).astype(np.uint8)
    out[r0, c0] = 2
    return out


def combined(z: np.ndarray, grid, observers, target_height: float) -> dict:
    """Union of several antennas. observers = [(lon, lat, height_m), ...]."""
    t0 = time.perf_counter()
    best = np.zeros(z.shape, np.uint8)
    H, W = z.shape
    for lon, lat, h in observers:
        r, c = (int(round(v)) for v in grid.lonlat_to_rowcol(lon, lat))
        if not (0 <= r < H and 0 <= c < W):
            continue
        best = np.maximum(best, viewshed(z, grid.res, (r, c), h, target_height))
    return {
        "grid": best,
        "clear_fraction": float((best == 2).mean()),
        "marginal_fraction": float((best == 1).mean()),
        "dead_fraction": float((best == 0).mean()),
        "compute_ms": (time.perf_counter() - t0) * 1000,
    }
