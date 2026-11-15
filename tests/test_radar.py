"""Ground radar under the rover's track (feature E1): reading the RIMFAX browse radargrams, laying them along the
drive, packing the atlas, and the API."""

import io

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from marsgeo.grid import SiteGrid
from pipeline import radar as rp
from server import radar as rs
from server.main import app
from server.site_store import get_site, is_built

client = TestClient(app)
JEZERO = "jezero_threeforks"


def _radargram(surface: np.ndarray, rows: int = 900, seed: int = 1) -> np.ndarray:
    """Synthetic browse radargram (value - 128): faint noise above each column's surface, a strong echo train below."""
    rng = np.random.default_rng(seed)
    img = rng.normal(0.0, 4.0, (rows, len(surface))).astype(np.float32)
    t = np.arange(rows)
    for c, s in enumerate(surface):
        below = t >= s
        img[below, c] = 110.0 * np.sin((t[below] - s) * 0.9) * np.exp(-(t[below] - s) / 500.0)
    return img


def test_surface_found_under_the_topography_shift():
    surf = (60 + 25 * np.sin(np.linspace(0, 3, 120))).astype(int)
    found = rp.surface_rows(_radargram(surf))
    assert np.abs(found - surf).max() <= 3


def test_stacked_traces_are_aligned_at_the_surface():
    surf = np.array([40, 40, 70, 70, 100, 100] * 4)
    img = _radargram(surf)
    out = rp.stack_columns(img, surf, stack=2, t_max_ns=60.0, rows=120)
    assert out.shape == (120, len(surf) // 2)
    # the same echo train under every column, wherever its surface sat
    assert np.allclose(out[:, 0], out[:, 1], atol=1.0) and np.allclose(out[:, 0], out[:, 2], atol=1.0)
    assert np.abs(out[:10]).mean() > 40   # strong echoes right under the surface
    u8 = rp.to_u8(out)
    assert u8.dtype == np.uint8 and abs(int(np.median(u8)) - 128) < 30


def test_columns_follow_the_drive():
    xy = np.array([[0.0, 0.0], [30.0, 0.0], [30.0, 40.0]])   # an L, 70 m long
    p = rp.polyline_at(xy, np.array([0.0, 15.0, 30.0, 50.0, 70.0]))
    assert np.allclose(p, [[0, 0], [15, 0], [30, 0], [30, 20], [30, 40]])


def test_only_long_runs_inside_the_site_are_kept():
    g = SiteGrid.from_bbox([77.38, 18.4275, 77.4375, 18.4825], 1.0)
    x0, x1 = g.x_min, g.x_max
    y = 0.5 * (g.y_min + g.y_max)
    xs = np.concatenate([np.linspace(x0 - 50, x0 - 10, 20),     # outside
                         np.linspace(x0 + 10, x0 + 60, 30),     # inside, long enough
                         np.linspace(x1 + 10, x1 + 30, 5),      # outside
                         np.linspace(x1 - 30, x1 - 20, 4)])     # inside but too short
    runs = rp.runs_inside(np.column_stack([xs, np.full_like(xs, y)]), g, min_run=10)
    assert runs == [(20, 50)]


def test_atlas_splits_a_run_across_strips():
    a = rp.Atlas(width=100, rows=8, pad=2)
    first = a.add(np.full((8, 70), 10, np.uint8))
    second = a.add(np.full((8, 50), 200, np.uint8))
    assert first == [(0, 0, 0, 70)]
    assert second == [(0, 70, 0, 30), (1, 0, 30, 20)]
    im = a.image()
    assert im.shape == (20, 100) and im[0, 69] == 10 and im[0, 70] == 200 and im[10, 19] == 200 and im[10, 20] == 128
    assert (im[8:10] == 128).all()   # the padding rows stay at zero


def test_runs_concatenate_their_pieces():
    doc = {"col_m": 0.2, "rows": 4, "atlas": {"strip_h": 6},
           "tracks": [{"run": 0, "sol": 400, "utc": "2022", "strip": 0, "x0": 10, "n": 3, "d0_m": 5.0,
                       "lon": [1, 2, 3], "lat": [4, 5, 6], "z": [0, 0, 0]},
                      {"run": 0, "sol": 400, "utc": "2022", "strip": 1, "x0": 0, "n": 2, "d0_m": 5.6,
                       "lon": [7, 8], "lat": [9, 10], "z": [0, 0]}]}
    runs = rs.group_runs(doc)
    assert len(runs) == 1 and runs[0]["n"] == 5 and runs[0]["lon"] == [1, 2, 3, 7, 8]
    assert runs[0]["pieces"] == [[0, 10, 3, 0], [1, 0, 2, 3]]
    atlas = np.zeros((12, 20), np.uint8)
    atlas[0:4, 10:13] = 50
    atlas[6:10, 0:2] = 60
    cols = rs.run_columns(doc, atlas, runs[0])
    assert cols.shape == (4, 5) and (cols[:, :3] == 50).all() and (cols[:, 3:] == 60).all()
    rgb = rs.palette(np.array([[0, 128, 255]], np.uint8))
    assert rgb[0, 0].sum() < rgb[0, 1].sum() < rgb[0, 2].sum()


@pytest.mark.skipif(not is_built(JEZERO) or not (get_site(JEZERO).dir / "radar.json").exists(),
                    reason="Jezero radar not built")
def test_radar_api_at_jezero():
    d = client.get(f"/api/sites/{JEZERO}/radar").json()
    assert d["instrument"].startswith("RIMFAX") and d["depth_m"] == pytest.approx(5.0, abs=0.1)
    assert len(d["sols"]) >= 30 and d["length_m"] > 3000 and d["runs"]
    r = max(d["runs"], key=lambda r: r["n"])
    assert len(r["lon"]) == len(r["lat"]) == r["n"] and sum(p[2] for p in r["pieces"]) == r["n"]
    # the nearest column to a point on a track is that point
    k = r["n"] // 2
    near = client.get(f"/api/sites/{JEZERO}/radar", params={"lon": r["lon"][k], "lat": r["lat"][k]}).json()["nearest"]
    assert near["run"] == r["run"] and near["dist_m"] < 0.5 and abs(near["i"] - k) <= 1
    far = client.get(f"/api/sites/{JEZERO}/radar", params={"lon": 77.381, "lat": 18.428, "within_m": 5}).json()
    assert far["nearest"] is None
    png = client.get(f"/api/sites/{JEZERO}/radar/run/{r['run']}.png")
    assert png.status_code == 200
    im = Image.open(io.BytesIO(png.content))
    assert im.size == (r["n"], d["rows"]) and im.mode == "RGB"
    assert client.get(f"/api/sites/{JEZERO}/radar/run/99999.png").status_code == 404
    atlas = Image.open(io.BytesIO(client.get(f"/api/sites/{JEZERO}/radar/atlas.png").content))
    assert atlas.size == (d["atlas"]["w"], d["atlas"]["h"])
    # every column sits inside the site
    s = get_site(JEZERO)
    lon0, lat0, lon1, lat1 = s.grid.bounds_lonlat()
    for run in d["runs"]:
        assert all(lon0 <= v <= lon1 for v in run["lon"]) and all(lat0 <= v <= lat1 for v in run["lat"])


@pytest.mark.skipif(not is_built("gale_boxwork"), reason="site not built")
def test_gale_has_no_radar():
    d = client.get("/api/sites/gale_boxwork/radar").json()
    assert d["runs"] == [] and "Perseverance" in d["note"]
