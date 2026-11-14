import math

import numpy as np
import pytest

from marsgeo import tiles as T
from marsgeo.constants import METERS_PER_DEG
from marsgeo.grid import SiteGrid, sample_bilinear
from pipeline import skyview
from server.viewshed import viewshed

BBOX = (137.3575, -4.8425, 137.4125, -4.7875)


def test_grid_round_trip():
    g = SiteGrid.from_bbox(BBOX, 1.0, multiple=8)
    assert g.width % 8 == 0 and g.height % 8 == 0
    lon, lat = 137.38417, -4.797708
    r, c = g.lonlat_to_rowcol(lon, lat)
    lon2, lat2 = g.rowcol_to_lonlat(r, c)
    assert lon2 == pytest.approx(lon, abs=1e-10) and lat2 == pytest.approx(lat, abs=1e-10)


def test_grid_scale_is_mars_metres():
    g = SiteGrid.from_bbox(BBOX, 1.0)
    _, y = g.lonlat_to_xy(g.lon0, g.lat0 + 1.0)
    assert y == pytest.approx(METERS_PER_DEG)
    assert METERS_PER_DEG == pytest.approx(59274.7, abs=0.5)  # vs 111 km on Earth


def test_resampled_grids_align():
    g = SiteGrid.from_bbox(BBOX, 1.0, multiple=8)
    g2 = g.resampled(2)
    # the centre of 2 m cell (0,0) is the corner shared by 1 m cells (0,0),(0,1),(1,0),(1,1)
    x2, y2 = g2.rowcol_to_xy(0, 0)
    x1, y1 = g.rowcol_to_xy(0.5, 0.5)
    assert x2 == pytest.approx(x1) and y2 == pytest.approx(y1)


def test_tms_flip_is_involution():
    for z in (3, 10, 17):
        for y in (0, 5, (1 << z) - 1):
            assert T.tms_y(T.tms_y(y, z), z) == y


def test_tile_round_trip():
    x, y = T.lonlat_to_tile(137.385, -4.815, 17)
    lon, lat = T.tile_to_lonlat(x, y, 17)
    assert lon == pytest.approx(137.385) and lat == pytest.approx(-4.815)
    w, s, e, n = T.tile_bounds(int(x), int(y), 17)
    assert w <= 137.385 <= e and s <= -4.815 <= n


def test_sample_bilinear():
    a = np.arange(12, dtype=float).reshape(3, 4)
    assert sample_bilinear(a, 1.0, 1.0) == 5.0
    assert sample_bilinear(a, 0.5, 0.5) == pytest.approx((0 + 1 + 4 + 5) / 4)
    assert math.isnan(sample_bilinear(a, -2, 0))


def test_viewshed_wall_blocks():
    z = np.zeros((60, 60))
    z[:, 30] = 20.0  # 20 m wall
    v = viewshed(z, 2.0, (30, 10), obs_height=3.0, target_height=2.0)
    assert v[30, 20] == 2  # same side: clear
    assert v[30, 50] == 0  # behind the wall: dead zone
    flat = viewshed(np.zeros((40, 40)), 2.0, (20, 20), 3.0, 2.0)
    assert (flat == 2).all()


def test_horizon_and_shielding():
    # a pit: walls 50 m high, 100 m away in every direction -> horizon ~26.6 deg
    n, res, m = 101, 4.0, 60
    rows, cols = np.mgrid[0:n + 2 * m, 0:n + 2 * m]
    c = (n + 2 * m) // 2
    r_m = np.hypot(rows - c, cols - c) * res
    ext = np.where(r_m > 100, 50.0, 0.0)
    tan_h = skyview.near_field_tan_horizon(ext, m, (n, n), res, n_az=16, max_dist=m * res)
    h = np.degrees(np.arctan(tan_h[:, n // 2, n // 2]))
    assert np.all(np.abs(h - 26.6) < 2.5)
    frac = skyview.shielded_fraction(tan_h)[n // 2, n // 2]
    assert frac == pytest.approx(math.sin(math.radians(26.6)) ** 2, abs=0.03)
