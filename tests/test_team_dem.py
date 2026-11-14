"""Co-registration of two terrain models (pipeline/team_dem.py) on synthetic terrain with a known offset."""

import numpy as np
from scipy import ndimage

from marsgeo.grid import SiteGrid, sample_bilinear
from pipeline import team_dem


def _terrain(n=320, seed=3):
    rng = np.random.default_rng(seed)
    z = ndimage.gaussian_filter(rng.normal(size=(n, n)), 3.0) * 40.0
    z += ndimage.gaussian_filter(rng.normal(size=(n, n)), 12.0) * 120.0
    yy, xx = np.mgrid[0:n, 0:n]
    return (z + 0.05 * xx - 0.02 * yy).astype(np.float32)


def _team_view(z, drow, dcol, dz, tilt=(0.0, 0.0), res=2.0):
    """What a team product would show: every feature moved by +d, heights offset by -dz (and a tilt)."""
    h, w = z.shape
    rr, cc = np.meshgrid(np.arange(h, dtype=float), np.arange(w, dtype=float), indexing="ij")
    out = np.asarray(sample_bilinear(z, rr - drow, cc - dcol), np.float32)
    xk = (cc - (w - 1) / 2) * res / 1000.0
    yk = -(rr - (h - 1) / 2) * res / 1000.0
    return out - (dz + tilt[0] * xk + tilt[1] * yk)


def test_phase_correlation_finds_a_subpixel_shift():
    z = _terrain()
    b = _team_view(z, 3.4, -5.7, 0.0)
    dr, dc, peak = team_dem.phase_correlation(z[40:280, 40:280], b[40:280, 40:280])
    assert abs(dr - 3.4) < 0.3 and abs(dc + 5.7) < 0.3
    assert peak > 0.1


def test_coregister_recovers_shift_height_and_tilt():
    z = _terrain()
    b = _team_view(z, -2.3, 4.1, 12.3, tilt=(0.8, -0.5))
    r = team_dem.coregister(z, b, res=2.0, crop=256)
    # team shows a feature at p + d: d = (+4.1 cells east, +2.3 cells north) = (8.2 m, 4.6 m)
    assert abs(r["dx_m"] - 8.2) < 0.25 and abs(r["dy_m"] - 4.6) < 0.25
    assert abs(r["dz_m"] - 12.3) < 0.15
    assert abs(r["tilt_m_per_km"][0] - 0.8) < 0.1 and abs(r["tilt_m_per_km"][1] + 0.5) < 0.1
    assert r["rms_m"] < 0.5
    inner = np.s_[20:-20, 20:-20]
    assert np.nanmax(np.abs(r["aligned"][inner] - z[inner])) < 2.0


def test_team_positions_move_into_our_frame():
    g = SiteGrid.from_bbox((137.35, -4.85, 137.41, -4.79), res=2.0)
    team = {"dx_m": 8.0, "dy_m": -6.0, "dz_m": 12.0, "tilt_m_per_km": [0.0, 0.0]}
    lon, lat = 137.38, -4.81
    lon2, lat2 = team_dem.to_site_frame(g, lon, lat, team)
    x1, y1 = g.lonlat_to_xy(lon, lat)
    x2, y2 = g.lonlat_to_xy(lon2, lat2)
    assert abs((x1 - x2) - 8.0) < 1e-6 and abs((y1 - y2) + 6.0) < 1e-6
    assert team_dem.to_site_frame(g, lon, lat, None) == (lon, lat)
    assert abs(float(team_dem.plane_at(g, lon, lat, team)) - 12.0) < 1e-9
