"""The planner checks DONKI's predicted CME arrivals at Mars against the suited window (data-use item D1)."""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from server import spaceweather
from server.main import app
from server.site_store import is_built

SITE = "gale_boxwork"
client = TestClient(app)


def test_plan_check_levels():
    start = datetime(2030, 1, 1, 12, 0, tzinfo=timezone.utc)
    suited = (0.0, 3 * 3600.0)

    def lvl(hours, glancing=False):
        a = {"arrival": (start + timedelta(hours=hours)).isoformat(), "glancing": glancing}
        return spaceweather.plan_check([a], start, suited, suited[1])["level"]

    assert lvl(1.5) == "nogo"                    # full hit forecast during the EVA
    assert lvl(1.5, glancing=True) == "caution"  # glancing blow during the EVA
    assert lvl(10) == "caution"                  # 7 h after the EVA ends: inside the +/- 12 h window
    assert lvl(10, glancing=True) == "info"
    assert lvl(20) == "ok" and lvl(-13) == "ok"  # window clear of the suited time
    assert spaceweather.is_clear([], start, suited)


def test_arrival_rows_carry_times_relative_to_the_eva():
    start = datetime(2030, 1, 1, 12, 0, tzinfo=timezone.utc)
    a = {"arrival": "2030-01-01T14:00:00+00:00", "glancing": False, "cme": "X"}
    r = spaceweather.plan_check([a], start, (900.0, 9000.0), 9900.0)
    row = r["arrivals"][0]
    assert row["t_rel_s"] == 7200.0 and row["t0_rel_s"] == 7200.0 - 12 * 3600 and row["overlap"] == "inside"


pytestmark_site = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


@pytest.fixture(scope="module")
def site():
    return client.get(f"/api/sites/{SITE}").json()


def _body(site, **extra):
    b = {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
         "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
         "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"]}
    b.update(extra)
    return b


@pytestmark_site
def test_cme_during_the_eva_is_no_go_with_a_clear_start(site):
    start = datetime.fromisoformat(site["defaults"]["start_utc"])
    hit = (start + timedelta(minutes=90)).isoformat()
    r = client.post(f"/api/sites/{SITE}/plan", json=_body(site, cme_arrivals=[{"arrival": hit, "glancing": False, "cme": "TEST"}]))
    assert r.status_code == 200, r.text
    p = r.json()
    sw = p["space_weather"]
    assert sw["checked"] and sw["source"] == "request" and sw["level"] == "nogo"
    assert p["totals"]["go"] is False
    assert p["issues"][0]["kind"] == "space_weather" and p["issues"][0]["level"] == "nogo"
    sug = sw["suggested"]
    assert sug is not None and sug["delay_h"] > 0
    t = datetime.fromisoformat(sug["start_utc"])
    assert spaceweather.is_clear([{"arrival": hit}], t, tuple(sw["suited_s"]))
    assert 7.0 - 0.01 <= sug["start_ltst"] <= 13.01


@pytestmark_site
def test_glancing_blow_near_the_eva_is_a_caution_only(site):
    start = datetime.fromisoformat(site["defaults"]["start_utc"])
    near = (start + timedelta(hours=-6)).isoformat()
    p = client.post(f"/api/sites/{SITE}/plan", json=_body(site, cme_arrivals=[{"arrival": near, "glancing": True}])).json()
    assert p["space_weather"]["level"] == "info"
    assert p["issues"][0]["level"] == "info"


@pytestmark_site
def test_no_arrivals_and_off(site):
    p = client.post(f"/api/sites/{SITE}/plan", json=_body(site, cme_arrivals=[])).json()
    assert p["space_weather"]["checked"] and p["space_weather"]["level"] == "ok"
    assert not any(i.get("kind") == "space_weather" for i in p["issues"])
    q = client.post(f"/api/sites/{SITE}/plan", json=_body(site, space_weather="off")).json()
    assert q["space_weather"]["checked"] is False
