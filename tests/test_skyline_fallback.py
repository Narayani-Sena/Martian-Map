"""Skyline fix (feature B1), the HUD-failure fallback card (B2) and grid references (G5)."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import fallback, skyline
from server.main import app
from server.site_store import get_site, is_built, load_config

pytestmark = pytest.mark.skipif(not is_built("gale_boxwork"), reason="gale_boxwork not built")
client = TestClient(app)


@pytest.fixture(scope="module")
def idx():
    return get_site("gale_boxwork").skyline


def test_noise_free_skyline_fixes_the_right_cell(idx):
    rng = np.random.default_rng(0)
    for _ in range(5):
        r, c = int(rng.integers(50, idx.shape[0] - 50)), int(rng.integers(50, idx.shape[1] - 50))
        fx = idx.locate(idx.observe(r, c, noise_deg=0.0, heading_err_deg=0.0, rng=rng), heading_known=True)
        assert np.hypot(fx["row"] - r, fx["col"] - c) * idx.grid.res <= fx["r95_m"] + 4.0


def test_unknown_heading_is_recovered(idx):
    rng = np.random.default_rng(1)
    r, c = 300, 500
    fx = idx.locate(idx.observe(r, c, noise_deg=0.2, heading_err_deg=60.0, rng=rng), heading_known=False)
    assert abs(((fx["heading_err_deg"] - 60.0) + 180) % 360 - 180) <= 7.5
    assert np.hypot(fx["row"] - r, fx["col"] - c) * idx.grid.res < 60.0


def test_median_error_on_random_cells(idx):
    """The acceptance check, on 60 cells here (the endpoint runs it on up to 1,000)."""
    ev = skyline.evaluate(idx, n=60, noise_deg=0.5)
    assert ev["median_m"] < 30.0
    assert ev["circle_holds"] >= 0.85


def test_fix_endpoint_and_profile():
    cfg = load_config("gale_boxwork")
    st = cfg["stops"][0]
    r = client.post("/api/sites/gale_boxwork/skyline/fix", json={"lon": st["lon"], "lat": st["lat"], "seed": 3})
    assert r.status_code == 200
    j = r.json()
    assert j["error_m"] <= j["fix"]["r95_m"] + 8.0 and j["likelihood_png"].startswith("data:image/png;base64,")
    p = client.get("/api/sites/gale_boxwork/skyline/profile", params={"lon": st["lon"], "lat": st["lat"]}).json()
    assert len(p["elev"]) == 24 and p["features"][0]["name"].startswith("Aeolis Mons")


def test_clock_positions():
    assert fallback.clock(0) == 12 and fallback.clock(90) == 3 and fallback.clock(-90) == 9 and fallback.clock(175) == 6


def test_grid_reference_names():
    s = get_site("gale_boxwork")
    h = s.habitat_haven()
    g = fallback.gridref(s, h["lon"], h["lat"])
    assert g["inside"] and g["ref"][0].isalpha() and g["say"].split()[0] in fallback.NATO
    sp = fallback.grid_spec(s)
    assert sp["cols"] * fallback.GRID_M >= s.grid.width * s.grid.res


def test_fallback_card():
    cfg = load_config("gale_boxwork")
    body = {"habitat": {"lon": cfg["habitat"]["lon"], "lat": cfg["habitat"]["lat"]}, "space_weather": "off",
            "stops": [{k: v for k, v in st.items() if k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for st in cfg["stops"]]}
    j = client.post("/api/sites/gale_boxwork/fallback-card.json", json=body).json()
    assert len(j["legs"]) == len(cfg["stops"]) + 1
    for L in j["legs"]:
        if L["shadow_clock"] and L["sun_clock"]:
            assert (L["shadow_clock"] - L["sun_clock"]) % 12 == 6  # the shadow points away from the sun
        assert abs(L["paces"] - L["dist_m"] / fallback.PACE_M) <= 1
    last = j["legs"][-1]
    assert next(m for m in last["landmarks"] if m["name"] == "Hab")["clock"] in (11, 12, 1)  # walking home: the hab ahead
    html = client.post("/api/sites/gale_boxwork/fallback-card", json=body).text
    assert "FALLBACK CARD" in html and "<svg" in html
