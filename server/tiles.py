"""Dynamic raster map tiles rendered straight from the site arrays.

Each tile pixel is mapped back to the site grid (Web-Mercator tile -> lon/lat
-> grid row/col), sampled, and coloured through a lookup table. This is what
tile servers like TiTiler do; here it is ~60 lines of numpy.
"""

from __future__ import annotations

import io
from functools import lru_cache

import numpy as np
from PIL import Image

from marsgeo import tiles as T
from marsgeo.grid import sample_bilinear


def lut(stops) -> np.ndarray:
    """stops: [(position 0..1, (r, g, b, a)), ...] -> (256, 4) uint8."""
    x = np.linspace(0, 1, 256)
    pos = [s[0] for s in stops]
    out = np.zeros((256, 4))
    for ch in range(4):
        out[:, ch] = np.interp(x, pos, [s[1][ch] for s in stops])
    return out.astype(np.uint8)


def _hex(h: str, a: int = 255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


# Continuous colour ramps (positions are fractions of vmin..vmax)
LUTS = {
    "slope": lut([(0.0, _hex("1a9850", 70)), (0.25, _hex("91cf60", 110)), (0.375, _hex("fee08b", 150)),
                  (0.5, _hex("fc8d59", 175)), (0.625, _hex("d73027", 200)), (1.0, _hex("67001f", 230))]),
    "roughness": lut([(0.0, _hex("2c7bb6", 0)), (0.15, _hex("2c7bb6", 60)), (0.35, _hex("abd9e9", 130)),
                      (0.55, _hex("fdae61", 180)), (1.0, _hex("d7191c", 230))]),
    "sand": lut([(0.0, _hex("f6d58b", 0)), (0.45, _hex("f6d58b", 0)), (0.6, _hex("f2c464", 110)),
                 (0.8, _hex("e8a33c", 180)), (1.0, _hex("c97a1e", 220))]),
    "shielding": lut([(0.0, _hex("6baed6", 0)), (0.06, _hex("6baed6", 40)), (0.25, _hex("4292c6", 130)),
                      (0.5, _hex("2171b5", 180)), (1.0, _hex("54278f", 230))]),
    "boulders": lut([(0.0, _hex("000000", 0)), (0.17, _hex("000000", 0)), (0.19, _hex("ffd166", 210)), (0.5, _hex("ff8a3d", 235)), (1.0, _hex("c1121f", 255))]),
    "skyview": lut([(0.0, _hex("3f007d", 220)), (0.5, _hex("807dba", 120)), (0.85, _hex("dadaeb", 40)), (1.0, _hex("ffffff", 0))]),
    "thermal": lut([(0.0, _hex("000004")), (0.25, _hex("420a68")), (0.5, _hex("932667")),
                    (0.75, _hex("dd513a")), (0.9, _hex("fca50a")), (1.0, _hex("fcffa4"))]),
    "thermal_day": lut([(0.0, _hex("0b1d51")), (0.25, _hex("3a6ea5")), (0.5, _hex("f2e3c6")),
                        (0.75, _hex("f0a35e")), (1.0, _hex("c8442b"))]),
    "elevation": lut([(0.0, _hex("2b3a67")), (0.15, _hex("3d6b8c")), (0.3, _hex("5f9e8f")), (0.45, _hex("a9c47f")),
                      (0.6, _hex("e9d98b")), (0.75, _hex("d99a5b")), (0.9, _hex("a65c3a")), (1.0, _hex("f2e6dc"))]),
    "hillshade": lut([(0.0, (0, 0, 0, 255)), (1.0, (255, 255, 255, 255))]),
    # confidence: low confidence loud, high confidence nearly clear (what to double-check stands out)
    "confidence": lut([(0.0, _hex("d7191c", 200)), (0.35, _hex("fdae61", 165)), (0.6, _hex("ffffbf", 90)),
                       (0.85, _hex("a6d96a", 25)), (1.0, _hex("1a9641", 0))]),
    # skyline fix radius, 0..240 m: a small radius (good fix) nearly clear, a big one loud
    "fixq": lut([(0.0, _hex("1a9850", 40)), (0.1, _hex("a6d96a", 70)), (0.25, _hex("fee08b", 140)), (0.5, _hex("f46d43", 185)),
                 (1.0, _hex("a50026", 215))]),
    "science": lut([(0.0, _hex("6a3d9a", 0)), (0.2, _hex("6a3d9a", 0)), (0.4, _hex("6a3d9a", 110)),
                    (0.65, _hex("e7298a", 180)), (1.0, _hex("ffd92f", 235))]),
}

SHADOW_COLORS = np.array([(0, 0, 0, 0), _hex("1b2a6b", 150), _hex("0a0f2a", 190)], np.uint8)
SCOUTED_COLORS = np.array([(0, 0, 0, 0), _hex("3ad6c6", 120)], np.uint8)

HAZARD_COLORS = np.array([(0, 0, 0, 0), _hex("ffd84d", 95), _hex("ff9a2e", 150), _hex("e8383d", 185), _hex("7a1fa2", 215)], np.uint8)
WALKBACK_BANDS = [(15, _hex("2ecc71", 60)), (30, _hex("9be15d", 70)), (45, _hex("f4e04d", 80)), (60, _hex("f7a541", 95)),
                  (90, _hex("f0643c", 115)), (120, _hex("d62f4b", 140)), (1e9, _hex("6d0f3a", 165))]
COMMS_COLORS = np.array([_hex("ff3b5c", 120), _hex("ffb020", 95), _hex("33d1ff", 0)], np.uint8)

LEGENDS = {
    "slope": {"unit": "deg", "stops": [[0, "#1a9850"], [10, "#91cf60"], [15, "#fee08b"], [20, "#fc8d59"], [25, "#d73027"], [40, "#67001f"]]},
    "roughness": {"unit": "m RMS", "stops": [[0, "#2c7bb6"], [0.15, "#abd9e9"], [0.3, "#fdae61"], [0.6, "#d7191c"]]},
    "sand": {"unit": "likelihood", "stops": [[0.45, "#f6d58b"], [0.6, "#f2c464"], [0.8, "#e8a33c"], [1.0, "#c97a1e"]]},
    "shielding": {"unit": "% GCR blocked", "stops": [[0, "#6baed6"], [5, "#4292c6"], [10, "#2171b5"], [20, "#54278f"]]},
    "boulders": {"unit": "m (largest boulder in the cell)", "stops": [[0.75, "#ffd166"], [2, "#ff8a3d"], [4, "#c1121f"]]},
    "skyview": {"unit": "sky fraction", "stops": [[0, "#3f007d"], [0.5, "#807dba"], [0.85, "#dadaeb"], [1, "#ffffff"]]},
    "thermal": {"unit": "THEMIS night IR (relative)", "stops": [[0, "#000004"], [0.5, "#932667"], [1, "#fcffa4"]]},
    "thermal_day": {"unit": "THEMIS day IR (relative: cold to warm)", "stops": [[0, "#0b1d51"], [0.5, "#f2e3c6"], [1, "#c8442b"]]},
    "hazard": {"classes": [["Easy", "#00000000"], ["Moderate", "#ffd84d"], ["Difficult", "#ff9a2e"], ["Hazardous", "#e8383d"], ["No-go", "#7a1fa2"]]},
    "walkback": {"classes": [[f"< {b} min" if b < 1e8 else "> 120 min", "#%02x%02x%02x" % c[:3]] for b, c in WALKBACK_BANDS]},
    "comms": {"classes": [["Dead zone", "#ff3b5c"], ["Marginal", "#ffb020"], ["Line of sight", "#33d1ff"]]},
    "confidence": {"unit": "0 = the clues disagree, 1 = they agree", "stops": [[0, "#d7191c"], [0.35, "#fdae61"], [0.6, "#ffffbf"], [1, "#1a9641"]]},
    "science": {"unit": "science opportunity (0-1)", "stops": [[0.2, "#6a3d9a"], [0.65, "#e7298a"], [1.0, "#ffd92f"]]},
    "shadow": {"classes": [["Sunlit", "#00000000"], ["Terrain shadow", "#1b2a6b"], ["Sun below the horizon", "#0a0f2a"]]},
    "scouted": {"classes": [["Not seen", "#00000000"], ["Seen from the air by Ingenuity", "#3ad6c6"]]},
}

_EMPTY = None


def empty_png() -> bytes:
    global _EMPTY
    if _EMPTY is None:
        buf = io.BytesIO()
        Image.new("RGBA", (256, 256), (0, 0, 0, 0)).save(buf, "PNG", optimize=True)
        _EMPTY = buf.getvalue()
    return _EMPTY


def encode(rgba: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, "PNG", compress_level=3)
    return buf.getvalue()


@lru_cache(maxsize=4096)
def _tile_lonlat(z: int, x: int, y: int):
    lon, lat = T.tile_pixel_lonlat(x, y, z)
    return lon, lat


def tile_rowcol(grid, z, x, y):
    lon, lat = _tile_lonlat(z, x, y)
    return grid.lonlat_to_rowcol(lon, lat)


def intersects(grid, z, x, y) -> bool:
    return T.tile_intersects(x, y, z, grid.bounds_lonlat())


def _inside(grid, rr, cc):
    return (rr >= -0.5) & (rr <= grid.height - 0.5) & (cc >= -0.5) & (cc <= grid.width - 0.5)


def render_continuous(arr, grid, z, x, y, vmin, vmax, lut_name) -> bytes:
    rr, cc = tile_rowcol(grid, z, x, y)
    vals = sample_bilinear(arr, rr, cc)
    idx = np.clip((vals - vmin) / (vmax - vmin) * 255.0, 0, 255)
    idx = np.nan_to_num(idx).astype(np.uint8)
    rgba = LUTS[lut_name][idx]
    rgba[~_inside(grid, rr, cc) | ~np.isfinite(vals)] = 0
    return encode(rgba)


def render_classes(arr_u8, grid, z, x, y, colors: np.ndarray, hatch_class: int | None = None) -> bytes:
    rr, cc = tile_rowcol(grid, z, x, y)
    ri = np.clip(np.rint(rr).astype(int), 0, grid.height - 1)
    ci = np.clip(np.rint(cc).astype(int), 0, grid.width - 1)
    cls = arr_u8[ri, ci]
    rgba = colors[np.clip(cls, 0, len(colors) - 1)].copy()
    if hatch_class is not None:
        # diagonal stripes so dead zones read clearly over imagery
        py, px = np.mgrid[0:256, 0:256]
        stripe = ((px + py + (x * 256 + y * 256)) // 6) % 2 == 0
        m = (cls == hatch_class) & stripe
        rgba[m, 3] = np.minimum(255, rgba[m, 3].astype(int) + 70).astype(np.uint8)
    rgba[~_inside(grid, rr, cc)] = 0
    return encode(rgba)


def render_walkback(field_s, grid, z, x, y) -> bytes:
    rr, cc = tile_rowcol(grid, z, x, y)
    minutes = sample_bilinear(np.where(np.isfinite(field_s), field_s / 60.0, 1e6).astype(np.float32), rr, cc)
    rgba = np.zeros(minutes.shape + (4,), np.uint8)
    lo = -1.0
    for hi, col in WALKBACK_BANDS:
        m = (minutes > lo) & (minutes <= hi)
        rgba[m] = col
        lo = hi
    rgba[~_inside(grid, rr, cc)] = 0
    return encode(rgba)


def render_hillshade(hs_u8, grid, z, x, y) -> bytes:
    rr, cc = tile_rowcol(grid, z, x, y)
    vals = sample_bilinear(hs_u8.astype(np.float32), rr, cc)
    g = np.nan_to_num(vals, nan=255).astype(np.uint8)
    rgba = np.stack([g, g, g, np.full_like(g, 255)], -1)
    rgba[~_inside(grid, rr, cc)] = (255, 255, 255, 0)
    return encode(rgba)


def render_rgba(rgba: np.ndarray, grid, z: int, x: int, y: int) -> bytes:
    """Tile from an RGBA image that lives on a site grid (nearest pixel; transparent outside)."""
    rr, cc = tile_rowcol(grid, z, x, y)
    ri = np.rint(rr).astype(int)
    ci = np.rint(cc).astype(int)
    h, w = rgba.shape[:2]
    ok = (ri >= 0) & (ri < h) & (ci >= 0) & (ci < w)
    out = np.zeros(ri.shape + (4,), np.uint8)
    out[ok] = rgba[ri[ok], ci[ok]]
    return encode(out)
