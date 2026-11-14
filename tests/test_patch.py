"""Mission patch (feature G1): drawn from the route, named for the crew, printed on the traverse sheet."""

import re
import xml.etree.ElementTree as ET

import pytest
from fastapi.testclient import TestClient

from server.main import app
from server.site_store import is_built

SITE = "gale_boxwork"
client = TestClient(app)
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


@pytest.fixture(scope="module")
def site():
    return client.get(f"/api/sites/{SITE}").json()


def _body(site, **extra):
    hab = [site["habitat"]["lon"], site["habitat"]["lat"]]
    stops = [[s["lon"], s["lat"]] for s in site["stops"]]
    return {"route": [hab] + stops + [hab], "stops": stops, "habitat": hab, **extra}


def test_patch_is_well_formed_svg_with_the_names(site):
    r = client.post(f"/api/sites/{SITE}/patch.svg", json=_body(site, crew=["Asha", "Bo"], sol=5075, dist_km=1.92, suit_min=162))
    assert r.status_code == 200 and r.headers["content-type"].startswith("image/svg+xml")
    root = ET.fromstring(r.text)
    assert root.tag.endswith("svg")
    text = " ".join(t.strip() for t in root.itertext() if t.strip())
    assert "ASHA · BO · SOL 5075" in text and "EVA-1" in text and "1.92 KM · 2 H 42" in text
    size = float(root.get("width"))
    # the route line stays inside the inner disc
    route = next(p for p in root.iter() if p.tag.endswith("path") and p.get("d", "").startswith("M") and " L" in p.get("d", ""))
    pts = [tuple(map(float, xy.split(","))) for xy in re.findall(r"[ML]([-\d.]+,[-\d.]+)", route.get("d"))]
    assert len(pts) == len(site["stops"]) + 2
    c, r_in = size / 2, size * 0.355
    assert all(((x - c) ** 2 + (y - c) ** 2) ** 0.5 < r_in for x, y in pts)
    # one star per stop
    assert sum(1 for p in root.iter() if p.tag.endswith("polygon")) == len(site["stops"])


def test_names_are_escaped(site):
    r = client.post(f"/api/sites/{SITE}/patch.svg", json=_body(site, crew=["<b>Eve</b>", "A&B"]))
    root = ET.fromstring(r.text)  # still parses
    assert "<B>EVE</B> · A&B" in " ".join(root.itertext())


def test_patch_needs_a_route(site):
    assert client.post(f"/api/sites/{SITE}/patch.svg", json={"route": [[0, 0]]}).status_code == 422


def test_traverse_sheet_carries_the_patch(site):
    body = {"habitat": {k: site["habitat"][k] for k in ("lon", "lat")},
            "stops": [{k: s[k] for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks")} for s in site["stops"]],
            "walk": site["defaults"]["walk"], "suit": site["defaults"]["suit"], "start_utc": site["defaults"]["start_utc"],
            "crew": ["Mira", "Teo"]}
    html = client.post(f"/api/sites/{SITE}/traverse-sheet", json=body).text
    assert 'aria-label="EVA patch' in html and "MIRA · TEO" in html
