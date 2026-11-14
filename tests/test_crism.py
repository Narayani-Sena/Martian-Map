"""CRISM browse-product georeferencing (synthetic label and image, no network)."""

import numpy as np
import pytest
from fastapi.testclient import TestClient

from marsgeo.grid import SiteGrid
from pipeline.crism import parse_label, to_grid

LABEL = """
  LINES                        = 100
  LINE_SAMPLES                 = 120
  MAP_PROJECTION_TYPE          = "EQUIRECTANGULAR"
  MAP_RESOLUTION               = 3000.0 <PIX/DEG>
  MAXIMUM_LATITUDE             = -4.7000000 <DEGREE>
  MINIMUM_LATITUDE             = -4.7333333 <DEGREE>
  EASTERNMOST_LONGITUDE        = 137.4400000 <DEGREE>
  WESTERNMOST_LONGITUDE        = 137.4000000 <DEGREE>
  BAND_NAME                    = ( "SINDEX2", "BD2100_2",
                                   "BD1900_2")
"""


def test_parse_label_reads_projection_and_bands():
    lab = parse_label(LABEL)
    assert lab["res"] == 3000.0 and lab["lines"] == 100 and lab["samples"] == 120
    assert lab["north"] == pytest.approx(-4.7) and lab["west"] == pytest.approx(137.4)
    assert lab["bands"] == ["SINDEX2", "BD2100_2", "BD1900_2"]


def test_to_grid_puts_a_pixel_at_its_longitude_and_latitude():
    lab = parse_label(LABEL)
    img = np.zeros((100, 120, 4), np.uint8)
    img[..., 3] = 255
    img[50, 60, :3] = 255
    lon = lab["west"] + 60.5 / lab["res"]
    lat = lab["north"] - 50.5 / lab["res"]
    grid = SiteGrid.from_bbox((lon - 0.0006, lat - 0.0006, lon + 0.0006, lat + 0.0006), res=4.0)
    rgb, valid = to_grid(img, lab, grid)
    assert valid.all()
    r, c = np.unravel_index(int(np.argmax(rgb[..., 0])), rgb.shape[:2])
    x, y = grid.rowcol_to_xy(r, c)
    lo, la = grid.xy_to_lonlat(x, y)
    assert abs(float(lo) - lon) < 1.0 / lab["res"] and abs(float(la) - lat) < 1.0 / lab["res"]


def test_no_data_outside_the_footprint():
    lab = parse_label(LABEL)
    img = np.zeros((100, 120, 4), np.uint8)
    img[..., 3] = 255
    grid = SiteGrid.from_bbox((137.30, -4.72, 137.31, -4.71), res=4.0)  # west of the image
    _, valid = to_grid(img, lab, grid)
    assert not valid.any()


def test_api_lists_and_drapes_crism_layers():
    from server.main import app
    from server.site_store import get_site, is_built
    if not is_built("gale_boxwork") or not get_site("gale_boxwork").crism:
        pytest.skip("CRISM layers not built for the site")
    client = TestClient(app)
    layers = client.get("/api/sites/gale_boxwork").json()["layers"]
    ids = [L["id"] for L in layers if L["id"].startswith("crism_")]
    assert "crism_hyd" in ids
    r = client.get("/api/sites/gale_boxwork/overlay/crism_hyd.png?size=256")
    assert r.status_code == 200 and r.content[:4] == b"\x89PNG"
    q = client.get("/api/sites/gale_boxwork/query?lon=137.377026&lat=-4.805671").json()
    assert "hyd" in q["crism"] and len(q["crism"]["hyd"]["rgb"]) == 3
