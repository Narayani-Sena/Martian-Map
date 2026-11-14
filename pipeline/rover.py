"""Rover traverse/waypoints from JPL MMGIS, clipped to the site and put on our DTM.

The rover teams publish positions in their own map frame. When the site build measured that frame's shift
against our DTM (pipeline/team_dem.py), every position is moved by it and every elevation gets the measured
height offset and tilt, so the track runs where the wheels went on our terrain (team=None keeps the old
behaviour: positions as published, heights compared with a median offset).
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np

from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import download

from .team_dem import plane_at, to_site_frame

log = logging.getLogger("pipeline.rover")


def load(url: str, cache: Path) -> dict:
    p = download(url, cache)
    return json.loads(Path(p).read_text(encoding="utf-8"))


def _inside(grid: SiteGrid, lon, lat, margin_m: float) -> np.ndarray:
    x, y = grid.lonlat_to_xy(lon, lat)
    return ((x >= grid.x_min - margin_m) & (x <= grid.x_max + margin_m)
            & (y >= grid.y_min - margin_m) & (y <= grid.y_max + margin_m))


def move(grid: SiteGrid, lon, lat, team: dict | None):
    """Team-frame lon/lat onto our DTM (no-op without a team-frame measurement)."""
    return to_site_frame(grid, np.asarray(lon, float), np.asarray(lat, float), team)


def process_waypoints(wp: dict, grid: SiteGrid, dem: np.ndarray, elev_key: str = "elev_geoid",
                      margin_m: float = 0.0, team: dict | None = None):
    """Clip waypoints to the site (after moving them onto our DTM); how far the rover's own heights sit from it.

    Returns (feature collection, median DTM - rover height, number of heights compared, spread of that difference).
    With a team-frame measurement the rover's heights get the measured offset and tilt first, so the median is
    what is left over (decimetres) rather than the whole datum difference.
    """
    feats = []
    for f in wp["features"]:
        lon, lat = f["geometry"]["coordinates"][:2]
        lon, lat = (float(v) for v in move(grid, lon, lat, team))
        if _inside(grid, lon, lat, margin_m):
            feats.append((lon, lat, f))
    diffs = []
    out = []
    for lon, lat, f in feats:
        p = f["properties"]
        r, c = grid.lonlat_to_rowcol(lon, lat)
        zd = float(sample_bilinear(dem, r, c))
        ze = p.get(elev_key)
        ze_ours = None
        if ze is not None:
            ze_ours = float(ze) + (float(plane_at(grid, lon, lat, team)) if team else 0.0)
            if np.isfinite(zd):
                diffs.append(zd - ze_ours)
        out.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [round(lon, 7), round(lat, 7)]},
            "properties": {
                "sol": p.get("sol"), "site": p.get("site"), "drive": p.get("drive"),
                "dist_total_m": p.get("dist_total_m"),
                "elev_rover": p.get(elev_key),
                "elev_rover_on_dtm": round(ze_ours, 2) if ze_ours is not None else None,
                "elev_dtm": round(zd, 2),
            },
        })
    out.sort(key=lambda f: (f["properties"]["sol"] or 0))
    offset = float(np.median(diffs)) if diffs else 0.0
    spread = float(np.subtract(*np.percentile(diffs, [84, 16])) / 2) if len(diffs) > 2 else None
    return {"type": "FeatureCollection", "features": out}, offset, len(diffs), spread


def clip_lines(tr: dict, grid: SiteGrid, margin_m: float = 0.0, team: dict | None = None) -> dict:
    """Keep traverse vertices inside the site (+margin), splitting lines where they leave."""
    lines = []
    for f in tr["features"]:
        g = f["geometry"]
        parts = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
        for part in parts:
            arr = np.asarray([p[:2] for p in part], float)
            if len(arr) < 2:
                continue
            arr = np.column_stack(move(grid, arr[:, 0], arr[:, 1], team))
            ins = _inside(grid, arr[:, 0], arr[:, 1], margin_m)
            cur = []
            for (lon, lat), ok in zip(arr, ins):
                if ok:
                    cur.append([round(float(lon), 7), round(float(lat), 7)])
                elif len(cur) > 1:
                    lines.append(cur)
                    cur = []
                else:
                    cur = []
            if len(cur) > 1:
                lines.append(cur)
    return {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": lines}, "properties": {}}]}


def simplify_full(tr: dict, step: int = 4, grid: SiteGrid | None = None, team: dict | None = None) -> dict:
    """Whole-mission traverse, decimated, for the zoomed-out context view (same shift as the site's track)."""
    pts = []
    for f in tr["features"]:
        g = f["geometry"]
        parts = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
        for part in parts:
            arr = np.asarray([p[:2] for p in part[::step]], float)
            if len(arr) == 0:
                continue
            if grid is not None and team:
                arr = np.column_stack(move(grid, arr[:, 0], arr[:, 1], team))
            pts.extend([[round(float(a), 6), round(float(b), 6)] for a, b in arr])
    return {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "LineString", "coordinates": pts}, "properties": {}}]}


def generic_points(fc: dict, grid: SiteGrid, keep_props: list[str], margin_m: float = 2000.0, team: dict | None = None) -> dict:
    out = []
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") != "Point":
            continue
        lon, lat = (round(float(v), 8) for v in move(grid, *g["coordinates"][:2], team))
        if not _inside(grid, lon, lat, margin_m):
            continue
        p = f.get("properties", {})
        out.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                    "properties": {k: p.get(k) for k in keep_props if k in p}})
    return {"type": "FeatureCollection", "features": out}


def generic_lines(fc: dict, grid: SiteGrid, keep_props: list[str], margin_m: float = 2000.0, team: dict | None = None) -> dict:
    out = []
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") not in ("LineString", "MultiLineString"):
            continue
        parts = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
        moved = []
        for part in parts:
            arr = np.asarray([q[:2] for q in part], float)
            if len(arr):
                arr = np.column_stack(move(grid, arr[:, 0], arr[:, 1], team))
            moved.append([[round(float(a), 8), round(float(b), 8)] for a, b in arr])
        arr = np.asarray([q for part in moved for q in part], float)
        if len(arr) == 0 or not _inside(grid, arr[:, 0], arr[:, 1], margin_m).any():
            continue
        p = f.get("properties", {})
        out.append({"type": "Feature", "geometry": {"type": g["type"], "coordinates": moved if g["type"] == "MultiLineString" else moved[0]},
                    "properties": {k: p.get(k) for k in keep_props if k in p}})
    return {"type": "FeatureCollection", "features": out}
