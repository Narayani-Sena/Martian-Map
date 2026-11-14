"""Draped layers for the 3D console: small palette PNGs, rendered fast, kept on disk once rendered."""

import io
import time

import pytest
from PIL import Image

from server import main
from server.site_store import is_built

SITE = "gale_boxwork"
pytestmark = pytest.mark.skipif(not is_built(SITE), reason="site not built")


def test_static_drape_is_a_palette_png_cached_on_disk(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "OVERLAY_DIR", tmp_path)
    main._overlay_cache.clear()
    t = time.perf_counter()
    png = main._overlay_bytes(SITE, "slope", 1024)
    assert time.perf_counter() - t < 5.0  # was ~2 s isolated and 10+ s under load before the rewrite
    im = Image.open(io.BytesIO(png))
    assert im.mode == "P" and im.size == (1024, 1024) and "transparency" in im.info
    files = list((tmp_path / SITE).glob("slope_1024_*.png"))
    assert len(files) == 1 and files[0].read_bytes() == png
    main._overlay_cache.clear()
    assert main._overlay_bytes(SITE, "slope", 1024) == png  # straight from disk


def test_dynamic_drapes_are_not_written_to_disk(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "OVERLAY_DIR", tmp_path)
    png = main._overlay_bytes(SITE, "hazard", 512)
    assert Image.open(io.BytesIO(png)).size == (512, 512)
    assert not any(tmp_path.rglob("*.png"))


def test_crism_drape_keeps_its_colours(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "OVERLAY_DIR", tmp_path)
    s = main._site(SITE)
    if not s.crism:
        pytest.skip("no CRISM layers built")
    kind = next(iter(s.crism))
    im = Image.open(io.BytesIO(main._overlay_bytes(SITE, f"crism_{kind}", 512)))
    assert im.mode == "RGBA" and im.getextrema()[3][1] > 0  # some pixels are visible
