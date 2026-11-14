"""Flood the crater (feature A4): the lake statistics, the depth drape, and the one body of water the 3D view draws."""

import io

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from server import lake
from server.main import app
from server.site_store import get_site, is_built, load_config

pytestmark = pytest.mark.skipif(not is_built("jezero_threeforks"), reason="jezero_threeforks not built")
client = TestClient(app)


def test_kodiak_level_matches_the_measurement():
    """At -2,500 m (Mangold et al. 2024: Kodiak and Eastern Cape) 57 % of the site is under water, about 46 m over
    the habitat and 19 m over Wildcat Ridge."""
    j = client.get("/api/sites/jezero_threeforks/lake", params={"level": -2500}).json()
    assert 0.54 <= j["share_under"] <= 0.60
    depth = {p["name"]: p["depth_m"] for p in j["points"]}
    assert 43 <= depth["Hab"] <= 49
    assert 16 <= depth["Wildcat Ridge"] <= 22
    assert [round(v["elev"]) for v in j["levels"]] == [-2400, -2410, -2448, -2500]
    # higher water covers more of the site
    hi = client.get("/api/sites/jezero_threeforks/lake", params={"level": -2448}).json()
    assert hi["share_under"] > j["share_under"]


def test_mask_is_one_body_of_water():
    """The mask keeps the crater's lake and leaves the low plains outside the rim dry, and it always covers the
    site's own footprint (where the 3D view draws the shoreline from the 1 m terrain)."""
    s = get_site("jezero_threeforks")
    arr, rg = s.regional
    z = arr + float(s.meta.get("regional_offset_m", 0.0))
    m = lake.mask(s, -2500.0) > 0
    below = np.isfinite(z) & (z < -2500.0)
    assert m.shape == arr.shape
    assert 0.08 < m.mean() < 0.18                      # the crater floor, not the region
    assert (below & ~m).sum() > 0.25 * below.sum()      # plenty of low ground outside the rim stays dry
    g = s.grid
    r = int((rg.y_max - g.y_max + g.height * g.res / 2) / rg.res)
    c = int((g.x_min + g.width * g.res / 2 - rg.x_min) / rg.res)
    assert m[r, c]                                       # the site's centre is in it


def test_mask_endpoint():
    r = client.get("/api/sites/jezero_threeforks/lake/mask.png", params={"level": -2500})
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"
    im = Image.open(io.BytesIO(r.content))
    a = np.asarray(im)
    assert im.mode == "L" and set(np.unique(a)) <= {0, 255}
    cfg = load_config("jezero_threeforks")
    assert a.shape[0] > 100 and cfg["lake"]["levels"]
