"""Ingenuity's flights around the site, on our terrain (Jezero only: the Mars 2020 helicopter, 2021-2024).

JPL MMGIS publishes the helicopter's flight paths and its waypoints (one per flight: sol, Earth date, maximum
altitude, duration, distance, take-off and landing airfields). Both are in the Mars 2020 team's map frame, so they
get the same measured shift as the rover track (pipeline/team_dem.py).

Each flight also marks a strip of ground the helicopter saw from the air: its downward navigation camera has a
~133 deg field of view, so it sees about 1.4 x its altitude to either side of the track. That strip is rasterised
onto the 4 m grid (the number of the latest flight that saw each cell) so stops can say "scouted from the air".
"""

from __future__ import annotations

import json
import logging
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from marsgeo.grid import SiteGrid

from . import rover

log = logging.getLogger("pipeline.ingenuity")

FLIGHT_PATH = "https://mars.nasa.gov/mmgis-maps/M20/Layers/json/m20_heli_flight_path.json"
WAYPOINTS = "https://mars.nasa.gov/mmgis-maps/M20/Layers/json/m20_heli_waypoints.json"
NAV_SWATH = 1.4          # half-width of the navigation camera's ground view, in multiples of the altitude
MIN_HALF_WIDTH_M = 6.0   # hops of a few metres still see the ground around the helicopter
MARGIN_M = 1500.0        # flights this close to the site are kept for context


def _coords(geom: dict) -> list[list[float]]:
    if geom.get("type") == "LineString":
        return [c[:2] for c in geom["coordinates"]]
    if geom.get("type") == "MultiLineString":
        return [c[:2] for part in geom["coordinates"] for c in part]
    return []


def flights(paths: dict, waypoints: dict, grid: SiteGrid, team: dict | None) -> list[dict]:
    """One record per flight near the site: path (lon/lat on our terrain), landing point and the flight's facts."""
    by_flight = {}
    for f in waypoints.get("features", []):
        p = f.get("properties") or {}
        if p.get("Flight") is not None:
            by_flight[int(p["Flight"])] = p
    out = []
    for f in paths.get("features", []):
        p = f.get("properties") or {}
        if p.get("Flight") is None:
            continue
        n = int(p["Flight"])
        pts = np.asarray(_coords(f.get("geometry") or {}), float)
        if len(pts) < 2:
            continue
        lon, lat = rover.move(grid, pts[:, 0], pts[:, 1], team)
        x, y = grid.lonlat_to_xy(lon, lat)
        near = ((x >= grid.x_min - MARGIN_M) & (x <= grid.x_max + MARGIN_M) & (y >= grid.y_min - MARGIN_M) & (y <= grid.y_max + MARGIN_M))
        if not near.any():
            continue
        inside = ((x >= grid.x_min) & (x <= grid.x_max) & (y >= grid.y_min) & (y <= grid.y_max))
        w = by_flight.get(n, {})
        # thin the path to ~1 m steps (MMGIS stores it at telemetry rate)
        keep = [0]
        for i in range(1, len(x)):
            if math.hypot(x[i] - x[keep[-1]], y[i] - y[keep[-1]]) >= 1.0:
                keep.append(i)
        if keep[-1] != len(x) - 1:
            keep.append(len(x) - 1)
        land = rover.move(grid, w["Lon"], w["Lat"], team) if w.get("Lon") is not None else (lon[-1], lat[-1])
        out.append({
            "flight": n, "sol": w.get("Sol", p.get("Sol")), "earth_date": w.get("Earth_Date"),
            "length_m": round(float(p.get("Length_m") or w.get("Dist_m") or 0.0), 1),
            "max_alt_m": float(w.get("Max_Alt_m") or 0.0), "duration_s": float(w.get("Duration_s") or 0.0),
            "from": w.get("FromAirfld"), "to": w.get("ToAirfld"),
            "in_site": bool(inside.any()),
            "lon": [round(float(lon[i]), 7) for i in keep], "lat": [round(float(lat[i]), 7) for i in keep],
            "land": [round(float(land[0]), 7), round(float(land[1]), 7)],
        })
    out.sort(key=lambda r: r["flight"])
    return out


def scouted_grid(rows: list[dict], grid4: SiteGrid) -> np.ndarray:
    """uint8 grid: the number of the latest flight whose navigation camera saw each 4 m cell (0 = none)."""
    out = np.zeros((grid4.height, grid4.width), np.uint8)
    for r in rows:  # ascending flight number: later flights paint over earlier ones
        half = max(MIN_HALF_WIDTH_M, NAV_SWATH * r["max_alt_m"])
        rr, cc = grid4.lonlat_to_rowcol(np.asarray(r["lon"]), np.asarray(r["lat"]))
        pts = [(float(c) + 0.5, float(rw) + 0.5) for rw, c in zip(rr, cc)]
        im = Image.new("1", (grid4.width, grid4.height), 0)
        d = ImageDraw.Draw(im)
        wpx = max(1, int(round(2 * half / grid4.res)))
        d.line(pts, fill=1, width=wpx, joint="curve")
        for px, py in (pts[0], pts[-1]):  # round ends: take-off and landing pads
            rad = half / grid4.res
            d.ellipse((px - rad, py - rad, px + rad, py + rad), fill=1)
        out[np.asarray(im, dtype=bool)] = min(255, r["flight"])
    return out


def build(out_dir: Path, grid: SiteGrid, grid4: SiteGrid, cache: Path, team: dict | None) -> dict | None:
    paths = rover.load(FLIGHT_PATH, cache / "M20_heli_flight_path.json")
    wps = rover.load(WAYPOINTS, cache / "M20_heli_waypoints.json")
    rows = flights(paths, wps, grid, team)
    if not rows:
        log.info("ingenuity: no flights near this site")
        return None
    feats = []
    for r in rows:
        props = {k: r[k] for k in ("flight", "sol", "earth_date", "length_m", "max_alt_m", "duration_s", "from", "to", "in_site")}
        feats.append({"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[a, b] for a, b in zip(r["lon"], r["lat"])]},
                      "properties": {**props, "kind": "flight"}})
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": r["land"]},
                      "properties": {**props, "kind": "landing"}})
    (out_dir / "ingenuity.geojson").write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
    sc = scouted_grid([r for r in rows if r["in_site"]], grid4)
    np.save(out_dir / "scouted_4m.npy", sc)
    in_site = [r for r in rows if r["in_site"]]
    meta = {"flights": len(rows), "in_site": len(in_site),
            "first": in_site[0]["flight"] if in_site else None, "last": in_site[-1]["flight"] if in_site else None,
            "sols": [in_site[0]["sol"], in_site[-1]["sol"]] if in_site else None,
            "scouted_fraction": round(float((sc > 0).mean()), 4),
            "source": "JPL MMGIS Mars 2020 layers m20_heli_flight_path.json and m20_heli_waypoints.json"}
    log.info("ingenuity: %d flights near the site, %d over it (flights %s-%s), %.1f %% of the site seen from the air",
             len(rows), len(in_site), meta["first"], meta["last"], meta["scouted_fraction"] * 100)
    return meta
