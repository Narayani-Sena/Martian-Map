"""Ground truth from the rover (server/trackcheck.py): the rover's real drive, sampled every metre against the hazard
classes. A rover only drives where its team judged the ground safe, so our map should call nearly all of it
passable, and no-go ground should be much rarer under the wheels than across the site."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import trackcheck
from server.main import app
from server.site_store import get_site, is_built

client = TestClient(app)
SITES = [s for s in ("gale_boxwork", "jezero_threeforks") if is_built(s)]


def test_densify_keeps_the_length_and_spacing():
    xy = np.array([[0.0, 0.0], [10.0, 0.0], [10.0, 4.5]])
    pts, w = trackcheck.densify(xy, 1.0)
    assert w.sum() == pytest.approx(14.5)
    assert w.max() <= 1.0 + 1e-9
    assert len(pts) == 15                      # 10 on the first leg, 5 on the second
    assert pts[0] == pytest.approx([0.5, 0.0])  # segment midpoints, never the corners twice


def test_densify_skips_repeated_points():
    pts, w = trackcheck.densify(np.array([[1.0, 1.0], [1.0, 1.0], [4.0, 1.0]]), 1.0)
    assert len(pts) == 3 and w.sum() == pytest.approx(3.0)


def test_summary_line_says_how_much_rarer():
    s = trackcheck.summary_line("Curiosity", 4900.0, 0.978, 0.998, 0.17, 0.022, 2.0)
    assert "4.90 km" in s and "97.8 %" in s and "8 times rarer" in s
    s0 = trackcheck.summary_line("Perseverance", 900.0, 1.0, 1.0, 0.04, 0.0, 2.0)
    assert "None of the track" in s0


@pytest.mark.parametrize("site_id", SITES)
def test_the_rover_drove_where_the_map_says_passable(site_id):
    r = trackcheck.check(get_site(site_id))
    assert r["available"]
    assert r["track_m"] > 1000                       # kilometres of real drive inside each site
    assert sum(r["track_share"]) == pytest.approx(1.0, abs=1e-3)
    assert sum(r["site_share"]) == pytest.approx(1.0, abs=1e-3)
    assert r["passable_share"] > 0.95
    assert r["passable_share_tolerant"] >= r["passable_share"]
    # the map picks out the ground a real vehicle chose: no-go is several times rarer on the track
    assert r["track_share"][4] < r["site_share"][4] / 3
    assert r["track_share"][0] > r["site_share"][0]   # and easy ground more common
    for spot in r["spots"]:
        assert spot["length_m"] > 0 and spot["cause"]


@pytest.mark.parametrize("site_id", SITES[:1])
def test_rover_check_api_follows_the_walking_limits(site_id):
    loose = client.get(f"/api/sites/{site_id}/rover-check").json()
    strict = client.get(f"/api/sites/{site_id}/rover-check", params={"max_slope": 12}).json()
    assert loose["available"] and strict["available"]
    assert strict["passable_share"] < loose["passable_share"]   # a 12 degree limit closes more of the track
    assert strict["limits"]["max_slope_deg"] == 12
    assert client.get(f"/api/sites/{site_id}/rover-check", params={"tolerance_m": 50}).status_code == 422
