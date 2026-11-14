"""Boulder detection from shadows on synthetic HiRISE-like images (0.5 m pixels)."""

import numpy as np
import pytest

from pipeline.boulders import PIX, detect
from server.walkmodel import BOULDER_NO_GO_M, WalkParams, cell_multiplier


def _scene(seed=0):
    rng = np.random.default_rng(seed)
    return (100.0 + rng.normal(0, 2.0, (200, 200))).astype(np.float32)


def _boulder(img, r, c, radius_px=2.5, shadow_len=6):
    """Sunlit boulder at (r, c) with the sun in the west: the shadow falls to the east (+col)."""
    yy, xx = np.mgrid[0:img.shape[0], 0:img.shape[1]]
    disk = (yy - r) ** 2 + (xx - c) ** 2 <= radius_px ** 2
    img[disk & (xx < c)] = 150.0                       # sunlit west face
    shadow = (np.abs(yy - r) <= radius_px) & (xx > c) & (xx <= c + radius_px + shadow_len)
    img[shadow] = 45.0


def test_finds_a_boulder_where_it_is_and_about_the_right_size():
    img = _scene()
    _boulder(img, 100, 100)
    found = detect(img, sun_az=270.0, sun_el=40.0)
    assert found, "the boulder should be detected"
    b = min(found, key=lambda f: (f["row"] - 100) ** 2 + (f["col"] - 100) ** 2)
    assert abs(b["row"] - 100) < 3 and abs(b["col"] - 100) < 4
    assert 1.5 <= b["diameter_m"] <= 3.5          # 5-6 px across at 0.5 m
    assert b["height_m"] > 0


def test_thin_dark_lines_are_not_boulders():
    img = _scene(1)
    img[100, 60:130] = 40.0                       # a fracture
    img[99, 60:130] = 150.0                       # ...with a bright rim, to tempt the sunlit-side test
    assert detect(img, sun_az=0.0, sun_el=40.0) == []


def test_wide_dark_bands_are_not_boulder_fields():
    img = _scene(2)
    img[:, 80:125] = 45.0                         # a dark sand band 22 m wide
    img[95:100, 78:80] = 150.0
    assert all(not (80 <= f["col"] <= 125) for f in detect(img, sun_az=270.0, sun_el=40.0))


def test_big_boulders_are_no_go_and_small_ones_cost_more():
    p = WalkParams()
    slope = np.zeros((3, 3), np.float32)
    zero = np.zeros((3, 3), np.float32)
    boulder = np.array([[0, 1.0, BOULDER_NO_GO_M]] * 3, np.float32)
    m = cell_multiplier(p, slope, zero, zero, boulder)
    assert np.isinf(m[0, 2])
    assert m[0, 1] > m[0, 0]
    assert PIX == 0.5


def test_api_serves_boulders_when_built():
    from fastapi.testclient import TestClient

    from server.main import app
    from server.site_store import get_site, is_built
    if not is_built("gale_boxwork") or get_site("gale_boxwork").boulder2 is None:
        pytest.skip("boulders not built for the site")
    r = TestClient(app).get("/api/sites/gale_boxwork/boulders.bin")
    n = int(r.headers["x-shape"].split(",")[0])
    a = np.frombuffer(r.content, "<f4").reshape(n, 4)
    assert n > 100 and (a[:, 2] >= 0.75).all()
