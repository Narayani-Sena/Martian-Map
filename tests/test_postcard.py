"""Arrival postcards (feature G2): a view rendered from the terrain at the arrival time and sun, beside a rover photo."""

import math
from datetime import datetime, timezone

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import postcard
from server.main import app
from server.site_store import get_site, is_built

SITE = "gale_boxwork"
client = TestClient(app)
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """The rover photo comes from NASA's raw image feed; tests stay offline."""
    monkeypatch.setattr(postcard, "rover_photo", lambda *a, **k: None)


@pytest.fixture(scope="module")
def body():
    site = client.get(f"/api/sites/{SITE}").json()
    return {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"],
            "space_weather": "off"}


def test_render_has_sky_above_and_ground_below():
    s = get_site(SITE)
    hab = s.cfg["habitat"]
    when = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
    im = postcard.render(s, hab["lon"], hab["lat"], 200.0, when, w=320, h=150)
    a = np.asarray(im).astype(int)
    assert a.shape == (150, 320, 3)
    top, bottom = a[0].mean(axis=0), a[-1].mean(axis=0)
    assert top[0] > top[2]                          # a dusty, reddish Martian sky
    assert np.abs(a[-1] - a[-1].mean(axis=0)).mean() > 1.0 or abs(bottom - top).sum() > 20  # ground, not sky


def test_flag_marks_the_stop():
    s = get_site(SITE)
    st = s.cfg["stops"][0]
    when = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
    lat0 = math.radians(st["lat"])
    lon_back = st["lon"] - 20.0 / (59274.0 * math.cos(lat0))  # 20 m west of the stop, looking east at it
    im = postcard.render(s, lon_back, st["lat"], 90.0, when, w=320, h=150, flag=(st["lon"], st["lat"], "S1"))
    a = np.asarray(im).astype(int)
    orange = (a[..., 0] > 220) & (a[..., 1] > 100) & (a[..., 1] < 160) & (a[..., 2] < 80)
    cols = np.flatnonzero(orange.any(axis=0))
    assert cols.size and abs(cols.mean() - 160) < 40     # the flag stands near the middle of the view


def test_arrival_viewpoint_is_a_few_steps_back_facing_the_stop():
    path = [[137.0, -4.8], [137.0 + 100 / 59274.0, -4.8]]  # 100 m due east (near enough at this latitude)
    lon, lat, hd = postcard.arrival_viewpoint(path, back_m=16.0)
    assert 60 <= hd <= 120                             # heading east, towards the stop
    back = (path[-1][0] - lon) * 59274.0 * math.cos(math.radians(-4.8))
    assert 14 <= back <= 101


def test_sun_words():
    assert "behind you" in postcard.sun_words(40, 270, 90)
    assert "ahead" in postcard.sun_words(40, 95, 90)
    assert "to your right" in postcard.sun_words(40, 180, 90)
    assert postcard.sun_words(-5, 0, 0) == "the sun is down"


def test_postcards_page_has_a_card_per_stop(body):
    r = client.post(f"/api/sites/{SITE}/postcards", json=body)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    html = r.text
    assert html.count('<section class="card">') == len(body["stops"])
    assert html.count("data:image/jpeg;base64,") == len(body["stops"])
    for st in body["stops"]:
        assert st["name"] in html
    assert 'aria-label="EVA patch' in html                       # the patch as the stamp
    assert "No rover photo to hand" in html                       # offline: said plainly, not faked


def test_traverse_sheet_gets_a_postcards_page(body):
    html = client.post(f"/api/sites/{SITE}/traverse-sheet", json=body).text
    assert "ARRIVAL POSTCARDS" in html and html.count("class='pc'") == len(body["stops"])
