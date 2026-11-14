"""USGS geologic units and NASA Mars Trek tiles (synthetic data for the algorithms, then the built sites)."""

import io

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from marsgeo.constants import METERS_PER_DEG
from marsgeo.grid import SiteGrid
from pipeline import geology, trek
from server.main import app
from server.site_store import is_built

client = TestClient(app)


def _grid():
    return SiteGrid.from_bbox((137.40, -4.80, 137.41, -4.79), res=10.0)


def _square(lon0, lat0, lon1, lat1):
    return [[lon0, lat0], [lon0, lat1], [lon1, lat1], [lon1, lat0], [lon0, lat0]]


def test_rasterize_fills_rings_even_odd_so_holes_stay_empty():
    g = _grid()
    outer = _square(137.401, -4.799, 137.409, -4.791)
    hole = _square(137.404, -4.796, 137.406, -4.794)
    feats = [{"attributes": {"Shape__Area": 2.0}, "geometry": {"rings": [outer, hole]}}]
    idx, cells = geology.rasterize(feats, g)
    r, c = (int(round(float(v))) for v in g.lonlat_to_rowcol(137.4025, -4.7975))
    assert idx[r, c] == 1                           # inside the outer ring
    r, c = (int(round(float(v))) for v in g.lonlat_to_rowcol(137.405, -4.795))
    assert idx[r, c] == 0                           # inside the hole
    r, c = (int(round(float(v))) for v in g.lonlat_to_rowcol(137.4002, -4.7998))
    assert idx[r, c] == 0                           # outside
    assert cells[0] == int((idx == 1).sum()) > 0


def test_small_unit_inside_a_big_one_is_not_painted_over():
    g = _grid()
    big = {"attributes": {"Shape__Area": 9.0}, "geometry": {"rings": [_square(137.400, -4.800, 137.410, -4.790)]}}
    small = {"attributes": {"Shape__Area": 1.0}, "geometry": {"rings": [_square(137.404, -4.796, 137.406, -4.794)]}}
    idx, _ = geology.rasterize([small, big], g)     # the service may list the small one first
    r, c = (int(round(float(v))) for v in g.lonlat_to_rowcol(137.405, -4.795))
    assert idx[r, c] == 1                           # still the small unit (feature 0)


def test_legend_lists_present_units_biggest_first_and_palette_matches():
    meta = {"units": [{"code": "A", "name": "Alpha", "color": "#ff0000", "share": 0.1},
                      {"code": "B", "name": "Beta", "color": "#00ff00", "share": 0.0},
                      {"code": "C", "name": "Gamma", "color": "#0000ff", "share": 0.9}]}
    lg = geology.legend(meta)["classes"]
    assert [x[0] for x in lg] == ["C · Gamma", "A · Alpha"]
    pal = geology.colors_rgba(meta, 200)
    assert pal.shape == (4, 4) and tuple(pal[0]) == (0, 0, 0, 0) and tuple(pal[3]) == (0, 0, 255, 200)


def test_trek_tile_geometry():
    # level 9: 1024 x 512 tiles of 256 px over 360 x 180 degrees, about 81 m a pixel on Mars
    assert trek.deg_per_px(0) == pytest.approx(180 / 256)
    assert trek.deg_per_px(9) * METERS_PER_DEG == pytest.approx(81.4, abs=0.2)
    assert trek.tile_url("X", 9, 3, 4).endswith("/X/1.0.0//default/default028mm/9/3/4.png")
    assert trek.open_url(137.4, -4.8) == "https://trek.nasa.gov/mars/"


@pytest.mark.skipif(not is_built("jezero_threeforks"), reason="Jezero not built")
def test_jezero_has_the_usgs_units_and_mars_trek_day_ir():
    info = client.get("/api/sites/jezero_threeforks").json()
    ids = {L["id"]: L for L in info["layers"]}
    if "geology" not in ids:
        pytest.skip("geology step not run")
    names = " ".join(x[0] for x in ids["geology"]["legend"]["classes"])
    assert "Jezero fan" in names and "Jezero floor" in names
    assert "SIM 3464" in ids["geology"]["about"]
    assert info["geology"]["scale"] == "1:75,000"
    assert "thermal_day" in ids and "Mars Trek" in ids["thermal_day"]["source"]
    # the delta front near the Three Forks depot is mapped as the fan unit or the floor unit
    q = client.get("/api/sites/jezero_threeforks/query", params={"lon": 77.41, "lat": 18.47}).json()
    assert q["inside"] and q["geology"]["code"] and q["geology"]["interpretation"]
    assert q["trek_url"].startswith("https://trek.nasa.gov/mars/")
    assert q["thermal_day"] is not None
    for layer in ("geology", "thermal_day"):
        r = client.get(f"/api/sites/jezero_threeforks/overlay/{layer}.png", params={"size": 512})
        assert r.status_code == 200
        im = Image.open(io.BytesIO(r.content))
        assert im.size == (512, 512)
        a = np.asarray(im.convert("RGBA"))
        assert (a[..., 3] > 0).mean() > 0.9     # the map covers the whole site


@pytest.mark.skipif(not is_built("gale_boxwork"), reason="Gale not built")
def test_gale_unit_comes_from_the_global_map():
    q = client.get("/api/sites/gale_boxwork/query", params={"lon": 137.385, "lat": -4.815}).json()
    if "geology" not in q:
        pytest.skip("geology step not run")
    assert q["geology"]["code"] == "Htu" and "SIM 3292" in q["geology"]["map"]
