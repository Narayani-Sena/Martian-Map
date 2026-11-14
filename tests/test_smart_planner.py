"""The map that learns and asks (features C1-C4), beat the planner (G3), sun in your eyes (B5) and pace notes (D3)."""

import math

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import glare
from server.main import app
from server.site_store import is_built

SITE = "gale_boxwork"
client = TestClient(app)
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")
M_PER_DEG = 59274.0  # metres per degree of latitude on Mars, as the server uses


@pytest.fixture(scope="module")
def body():
    site = client.get(f"/api/sites/{SITE}").json()
    return {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"]}


@pytest.fixture(scope="module")
def plan(body):
    r = client.post(f"/api/sites/{SITE}/plan", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def _metres(lon0, lat0, lon1, lat1):
    return math.hypot((lon1 - lon0) * math.cos(math.radians(lat0)), lat1 - lat0) * M_PER_DEG


def _dense(path, step_m=0.5):
    """Points every step_m along a [lon, lat] polyline."""
    out = []
    for (a0, b0), (a1, b1) in zip(path[:-1], path[1:]):
        n = max(1, int(_metres(a0, b0, a1, b1) / step_m))
        out += [(a0 + (a1 - a0) * i / n, b0 + (b1 - b0) * i / n) for i in range(n)]
    return out + [tuple(path[-1])]


# ------------------------------------------------------------------ C3 plan it for me
def test_plan_it_for_me_beats_the_hand_picked_eva(body, plan):
    """Acceptance check: at the hand-picked EVA's own time in suits the planner collects more science, and all three
    variants (safe, balanced, bold) are planned for real and come out GO."""
    user_min = plan["totals"]["suit_s"] / 60.0
    r = client.post(f"/api/sites/{SITE}/autoplan", json={**{k: body[k] for k in ("habitat", "stops", "walk", "suit", "start_utc")},
                                                         "suit_budget_min": 240, "user_suit_min": user_min})
    assert r.status_code == 200, r.text
    j = r.json()
    assert [v["id"] for v in j["variants"]] == ["safe", "balanced", "bold"]
    same = j["same_time"]
    # 1.27 at Gale since the CRISM layers were lined up with HiRISE (the hand-picked stops gained mineral signal)
    assert same["planner_science"] >= 1.2 * same["user_science"] > 0
    for v in j["variants"]:
        assert v["stops"] and v["plan"] and v["plan"]["go"], v["name"]
        assert v["plan"]["suit_min"] <= 240 + 15  # inside the time asked for (the estimate is checked by the real plan)
    # bolder variants accept longer walks back
    wb = [v["wb_limit_min"] for v in j["variants"]]
    assert wb == sorted(wb)


# ------------------------------------------------------------------ C1 scout first
def test_scout_first_finds_shaky_stretches_and_flies_them(body):
    j = client.post(f"/api/sites/{SITE}/scout", json=body).json()
    assert j["simulated"] is True
    assert j["stretches"], "the default Gale route crosses ground where the two terrain models disagree"
    assert {s["kind"] for s in j["stretches"]} <= {"terrain", "sand"}
    assert all(s["d1"] > s["d0"] and s["length_m"] > 0 for s in j["stretches"])
    assert j["flight"]["flights"] and j["flight"]["total_m"] > sum(s["length_m"] for s in j["stretches"]) * 0.9
    assert 0 < j["scouted_route_fraction"] <= 1
    assert j["after"]["speed_dispersion_scale"] < 1.0
    # once the ground is seen, the worst case can only get better
    assert j["after"]["margin_range_min"][0] >= j["before"]["margin_range_min"][0]
    assert j["after"]["terrain_low_m"] == 0


# ------------------------------------------------------------------ C2 crew-tagged map
def test_hazard_tag_reroutes_the_plan(body, plan):
    leg = max(plan["legs"], key=lambda L: len(L["path"]))
    lon, lat = leg["path"][len(leg["path"]) // 2]
    radius = 15.0
    r = client.post(f"/api/sites/{SITE}/tags", json={"kind": "hazard", "lon": lon, "lat": lat, "note": "test", "by": "test",
                                                     "radius_m": radius})
    assert r.status_code == 200, r.text
    tag = r.json()["tag"]
    try:
        assert tag["kind"] == "hazard" and tag["radius_m"] == radius
        p2 = client.post(f"/api/sites/{SITE}/plan", json=body).json()
        pts = [pt for L in p2["legs"] for pt in _dense(L["path"])]
        nearest = min(_metres(lon, lat, a, b) for a, b in pts)
        assert nearest >= radius - 3.0, f"the new route passes {nearest:.1f} m from the hazard"
        assert [L["path"] for L in p2["legs"]] != [L["path"] for L in plan["legs"]]  # the route was planned again
        assert p2["tags"] and any(t["id"] == tag["id"] for t in p2["tags"])  # and the plan says which tags it used
    finally:
        client.delete(f"/api/sites/{SITE}/tags/{tag['id']}")
    assert all(t["id"] != tag["id"] for t in client.get(f"/api/sites/{SITE}/tags").json()["tags"])


def test_tags_outside_the_site_or_of_unknown_kind_are_refused(body):
    assert client.post(f"/api/sites/{SITE}/tags", json={"kind": "hazard", "lon": 0.0, "lat": 0.0}).status_code == 422
    h = body["habitat"]
    assert client.post(f"/api/sites/{SITE}/tags", json={"kind": "lava", "lon": h["lon"], "lat": h["lat"]}).status_code == 422


# ------------------------------------------------------------------ C4 the cost of a rock
def test_each_sample_has_a_price_in_margin(body, plan):
    sm = plan["samples"]
    rows = sm["per_stop"]
    assert len(rows) == len(body["stops"]) and sm["total_kg"] == pytest.approx(sm["kg_per_stop"] * len(rows))
    assert all(r["margin_cost_min"] > 0 for r in rows)
    carried = [r["carried_min"] for r in rows]
    assert carried == sorted(carried, reverse=True)  # the first rock is carried longest
    light = client.post(f"/api/sites/{SITE}/plan", json={**body, "sample_kg_per_stop": 0}).json()
    assert light["totals"]["min_margin_min"] > plan["totals"]["min_margin_min"]


def test_debrief_has_a_passport_per_sample_and_the_flown_track(body, plan):
    path = [pt for L in plan["legs"] for pt in L["path"]]
    track = [[i * 60.0, lon, lat] for i, (lon, lat) in enumerate(path[::5])]
    r = client.post(f"/api/sites/{SITE}/debrief", json={**body, "track": track})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    html = r.text
    assert "passport" in html.lower()
    for st in body["stops"]:
        assert st["name"] in html
    assert "#e11d48" in html  # the walk as flown, drawn over the plan


# ------------------------------------------------------------------ G3 beat the planner
def test_the_planners_own_line_scores_about_1000(body, plan):
    leg = plan["legs"][0]
    j = client.post(f"/api/sites/{SITE}/score-route", json={"points": leg["path"], "walk": body["walk"]}).json()
    assert j["yours"]["nogo_m"] == 0 and 950 <= j["score"] <= 1050
    assert j["planner"]["path"]


def test_a_straight_line_loses_and_no_go_ground_is_counted(body, plan):
    leg = plan["legs"][0]
    j = client.post(f"/api/sites/{SITE}/score-route", json={"points": [leg["path"][0], leg["path"][-1]], "walk": body["walk"]}).json()
    assert j["yours"]["nogo_m"] > 0 and j["score"] < 950
    assert "no-go" in j["verdict"]
    assert client.post(f"/api/sites/{SITE}/score-route", json={"points": [leg["path"][0]]}).status_code == 422


# ------------------------------------------------------------------ B5 sun in your eyes
def test_glare_and_flat_light_rules():
    assert glare.classify(10, 90, 90) == "glare"        # low sun straight ahead
    assert glare.classify(10, 120, 90) == "glare"       # within 35 deg of the heading
    assert glare.classify(30, 90, 90) is None           # high sun ahead: no glare
    assert glare.classify(40, 270, 90) == "flat"        # sun right behind: no shadows
    assert glare.classify(5, 270, 90) is None           # too low to wash out the relief
    assert glare.classify(40, 0, 90) is None            # sun to the side
    assert glare.classify(-3, 90, 90) is None           # night


def test_plan_reports_glare_per_leg_and_the_reversed_loop(plan):
    g = plan["glare"]
    walks = [e for e in plan["events"] if e["kind"] == "walk"]
    assert len(g["legs"]) == len(walks)
    assert g["flat_min"] == pytest.approx(sum(x["flat_min"] for x in g["legs"]), abs=0.15)
    assert g["glare_min"] == pytest.approx(sum(x["glare_min"] for x in g["legs"]), abs=0.15)
    assert {"glare_min", "flat_min"} <= set(g["reversed"]) and isinstance(g["reverse_better"], bool)
    has_issue = any(i.get("kind") == "sun_glare" for i in plan["issues"])
    assert has_issue == (g["glare_min"] >= 3 or g["flat_min"] >= 5)


# ------------------------------------------------------------------ D3 pace notes
def test_pace_notes_read_like_a_co_driver(plan):
    notes = plan["pace_notes"]
    assert len(notes) == len(plan["legs"])
    kinds = set()
    for leg in notes:
        ds = [n["d"] for n in leg["notes"]]
        assert ds == sorted(ds)
        assert all(0 <= d <= leg["dist_m"] + 10 for d in ds)
        for n in leg["notes"]:
            assert n["text"].startswith(f"{n['d']} m:")
            kinds.update(n["kinds"])
            if "boulder" in n["kinds"]:
                assert "keep left" in n["text"] or "keep right" in n["text"]
    assert {"turn", "boulder"} <= kinds


def test_glare_check_on_a_synthetic_leg():
    """A leg walked due east at sunrise has the low sun in the visor; walked back west it has it behind."""
    from datetime import datetime, timedelta, timezone
    from marsgeo import mars24
    lat0, lon0 = -4.8, 137.4
    # find a moment just after sunrise, with the sun low and close to due east
    t = datetime(2026, 11, 20, tzinfo=timezone.utc)
    for _ in range(25 * 60):
        el, az, _ = mars24.sun_position(mars24.mars_time(t), lat0, lon0)
        if 3 < el < 10 and abs(az - 90) < 25:
            break
        t += timedelta(minutes=1)
    else:
        pytest.skip("no sunrise close to due east in this sol")
    east = [[lon0, lat0], [lon0 + 400 / M_PER_DEG, lat0]]
    out = glare.leg_minutes(t, lat0, lon0, [{"path": east, "time_s": 600.0}], [0.0])
    assert out[0]["glare_min"] > 5
    west = [east[1], east[0]]
    out = glare.leg_minutes(t, lat0, lon0, [{"path": west, "time_s": 600.0}], [0.0])
    assert out[0]["glare_min"] == 0
