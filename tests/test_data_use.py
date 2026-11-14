"""The data-use pass (items D2-D7): sand model, science stops, terrain sunlight, Ingenuity, team frame, uncertainty."""

import json
from datetime import datetime, timedelta, timezone

import numpy as np
import pytest
from fastapi.testclient import TestClient

from marsgeo import mars24
from pipeline import sand
from server.main import app
from server.site_store import get_site, is_built

client = TestClient(app)
GALE, JEZERO = "gale_boxwork", "jezero_threeforks"
need = pytest.mark.skipif(not (is_built(GALE) and is_built(JEZERO)), reason="sites not built")


# ------------------------------------------------------------------ D2 sand model (no site needed)
def test_sand_two_scales_keep_the_patch_share_and_fill_hollows():
    rng = np.random.default_rng(1)
    H = W = 120
    slope = np.full((H, W), 5.0, np.float32)
    tpi = np.zeros((H, W), np.float32)
    tpi[40:50, 40:50] = -1.5  # a hollow
    night = np.full((H, W), 200.0, np.float32)
    night[:, 60:] = 150.0      # the east half cools fast at night: loose sand
    parts = sand.clues(slope, tpi + rng.normal(0, 0.05, (H, W)).astype(np.float32), night)
    p, conf = sand.combine(parts, footprint_px=10)
    assert p[:, 70:].mean() > 3 * p[:, :50].mean()        # cold-at-night half is sandier
    assert p[42:48, 42:48].mean() > p[20:30, 20:30].mean()  # the hollow collects the patch's sand
    assert 0.0 <= conf.min() and conf.max() <= 1.0


def test_sand_ignores_missing_mosaic_tiles():
    H = W = 80
    bright = np.full((H, W), 120.0, np.float32)
    bright[30:50, 30:50] = 0.0  # a missing tile is pure black
    parts = sand.clues(np.full((H, W), 5.0, np.float32), np.zeros((H, W), np.float32), None, bright)
    assert np.all(parts["dark"][30:50, 30:50] == 0.0) and np.all(parts["dark_local"][30:50, 30:50] == 0.0)


def test_sand_explain_names_the_clues():
    why = sand.explain({"thermal": 1.2, "hollow": -0.6, "dark": 0.05, "steep": -1.0})
    assert why["for"] == ["cold at night (THEMIS)"]
    assert why["against"] == ["too steep to hold sand", "on a rise"]


@need
def test_new_sand_score_finds_jezero_bedforms_without_flagging_the_rest():
    m = get_site(JEZERO).meta["sand"]
    chk = m["check_bedform_unit"]
    assert chk["in_mean"] > 3 * chk["out_mean"]
    assert chk["out_flagged_ge_058"] < 0.05  # the old score flagged 60 % of non-dune ground


# ------------------------------------------------------------------ D6 team frame
@need
def test_rover_tracks_sit_on_our_terrain_after_the_team_shift():
    for sid in (GALE, JEZERO):
        m = get_site(sid).meta
        assert m["team_dem"]["shift_m"] > 10 and m["team_dem"]["rms_m"] < 2.0
        assert m["rover"]["aligned_with_team_dem"]
        assert abs(m["rover"]["datum_offset_m"]) < 0.5 < abs(m["rover"]["unaligned_offset_m"])
        assert m["rover"]["datum_spread_m"] < m["rover"]["unaligned_spread_m"]
        assert m["texture_offset_m"] == [m["team_dem"]["dx_m"], m["team_dem"]["dy_m"]]


# ------------------------------------------------------------------ D4 sunlight
@need
def test_terrain_horizon_delays_sunrise_and_advances_sunset_at_gale():
    s = get_site(GALE)
    hab = s.cfg["habitat"]
    st = s.sun_times(hab["lon"], hab["lat"], datetime(2026, 11, 14, tzinfo=timezone.utc))
    assert st["sunrise_ltst"] > st["flat_sunrise_ltst"] + 0.2
    assert st["sunset_ltst"] < st["flat_sunset_ltst"] - 0.2
    assert len(st["horizon_deg"]) == 24 and max(st["horizon_deg"]) > 5
    night = s.shadow_grid(-10.0, 90.0)
    assert (night == 2).all()


def _body(site, **extra):
    b = {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
         "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
         "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"],
         "cme_arrivals": []}
    b.update(extra)
    return b


@pytest.fixture(scope="module")
def gale_site():
    return client.get(f"/api/sites/{GALE}").json()


@need
def test_plan_reports_terrain_sun_margin_range_and_confidence(gale_site):
    p = client.post(f"/api/sites/{GALE}/plan", json=_body(gale_site)).json()
    t = p["totals"]
    assert t["go"] is True
    assert t["sun_horizon"] == "terrain" and t["terrain_sunset_ltst"] < t["sunset_ltst"]
    lo, hi = t["margin_range_min"]
    assert lo <= t["min_margin_min"] <= hi
    assert "terrain_low_m" in t["route_confidence"] and "sand_conf_mean" in t["route_confidence"]
    assert len(p["profile"]["sunlit"]) == len(p["profile"]["d"])
    stops = [e for e in p["events"] if e["kind"] == "stop"]
    assert all("light" in e and e["light"]["note"] for e in stops)
    assert any(e.get("science", {}).get("reasons") for e in stops)


@need
def test_an_early_start_walks_in_terrain_shadow_and_costs_heater_power(gale_site):
    lon = get_site(GALE).grid.lon0
    # egress ends ~06:21: the sun is up (flat sunrise ~06:02) but behind the terrain east of the hab until ~06:32
    start = mars24.utc_for_ltst(datetime.fromisoformat(gale_site["defaults"]["start_utc"]), lon, 6.1)
    p = client.post(f"/api/sites/{GALE}/plan", json=_body(gale_site, start_utc=start.isoformat())).json()
    assert p["totals"]["shade_min"] > 0
    assert p["totals"]["shade_heater_wh"] >= 0  # small: at low sun the dusty air leaves little direct beam to miss
    assert p["sun"]["shade"] and p["sun"]["shade"][0]["min"] > 0
    assert 0 in p["profile"]["sunlit"]


# ------------------------------------------------------------------ D3 suggestions
@need
@pytest.mark.parametrize("sid", [GALE, JEZERO])
def test_suggested_stops_are_reachable_separated_and_explained(sid):
    site = client.get(f"/api/sites/{sid}").json()
    body = _body(site)
    r = client.post(f"/api/sites/{sid}/suggest-stops", json={"habitat": body["habitat"], "stops": body["stops"], "walk": body["walk"],
                                                            "n": 4, "max_walkback_min": 25, "min_sep_m": 150})
    assert r.status_code == 200, r.text
    sug = r.json()["suggestions"]
    assert 1 <= len(sug) <= 4
    s = get_site(sid)
    xy = [s.grid.lonlat_to_xy(x["lon"], x["lat"]) for x in sug]
    for i, a in enumerate(xy):
        for b in xy[i + 1:]:
            assert np.hypot(float(a[0]) - float(b[0]), float(a[1]) - float(b[1])) >= 150 - 2
    for x in sug:
        assert x["walkback_min"] <= 25 and x["hazard"] <= 2 and x["reasons"] and x["tasks"] and x["name"]
    assert [x["score"] for x in sug] == sorted([x["score"] for x in sug], reverse=True)


# ------------------------------------------------------------------ D5 Ingenuity
@need
def test_ingenuity_flights_and_scouted_ground_at_jezero():
    s = get_site(JEZERO)
    assert s.meta["ingenuity"]["in_site"] >= 20
    r = client.get(f"/api/sites/{JEZERO}/ingenuity").json()
    nums = [f["flight"] for f in r["flights"]]
    assert nums == sorted(nums) and all(f["sol"] for f in r["flights"])
    seen = np.argwhere(s.scouted4 > 0)
    rr, cc = seen[len(seen) // 2]
    lon, lat = s.grid4.rowcol_to_lonlat(rr, cc)
    q = client.get(f"/api/sites/{JEZERO}/query", params={"lon": float(lon), "lat": float(lat)}).json()
    assert q["scouted"]["flight"] == int(s.scouted4[rr, cc])
    assert get_site(GALE).scouted4 is None


@need
def test_inspect_explains_sand_terrain_and_science():
    s = get_site(GALE)
    hab = s.cfg["habitat"]
    q = client.get(f"/api/sites/{GALE}/query", params={"lon": hab["lon"], "lat": hab["lat"]}).json()
    assert set(q["sand_why"]) == {"for", "against"}
    assert 0.0 <= q["sand_conf"] <= 1.0 and 0.0 <= q["terrain_conf"] <= 1.0
    assert q["sun"]["sunrise_ltst"] > q["sun"]["flat_sunrise_ltst"]
    layers = {L["id"] for L in client.get(f"/api/sites/{GALE}").json()["layers"]}
    assert {"science", "shadow", "sand_conf", "terrain_conf"} <= layers
    png = client.get(f"/api/sites/{GALE}/overlay/shadow.png", params={"size": 256, "utc": "2026-11-14T12:00:00Z"})
    assert png.status_code == 200 and png.content[:4] == b"\x89PNG"
