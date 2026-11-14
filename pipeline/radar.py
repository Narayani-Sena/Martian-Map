"""Ground-penetrating radar under the rover's track (feature E1): what lies under the ground the crew walks over.

Perseverance's RIMFAX radar sounds the ground every 10 cm while the rover drives (sounding_group_spacing = 10 cm in
the archive's catalogue). For every sol with data the PDS Geosciences Node publishes the calibrated radargram as a
browse image (browse_radargram/<year>/rimfax_browse_<sol>.png): one column per sounding of the Shallow mode, 2,048
rows of two-way travel time at 0.1419 ns (0 to 290 ns), the surface shifted down by the topography. A browse image
carries no positions, so its columns are laid along that sol's drive (the rover's traverse line, moved into our frame
like the rest of the rover data) and stretched to the drive's length. Sols whose radargram length disagrees with the
drive by more than 15 % (short drives where stationary soundings dominate, or drives the traverse line misses) are
left out and listed.

Each output column stacks 2 soundings (0.2 m of drive), aligned at the surface, and keeps the signed trace: buried
layers and boulders show as coherent bands and chevrons (diffraction hyperbolas); the browse images are already
gained, so amplitude says little. Travel time
becomes depth with an assumed relative permittivity of 9 (0.1 m/ns), typical of basaltic rock and sediment, so the
depth scale is approximate. Only Perseverance carries a ground radar, so the Gale site has none.
"""

from __future__ import annotations

import csv
import io
import json
import logging
import math
from pathlib import Path

import numpy as np
from PIL import Image

from marsgeo.grid import SiteGrid, sample_bilinear

log = logging.getLogger("pipeline.radar")

BUNDLE = "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_rimfax/"
CATALOG = BUNDLE + "document/rimfax_calibrated_data_catalog.csv"
SOURCE = ("RIMFAX calibrated radargrams (browse_radargram), Mars 2020 RIMFAX bundle, PDS Geosciences Node "
          "(NASA/JPL-Caltech/FFI, Hamran et al. 2020)")

SOUNDING_M = 0.10          # one browse column per 10 cm of drive
DT_NS = 0.1418922          # browse row spacing (Shallow-mode time samples, two-way travel time)
STACK = 2                  # browse columns per output column -> 0.2 m
COL_M = SOUNDING_M * STACK
T_MAX_NS = 100.0           # kept below the surface (the signal fades into noise by ~100-130 ns)
ROWS = 300                 # 0.33 ns per output row
PAD = 2                    # empty rows between atlas strips (no bleeding under linear filtering)
ATLAS_W = 4096
EPS_R = 9.0                # assumed relative permittivity
V_M_PER_NS = 0.299792458 / math.sqrt(EPS_R)
DEPTH_M = V_M_PER_NS * T_MAX_NS / 2.0
RATIO_OK = (0.85, 1.15)    # radargram length / drive length accepted
MIN_RUN = 10               # output columns (5 m) for a piece of track inside the site


def browse_url(sol: int, year: int) -> str:
    return f"{BUNDLE}browse_radargram/{year}/rimfax_browse_{sol:05d}.png"


def read_catalog(text: str) -> dict[int, dict]:
    """sol -> {year, utc} from the RIMFAX calibrated-data catalogue."""
    out = {}
    for r in csv.DictReader(io.StringIO(text)):
        try:
            out[int(r["sol"])] = {"year": int(r["year_min"]), "utc": r.get("utc_min", "")}
        except (KeyError, ValueError):
            continue
    return out


def surface_rows(img: np.ndarray, level: float = 40.0, smooth_cols: int = 31) -> np.ndarray:
    """Row where the signal starts in each column (the ground surface after the topography shift).

    img: signed (rows, cols) radargram (browse value - 128). The band above the surface holds only faint noise."""
    from scipy.ndimage import median_filter, uniform_filter1d
    env = uniform_filter1d(np.abs(img.astype(np.float32)), 15, axis=0)
    hit = env > level
    first = np.where(hit.any(axis=0), np.argmax(hit, axis=0), 0)
    if img.shape[1] >= 3:
        first = median_filter(first, size=min(smooth_cols, img.shape[1] | 1), mode="nearest")
    return first.astype(int)


def stack_columns(img: np.ndarray, surf: np.ndarray, stack: int = STACK, t_max_ns: float = T_MAX_NS,
                  rows: int = ROWS, dt_ns: float = DT_NS) -> np.ndarray:
    """(rows, n_out) signed traces: each output column is the mean of `stack` soundings aligned at their surface,
    resampled from 0 to t_max_ns below the surface."""
    n_in = int(round(t_max_ns / dt_ns))
    h, w = img.shape
    n_out = w // stack
    pad = np.zeros((n_in, w), np.float32)
    for c in range(w):
        s = int(surf[c])
        seg = img[s:s + n_in, c]
        pad[:len(seg), c] = seg
    st = pad[:, :n_out * stack].reshape(n_in, n_out, stack).mean(axis=2)
    # light low-pass (3 rows) then sample at the output rows
    from scipy.ndimage import uniform_filter1d
    st = uniform_filter1d(st, 3, axis=0)
    t_in = np.arange(n_in) * dt_ns
    t_out = (np.arange(rows) + 0.5) * (t_max_ns / rows)
    out = np.empty((rows, n_out), np.float32)
    for j in range(n_out):
        out[:, j] = np.interp(t_out, t_in, st[:, j])
    return out


def energy_u8(tr: np.ndarray) -> np.ndarray:
    """Echo strength (RMS over ~3 ns and ~1.4 m), 0-255 against the sol's own 98th percentile: what the 3D curtain
    shows from far away, where the wiggles are too fine to draw."""
    from scipy.ndimage import uniform_filter
    e = np.sqrt(uniform_filter(tr.astype(np.float32) ** 2, size=(9, 7)))
    s = float(np.percentile(e, 98)) + 1e-6
    return np.clip(255.0 * np.clip(e / s, 0.0, 1.0) ** 0.8, 0, 255).astype(np.uint8)


def to_u8(tr: np.ndarray, gain: float = 1.0) -> np.ndarray:
    """Signed traces -> 8 bit, 128 = zero. A gentle depth gain brings up the fainter, deeper echoes."""
    rows = tr.shape[0]
    g = 1.0 + 0.8 * (np.arange(rows, dtype=np.float32) / max(rows - 1, 1)) ** 1.5
    return np.clip(128.0 + tr * gain * g[:, None], 0, 255).astype(np.uint8)


def polyline_at(xy: np.ndarray, d: np.ndarray) -> np.ndarray:
    """Points at distances d along a polyline xy (n, 2)."""
    seg = np.hypot(*np.diff(xy, axis=0).T)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    return np.column_stack([np.interp(d, cum, xy[:, 0]), np.interp(d, cum, xy[:, 1])])


def drive_xy(traverse: dict, sol: int, grid: SiteGrid, team: dict | None) -> np.ndarray | None:
    """The sol's drive as site metres (team frame moved onto our DTM), in the order the file lists it."""
    from .rover import move
    pts = []
    for f in traverse.get("features", []):
        if (f.get("properties") or {}).get("sol") != sol:
            continue
        g = f.get("geometry") or {}
        parts = g.get("coordinates", []) if g.get("type") == "MultiLineString" else [g.get("coordinates", [])]
        for part in parts:
            pts.extend(p[:2] for p in part)
    if len(pts) < 2:
        return None
    arr = np.asarray(pts, float)
    lon, lat = move(grid, arr[:, 0], arr[:, 1], team)
    x, y = grid.lonlat_to_xy(np.asarray(lon), np.asarray(lat))
    xy = np.column_stack([x, y])
    keep = np.concatenate([[True], np.hypot(*np.diff(xy, axis=0).T) > 1e-6])
    xy = xy[keep]
    return xy if len(xy) >= 2 else None


def runs_inside(xy: np.ndarray, grid: SiteGrid, margin: float = 2.0, min_run: int = MIN_RUN) -> list[tuple[int, int]]:
    ins = ((xy[:, 0] >= grid.x_min + margin) & (xy[:, 0] <= grid.x_max - margin)
           & (xy[:, 1] >= grid.y_min + margin) & (xy[:, 1] <= grid.y_max - margin))
    out, start = [], None
    for i, ok in enumerate(ins):
        if ok and start is None:
            start = i
        elif not ok and start is not None:
            if i - start >= min_run:
                out.append((start, i))
            start = None
    if start is not None and len(ins) - start >= min_run:
        out.append((start, len(ins)))
    return out


class Atlas:
    """Packs track pieces into strips of ATLAS_W columns (a piece that does not fit is split). One channel, or
    several with `fill` giving each channel's empty value."""

    def __init__(self, width: int = ATLAS_W, rows: int = ROWS, pad: int = PAD, fill: tuple = (128,)):
        self.w, self.rows, self.pad = width, rows, pad
        self.fill = tuple(int(v) for v in fill)
        self.strips: list[np.ndarray] = []
        self.x = width  # forces a new strip on the first add

    def _strip(self) -> np.ndarray:
        if len(self.fill) == 1:
            return np.full((self.rows + self.pad, self.w), self.fill[0], np.uint8)
        s = np.empty((self.rows + self.pad, self.w, len(self.fill)), np.uint8)
        s[...] = np.asarray(self.fill, np.uint8)
        return s

    def add(self, cols: np.ndarray) -> list[tuple[int, int, int, int]]:
        """cols (rows, n[, ch]) uint8 -> [(strip, x0, i0, n)] placements (i0 = first column of cols placed there)."""
        placed, i0, n = [], 0, cols.shape[1]
        while i0 < n:
            if self.x >= self.w:
                self.strips.append(self._strip())
                self.x = 0
            k = min(self.w - self.x, n - i0)
            self.strips[-1][:self.rows, self.x:self.x + k] = cols[:, i0:i0 + k]
            placed.append((len(self.strips) - 1, self.x, i0, k))
            self.x += k
            i0 += k
        return placed

    def image(self) -> np.ndarray:
        return np.vstack(self.strips) if self.strips else self._strip()[:, :1]


def build(out_dir: Path, cfg: dict, grid: SiteGrid, cache: Path, team: dict | None = None, session=None,
          dem: np.ndarray | None = None) -> dict | None:
    """radar.json + radar_atlas.png for a Perseverance site; None for other missions or without traverse data."""
    if cfg.get("mission") != "M20":
        return None
    tr_path = cache.parent / "M20_traverse.json"
    wp_path = cache.parent / "M20_waypoints.json"
    if not tr_path.exists() or not wp_path.exists():
        return None
    traverse = json.loads(tr_path.read_text(encoding="utf-8"))
    wps = json.loads(wp_path.read_text(encoding="utf-8"))
    lon0, lat0, lon1, lat1 = grid.bounds_lonlat()
    sols = sorted({int(f["properties"]["sol"]) for f in wps.get("features", [])
                   if f.get("properties", {}).get("sol") is not None
                   and lon0 - 0.003 <= f["geometry"]["coordinates"][0] <= lon1 + 0.003
                   and lat0 - 0.003 <= f["geometry"]["coordinates"][1] <= lat1 + 0.003})
    if not sols:
        return None
    if session is None:
        from marsgeo.net import session as _s
        session = _s()
    cache.mkdir(parents=True, exist_ok=True)
    cat_path = cache / "rimfax_calibrated_data_catalog.csv"
    if not cat_path.exists():
        r = session.get(CATALOG, timeout=120)
        r.raise_for_status()
        cat_path.write_bytes(r.content)
    catalog = read_catalog(cat_path.read_text(encoding="utf-8", errors="replace"))

    atlas = Atlas(fill=(128, 0))   # L = signed trace, A = echo strength
    tracks, used, skipped = [], [], []
    for sol in sols:
        if sol not in catalog:
            continue
        xy = drive_xy(traverse, sol, grid, team)
        if xy is None:
            skipped.append({"sol": sol, "why": "no drive in the traverse"})
            continue
        drive_m = float(np.hypot(*np.diff(xy, axis=0).T).sum())
        png = cache / f"rimfax_browse_{sol:05d}.png"
        if not png.exists():
            r = session.get(browse_url(sol, catalog[sol]["year"]), timeout=300)
            if r.status_code != 200:
                skipped.append({"sol": sol, "why": f"no browse radargram (HTTP {r.status_code})"})
                continue
            png.write_bytes(r.content)
        img = np.asarray(Image.open(png).convert("L"), np.float32) - 128.0
        ratio = img.shape[1] * SOUNDING_M / drive_m if drive_m > 0 else float("inf")
        if not (RATIO_OK[0] <= ratio <= RATIO_OK[1]):
            skipped.append({"sol": sol, "why": f"radargram {img.shape[1] * SOUNDING_M:.0f} m vs drive {drive_m:.0f} m"})
            continue
        surf = surface_rows(img)
        tr_cols = stack_columns(img, surf)
        cols = np.dstack([to_u8(tr_cols), energy_u8(tr_cols)])
        n = cols.shape[1]
        d = (np.arange(n) + 0.5) * (drive_m / n)          # stretched to the drive's length
        pxy = polyline_at(xy, d)
        pieces = runs_inside(pxy, grid)
        if not pieces:
            continue
        used.append(sol)
        for a, b in pieces:
            run = 1 + max((t["run"] for t in tracks), default=-1)
            for strip, x0, i0, k in atlas.add(cols[:, a:b]):
                sel = slice(a + i0, a + i0 + k)
                lon, lat = grid.xy_to_lonlat(pxy[sel, 0], pxy[sel, 1])
                tr = {"run": run, "sol": sol, "utc": catalog[sol]["utc"][:10], "strip": strip, "x0": x0, "n": k,
                      "d0_m": round(float(d[a + i0]), 2), "lon": [round(float(v), 7) for v in np.atleast_1d(lon)],
                      "lat": [round(float(v), 7) for v in np.atleast_1d(lat)]}
                if dem is not None:
                    rr, cc = grid.xy_to_rowcol(pxy[sel, 0], pxy[sel, 1])
                    z = sample_bilinear(dem, rr, cc)
                    tr["z"] = [None if not np.isfinite(v) else round(float(v), 2) for v in z]
                tracks.append(tr)
    if not tracks:
        return None
    im = atlas.image()
    Image.fromarray(im, "LA").save(out_dir / "radar_atlas.png", optimize=True)
    total_m = sum(t["n"] for t in tracks) * COL_M
    doc = {"instrument": "RIMFAX ground-penetrating radar", "rover": "Perseverance", "source": SOURCE,
           "mode": "Shallow", "channels": "L = signed trace (128 = zero), A = echo strength", "col_m": COL_M, "rows": ROWS, "pad": PAD, "t_max_ns": T_MAX_NS,
           "eps_r": EPS_R, "v_m_per_ns": round(V_M_PER_NS, 4), "depth_m": round(DEPTH_M, 2),
           "atlas": {"w": int(im.shape[1]), "h": int(im.shape[0]), "strip_h": ROWS + PAD, "n_strips": len(atlas.strips)},
           "placement": "Each sol's radargram is laid along that sol's drive and stretched to its length "
                        f"(accepted when they agree within {int(round((RATIO_OK[1] - 1) * 100))} %).",
           "depth_note": f"Depth assumes a relative permittivity of {EPS_R:g} ({V_M_PER_NS:.2f} m/ns); it is approximate.",
           "sols": used, "skipped": skipped, "length_m": round(total_m, 1), "tracks": tracks}
    (out_dir / "radar.json").write_text(json.dumps(doc), encoding="utf-8")
    return {"sols": len(used), "length_m": round(total_m, 1), "pieces": len(tracks), "skipped": len(skipped),
            "atlas": [int(im.shape[1]), int(im.shape[0])]}
