"""Rover-assisted EVA: PR-2 mobility limits, the cabin timeline and the whole plan."""

from datetime import datetime, timezone

import numpy as np
import pytest

from server import eva
from server.rover import DriveParams, track
from server.walkmodel import WalkParams, cell_multiplier


def test_rover_has_its_own_limits_and_cache_key():
    d, w = DriveParams(), WalkParams()
    assert d.key() != w.key() and d.key().startswith("d")
    # slower on a 20 deg climb than on the flat, never faster than flat (admissible A* heuristic)
    g = np.tan(np.radians([-20, -10, 0, 10, 20]))
    f = d.grade_factor(g)
    assert np.all(f <= d.max_factor() + 1e-12) and f[2] == 1.0 and f[4] < 0.5
    # a 1.2 m boulder: the walker steps around it at a cost, the rover cannot drive over it or right beside it
    slope = np.zeros((5, 5), np.float32)
    zero = np.zeros((5, 5), np.float32)
    boulder = zero.copy()
    boulder[2, 2] = 1.2
    mw = cell_multiplier(w, slope, zero, zero, boulder)
    md = cell_multiplier(d, slope, zero, zero, boulder)
    assert np.isfinite(mw[2, 2]) and np.isinf(md[2, 2]) and np.isinf(md[1, 1]) and np.isfinite(md[0, 0])
    with pytest.raises(ValueError):
        DriveParams.from_dict({"flat_speed": 9})


def _legs():
    n = 11
    t = np.linspace(0, 600, n)
    return [{"d": np.linspace(0, 400, n), "t": t, "z": np.zeros(n), "grade": np.zeros(n), "slope": np.zeros(n),
             "lonlat": np.column_stack([np.linspace(0, 0.001, n), np.zeros(n)]), "shield": np.full(n, 0.1),
             "comms": np.ones(n, int), "walkback_s": np.linspace(0, 500, n), "hazard": np.zeros(n, int),
             "sand": np.zeros(n)}] * 2


def test_cabin_time_uses_no_suit_consumables():
    suit = eva.SuitParams()
    stops = [{"id": "S1", "name": "S1", "dwell_min": 20, "tasks": []}]
    rv = {"name": "PR-2", "out_s": 1200.0, "out_m": 2000.0, "back_s": 1100.0, "back_m": 2000.0, "suitport_min": 10.0}
    rows, events, total = eva.build_timeline(_legs(), stops, suit, rover=rv)
    kinds = [e["kind"] for e in events]
    assert kinds == ["drive", "egress", "walk", "stop", "walk", "ingress", "drive"]
    assert events[1]["t0"] == 1200.0 and events[1]["t1"] == 1800.0  # suitport, not the 15 min airlock
    assert total == pytest.approx(events[-1]["t1"]) and rows[0]["t"] == pytest.approx(1800.0)
    start = datetime(2026, 11, 12, 12, tzinfo=timezone.utc)
    sim, summary = eva.simulate(rows, events, total, suit, start, -4.8, 137.4, False, 0.8,
                                cabin={"met_w": 120, "gcr_factor": 0.7, "sep_factor": 0.1, "shield": 0.0})
    t = np.asarray(sim["t"])
    o2 = np.asarray(sim["o2_pct"])
    assert np.all(o2[t < 1200] == 100.0)  # riding out: suits untouched
    assert o2[np.searchsorted(t, 1900)] < 100.0  # suited: consumables flow
    back = t >= events[-1]["t0"]
    assert np.ptp(o2[back]) == 0  # riding home: frozen again
    assert set(np.asarray(sim["state"])[t < 1200]) == {"cabin"}


def test_track_follows_both_drives():
    legs = [{"t": np.array([0.0, 10.0, 20.0]), "lonlat": np.array([[0, 0], [1, 1], [2, 2]])},
            {"t": np.array([0.0, 30.0]), "lonlat": np.array([[2, 2], [0, 0]])}]
    tr = track(legs, [0.0, 100.0])
    assert tr["t"] == [0.0, 10.0, 20.0, 100.0, 130.0] and tr["lon"][-1] == 0


# ------------------------------------------------------------------ whole plan on the built site
def _plan(rover: dict):
    from fastapi.testclient import TestClient

    from server.main import app
    from server.site_store import is_built
    if not is_built("gale_boxwork"):
        pytest.skip("site not built")
    c = TestClient(app)
    site = c.get("/api/sites/gale_boxwork").json()
    body = {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"],
            "rover": rover}
    r = c.post("/api/sites/gale_boxwork/plan", json=body)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture(scope="module")
def plans():
    return {False: _plan({"enabled": False}), True: _plan({"enabled": True})}


def test_rover_shortens_the_walk_and_the_time_in_suits(plans):
    walk, ride = plans[False]["totals"], plans[True]["totals"]
    assert ride["rover"] and not walk["rover"]
    assert ride["dist_m"] < walk["dist_m"] and ride["drive_m"] > 0
    assert ride["suit_s"] < walk["suit_s"]
    assert ride["max_walkback_min"] < walk["max_walkback_min"]  # the parked rover is the safe haven
    R = plans[True]["rover"]
    assert R["enabled"] and R["dropoff"]["auto"] and len(R["legs"]) == 2
    assert all(L["mode"] == "drive" and L["max_slope"] <= R["drive"]["max_slope"] + 2 for L in R["legs"])
    assert R["track"]["t"][0] == 0 and R["track"]["t"][-1] == pytest.approx(plans[True]["events"][-1]["t1"], abs=1)
    kinds = [e["kind"] for e in plans[True]["events"]]
    assert kinds[0] == "drive" and kinds[-1] == "drive"
    assert plans[False]["rover"]["enabled"] is False


def test_manual_dropoff_is_used(plans):
    auto = plans[True]["rover"]["dropoff"]
    p = _plan({"enabled": True, "dropoff": {"lon": auto["lon"] + 0.0006, "lat": auto["lat"]}})
    assert p["rover"]["dropoff"]["auto"] is False
    assert p["rover"]["dropoff"]["lon"] == pytest.approx(auto["lon"] + 0.0006)
