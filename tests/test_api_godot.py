"""Endpoints added for the native Godot client (raw grids, image proxy, overlay cache)."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from server.main import app
from server.site_store import is_built

SITE = "gale_boxwork"
client = TestClient(app)
built = pytest.mark.skipif(not is_built(SITE), reason="site not built (run the pipeline first)")


@pytest.mark.parametrize("url", [
    "https://example.com/a.jpg",
    "https://mars.nasa.gov.evil.example/a.jpg",
    "file:///C:/Windows/win.ini",
    "ftp://mars.nasa.gov/a.jpg",
])
def test_image_proxy_only_fetches_from_nasa(url):
    r = client.get("/api/image-proxy", params={"url": url})
    assert r.status_code == 403


@built
def test_dem_bin_matches_its_headers():
    r = client.get(f"/api/sites/{SITE}/dem.bin")
    assert r.status_code == 200
    rows, cols = (int(v) for v in r.headers["x-shape"].split(","))
    a = np.frombuffer(r.content, dtype="<f4")
    assert a.size == rows * cols
    assert np.isfinite(a).all()
    # Gale boxwork sits a few km below the Mars datum
    assert -4500 < float(a.min()) < float(a.max()) < -3000


@built
def test_regional_bin_has_offset_and_shape():
    r = client.get(f"/api/sites/{SITE}/regional.bin")
    assert r.status_code == 200
    rows, cols = (int(v) for v in r.headers["x-shape"].split(","))
    assert np.frombuffer(r.content, dtype="<f4").size == rows * cols
    float(r.headers["x-offset"])


@built
@pytest.mark.parametrize("layer", ["slope", "skyview", "thermal"])
def test_overlay_png_is_cached(layer):
    url = f"/api/sites/{SITE}/overlay/{layer}.png?size=256"
    a = client.get(url)
    assert a.status_code == 200 and a.content[:8] == b"\x89PNG\r\n\x1a\n"
    b = client.get(url)
    assert b.content == a.content
