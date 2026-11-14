"""The shrinking world (feature A3), partner down (B3) and caches at the gateways (B4)."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import envelope as env
from server.main import app
from server.site_store import get_site, is_built, load_config
from server.walkmodel import WalkParams

pytestmark = pytest.mark.skipif(not is_built("gale_boxwork"), reason="gale_boxwork not built")
client = TestClient(app)
CFG = load_config("gale_boxwork")


def test_leak_at_ridge_alpha_matches_the_measurement():
    """Design measurement 1: 120 min of oxygen leaves ~194 ha (24 %), 90 min ~118 ha, 60 min ~43 ha, and below
    ~52 min the hab is out of reach with the 30 min reserve."""
    s = get_site("gale_boxwork")
    ra = next(st for st in CFG["stops"] if st["name"] == "Ridge Alpha")
    e = env.envelope(s, (ra["lon"], ra["lat"]), [s.habitat_haven()], WalkParams())
    st120 = env.envelope_stats(e, 120)
    assert 180 <= st120["area_ha"] <= 210 and 0.22 <= st120["share_of_walkable"] <= 0.26
    assert 105 <= env.envelope_stats(e, 90)["area_ha"] <= 130
    assert 35 <= env.envelope_stats(e, 60)["area_ha"] <= 50
    hab = e["havens"][0]
    assert 49 <= hab["needs_min"] <= 55
    assert env.envelope_stats(e, hab["needs_min"] - 0.5)["havens_in_reach"] == []
    # the envelope only shrinks as the oxygen drops
    areas = [env.envelope_stats(e, m)["area_ha"] for m in (200, 150, 100, 50)]
    assert areas == sorted(areas, reverse=True)


def test_envelope_endpoint_png_roundtrip():
    ra = next(st for st in CFG["stops"] if st["name"] == "Ridge Alpha")
    j = client.get("/api/sites/gale_boxwork/envelope", params={"lon": ra["lon"], "lat": ra["lat"], "minutes_left": 120}).json()
    assert j["needed_png"].startswith("data:image/png;base64,") and 330 <= j["egress_minutes"] <= 360
    import base64, io
    from PIL import Image
    a = np.asarray(Image.open(io.BytesIO(base64.b64decode(j["needed_png"].split(",", 1)[1]))))
    m = np.where(a[..., 3] > 0, (a[..., 0].astype(int) * 256 + a[..., 1]) / 10.0, np.inf)
    n = int((m <= 120).sum())
    assert abs(n * j["cell_ha"] - j["stats"]["area_ha"]) < 2.0  # the client's count matches the server's


def test_time_bank_in_inspect():
    h = CFG["habitat"]
    st = CFG["stops"][0]
    v = client.get("/api/sites/gale_boxwork/query", params={"lon": st["lon"], "lat": st["lat"], "hab_lon": h["lon"], "hab_lat": h["lat"]}).json()
    assert 200 < v["time_bank_min"] < v["egress_minutes"]


def test_partner_down_route_check():
    body = {"habitat": {"lon": CFG["habitat"]["lon"], "lat": CFG["habitat"]["lat"]}, "space_weather": "off",
            "stops": [{k: v for k, v in st.items() if k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for st in CFG["stops"]]}
    j = client.post("/api/sites/gale_boxwork/rescue", json=body).json()
    assert j["worst_min"] is not None and 10 < j["worst_min"] < 120
    assert j["worst_mode"] in ("buddy carry", "PR-2 rescue") and j["level"] in ("ok", "caution")
    assert 0 < j["carry_ok_share"] <= 1 and j["pr2_share"] > j["carry_ok_share"]  # PR-2 reaches more than a carry


def test_caches_raise_emergency_coverage():
    s = get_site("gale_boxwork")
    out = env.place_caches(s, [s.habitat_haven()], WalkParams(), k=2, budget_min=30)
    assert len(out["caches"]) == 2
    assert out["coverage_after"] > out["coverage_before"] + 0.2
    gains = [c["gain_share"] for c in out["caches"]]
    assert gains == sorted(gains, reverse=True)  # greedy: the best first
