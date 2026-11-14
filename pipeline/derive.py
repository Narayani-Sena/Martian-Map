"""Terrain derivatives written from scratch with numpy.

Everything here is a few lines of array math, so you can see exactly what
"slope" or "hillshade" means. tests/test_derive.py checks the results on
synthetic surfaces where the right answer is known.

Array convention: row 0 is north, so +row points south.
"""

from __future__ import annotations

import numpy as np
from scipy import ndimage


def horn_gradient(z: np.ndarray, res: float):
    """Horn (1981) 3x3 gradient. Returns (dz/dx east, dz/dy north) in m/m."""
    zp = np.pad(z, 1, mode="edge")
    a, b, c = zp[:-2, :-2], zp[:-2, 1:-1], zp[:-2, 2:]
    d, f = zp[1:-1, :-2], zp[1:-1, 2:]
    g, h, i = zp[2:, :-2], zp[2:, 1:-1], zp[2:, 2:]
    dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) / (8.0 * res)
    dz_south = ((g + 2 * h + i) - (a + 2 * b + c)) / (8.0 * res)
    return dzdx, -dz_south


def slope_deg(z: np.ndarray, res: float) -> np.ndarray:
    gx, gy = horn_gradient(z, res)
    return np.degrees(np.arctan(np.hypot(gx, gy))).astype(np.float32)


def aspect_deg(z: np.ndarray, res: float) -> np.ndarray:
    """Direction the slope faces (downhill), degrees clockwise from north."""
    gx, gy = horn_gradient(z, res)
    return (np.degrees(np.arctan2(-gx, -gy)) % 360.0).astype(np.float32)


def hillshade(z: np.ndarray, res: float, azimuth: float = 315.0, altitude: float = 45.0,
              z_factor: float = 1.0) -> np.ndarray:
    """Lambertian shading 0..1: dot product of the surface normal and the sun vector."""
    gx, gy = horn_gradient(z * z_factor, res)
    norm = np.sqrt(gx * gx + gy * gy + 1.0)
    az, alt = np.radians(azimuth), np.radians(altitude)
    sx, sy, sz = np.sin(az) * np.cos(alt), np.cos(az) * np.cos(alt), np.sin(alt)
    shade = (-gx * sx - gy * sy + sz) / norm
    return np.clip(shade, 0.0, 1.0).astype(np.float32)


def multidirectional_hillshade(z: np.ndarray, res: float, z_factor: float = 1.0) -> np.ndarray:
    """Blend of four sun azimuths (like gdaldem -multidirectional) for a softer relief look."""
    out = np.zeros(z.shape, np.float32)
    for az, w in ((225, 0.20), (270, 0.25), (315, 0.35), (360, 0.20)):
        out += w * hillshade(z, res, az, 45.0, z_factor)
    return out


def normal_map(z: np.ndarray, res: float, strength: float = 1.0) -> np.ndarray:
    """Tangent-space normal map (H, W, 3) uint8 for the 3D view (x=east, y=north, z=up)."""
    gx, gy = horn_gradient(z, res)
    nx, ny, nz = -gx * strength, -gy * strength, np.ones_like(gx)
    n = np.sqrt(nx * nx + ny * ny + nz * nz)
    rgb = np.stack([nx / n, ny / n, nz / n], axis=-1)
    return np.clip((rgb * 0.5 + 0.5) * 255.0 + 0.5, 0, 255).astype(np.uint8)


def roughness(z: np.ndarray, res: float, window_m: float = 5.0) -> np.ndarray:
    """RMS height (m) left over after fitting a plane to every window_m x window_m patch.

    A tilted plane scores 0 and a smooth bowl or dome scores almost 0 (curvature is
    tiny over 5 m), while steps, ledges and blocks score high - which is what makes
    ground hard to walk on. Done with box filters: for a window,
        residual variance = var(z) - cov(z,x)^2/var(x) - cov(z,y)^2/var(y)
    """
    k = max(3, int(round(window_m / res)) | 1)
    zc = z.astype(np.float64) - float(np.nanmean(z))
    h, w = zc.shape
    X = (np.arange(w, dtype=np.float64) - w / 2)[None, :] * res
    Y = (np.arange(h, dtype=np.float64) - h / 2)[:, None] * res

    def U(a):
        return ndimage.uniform_filter(a, size=k, mode="nearest")

    mz = U(zc)
    cov_x = U(zc * X) - mz * X
    cov_y = U(zc * Y) - mz * Y
    var_xy = res * res * (k * k - 1) / 12.0
    resid = U(zc * zc) - mz * mz - (cov_x * cov_x + cov_y * cov_y) / var_xy
    return np.sqrt(np.clip(resid, 0.0, None)).astype(np.float32)


def tpi(z: np.ndarray, res: float, radius_m: float) -> np.ndarray:
    """Topographic Position Index: height above the local mean (+ ridge, - hollow)."""
    size = max(3, int(round(2 * radius_m / res)) | 1)
    return (z - ndimage.uniform_filter(z, size=size, mode="nearest")).astype(np.float32)


def block_reduce(a: np.ndarray, factor: int, func: str = "mean") -> np.ndarray:
    h, w = (a.shape[0] // factor) * factor, (a.shape[1] // factor) * factor
    v = a[:h, :w].reshape(h // factor, factor, w // factor, factor)
    if func == "mean":
        return np.nanmean(v, axis=(1, 3)).astype(a.dtype)
    if func == "max":
        return np.nanmax(v, axis=(1, 3)).astype(a.dtype)
    if func == "min":
        return np.nanmin(v, axis=(1, 3)).astype(a.dtype)
    raise ValueError(func)


def fill_nodata(z: np.ndarray, max_iter: int = 200) -> np.ndarray:
    """Fill NaN holes: nearest valid value, then smooth only inside the holes."""
    z = z.astype(np.float32, copy=True)
    holes = ~np.isfinite(z)
    if not holes.any():
        return z
    if holes.all():
        raise ValueError("no valid elevations to fill from")
    idx = ndimage.distance_transform_edt(holes, return_distances=False, return_indices=True)
    z = z[tuple(idx)]
    for _ in range(max_iter // 10):
        sm = ndimage.uniform_filter(z, size=5, mode="nearest")
        z[holes] = sm[holes]
    return z


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))
