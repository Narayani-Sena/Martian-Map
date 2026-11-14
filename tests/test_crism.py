"""CRISM browse-product georeferencing (synthetic label and image, no network)."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from marsgeo.grid import SiteGrid
from pipeline.crism import parse_label, to_grid

LABEL = """
  LINES                        = 100
  LINE_SAMPLES                 = 120
  MAP_PROJECTION_TYPE          = "EQUIRECTANGULAR"
  MAP_RESOLUTION               = 3000.0 <PIX/DEG>
  MAXIMUM_LATITUDE             = -4.7000000 <DEGREE>
  MINIMUM_LATITUDE             = -4.7333333 <DEGREE>
  EASTERNMOST_LONGITUDE        = 137.4400000 <DEGREE>
  WESTERNMOST_LONGITUDE        = 137.4000000 <DEGREE>
  BAND_NAME                    = ( "SINDEX2", "BD2100_2",
                                   "BD1900_2")
"""


def test_parse_label_reads_projection_and_bands():
    lab = parse_label(LABEL)
    assert lab["res"] == 3000.0 and lab["lines"] == 100 and lab["samples"] == 120
    assert lab["north"] == pytest.approx(-4.7) and lab["west"] == pytest.approx(137.4)
    assert lab["bands"] == ["SINDEX2", "BD2100_2", "BD1900_2"]


def test_to_grid_puts_a_pixel_at_its_longitude_and_latitude():
    lab = parse_label(LABEL)
    img = np.zeros((100, 120, 4), np.uint8)
    img[..., 3] = 255
    img[50, 60, :3] = 255
    lon = lab["west"] + 60.5 / lab["res"]
    lat = lab["north"] - 50.5 / lab["res"]
    grid = SiteGrid.from_bbox((lon - 0.0006, lat - 0.0006, lon + 0.0006, lat + 0.0006), res=4.0)
    rgb, valid = to_grid(img, lab, grid)
    assert valid.all()
    r, c = np.unravel_index(int(np.argmax(rgb[..., 0])), rgb.shape[:2])
    x, y = grid.rowcol_to_xy(r, c)
    lo, la = grid.xy_to_lonlat(x, y)
    assert abs(float(lo) - lon) < 1.0 / lab["res"] and abs(float(la) - lat) < 1.0 / lab["res"]


def test_no_data_outside_the_footprint():
    lab = parse_label(LABEL)
    img = np.zeros((100, 120, 4), np.uint8)
    img[..., 3] = 255
    grid = SiteGrid.from_bbox((137.30, -4.72, 137.31, -4.71), res=4.0)  # west of the image
    _, valid = to_grid(img, lab, grid)
    assert not valid.any()


def test_api_lists_and_drapes_crism_layers():
    from server.main import app
    from server.site_store import get_site, is_built
    if not is_built("gale_boxwork") or not get_site("gale_boxwork").crism:
        pytest.skip("CRISM layers not built for the site")
    client = TestClient(app)
    layers = client.get("/api/sites/gale_boxwork").json()["layers"]
    ids = [L["id"] for L in layers if L["id"].startswith("crism_")]
    assert "crism_hyd" in ids
    r = client.get("/api/sites/gale_boxwork/overlay/crism_hyd.png?size=256")
    assert r.status_code == 200 and r.content[:4] == b"\x89PNG"
    q = client.get("/api/sites/gale_boxwork/query?lon=137.377026&lat=-4.805671").json()
    assert "hyd" in q["crism"] and len(q["crism"]["hyd"]["rgb"]) == 3


# ------------------------------------------------------------------ registration against HiRISE
def _texture(h=400, w=400, seed=3):
    """A ground-like texture: smoothed noise with a few sharp-edged features at several scales."""
    from scipy import ndimage
    rng = np.random.default_rng(seed)
    t = ndimage.gaussian_filter(rng.normal(size=(h, w)), 6) * 40 + ndimage.gaussian_filter(rng.normal(size=(h, w)), 2) * 15
    for _ in range(30):
        r, c, s = rng.integers(20, h - 20), rng.integers(20, w - 20), rng.integers(4, 14)
        t[r - s:r + s, c - s:c + s] += rng.choice([-30, 30])
    return t.astype(np.float32)


def test_registration_recovers_a_known_shift():
    from pipeline.crism import register
    ref = _texture()
    # the "CRISM" image shows the ground 20 cells (80 m) east and 12 cells (48 m) south of where it is,
    # with its own stretch: image(p) = ground(p - shift)
    img = np.roll(ref, (12, 20), axis=(0, 1)) * 0.6 + 50
    valid = np.ones_like(ref, bool)
    r = register(img, valid, ref, res=4.0)
    assert r["used"]
    assert r["east_m"] == pytest.approx(80, abs=8)
    assert r["north_m"] == pytest.approx(-48, abs=8)
    assert r["ncc_after"] > r["ncc_before"] + 0.3


def test_registration_refuses_unrelated_ground():
    from pipeline.crism import register
    r = register(_texture(seed=4), np.ones((400, 400), bool), _texture(seed=5), res=4.0)
    assert r is not None and not r["used"]


def test_to_grid_applies_the_shift():
    lab = parse_label(LABEL)
    grid = SiteGrid.from_bbox([137.405, -4.73, 137.435, -4.705], 4.0)
    rgba = np.zeros((100, 120, 4), np.uint8)
    rgba[..., 3] = 255
    rgba[:, 60:, 0] = 200   # the east half is red
    plain, _ = to_grid(rgba, lab, grid)
    moved, _ = to_grid(rgba, lab, grid, shift_m=(200.0, 0.0))   # the image shows the ground 200 m east of it
    # the red edge moves 200 m (50 cells) west on the site grid
    edge = lambda rgb: int(np.argmax(rgb[grid.height // 2, :, 0] > 100))
    assert edge(plain) - edge(moved) == pytest.approx(50, abs=1)


@pytest.mark.parametrize("site_id", ["gale_boxwork", "jezero_threeforks"])
def test_built_sites_record_their_crism_registration(site_id):
    import json
    from server.site_store import DATA_DIR, is_built
    if not is_built(site_id):
        pytest.skip("site not built")
    meta = json.loads((DATA_DIR / "sites" / site_id / "crism_meta.json").read_text())
    reg = meta.get("registration") or {}
    if not reg:
        pytest.skip("built before the registration step")
    used = [r for r in reg.values() if r["used"]]
    assert used, "no observation could be registered"
    for r in used:
        assert r["ncc_after"] >= 0.2 and np.hypot(r["east_m"], r["north_m"]) <= 600
