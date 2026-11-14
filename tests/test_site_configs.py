"""Every site config is complete and self-consistent; every built site plans an EVA."""

import pytest

from server.site_store import is_built, load_config, site_ids

REQUIRED = ("id", "name", "short_name", "region", "mission", "rover_name", "story", "bbox", "dem", "basemap",
            "rover", "habitat", "stops", "shelters", "radio")


def _inside(bbox, lon, lat):
    return bbox[0] <= lon <= bbox[2] and bbox[1] <= lat <= bbox[3]


@pytest.mark.parametrize("sid", site_ids())
def test_config_is_complete(sid):
    cfg = load_config(sid)
    for k in REQUIRED:
        assert k in cfg, f"{sid}: missing {k}"
    assert cfg["id"] == sid
    b = cfg["bbox"]
    assert b[0] < b[2] and b[1] < b[3] and (b[2] - b[0]) < 0.2 and (b[3] - b[1]) < 0.2
    assert _inside(b, cfg["habitat"]["lon"], cfg["habitat"]["lat"]), "habitat outside the site"
    ids = set()
    for st in cfg["stops"]:
        assert _inside(b, st["lon"], st["lat"]), f"stop {st['name']} outside the site"
        assert st["id"] not in ids and st.get("tasks") and 5 <= st.get("dwell_min", 20) <= 120
        ids.add(st["id"])
    for sh in cfg["shelters"]:
        assert _inside(b, sh["lon"], sh["lat"])
    rv = cfg["rover"]
    assert rv["raw_images_mission"] in ("msl", "mars2020") and rv["landing_msd_local"] > 40000
    assert "{z}" in cfg["basemap"]["url"] and cfg["dem"]["collection"] == "mro_hirise_socet_dtms"


def test_there_are_two_sites():
    assert {"gale_boxwork", "jezero_threeforks"} <= set(site_ids())


@pytest.mark.parametrize("sid", [s for s in site_ids() if is_built(s)])
def test_every_built_site_plans_an_eva(sid):
    from fastapi.testclient import TestClient

    from server.main import app
    c = TestClient(app)
    site = c.get(f"/api/sites/{sid}").json()
    body = {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"]}
    r = c.post(f"/api/sites/{sid}/plan", json=body)
    assert r.status_code == 200, r.text
    p = r.json()
    assert len(p["legs"]) == len(site["stops"]) + 1
    assert p["totals"]["dist_m"] > 300 and p["totals"]["min_margin_min"] > 0
