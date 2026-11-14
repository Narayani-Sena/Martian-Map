"""Ground radar under the rover's track (feature E1): Perseverance's RIMFAX radargrams laid along each sol's drive.

The site build (pipeline/radar.py) stores the radargrams as one 8-bit atlas (128 = zero, signed traces, 0.2 m
columns, 0.33 ns rows below the surface) and the pieces of track that sit inside the site. Here the pieces become
runs (one stretch of one sol's drive), the nearest column to a point is found, and a run is drawn the way
radargrams are read (light and dark for the two signs of an echo).
"""

from __future__ import annotations

import numpy as np

from marsgeo.grid import SiteGrid

LIGHT = np.array([232, 246, 255], np.float32)  # positive amplitude
DARK = np.array([6, 10, 16], np.float32)       # negative amplitude


def group_runs(doc: dict) -> list[dict]:
    """Pieces (one per atlas placement) -> runs: {run, sol, utc, d0_m, n, lon[], lat[], z[], pieces[[strip, x0, n, at]]}."""
    runs: dict[int, dict] = {}
    for k, t in enumerate(doc.get("tracks", [])):
        rid = int(t.get("run", k))
        r = runs.get(rid)
        if r is None:
            r = runs[rid] = {"run": rid, "sol": t["sol"], "utc": t.get("utc"), "d0_m": t["d0_m"], "n": 0,
                             "lon": [], "lat": [], "z": [], "pieces": []}
        r["pieces"].append([int(t["strip"]), int(t["x0"]), int(t["n"]), r["n"]])
        r["n"] += int(t["n"])
        r["lon"] += t["lon"]
        r["lat"] += t["lat"]
        r["z"] += t.get("z") or [None] * int(t["n"])
    return [runs[k] for k in sorted(runs)]


def summary(doc: dict) -> dict:
    """The document without its per-column arrays (for the site summary and listings)."""
    return {k: v for k, v in doc.items() if k not in ("tracks", "runs")}


def nearest(doc: dict, grid: SiteGrid, lon: float, lat: float, within_m: float) -> dict | None:
    """The radar column nearest to lon/lat within `within_m` metres, or None."""
    x0, y0 = grid.lonlat_to_xy(lon, lat)
    best = None
    for r in doc.get("runs", []):
        x, y = grid.lonlat_to_xy(np.asarray(r["lon"], float), np.asarray(r["lat"], float))
        d = np.hypot(np.asarray(x) - x0, np.asarray(y) - y0)
        i = int(np.argmin(d))
        if best is None or d[i] < best[0]:
            best = (float(d[i]), r, i)
    if best is None or best[0] > within_m:
        return None
    d, r, i = best
    return {"run": r["run"], "sol": r["sol"], "utc": r["utc"], "i": i, "n": r["n"], "dist_m": round(d, 1),
            "along_m": round(r["d0_m"] + i * float(doc["col_m"]), 1), "lon": r["lon"][i], "lat": r["lat"][i],
            "z": r["z"][i] if i < len(r["z"]) else None}


def run_columns(doc: dict, atlas: np.ndarray, run: dict) -> np.ndarray:
    """(rows, n) uint8 radargram of one run, cut from the atlas."""
    rows, sh = int(doc["rows"]), int(doc["atlas"]["strip_h"])
    parts = [atlas[st * sh: st * sh + rows, x0:x0 + n] for st, x0, n, _ in run["pieces"]]
    return np.concatenate(parts, axis=1) if parts else np.full((rows, 1), 128, np.uint8)


def palette(u8: np.ndarray, contrast: float = 1.5) -> np.ndarray:
    """Signed 8-bit radargram -> RGB, the way radargrams are read: echoes of one sign light, the other dark, a
    faint cool tint, mid-grey where nothing returns."""
    f = np.clip(0.5 + (u8.astype(np.float32) / 255.0 - 0.5) * contrast, 0.0, 1.0)[..., None]
    return np.clip(DARK + (LIGHT - DARK) * f, 0, 255).astype(np.uint8)
