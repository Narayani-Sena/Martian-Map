"""Whole-plan checks on the built site (slow-ish: the first call builds the cost grids)."""

import pytest
from fastapi.testclient import TestClient

from server.main import app
from server.site_store import is_built

SITE = "gale_boxwork"
client = TestClient(app)
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


def _body(site: dict, load_kg: float) -> dict:
    return {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": dict(site["defaults"]["walk"], load_kg=load_kg), "suit": site["defaults"]["suit"],
            "start_utc": site["defaults"]["start_utc"]}


@pytest.fixture(scope="module")
def plans():
    site = client.get(f"/api/sites/{SITE}").json()
    out = {}
    for load in (0, 30):
        r = client.post(f"/api/sites/{SITE}/plan", json=_body(site, load))
        assert r.status_code == 200, r.text
        out[load] = r.json()
    return out


def test_every_route_point_has_a_walk_back_time(plans):
    # regression: route points in gaps of the 4 m walk-back grid used to read as "unreachable",
    # which made the simulator assume a 4-hour walk home and flipped the plan to NO-GO
    for p in plans.values():
        assert all(v is not None for v in p["profile"]["walkback_min"])
        assert max(p["sim"]["need_min"]) < 120


def test_carrying_more_costs_time_and_margin(plans):
    light, heavy = plans[0]["totals"], plans[30]["totals"]
    assert heavy["walk_s"] > light["walk_s"]
    assert heavy["min_margin_min"] < light["min_margin_min"]
    assert plans[30]["walk"]["load_kg"] == 30


def test_traverse_sheet_is_a_printable_photomap():
    site = client.get(f"/api/sites/{SITE}").json()
    r = client.post(f"/api/sites/{SITE}/traverse-sheet", json=_body(site, 8))
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    html = r.text
    assert "<svg" in html and "data:image/jpeg;base64," in html
    assert "STA 1" in html and "FLIGHT RULES" in html and "@page" in html
    for s in site["stops"]:
        assert s["name"] in html
