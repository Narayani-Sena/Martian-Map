import math

import numpy as np
import pytest

from pipeline import derive


def plane(h=60, w=80, res=2.0, dzdx=0.0, dzdy_north=0.0):
    rows, cols = np.mgrid[0:h, 0:w]
    x = cols * res
    y = -rows * res  # row 0 is north
    return (dzdx * x + dzdy_north * y).astype(np.float64)


def test_slope_of_tilted_plane():
    z = plane(dzdx=math.tan(math.radians(20)))
    s = derive.slope_deg(z, 2.0)
    assert np.allclose(s[2:-2, 2:-2], 20.0, atol=1e-4)


def test_gradient_signs():
    gx, gy = derive.horn_gradient(plane(dzdx=0.1, dzdy_north=-0.3), 2.0)
    assert gx[10, 10] == pytest.approx(0.1)
    assert gy[10, 10] == pytest.approx(-0.3)


def test_aspect_faces_downhill():
    # rises to the east -> faces (downhill) west = 270 deg
    a = derive.aspect_deg(plane(dzdx=0.2), 2.0)
    assert a[10, 10] == pytest.approx(270.0, abs=1e-6)
    # rises to the north -> faces south = 180 deg
    a = derive.aspect_deg(plane(dzdy_north=0.2), 2.0)
    assert a[10, 10] == pytest.approx(180.0, abs=1e-6)


def test_hillshade_flat_equals_sin_altitude():
    hs = derive.hillshade(np.zeros((20, 20)), 1.0, azimuth=315, altitude=30)
    assert np.allclose(hs, math.sin(math.radians(30)))


def test_hillshade_slope_facing_sun_is_brighter():
    east_rising = plane(dzdx=0.5)  # faces west
    lit_from_west = derive.hillshade(east_rising, 2.0, azimuth=270, altitude=30)
    lit_from_east = derive.hillshade(east_rising, 2.0, azimuth=90, altitude=30)
    assert lit_from_west[10, 10] > lit_from_east[10, 10]


def test_roughness_zero_on_plane_positive_on_bumps():
    z = plane(dzdx=0.1)
    assert derive.roughness(z, 1.0)[15:-15, 15:-15].max() < 1e-3  # away from filter edge effects
    rng = np.random.default_rng(0)
    bumpy = z + rng.normal(0, 0.5, z.shape)
    assert derive.roughness(bumpy, 1.0).mean() > 0.2


def test_fill_nodata():
    z = plane(dzdx=0.1)
    z[20:25, 30:35] = np.nan
    f = derive.fill_nodata(z)
    assert np.isfinite(f).all()
    assert np.abs(f[22, 32] - plane(dzdx=0.1)[22, 32]) < 0.6
