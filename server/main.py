"""Martian Map API.

    uvicorn server.main:app --port 8000

Serves the built web app from web/dist when it exists, so one process is
enough for a demo. During development, Vite (port 5173) proxies /api here.
"""

from __future__ import annotations

import io
import json
import math
import os
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, Field

from marsgeo import mars24
from marsgeo import tiles as T
from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import session

from pipeline import sand as sandlib
from pipeline import science as scilib

from . import climate, eva, rover_images, spaceweather, traverse_sheet, weather_live
from . import flow as flowlib
from . import tower as towerlib
from . import skyline as skylib
from . import fallback as fallbacklib
from . import envelope as envlib
from . import live as livelib
from . import orrery as orrerylib
from . import lake as lakelib
from . import autoplan as autoplanlib
from . import glare as glarelib
from . import pacenotes as pacelib
from . import scout as scoutlib
from . import tags as tagslib
from . import debrief as debrieflib
from . import rover as pr
from . import tiles as tilelib
from .routing import evaluate_cells, simplify_cells
from .site_store import DATA_DIR, ROOT, get_site, is_built, load_config, site_ids
from .walkmodel import WalkParams

app = FastAPI(title="Martian Map API", version="1.0")
app.add_middleware(GZipMiddleware, minimum_size=1024)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

TILE_HEADERS = {"Cache-Control": "public, max-age=86400"}
DYN_HEADERS = {"Cache-Control": "public, max-age=600"}


# ====================================================================== models
class LonLat(BaseModel):
    lon: float
    lat: float


class Stop(BaseModel):
    id: str | None = None
    name: str = "Stop"
    lon: float
    lat: float
    dwell_min: float = 20
    kind: str | None = None
    tasks: list[str] = []
    samples_kg: float | None = None  # mass bagged here (feature C4); None = the plan's sample_kg_per_stop
    note: str | None = None          # the crew's voice note for the sample passport


class Relay(BaseModel):
    lon: float
    lat: float
    height_m: float = 3.0
    name: str | None = None


class Radio(BaseModel):
    habitat_mast_m: float = 12.0
    suit_antenna_m: float = 2.0
    relays: list[Relay] = []


class RoverPlan(BaseModel):
    """Rover-assisted EVA: PR-2 drives the crew to a drop-off point and back (see server/rover.py)."""
    enabled: bool = False
    dropoff: LonLat | None = None  # None = choose automatically
    drive: dict = {}  # DriveParams overrides (flat_speed, max_slope, ...)
    suitport_min: float = Field(pr.SUITPORT_MIN, ge=2, le=60)
    antenna_m: float = Field(pr.ANTENNA_M, ge=0, le=20)


class CmeArrival(BaseModel):
    """A predicted CME arrival at Mars (what-if drills and tests; normally these come from DONKI)."""
    arrival: str
    glancing: bool = False
    cme: str | None = None
    speed_kms: float | None = None


class PlanRequest(BaseModel):
    habitat: LonLat
    stops: list[Stop] = []
    return_to_habitat: bool = True
    algorithm: str = "astar"
    astar_weight: float = 1.0
    walk: dict = {}
    suit: dict = {}
    radio: Radio = Field(default_factory=Radio)
    start_utc: str | None = None
    sep_active: bool = False
    rover: RoverPlan = Field(default_factory=RoverPlan)
    space_weather: str = "live"  # live: check DONKI's CME arrivals at Mars; off: skip the check
    cme_arrivals: list[CmeArrival] | None = None  # use these instead of DONKI (what-if drills, tests)
    sample_kg_per_stop: float = Field(1.5, ge=0, le=20)  # samples add mass as the EVA goes on (feature C4)
    speed_dispersion_scale: float = Field(1.0, ge=0, le=1)  # < 1 once the ground is scouted (feature C1)


class SuggestRequest(BaseModel):
    """Ask for science stops inside the safe walk-back range (data-use item D3)."""
    habitat: LonLat
    haven: LonLat | None = None  # walk back to this instead of the hab (PR-2 parked at its drop-off)
    stops: list[Stop] = []
    walk: dict = {}
    n: int = Field(3, ge=1, le=8)
    max_walkback_min: float = Field(35.0, ge=5, le=120)
    min_sep_m: float = Field(150.0, ge=30, le=1000)


class RouteRequest(BaseModel):
    a: LonLat
    b: LonLat
    walk: dict = {}
    engines: list[str] = ["astar", "dijkstra"]
    astar_weight: float = 1.0


class WalkbackRequest(BaseModel):
    habitat: LonLat
    walk: dict = {}


class ViewshedRequest(BaseModel):
    habitat: LonLat
    radio: Radio = Field(default_factory=Radio)


# ===================================================================== helpers
def _site(site_id: str):
    try:
        return get_site(site_id)
    except KeyError:
        raise HTTPException(404, f"Site '{site_id}' is not built. Run: python -m pipeline.build_site {site_id}")


def _walk(d: dict) -> WalkParams:
    try:
        return WalkParams.from_dict(d)
    except (TypeError, ValueError) as e:
        raise HTTPException(422, str(e))


def _drive(d: dict) -> pr.DriveParams:
    try:
        return pr.DriveParams.from_dict(d)
    except (TypeError, ValueError) as e:
        raise HTTPException(422, str(e))


def _walk_from_query(q: dict) -> WalkParams:
    keys = ("flat_speed", "max_slope", "caution_slope", "max_rough", "sand_penalty", "hazard_aversion", "load_kg")
    return _walk({k: q[k] for k in keys if k in q and q[k] not in (None, "")})


def _parse_utc(s: str | None) -> datetime:
    if not s:
        return datetime.now(timezone.utc)
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(422, "bad datetime")
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _png(data: bytes, headers=TILE_HEADERS) -> Response:
    return Response(content=data, media_type="image/png", headers=headers)


_route_cache: dict = {}
_route_lock = threading.Lock()


def _route(site, a: LonLat | dict, b: LonLat | dict, p: WalkParams, engine: str, weight: float):
    a = a if isinstance(a, dict) else a.model_dump()
    b = b if isinstance(b, dict) else b.model_dump()
    key = (site.id, round(a["lon"], 7), round(a["lat"], 7), round(b["lon"], 7), round(b["lat"], 7), p.key(), engine, round(weight, 3))
    with _route_lock:
        if key in _route_cache:
            return _route_cache[key]
    mult = site.multiplier(p)
    g2 = site.grid2
    warn = []
    ends = []
    for pt in (a, b):
        r, c = (int(round(v)) for v in g2.lonlat_to_rowcol(pt["lon"], pt["lat"]))
        if not (0 <= r < g2.height and 0 <= c < g2.width):
            raise HTTPException(422, "A point is outside the mapped site")
        r2, c2, moved = site.router.snap_passable(p.key(), r, c)
        if moved:
            warn.append("A stop sits on no-go terrain; the route ends at the nearest safe spot")
        ends.append((r2, c2))
    if engine == "dijkstra":
        res = site.router.dijkstra(p.key(), ends[0], ends[1], p, site.slope2)
    else:
        res = site.router.astar(p.key(), ends[0], ends[1], p, weight=weight)
    res.warnings = warn + res.warnings
    with _route_lock:
        if len(_route_cache) > 400:
            _route_cache.pop(next(iter(_route_cache)))
        _route_cache[key] = res
    return res


def _sample_field(field: np.ndarray, rr, cc):
    """Bilinear where all four neighbours are reachable; otherwise the nearest cell (may be inf).

    Never interpolate between a finite time and 'unreachable' - that invents huge fake values.
    """
    rr = np.atleast_1d(np.asarray(rr, dtype=float))
    cc = np.atleast_1d(np.asarray(cc, dtype=float))
    v = np.asarray(sample_bilinear(np.where(np.isfinite(field), field, np.nan).astype(np.float32), rr, cc), dtype=float)
    bad = ~np.isfinite(v)
    if bad.any():
        h, w = field.shape
        ri = np.clip(np.rint(rr).astype(int), 0, h - 1)
        ci = np.clip(np.rint(cc).astype(int), 0, w - 1)
        v = np.where(bad, field[ri, ci], v)
    return v


def _leg_arrays(site, res, p: WalkParams, mult, hz, comms_grid, wb_field):
    g2, g4 = site.grid2, site.grid4
    cells = res.cells
    ev = evaluate_cells(cells, site.z2, site.slope2, mult, g2.res, p)
    rc = np.asarray(cells, dtype=float)
    lon, lat = g2.rowcol_to_lonlat(rc[:, 0], rc[:, 1])
    r4, c4 = g4.lonlat_to_rowcol(lon, lat)
    ri, ci = rc[:, 0].astype(int), rc[:, 1].astype(int)
    wb_vals = np.asarray(_sample_field(wb_field, r4, c4), dtype=float)
    # The route squeezes through gaps the coarser 4 m walk-back grid can miss. The crew is on a
    # route that connects to the hab, so take the walk-back time from the neighbouring route points
    # instead of treating those few points as "unreachable" (which made the sim assume a 4 h walk).
    bad = ~np.isfinite(wb_vals)
    if bad.any() and (~bad).any():
        k = np.arange(wb_vals.size)
        wb_vals[bad] = np.interp(k[bad], k[~bad], wb_vals[~bad])
    ev.update({
        "lonlat": np.column_stack([lon, lat]),
        "shield": sample_bilinear(site.shield4, r4, c4),
        "comms": comms_grid[ri, ci],
        "walkback_s": wb_vals,
        "hazard": hz[ri, ci],
        "sand": site.sand2[ri, ci],
    })
    return ev


def _climate_cal(site):
    """Calibration hook for climate.calibrated(): measured REMS season means at Curiosity's site."""
    mission = site.cfg["rover"].get("raw_images_mission")
    if mission not in weather_live.FEEDS:
        return None
    return lambda ls: weather_live.ls_climatology(mission, ls)  # None where the feed has no sols near this Ls


def _site_climate(site):
    """climate.at_site() for this site: its latitude and median elevation."""
    return climate.at_site(site.grid.lat0, float(np.median(site.z2)))


def _default_start(lon: float) -> datetime:
    now = datetime.now(timezone.utc)
    t = mars24.utc_for_ltst(now, lon, 9.0)
    if t < now:
        t = mars24.utc_for_ltst(now + timedelta(seconds=mars24.MARS_SOL_DAYS * 86400), lon, 9.0)
    return t.replace(microsecond=0)


def _layer_catalog(site) -> list[dict]:
    th = site.thermal4 is not None
    L = [
        {"id": "hillshade", "name": "Shaded relief (1 m DTM)", "group": "Terrain", "blend": "multiply", "default_opacity": 0.55},
        {"id": "elevation", "name": "Elevation tint", "group": "Terrain", "default_opacity": 0.55, "legend": {
            "unit": "m", "stops": [[round(float(site.z2.min())), "#2b3a67"], [round(float(np.median(site.z2))), "#e9d98b"],
                                   [round(float(site.z2.max())), "#f2e6dc"]]}},
        {"id": "slope", "name": "Slope", "group": "Hazards", "default_opacity": 0.75, "legend": tilelib.LEGENDS["slope"]},
        {"id": "roughness", "name": "Roughness (metre-scale relief)", "group": "Hazards", "default_opacity": 0.8, "legend": tilelib.LEGENDS["roughness"]},
        {"id": "sand", "name": "Loose-sand likelihood", "group": "Hazards", "default_opacity": 0.85, "legend": tilelib.LEGENDS["sand"],
         "about": "Where loose sand probably lies. THEMIS night IR (sand and dust cool fast at night), HiRISE darkness and, where "
                  "the USGS map has one, the dune/bedform unit say how much of each ~100 m patch is sand; hollows and dark spots "
                  "inside the patch get it. Checked against Jezero's mapped bedform unit (AUC 0.84 without using the map).",
         "source": "Mars Odyssey THEMIS night IR, MRO HiRISE colour, USGS geologic map; own model (pipeline/sand.py)"},
        {"id": "hazard", "name": "Combined hazard class", "group": "Hazards", "default_opacity": 0.8, "legend": tilelib.LEGENDS["hazard"], "dynamic": "walk"},
        *([{"id": "boulders", "name": "Boulders (HiRISE shadows)", "group": "Hazards", "default_opacity": 0.9, "legend": tilelib.LEGENDS["boulders"],
            "about": "Boulders found by our own shadow detector in the DTM's 25 cm HiRISE orthoimage (read at 0.5 m). "
                     "Boulders of 2 m or more are walked around; smaller ones raise the route cost.",
            "source": "MRO HiRISE controlled orthoimage, own shadow-detection algorithm"}] if site.boulder2 is not None else []),
        {"id": "shielding", "name": "Terrain radiation shielding", "group": "Radiation", "default_opacity": 0.8, "legend": tilelib.LEGENDS["shielding"]},
        {"id": "skyview", "name": "Sky-view factor", "group": "Radiation", "default_opacity": 0.6, "legend": tilelib.LEGENDS["skyview"]},
        {"id": "walkback", "name": "Walk-back time to hab", "group": "Safety", "default_opacity": 0.75, "legend": tilelib.LEGENDS["walkback"], "dynamic": "walkback"},
        {"id": "ways_home", "name": "Ways home (every fastest walk back)", "group": "Safety", "default_opacity": 0.95,
         "legend": flowlib.legend(), "dynamic": "havens",
         "about": "The fastest walk back from every 4 m cell, drawn as one network. Paths merge like rivers: trunks most of the "
                  "site uses to get home, gateways where branches meet, and dark red ground with no way home. With PR-2 "
                  "parked or a cache placed, every cell drains to its nearest haven and the site splits into basins.",
         "source": "HiRISE DTM walking-time graph, Dijkstra predecessors and flow accumulation (server/flow.py)"},
        {"id": "comms", "name": "Radio line of sight", "group": "Safety", "default_opacity": 0.8, "legend": tilelib.LEGENDS["comms"], "dynamic": "comms"},
    ]
    if th:
        L.insert(5, {"id": "thermal", "name": "THEMIS night IR (100 m)", "group": "Thermal", "default_opacity": 0.6, "legend": tilelib.LEGENDS["thermal"],
                     "about": "Night-time surface temperature. Rock and cemented ground stay warm at night (high thermal inertia); "
                              "loose sand and dust cool fast and show dark.",
                     "source": "Mars Odyssey THEMIS controlled night-IR mosaic (ASU, USGS)"})
    if site.thermal_day4 is not None:
        src = site.meta.get("thermal_day_source", {})
        L.insert(6 if th else 5, {"id": "thermal_day", "name": "THEMIS day IR (100 m, Mars Trek)", "group": "Thermal", "default_opacity": 0.6,
                                  "legend": tilelib.LEGENDS["thermal_day"],
                                  "about": "Afternoon surface temperature. Sun-facing slopes and dark, dusty or sandy ground are warm; shaded "
                                           "slopes are cold. Ground that is warm by day but cold at night is loose, low-inertia material.",
                                  "source": f"Mars Odyssey THEMIS day-IR controlled mosaic v2 (ASU), served by NASA Mars Trek ({src.get('layer', '')})"})
    if site.geology2 is not None:
        gm = site.geology_meta
        from pipeline import geology as _geo
        n_units = len([u for u in gm.get("units", []) if u.get("share", 0) > 0])
        L.append({"id": "geology", "name": "Geologic units (USGS)", "group": "Geology",
                  "default_opacity": 0.55 if n_units > 1 else 0.3,  # one unit over the whole site: a light wash
                  "legend": _geo.legend(gm),
                  "about": (f"{gm.get('map', '')}, {gm.get('scale', '')}. " + (gm.get("note") or "")).strip(),
                  "source": gm.get("citation", "")})
    if site.science:
        L.append({"id": "science", "name": "Science opportunity", "group": "Science", "default_opacity": 0.8,
                  "legend": tilelib.LEGENDS["science"],
                  "about": "Where a geologist would want to stop: strong CRISM mineral signals (hydrated minerals, sulfates, clays "
                           "first), boundaries between USGS map units, ridge crests and hollow floors, and rover sample sites, "
                           "lowered where loose sand hides the rock. SUGGEST STOPS picks from this inside the safe walk-back range.",
                  "source": "MRO CRISM, USGS geologic map, HiRISE DTM, rover data; own score (pipeline/science.py)"})
    if site.horizon is not None:
        L.append({"id": "shadow", "name": "Terrain shadow (at the EVA time)", "group": "Sun", "default_opacity": 0.7,
                  "legend": tilelib.LEGENDS["shadow"], "dynamic": "sun",
                  "about": "Ground where hills and ridges hide the sun at the chosen time, from the terrain horizon of every 4 m cell "
                           "(near field from the HiRISE DTM, far field such as Mount Sharp from the 200 m regional DEM).",
                  "source": "HiRISE DTM + HRSC-MOLA horizon, Mars24 sun position"})
    lk = site.cfg.get("lake") or {}
    L.append({"id": "lake", "name": "Ancient lake (flood the crater)", "group": "Geology", "default_opacity": 0.85,
              "legend": lakelib.LEGEND, "dynamic": "level", "levels": lk.get("levels", []),
              "default_level": (lk.get("levels") or [{}])[0].get("elev", round(float(np.median(site.z2)), 0)),
              "about": lk.get("note") or "A water surface at the chosen level: what lay under water if a lake filled the crater to "
                                       "this height. No published lake level for this site is in our sources, so this is a what-if.",
              "source": lk.get("source") or "HiRISE DTM heights"})
    L.append({"id": "rescue", "name": "Partner down: minutes to pressure", "group": "Safety", "default_opacity": 0.75,
              "legend": envlib.RESCUE_LEGEND, "dynamic": "rescue",
              "about": "If one crew member is hurt, how long until they are back in pressure: carried home by the other (a third of "
                       "walking speed, slopes under 14 deg) or, hatched, PR-2 driving out to the nearest drivable ground to meet them. "
                       "Dark: no way to bring them in.",
              "source": "Walking and rover models on the HiRISE DTM (server/envelope.py)"})
    if site.horizon is not None:
        L.append({"id": "skyline_fix", "name": "Skyline fix quality (no GPS)", "group": "Navigation", "default_opacity": 0.7,
                  "legend": skylib.FIX_LEGEND,
                  "about": "There is no GPS on Mars. The helmet can fix its position by matching the skyline it sees against the "
                           "stored horizon of every 4 m cell. This layer is the expected 95 % fix radius: green where the skyline "
                           "is distinctive, red in featureless hollows where many places look the same.",
                  "source": "HiRISE DTM + HRSC-MOLA horizon (24 directions per 4 m cell), own matcher (server/skyline.py)"})
    if site.scouted4 is not None and site.ingenuity:
        L.append({"id": "scouted", "name": "Seen from the air by Ingenuity", "group": "Science", "default_opacity": 0.75,
                  "legend": tilelib.LEGENDS["scouted"],
                  "about": "Ground under Ingenuity's flights: its downward navigation camera saw about 1.4x its altitude to either "
                           "side. Inspect a point to see which flight and open its photos.",
                  "source": "JPL MMGIS Mars 2020 helicopter flight paths, placed on our terrain with the team-DEM shift"})
    if site.sand_conf2 is not None:
        L.append({"id": "sand_conf", "name": "Sand estimate confidence", "group": "Confidence", "default_opacity": 0.75,
                  "legend": tilelib.LEGENDS["confidence"],
                  "about": "How far the sand clues agree (night IR, darkness, hollows, the geologic map). Red: they disagree, so the "
                           "sand likelihood there is a guess.", "source": "pipeline/sand.py"})
    if site.terrain_conf2 is not None:
        tm = site.meta.get("team_dem", {})
        L.append({"id": "terrain_conf", "name": "Terrain data confidence", "group": "Confidence", "default_opacity": 0.75,
                  "legend": tilelib.LEGENDS["confidence"],
                  "about": "Whether our USGS DTM and the rover team's own DTM agree after lining them up (height within ~2 m, slope "
                           "within ~8 deg). Red: the two stereo models disagree, so slope and roughness there are less certain.",
                  "source": f"USGS HiRISE DTM vs {tm.get('name', 'the team DTM')}"})
    colors = ["#ff3b3b", "#3bff5a", "#3b8bff"]
    for kind, c in site.crism.items():
        m = c["meta"]
        bands = m.get("bands", [])
        L.append({"id": f"crism_{kind}", "name": m.get("name", f"CRISM {kind}"), "group": "Spectral (CRISM)", "default_opacity": 0.85,
                  "about": m.get("about", ""), "bands": bands,
                  "legend": {"unit": " · ".join(f"{ch} = {b}" for ch, b in zip("RGB", bands)), "stops": [[i, colors[i]] for i in range(len(bands[:3]))]},
                  "source": f"MRO CRISM MTRDR ({len(m.get('products', []))} observations, 18-36 m pixels)"})
    return L


# ====================================================================== routes
@app.get("/api/health")
def health():
    return {"ok": True, "time": datetime.now(timezone.utc).isoformat(), "sites": [s for s in site_ids() if is_built(s)]}


@app.get("/api/sites")
def sites():
    out = []
    for sid in site_ids():
        cfg = load_config(sid)
        out.append({"id": sid, "name": cfg["name"], "short_name": cfg.get("short_name", cfg["name"]),
                    "mission": cfg["mission"], "rover_name": cfg.get("rover_name"), "built": is_built(sid),
                    "bbox": cfg["bbox"]})
    return out


@app.get("/api/sites/{site_id}")
def site_info(site_id: str):
    _warm_overlays(site_id)
    s = _site(site_id)
    cfg, meta = s.cfg, s.meta
    g = s.grid
    lon_min, lat_min, lon_max, lat_max = g.bounds_lonlat()

    def basemap(b):
        if not b:
            return None
        return {**{k: v for k, v in b.items() if k != "url"}, "proxy_url": f"/api/basemap/{cfg['mission']}/{b['id']}/{{z}}/{{x}}/{{y}}.png",
                "upstream_url": b["url"]}

    files = sorted(p.name for p in s.dir.iterdir() if p.suffix in (".jpg", ".png", ".geojson"))
    return {
        "id": site_id, "name": cfg["name"], "short_name": cfg.get("short_name"), "region": cfg.get("region"),
        "mission": cfg["mission"], "rover_name": cfg.get("rover_name"), "story": cfg.get("story"),
        "bounds": [[lat_min, lon_min], [lat_max, lon_max]],
        "center": {"lon": g.lon0, "lat": g.lat0},
        "grid": meta["grid_1m"], "grid2": meta["grid_2m"], "grid4": meta["grid_4m"],
        "size_m": meta.get("size_m"), "elev_min": meta.get("elev_min"), "elev_max": meta.get("elev_max"),
        "regional_grid": meta.get("regional_grid"), "regional_elev": meta.get("regional_elev"),
        "habitat": cfg.get("habitat"), "stops": cfg.get("stops", []), "shelters": cfg.get("shelters", []),
        "radio": cfg.get("radio", {}), "refuges": s.refuges(),
        "basemap": basemap(cfg.get("basemap")), "context_basemap": basemap(cfg.get("context_basemap")),
        "labels": basemap(cfg.get("labels")),
        "layers": _layer_catalog(s),
        "rover": {**meta.get("rover", {}), "raw_images_mission": cfg["rover"].get("raw_images_mission"),
                  "landing_msd_local": cfg["rover"].get("landing_msd_local"),
                  "extras": [{"id": e["id"], "name": e.get("name", e["id"]), "kind": e["kind"]} for e in cfg["rover"].get("extras", [])]},
        "dem_sources": meta.get("dem_sources"), "thermal_source": meta.get("thermal_source"),
        "thermal_day_source": meta.get("thermal_day_source"),
        "geology": ({k: s.geology_meta.get(k) for k in ("map", "citation", "scale", "url", "note", "coverage")}
                    if s.geology_meta else None),
        "trek_url": __import__("pipeline.trek", fromlist=["open_url"]).open_url(g.lon0, g.lat0),
        "shield_stats": meta.get("shield_stats"), "centre_horizon_deg": meta.get("centre_horizon_deg"),
        "team_dem": ({k: v for k, v in meta["team_dem"].items()} if meta.get("team_dem") else None),
        "texture_offset_m": meta.get("texture_offset_m"),
        "sand": meta.get("sand"), "terrain_confidence": meta.get("terrain_confidence"),
        "ingenuity": meta.get("ingenuity"), "has_horizon": s.horizon is not None,
        "files": files,
        "built_utc": meta.get("built_utc"),
        "defaults": {"walk": WalkParams().to_dict(), "suit": eva.SuitParams().to_dict(), "start_utc": _default_start(g.lon0).isoformat()},
    }


@app.get("/api/sites/{site_id}/files/{name}")
def site_file(site_id: str, name: str):
    s = _site(site_id)
    p = (s.dir / name).resolve()
    if p.parent != s.dir.resolve() or p.suffix not in (".jpg", ".png", ".geojson", ".json") or not p.exists():
        raise HTTPException(404)
    media = {"jpg": "image/jpeg", "png": "image/png", "geojson": "application/geo+json", "json": "application/json"}[p.suffix[1:]]
    return FileResponse(p, media_type=media, headers={"Cache-Control": "public, max-age=3600"})


def _resample(arr: np.ndarray, w: int, h: int) -> np.ndarray:
    return np.asarray(Image.fromarray(arr.astype(np.float32)).resize((w, h), Image.BILINEAR), np.float32)


@app.get("/api/sites/{site_id}/terrain")
def terrain(site_id: str, size: int = Query(513, ge=65, le=2049)):
    s = _site(site_id)
    a = _resample(s.dem1, size, size)
    return Response(a.tobytes(), media_type="application/octet-stream",
                    headers={"X-Size": str(size), "X-Extent": json.dumps(s.meta["size_m"]), "Cache-Control": "public, max-age=3600"})


@app.get("/api/sites/{site_id}/regional-terrain")
def regional_terrain(site_id: str, size: int = Query(257, ge=65, le=1025)):
    s = _site(site_id)
    arr, rg = s.regional
    if arr is None:
        raise HTTPException(404, "no regional DEM")
    a = _resample(arr, size, size)
    return Response(a.tobytes(), media_type="application/octet-stream",
                    headers={"X-Size": str(size), "Cache-Control": "public, max-age=3600"})


def _raw_grid(arr: np.ndarray, grid: dict, extra: dict | None = None) -> Response:
    """Native-resolution float32 grid (row 0 = north edge) for GPU height textures."""
    a = np.ascontiguousarray(arr, dtype=np.float32)
    hdr = {"X-Shape": f"{a.shape[0]},{a.shape[1]}", "X-Grid": json.dumps(grid), "X-Dtype": "float32",
           "Access-Control-Expose-Headers": "X-Shape,X-Grid,X-Dtype,X-Offset", "Cache-Control": "public, max-age=3600"}
    hdr.update(extra or {})
    return Response(a.tobytes(), media_type="application/octet-stream", headers=hdr)


@app.get("/api/sites/{site_id}/dem.bin")
def dem_native(site_id: str):
    """The full 1 m HiRISE DTM (about 42 MB). The Godot client streams it into a GPU height texture."""
    s = _site(site_id)
    return _raw_grid(np.nan_to_num(s.dem1, nan=float(np.nanmin(s.dem1))), s.meta["grid_1m"])


@app.get("/api/sites/{site_id}/boulders.bin")
def boulders_bin(site_id: str):
    """Detected boulders as float32 rows (x, y, diameter, height), site metres, for the 3D rock field."""
    s = _site(site_id)
    b = np.ascontiguousarray(s.boulders, dtype=np.float32)
    return Response(b.tobytes(), media_type="application/octet-stream",
                    headers={"X-Shape": f"{b.shape[0]},4", "Access-Control-Expose-Headers": "X-Shape", "Cache-Control": "public, max-age=3600"})


@app.get("/api/sites/{site_id}/regional.bin")
def regional_native(site_id: str):
    """The 200 m regional DEM (the crater, its rim and nearby mountains) at native resolution."""
    s = _site(site_id)
    arr, _ = s.regional
    if arr is None:
        raise HTTPException(404, "no regional DEM")
    return _raw_grid(arr, s.meta["regional_grid"], {"X-Offset": str(s.meta.get("regional_offset_m", 0.0))})


_IMG_HOSTS = ("mars.nasa.gov", "mars.jpl.nasa.gov", "science.nasa.gov", "photojournal.jpl.nasa.gov", "pds-imaging.jpl.nasa.gov")
_IMG_FETCH = threading.BoundedSemaphore(4)


@app.get("/api/image-proxy")
def image_proxy(url: str, max_px: int = Query(1024, ge=64, le=4096)):
    """Fetch a NASA image once, cache it on disk, and return a resized JPEG.

    Native clients (the Godot app) use this instead of talking TLS to NASA themselves.
    """
    from hashlib import sha1
    from urllib.parse import urlparse

    u = urlparse(url)
    if u.scheme not in ("http", "https") or not any(u.hostname == h or (u.hostname or "").endswith("." + h) for h in _IMG_HOSTS):
        raise HTTPException(403, "only NASA image hosts are allowed")
    key = sha1(f"{url}|{max_px}".encode()).hexdigest()
    p = DATA_DIR / "cache" / "img" / f"{key}.jpg"
    if not p.exists():
        try:
            with _IMG_FETCH:  # a page of 12+ thumbnails at once gets throttled upstream: a few at a time
                r = session().get(url, timeout=40)
        except Exception as e:
            raise HTTPException(502, f"image fetch failed: {type(e).__name__}")
        if r.status_code != 200 or not r.content:
            raise HTTPException(502, f"upstream status {r.status_code}")
        try:
            im = Image.open(io.BytesIO(r.content))
            im = im.convert("RGB")
            im.thumbnail((max_px, max_px), Image.LANCZOS)
            buf = io.BytesIO()
            im.save(buf, "JPEG", quality=88)
        except Exception:
            raise HTTPException(502, "upstream returned something that is not an image")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(buf.getvalue())
    return Response(p.read_bytes(), media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})


# ---------------------------------------------------------------------- tiles
@app.get("/api/sites/{site_id}/tiles/{layer}/{z}/{x}/{y}.png")
def site_tile(site_id: str, layer: str, z: int, x: int, y: int,
              hab_lon: float | None = None, hab_lat: float | None = None, utc: str | None = None,
              flat_speed: float | None = None, max_slope: float | None = None, caution_slope: float | None = None,
              max_rough: float | None = None, sand_penalty: float | None = None, hazard_aversion: float | None = None, load_kg: float | None = None,
              obs: str | None = None, tgt: float = 2.0, havens: str | None = None,
              rover_lon: float | None = None, rover_lat: float | None = None, level: float | None = None):
    s = _site(site_id)
    grid = {"hillshade": s.grid, "thermal": s.grid4, "thermal_day": s.grid4, "shielding": s.grid4, "skyview": s.grid4, "walkback": s.grid4,
            "shadow": s.grid4, "scouted": s.grid4}.get(layer, s.grid2)
    if not tilelib.intersects(grid, z, x, y):
        return _png(tilelib.empty_png())
    q = dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
             sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg)
    if layer == "hillshade":
        return _png(tilelib.render_hillshade(s.hillshade1, grid, z, x, y))
    if layer.startswith("crism_") and layer[6:] in s.crism:
        return _png(tilelib.render_rgba(s.crism[layer[6:]]["rgba"], s.grid4, z, x, y))
    if layer == "elevation":
        return _png(tilelib.render_continuous(s.z2, grid, z, x, y, float(s.z2.min()), float(s.z2.max()), "elevation"))
    if layer == "slope":
        return _png(tilelib.render_continuous(s.slope2, grid, z, x, y, 0, 40, "slope"))
    if layer == "roughness":
        return _png(tilelib.render_continuous(s.rough2, grid, z, x, y, 0, 0.6, "roughness"))
    if layer == "sand":
        return _png(tilelib.render_continuous(s.sand2, grid, z, x, y, 0, 1.0, "sand"))
    if layer == "boulders" and s.boulder2 is not None:
        return _png(tilelib.render_continuous(s.boulder2, grid, z, x, y, 0, 4.0, "boulders"))
    if layer == "shielding":
        return _png(tilelib.render_continuous(s.shield4, grid, z, x, y, 0, 0.2, "shielding"))
    if layer == "skyview":
        return _png(tilelib.render_continuous(s.svf4, grid, z, x, y, 0.6, 1.0, "skyview"))
    if layer == "thermal" and s.thermal4 is not None:
        lo, hi = np.percentile(s.thermal4, [1, 99])
        return _png(tilelib.render_continuous(s.thermal4, grid, z, x, y, float(lo), float(hi), "thermal"))
    if layer == "thermal_day" and s.thermal_day4 is not None:
        lo, hi = np.percentile(s.thermal_day4, [1, 99])
        return _png(tilelib.render_continuous(s.thermal_day4, grid, z, x, y, float(lo), float(hi), "thermal_day"))
    if layer == "geology" and s.geology2 is not None:
        from pipeline import geology as _geo
        return _png(tilelib.render_classes(s.geology2, grid, z, x, y, _geo.colors_rgba(s.geology_meta)))
    if layer == "science" and s.science:
        return _png(tilelib.render_continuous(s.science["score"], grid, z, x, y, 0, 1.0, "science"))
    if layer == "sand_conf" and s.sand_conf2 is not None:
        return _png(tilelib.render_continuous(s.sand_conf2, grid, z, x, y, 0, 1.0, "confidence"))
    if layer == "terrain_conf" and s.terrain_conf2 is not None:
        return _png(tilelib.render_continuous(s.terrain_conf2, grid, z, x, y, 0, 1.0, "confidence"))
    if layer == "scouted" and s.scouted4 is not None:
        return _png(tilelib.render_classes((s.scouted4 > 0).astype(np.uint8), grid, z, x, y, tilelib.SCOUTED_COLORS, hatch_class=1))
    if layer == "shadow" and s.horizon is not None:
        return _png(tilelib.render_classes(_shadow_at(s, utc), grid, z, x, y, tilelib.SHADOW_COLORS), DYN_HEADERS)
    if layer == "hazard":
        p = _walk_from_query(q)
        return _png(tilelib.render_classes(s.hazard(p), grid, z, x, y, tilelib.HAZARD_COLORS), DYN_HEADERS)
    if layer == "ways_home":
        tree = s.flow(_havens(s, havens, hab_lon, hab_lat), _walk_from_query(q))
        rgba, g = _flow_tile_source(tree)
        return _png(tilelib.render_rgba(rgba, g, z, x, y), DYN_HEADERS)
    if layer == "skyline_fix" and s.horizon is not None:
        m, g = s.fix_quality
        return _png(tilelib.render_continuous(m, g, z, x, y, 0, 240.0, "fixq"))
    if layer == "rescue":
        res = _rescue_field(s, _havens(s, havens, hab_lon, hab_lat), _walk_from_query(q), rover_lon, rover_lat)
        return _png(tilelib.render_rgba(res["_rgba"], s.grid4, z, x, y), DYN_HEADERS)
    if layer == "lake":
        lv = float(level) if level is not None else float(np.median(s.z2))
        rr, cc = tilelib.tile_rowcol(s.grid2, z, x, y)
        zz = sample_bilinear(s.z2, rr, cc)
        rgba = lakelib.water_rgba(zz, lv)
        rgba[~((rr >= -0.5) & (rr <= s.grid2.height - 0.5) & (cc >= -0.5) & (cc <= s.grid2.width - 0.5))] = 0
        return _png(tilelib.encode(rgba), DYN_HEADERS)
    if layer == "walkback":
        if hab_lon is None or hab_lat is None:
            raise HTTPException(422, "hab_lon/hab_lat required")
        p = _walk_from_query(q)
        wbk = s.walkback((hab_lon, hab_lat), p)
        return _png(tilelib.render_walkback(wbk["field"], grid, z, x, y), DYN_HEADERS)
    if layer == "comms":
        observers = _parse_observers(obs)
        if not observers:
            raise HTTPException(422, "obs required: lon,lat,height;...")
        c = s.comms(observers, tgt)
        return _png(tilelib.render_classes(c["grid"], grid, z, x, y, tilelib.COMMS_COLORS, hatch_class=0), DYN_HEADERS)
    raise HTTPException(404, f"unknown layer {layer}")


OVERLAY_DIR = DATA_DIR / "cache" / "overlays"
# Drapes that depend only on the site build: rendered once, kept on disk, warmed in the background.
STATIC_OVERLAYS = ("slope", "roughness", "sand", "elevation", "shielding", "skyview", "thermal", "thermal_day", "boulders", "geology",
                   "science", "sand_conf", "terrain_conf", "scouted")
WARM_SIZES = (1632, 2048)  # Godot asks for 1632 px on the low preset, 2048 otherwise


def _is_static_overlay(layer: str) -> bool:
    return layer in STATIC_OVERLAYS or layer.startswith("crism_")


def _resize(arr: np.ndarray, size: int, nearest: bool = False) -> np.ndarray:
    """A whole-site grid onto size x size pixel centres (what the 3D drape expects); Pillow does it in C."""
    im = Image.fromarray(np.ascontiguousarray(arr, dtype=np.float32), "F")
    return np.asarray(im.resize((size, size), Image.NEAREST if nearest else Image.BILINEAR), dtype=np.float32)


def _indexed(idx: np.ndarray, colors) -> Image.Image:
    """Palette image: 1 byte per pixel instead of 4, so the PNG is smaller and much faster to encode and send."""
    pal = np.zeros((256, 4), np.uint8)
    c = np.asarray(colors, np.uint8).reshape(-1, 4)
    pal[: len(c)] = c
    im = Image.fromarray(np.ascontiguousarray(idx, dtype=np.uint8), "P")
    im.putpalette(pal[:, :3].tobytes())
    im.info["transparency"] = pal[:, 3].tobytes()
    return im


def _shadow_at(s, utc: str | None) -> np.ndarray:
    """Terrain-shadow classes on the 4 m grid at a UTC time (default: now), cached per minute."""
    when = _parse_utc(utc).replace(second=0, microsecond=0)
    key = (s.id, when.isoformat())
    with _overlay_lock:
        hit = _shadow_cache.get(key)
    if hit is not None:
        return hit
    e, a, _ = mars24.sun_position(mars24.mars_time(when), s.grid.lat0, s.grid.lon0)
    g = s.shadow_grid(e, a)
    with _overlay_lock:
        _shadow_cache[key] = g
        while len(_shadow_cache) > 32:
            _shadow_cache.pop(next(iter(_shadow_cache)))
    return g


_shadow_cache: dict = {}


def _layer_on_grid(s, layer: str, size: int, q: dict, hab_lon=None, hab_lat=None, obs=None, tgt=2.0, utc=None) -> Image.Image:
    """A layer over the whole site (north-up, site grid) as a palette or RGBA image, for draping on 3D terrain."""
    def cont(arr, vmin, vmax, name):
        v = _resize(arr, size)
        idx = np.nan_to_num(np.clip((v - vmin) / (vmax - vmin) * 255, 0, 255)).astype(np.uint8)
        return _indexed(idx, tilelib.LUTS[name])

    if layer == "slope":
        return cont(s.slope2, 0, 40, "slope")
    if layer == "roughness":
        return cont(s.rough2, 0, 0.6, "roughness")
    if layer == "sand":
        return cont(s.sand2, 0, 1.0, "sand")
    if layer == "shielding":
        return cont(s.shield4, 0, 0.2, "shielding")
    if layer == "elevation":
        return cont(s.z2, float(s.z2.min()), float(s.z2.max()), "elevation")
    if layer == "skyview":
        return cont(s.svf4, 0.6, 1.0, "skyview")
    if layer == "thermal" and s.thermal4 is not None:
        lo, hi = np.percentile(s.thermal4, [1, 99])
        return cont(s.thermal4, float(lo), float(hi), "thermal")
    if layer == "thermal_day" and s.thermal_day4 is not None:
        lo, hi = np.percentile(s.thermal_day4, [1, 99])
        return cont(s.thermal_day4, float(lo), float(hi), "thermal_day")
    if layer == "geology" and s.geology2 is not None:
        from pipeline import geology as _geo
        return _indexed(_resize(s.geology2, size, nearest=True), _geo.colors_rgba(s.geology_meta))
    if layer.startswith("crism_") and layer[6:] in s.crism:
        rgba = s.crism[layer[6:]]["rgba"]  # Pillow resizes RGBA premultiplied: no colour fringes at the data edge
        return Image.fromarray(np.ascontiguousarray(rgba, dtype=np.uint8), "RGBA").resize((size, size), Image.BILINEAR)
    if layer == "boulders" and s.boulder2 is not None:
        return cont(s.boulder2, 0, 4, "boulders")
    if layer == "science" and s.science:
        return cont(s.science["score"], 0, 1.0, "science")
    if layer == "sand_conf" and s.sand_conf2 is not None:
        return cont(np.nan_to_num(s.sand_conf2, nan=1.0), 0, 1.0, "confidence")
    if layer == "terrain_conf" and s.terrain_conf2 is not None:
        return cont(np.nan_to_num(s.terrain_conf2, nan=1.0), 0, 1.0, "confidence")
    if layer == "scouted" and s.scouted4 is not None:
        return _indexed(_resize((s.scouted4 > 0).astype(np.float32), size, nearest=True), tilelib.SCOUTED_COLORS)
    if layer == "shadow" and s.horizon is not None:
        return _indexed(_resize(_shadow_at(s, utc).astype(np.float32), size, nearest=True), tilelib.SHADOW_COLORS)
    if layer == "hazard":
        return _indexed(_resize(s.hazard(_walk_from_query(q)), size, nearest=True), tilelib.HAZARD_COLORS)
    if layer == "comms":
        return _indexed(_resize(s.comms(_parse_observers(obs), tgt)["grid"], size, nearest=True), tilelib.COMMS_COLORS)
    if layer == "skyline_fix" and s.horizon is not None:
        return cont(s.fix_quality[0], 0, 240.0, "fixq")
    if layer == "rescue":
        res = _rescue_field(s, _havens(s, q.get("havens"), hab_lon, hab_lat), _walk_from_query(q), q.get("rover_lon"), q.get("rover_lat"))
        return Image.fromarray(res["_rgba"], "RGBA").resize((size, size), Image.NEAREST)
    if layer == "lake":
        lv = float(q["level"]) if q.get("level") is not None else float(np.median(s.z2))
        return Image.fromarray(lakelib.water_rgba(_resize(s.z2, size), lv), "RGBA")
    if layer in ("ways_home", "ways_home_data"):
        tree = s.flow(_havens(s, q.get("havens"), hab_lon, hab_lat), _walk_from_query(q))
        with tree.lock:
            return tree.render(size) if layer == "ways_home" else tree.data_texture(min(size, 2048))
    if layer == "walkback":
        f = s.walkback((hab_lon, hab_lat), _walk_from_query(q))["field"]
        m = _resize(np.where(np.isfinite(f), f / 60.0, 1e6), size)
        idx = np.zeros(m.shape, np.uint8)
        lo = -1.0
        for k, (hi, _col) in enumerate(tilelib.WALKBACK_BANDS):
            idx[(m > lo) & (m <= hi)] = k + 1
            lo = hi
        return _indexed(idx, [(0, 0, 0, 0)] + [col for _, col in tilelib.WALKBACK_BANDS])
    raise HTTPException(404, f"unknown layer {layer}")


def _encode_png(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    if im.mode == "P":
        im.save(buf, "PNG", compress_level=1, transparency=im.info.get("transparency"))
    else:
        im.save(buf, "PNG", compress_level=1)  # fast: these are fetched over localhost
    return buf.getvalue()


def _overlay_bytes(site_id: str, layer: str, size: int, q: dict | None = None, hab_lon=None, hab_lat=None,
                   obs=None, tgt: float = 2.0, utc: str | None = None) -> bytes:
    """PNG of a draped layer: memory cache, then the on-disk copy (static layers), then render."""
    s = _site(site_id)
    q = q or {}
    if layer == "shadow":  # one picture per minute of sun motion
        utc = _parse_utc(utc).replace(second=0, microsecond=0).isoformat()
    key = (site_id, layer, size, hab_lon, hab_lat, obs, tgt, utc, tuple(sorted((k, v) for k, v in q.items() if v is not None)))
    with _overlay_lock:
        hit = _overlay_cache.pop(key, None)
        if hit is not None:
            _overlay_cache[key] = hit  # most recently used goes last
            return hit
    disk = None
    if _is_static_overlay(layer):
        stamp = re.sub(r"\W", "", str(s.meta.get("built_utc", "")))
        disk = OVERLAY_DIR / site_id / f"{layer}_{size}_{stamp}.png"
        if disk.exists():
            hit = disk.read_bytes()
    if hit is None:
        hit = _encode_png(_layer_on_grid(s, layer, size, q, hab_lon, hab_lat, obs, tgt, utc))
        if disk is not None:
            disk.parent.mkdir(parents=True, exist_ok=True)
            tmp = disk.with_name(f"{disk.name}.{threading.get_ident()}.tmp")
            tmp.write_bytes(hit)
            os.replace(tmp, disk)
    with _overlay_lock:
        _overlay_cache[key] = hit
        while len(_overlay_cache) > 48:
            _overlay_cache.pop(next(iter(_overlay_cache)))
    return hit


@app.get("/api/sites/{site_id}/overlay/{layer}.png")
def site_overlay(site_id: str, layer: str, size: int = Query(2048, ge=256, le=4096),
                 hab_lon: float | None = None, hab_lat: float | None = None, obs: str | None = None, tgt: float = 2.0,
                 utc: str | None = None, havens: str | None = None, rover_lon: float | None = None, rover_lat: float | None = None,
                 level: float | None = None, flat_speed: float | None = None, max_slope: float | None = None, caution_slope: float | None = None,
                 max_rough: float | None = None, sand_penalty: float | None = None, hazard_aversion: float | None = None, load_kg: float | None = None):
    q = dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
             sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg, havens=havens,
             rover_lon=rover_lon, rover_lat=rover_lat, level=level)
    return _png(_overlay_bytes(site_id, layer, size, q, hab_lon, hab_lat, obs, tgt, utc), DYN_HEADERS)


_overlay_cache: dict = {}
_overlay_lock = threading.Lock()
_warmed: set = set()


def _warm_overlays(site_id: str, delay_s: float = 3.0):
    """Render a site's static drapes in the background, once per site (they are then kept on disk)."""
    with _overlay_lock:
        if site_id in _warmed:
            return
        _warmed.add(site_id)

    def run():
        time.sleep(delay_s)  # let the client's first requests (manifest, DEM, plan) go first
        try:
            s = get_site(site_id)
            layers = [L for L in STATIC_OVERLAYS
                      if not (L == "thermal" and s.thermal4 is None) and not (L == "boulders" and s.boulder2 is None)
                      and not (L == "thermal_day" and s.thermal_day4 is None) and not (L == "geology" and s.geology2 is None)
                      and not (L == "science" and not s.science) and not (L == "sand_conf" and s.sand_conf2 is None)
                      and not (L == "terrain_conf" and s.terrain_conf2 is None)
                      and not (L == "scouted" and (s.scouted4 is None or not s.ingenuity))]
            layers += [f"crism_{k}" for k in s.crism]
            for size in WARM_SIZES:
                for layer in layers:
                    _overlay_bytes(site_id, layer, size)
        except Exception:  # a warm-up must never take the server down
            pass

    threading.Thread(target=run, name=f"warm-overlays-{site_id}", daemon=True).start()


@app.get("/api/sites/{site_id}/grid/{layer}.bin")
def site_grid(site_id: str, layer: str, hab_lon: float | None = None, hab_lat: float | None = None,
              obs: str | None = None, tgt: float = 2.0, flat_speed: float | None = None, max_slope: float | None = None,
              caution_slope: float | None = None, max_rough: float | None = None, sand_penalty: float | None = None,
              hazard_aversion: float | None = None, load_kg: float | None = None):
    """Raw grids for instant client-side lookups in the helmet HUD.

    walkback: float32 seconds on the 4 m grid (-1 = unreachable); comms / hazard: uint8 on the 2 m grid.
    Header X-Grid tells which grid (same dict as /api/sites/{id} 'grid2'/'grid4').
    """
    s = _site(site_id)
    q = dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
             sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg)
    if layer == "walkback":
        f = s.walkback((hab_lon, hab_lat), _walk_from_query(q))["field"]
        arr, g = np.where(np.isfinite(f), f, -1).astype(np.float32), "grid4"
    elif layer == "comms":
        arr, g = s.comms(_parse_observers(obs), tgt)["grid"].astype(np.uint8), "grid2"
    elif layer == "hazard":
        arr, g = s.hazard(_walk_from_query(q)).astype(np.uint8), "grid2"
    elif layer == "shield":
        arr, g = s.shield4.astype(np.float32), "grid4"
    else:
        raise HTTPException(404)
    return Response(np.ascontiguousarray(arr).tobytes(), media_type="application/octet-stream",
                    headers={"X-Grid": g, "X-Shape": f"{arr.shape[0]},{arr.shape[1]}", "X-Dtype": arr.dtype.name,
                             "Access-Control-Expose-Headers": "X-Grid,X-Shape,X-Dtype", **DYN_HEADERS})


def _parse_observers(obs: str | None):
    out = []
    for part in (obs or "").split(";"):
        bits = part.split(",")
        if len(bits) == 3:
            out.append((float(bits[0]), float(bits[1]), float(bits[2])))
    return out


_bm_lock = threading.Lock()


@app.get("/api/basemap/{mission}/{layer}/{z}/{x}/{y}.png")
def basemap_tile(mission: str, layer: str, z: int, x: int, y: int):
    """Offline-first proxy for JPL MMGIS basemap tiles (cached under data/tiles)."""
    cfg = None
    for sid in site_ids():
        c = load_config(sid)
        if c["mission"] == mission:
            for key in ("basemap", "context_basemap", "labels"):
                b = c.get(key)
                if b and b["id"] == layer:
                    cfg = b
    if cfg is None:
        raise HTTPException(404)
    if z > cfg.get("max_native_zoom", 18) or z < 0:
        return _png(tilelib.empty_png())
    d = DATA_DIR / "tiles" / f"{mission}_{layer}" / str(z) / str(x)
    p = d / f"{y}.png"
    miss = d / f"{y}.404"
    if p.exists():
        return Response(p.read_bytes(), media_type="image/png", headers=TILE_HEADERS)
    if miss.exists():
        return _png(tilelib.empty_png())
    url = cfg["url"].format(z=z, x=x, y=T.tms_y(y, z) if cfg.get("tms", True) else y)
    try:
        r = session().get(url, timeout=20)
    except Exception:
        return _png(tilelib.empty_png(), {"Cache-Control": "no-store"})
    d.mkdir(parents=True, exist_ok=True)
    if r.status_code in (403, 404) or not r.content or r.headers.get("content-type", "").startswith("text"):
        miss.touch()
        return _png(tilelib.empty_png())
    if r.status_code != 200:
        return _png(tilelib.empty_png(), {"Cache-Control": "no-store"})
    p.write_bytes(r.content)
    return Response(r.content, media_type=r.headers.get("content-type", "image/png"), headers=TILE_HEADERS)


# -------------------------------------------------------------------- routing
@app.post("/api/sites/{site_id}/route")
def route(site_id: str, req: RouteRequest):
    s = _site(site_id)
    p = _walk(req.walk)
    mult = s.multiplier(p)
    out = []
    for eng in req.engines:
        if eng not in ("astar", "dijkstra"):
            raise HTTPException(422, "engines: astar | dijkstra")
        res = _route(s, req.a, req.b, p, eng, req.astar_weight)
        if not res.cells:
            out.append({"engine": eng, "ok": False, "warnings": res.warnings, "compute_ms": res.compute_ms, "expansions": res.expansions})
            continue
        ev = evaluate_cells(res.cells, s.z2, s.slope2, mult, s.grid2.res, p)
        keep = simplify_cells(res.cells)
        rc = np.asarray(res.cells, float)[keep]
        lon, lat = s.grid2.rowcol_to_lonlat(rc[:, 0], rc[:, 1])
        out.append({
            "engine": eng, "ok": True, "compute_ms": round(res.compute_ms, 1), "expansions": res.expansions,
            "algorithm_cost_s": round(res.cost_s, 1),
            "dist_m": round(float(ev["d"][-1]), 1), "time_s": round(float(ev["t"][-1]), 1),
            "ascent_m": round(float(np.clip(ev["dz"], 0, None).sum()), 1), "descent_m": round(float(-np.clip(ev["dz"], None, 0).sum()), 1),
            "max_slope": round(float(ev["slope"].max()), 1),
            "path": [[round(float(a), 7), round(float(b), 7)] for a, b in zip(lon, lat)],
            "warnings": res.warnings,
        })
    return {"results": out, "walk": p.to_dict()}


def _sun_times_at(s, lon: float, lat: float, day: datetime, cache: dict | None = None) -> dict:
    """Terrain sunrise/sunset at a point for the sol containing `day` (memoised per call site in `cache`)."""
    key = (round(lon, 6), round(lat, 6), int(mars24.mars_time(day).msd + lon / 360.0))
    if cache is not None and key in cache:
        return cache[key]
    v = s.sun_times(lon, lat, day)
    if cache is not None:
        cache[key] = v
    return v


def _daylight_ok(s, start: datetime, total_s: float, margin_s: float = 1800.0, haven: tuple[float, float] | None = None,
                 cache: dict | None = None) -> bool:
    """The EVA starts after sunrise and ends at least margin_s before sunset, over the real terrain at the haven."""
    lon, lat = haven or (s.grid.lon0, s.grid.lat0)
    st = _sun_times_at(s, lon, lat, start, cache)
    if not st.get("sunrise_utc"):
        return False
    rise = datetime.fromisoformat(st["sunrise_utc"])
    sset = datetime.fromisoformat(st["sunset_utc"])
    return rise <= start and start + timedelta(seconds=total_s) <= sset - timedelta(seconds=margin_s)


def _space_weather(s, req: PlanRequest, start: datetime, events: list[dict], total_s: float,
                   haven: tuple[float, float] | None = None) -> dict:
    """Predicted CME arrivals at Mars against the suited window, and the first start that clears them."""
    if req.space_weather == "off" and req.cme_arrivals is None:
        return {"checked": False, "source": "off", "arrivals": [], "level": "ok"}
    if req.cme_arrivals is not None:
        arrivals, info = [a.model_dump() for a in req.cme_arrivals], {"source": "request"}
    else:
        arrivals, info = spaceweather.arrivals_for_plan()
    if arrivals is None:
        return {"checked": False, "source": info.get("source"), "arrivals": [], "level": "ok"}
    eg, ig = eva.suited_window(events)
    suited = (float(eg["t0"]), float(ig["t1"]))
    chk = spaceweather.plan_check(arrivals, start, suited, total_s)
    out = {"checked": True, **info, **chk, "suited_s": [round(suited[0], 1), round(suited[1], 1)]}
    if chk["level"] != "ok":
        out["suggested"] = _clear_start(s, arrivals, start, suited, total_s, haven)
    return out


def _clear_start(s, arrivals: list[dict], start: datetime, suited: tuple[float, float], total_s: float,
                 haven: tuple[float, float] | None = None) -> dict | None:
    """The first start time, from the planned one onwards (never in the past), whose suited window is clear of
    every arrival window and still fits in daylight: half-hour steps of local time 07:00-13:00 for six sols."""
    lon0 = s.grid.lon0
    now = datetime.now(timezone.utc)
    t_from = max(start, now)
    sol_s = mars24.MARS_SOL_DAYS * 86400
    planned_ltst = mars24.local_true_solar_time(mars24.mars_time(start), lon0)
    cache: dict = {}
    for k in range(0, 7):
        day = start + timedelta(seconds=k * sol_s)
        for h in np.arange(7.0, 13.01, 0.5):
            t = mars24.utc_for_ltst(day, lon0, float(h)).replace(microsecond=0)
            if t < t_from - timedelta(seconds=60):
                continue
            if not _daylight_ok(s, t, total_s, haven=haven, cache=cache):
                continue
            if spaceweather.is_clear(arrivals, t, suited):
                mt = mars24.mars_time(t)
                return {"start_utc": t.isoformat(), "start_ltst": round(mars24.local_true_solar_time(mt, lon0), 4),
                        "mission_sol": mars24.mission_sol(mt, lon0, s.cfg["rover"].get("landing_msd_local", 0)),
                        "delay_h": round((t - start).total_seconds() / 3600, 1), "planned_ltst": round(planned_ltst, 4)}
    return None


def _sw_issue(sw: dict, haven: str) -> dict | None:
    """The GO/NO-GO line for the worst predicted arrival."""
    if not sw.get("checked") or sw["level"] == "ok":
        return None
    rank = {"ok": 0, "info": 1, "caution": 2, "nogo": 3}
    a = max(sw["arrivals"], key=lambda x: rank[x["level"]])
    when = datetime.fromisoformat(a["arrival"]).strftime("%b %d %H:%M UTC")
    kind = "glancing CME" if a["glancing"] else "CME"
    if a["overlap"] == "inside":
        text = f"DONKI predicts a {kind} reaching Mars during the EVA ({when})"
    else:
        text = f"A {kind} predicted at Mars on {when} could arrive during the EVA (forecasts miss by up to ±{sw['uncertainty_h']:.0f} h)"
    sug = sw.get("suggested")
    if sug:
        d = sug["delay_h"]
        text += f"; first clear start: sol {sug['mission_sol']} {mars24.hours_to_hms(sug['start_ltst'])[:5]} LTST ({'+' if d >= 0 else ''}{d:.0f} h)"
    else:
        text += "; no clear start in the next six sols"
    if a["level"] != "info":
        text += f". Shelter: {haven}"
    return {"level": a["level"], "text": text, "kind": "space_weather"}



# ------------------------------------------------------------- sunlight, uncertainty, science (data-use item D3/D4/D7)
def _sun_track(s, start: datetime, total_s: float, step_s: float = 60.0):
    """Sun elevation and azimuth at the site centre every step_s seconds from `start` (interpolated per sample)."""
    n = int(total_s // step_s) + 2
    ts = np.arange(n, dtype=float) * step_s
    el = np.empty(n)
    az = np.empty(n)
    for i, t in enumerate(ts):
        e, a, _ = mars24.sun_position(mars24.mars_time(start + timedelta(seconds=float(t))), s.grid.lat0, s.grid.lon0)
        el[i], az[i] = e, a
    return ts, el, az


def _sun_at(track, t):
    ts, el, az = track
    e = np.interp(t, ts, el)
    r = np.radians(az)
    a = np.degrees(np.arctan2(np.interp(t, ts, np.sin(r)), np.interp(t, ts, np.cos(r)))) % 360.0
    return e, a


def _mark_sunlight(s, rows: list[dict], track) -> None:
    """rows[k]["sunlit"]: is the crew in direct sun there (terrain horizon at that 4 m cell)?"""
    if not rows:
        return
    t = np.array([r["t"] for r in rows])
    e, a = _sun_at(track, t)
    lit = s.sunlit(np.array([r["lon"] for r in rows]), np.array([r["lat"] for r in rows]), e, a)
    for r, v, ee in zip(rows, lit, e):
        r["sunlit"] = bool(v)
        r["sun_up"] = bool(ee > -0.25)


def _shade_runs(rows: list[dict], min_s: float = 30.0) -> list[dict]:
    """Stretches of the walk where the sun is up but behind the terrain."""
    runs, cur = [], None
    for r in rows:
        if (not r.get("sunlit", True)) and r.get("sun_up", True):
            if cur is None:
                cur = {"t0": r["t"], "d0": r["d"], "leg": r["leg"]}
            cur["t1"], cur["d1"] = r["t"], r["d"]
        elif cur is not None:
            runs.append(cur)
            cur = None
    if cur is not None:
        runs.append(cur)
    return [{k: round(v, 1) if isinstance(v, float) else v for k, v in {**c, "min": (c["t1"] - c["t0"]) / 60.0}.items()}
            for c in runs if c["t1"] - c["t0"] >= min_s]


def _stop_light(s, lon: float, lat: float, track, t0: float, t1: float) -> dict:
    """The light at a stop: sun height and direction while the crew works there, and whether terrain shades it."""
    ts = np.linspace(t0, t1, 7)
    e, a = _sun_at(track, ts)
    lit = s.sunlit(np.full(7, lon), np.full(7, lat), e, a)
    frac = float(lit.mean())
    lo, hi = float(e.min()), float(e.max())
    if frac == 0.0:
        note = "In terrain shadow the whole stop: even, cold light; use the helmet lights for close-ups"
    elif hi < 20.0:
        note = f"Low sun ({lo:.0f}-{hi:.0f} deg): long shadows bring out texture and relief, good for context photos"
    elif lo > 55.0:
        note = f"High sun ({lo:.0f}-{hi:.0f} deg): flat light and true colours, short shadows"
    else:
        note = f"Sun at {lo:.0f}-{hi:.0f} deg: good general light"
    if 0.0 < frac < 1.0:
        note += f"; in shadow for about {(1 - frac) * (t1 - t0) / 60:.0f} min of it"
    return {"sun_elev": [round(lo, 1), round(hi, 1)], "sun_az": round(float(a[3]), 0), "sunlit_fraction": round(frac, 2), "note": note}


def _sample_steps(events: list[dict], stops: list[dict], req) -> list[tuple[float, float]]:
    """(time, kg): the samples bagged at each stop, added to the load as the crew leaves it (feature C4)."""
    out = []
    for e, st in zip([e for e in events if e["kind"] == "stop"], stops):
        kg = st.get("samples_kg")
        kg = float(req.sample_kg_per_stop if kg is None else kg)
        if kg > 0:
            out.append((float(e["t1"]), kg))
    return out


def _margin_range(s, legs_eval, stops, suit, rv_info, start, req, p, cabin, track) -> dict:
    """The worst return margin again under planning dispersions (eva.DISPERSIONS): slower walking and a higher
    metabolic rate, and the other way round. Walking and walk-back times scale with the speed. A scouted route
    (feature C1) narrows the speed dispersion by req.speed_dispersion_scale."""
    out = {}
    k = float(getattr(req, "speed_dispersion_scale", 1.0))
    for name, d0 in eva.DISPERSIONS.items():
        d = {"met": d0["met"], "speed": 1.0 + (d0["speed"] - 1.0) * k}
        legs2 = []
        for L in legs_eval:
            L2 = dict(L)
            L2["t"] = np.asarray(L["t"], float) / d["speed"]
            L2["walkback_s"] = np.asarray(L["walkback_s"], float) / d["speed"]
            legs2.append(L2)
        rows2, events2, total2 = eva.build_timeline(legs2, stops, suit, rover=rv_info)
        _mark_sunlight(s, rows2, track)
        _, summ = eva.simulate(rows2, events2, total2, suit, start, s.grid.lat0, s.grid.lon0, req.sep_active, p.flat_speed,
                               load_kg=p.load_kg, cabin=cabin, met_scale=d["met"], load_steps=_sample_steps(events2, stops, req))
        out[name] = {"min_margin_min": summ["min_margin_min"], "limiting": summ["limiting"], "total_s": round(total2, 1),
                     "met_scale": d["met"], "speed_scale": d["speed"]}
    return out


def _route_confidence(s, rows: list[dict]) -> dict:
    """How much of the route stands on uncertain data: terrain where the two DTMs disagree, sand the clues can't settle."""
    if not rows:
        return {}
    lon = np.array([r["lon"] for r in rows])
    lat = np.array([r["lat"] for r in rows])
    d = np.array([r["d"] for r in rows])
    seg = np.clip(np.diff(d, prepend=d[0]), 0.0, None)
    r2, c2 = s.grid2.lonlat_to_rowcol(lon, lat)
    ri = np.clip(np.rint(r2).astype(int), 0, s.grid2.height - 1)
    ci = np.clip(np.rint(c2).astype(int), 0, s.grid2.width - 1)
    out: dict = {}
    if s.terrain_conf2 is not None:
        tc = s.terrain_conf2[ri, ci].astype(float)
        su = s.slope_unc2[ri, ci].astype(float)
        known = np.isfinite(tc)
        out["terrain_low_m"] = round(float(seg[known & (tc < 0.5)].sum()))
        out["terrain_unknown_m"] = round(float(seg[~known].sum()))
        out["terrain_mean"] = round(float(np.nanmean(tc)), 2) if known.any() else None
        out["slope_unc_p95_deg"] = round(float(np.nanpercentile(su, 95)), 1) if np.isfinite(su).any() else None
        for r, v in zip(rows, tc):
            r["terrain_conf"] = float(v) if np.isfinite(v) else None
    if s.sand_conf2 is not None:
        sc = s.sand_conf2[ri, ci].astype(float)
        sd = np.array([r["sand"] for r in rows])
        out["sand_unsure_m"] = round(float(seg[(sc < 0.3) & (sd >= 0.3)].sum()))
        out["sand_conf_mean"] = round(float(np.mean(sc)), 2)
        for r, v in zip(rows, sc):
            r["sand_conf"] = float(v)
    return out


KIND_LABEL = {"mineral": "outcrop", "contact": "contact", "ridge": "ridge", "hollow": "hollow", "sample": "outcrop", "track": "outcrop"}
STOP_TASKS = {
    "ridge": ["Hammer sample of the ridge crest", "Close-up imaging of the ridge wall and any veins", "Measure the ridge height and strike"],
    "hollow": ["Scoop the hollow fill", "Trench 10 cm to look for layering", "Panorama of the surrounding ridges"],
    "contact": ["Sample both units either side of the contact", "Photograph the contact at close range", "Note the contact's orientation"],
    "outcrop": ["Sample the outcrop where the CRISM signal is strongest", "Close-up imaging for texture, veins and layering", "Contingency sample"],
}
STOP_DWELL = {"ridge": 30, "hollow": 20, "contact": 30, "outcrop": 25}


def _nearest_feature(path: Path, grid, lon: float, lat: float):
    if not path.exists():
        return None, None
    fc = json.loads(path.read_text(encoding="utf-8"))
    best, best_d = None, 1e18
    x0, y0 = grid.lonlat_to_xy(lon, lat)
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") != "Point":
            continue
        x, y = grid.lonlat_to_xy(*g["coordinates"][:2])
        dd = float(math.hypot(float(x) - float(x0), float(y) - float(y0)))
        if dd < best_d:
            best, best_d = f.get("properties") or {}, dd
    return best, best_d


def _science_at(s, lon: float, lat: float, radius_px: int = 3) -> dict | None:
    """Science score at a point and its reasons, from the parts of pipeline/science.py (strongest within ~14 m)."""
    sc = s.science
    if not sc:
        return None
    r, c = (int(round(float(v))) for v in s.grid2.lonlat_to_rowcol(lon, lat))
    H, W = sc["score"].shape
    if not (0 <= r < H and 0 <= c < W):
        return None
    r0, r1, c0, c1 = max(0, r - radius_px), min(H, r + radius_px + 1), max(0, c - radius_px), min(W, c + radius_px + 1)

    def win(k):
        return sc[k][r0:r1, c0:c1]
    reasons = []
    m = float(np.max(win("mineral")))
    if m >= 0.3:
        vals = win("mineral")
        idx = np.unravel_index(int(np.argmax(vals)), vals.shape)
        ki = int(win("mineral_kind")[idx])
        if ki != 255:
            kind = scilib.KINDS[ki]
            cm = s.crism.get(kind, {})
            name = cm.get("meta", {}).get("name", f"CRISM {kind.upper()}")
            band = None
            rgba, bands = cm.get("rgba"), cm.get("meta", {}).get("bands", [])
            if rgba is not None and bands:
                px = rgba[min((r0 + idx[0]) // 2, rgba.shape[0] - 1), min((c0 + idx[1]) // 2, rgba.shape[1] - 1)]
                band = bands[int(np.argmax(px[:3]))]
            reasons.append({"kind": "mineral", "strength": round(m, 2), "text": f"{name}: strong signal" + (f" ({band})" if band else "")})
    ct = float(np.max(win("contact")))
    if ct >= 0.4 and s.geology2 is not None:
        units = s.geology_meta.get("units", [])
        here = int(s.geology2[r, c])
        rad = int(3 * scilib.CONTACT_M / s.grid2.res)
        ra, rb, ca, cb = max(0, r - rad), min(H, r + rad + 1), max(0, c - rad), min(W, c + rad + 1)
        g = s.geology2[ra:rb, ca:cb]
        mask = (g > 0) & (g != here)
        if mask.any() and 0 < here <= len(units):
            o = int(np.bincount(g[mask]).argmax())
            yy, xx = np.nonzero(g == o)
            dist = float(np.min(np.hypot(yy + ra - r, xx + ca - c))) * s.grid2.res
            a, b = units[here - 1], units[o - 1]
            reasons.append({"kind": "contact", "strength": round(ct, 2), "units": [a["code"], b["code"]],
                            "text": f"Contact between {a['code']} ({a['name']}) and {b['code']} ({b['name']}), "
                                    + ("here" if dist < 10 else f"{dist:.0f} m away")})
    rl = float(np.max(win("relief")))
    if rl >= 0.4:
        tpi = float(s.tpi2[r, c])
        sign = 1 if tpi >= 0 else -1
        reasons.append({"kind": "ridge" if sign > 0 else "hollow", "strength": round(rl, 2),
                        "text": (f"Ridge crest {tpi:.1f} m above its surroundings" if sign > 0
                                 else f"Hollow floor {-tpi:.1f} m below its surroundings")})
    sp = float(np.max(win("sample")))
    if sp >= 0.3:
        f, dist = _nearest_feature(s.dir / "extra_samples.geojson", s.grid, lon, lat)
        if f:
            nm = f.get("sample_name") or f.get("outcrop_name") or "a sample"
            where = "here" if dist < 10 else f"{dist:.0f} m away"
            reasons.append({"kind": "sample", "strength": round(sp, 2),
                            "text": f"{s.cfg.get('rover_name', 'The rover')} cored {nm} (sample {f.get('sample_num', '?')}) {where}: compare"})
    tk = float(np.max(win("track")))
    if tk >= 0.4:
        reasons.append({"kind": "track", "strength": round(tk, 2), "text": f"On {s.cfg.get('rover_name', 'the rover')}'s track: its close-up images exist for comparison"})
    reasons.sort(key=lambda x: -x["strength"])
    return {"score": round(float(np.max(win("score"))), 2), "reasons": reasons, "sand": round(float(s.sand2[r, c]), 2)}


@app.post("/api/sites/{site_id}/plan")
def plan(site_id: str, req: PlanRequest):
    t_start = time.perf_counter()
    s = _site(site_id)
    p = _walk(req.walk)
    suit = eva.SuitParams.from_dict(req.suit)
    mult = s.multiplier(p)
    hz = s.hazard(p)
    hab = req.habitat.model_dump()
    stops = [st.model_dump() for st in req.stops]
    # Rover-assisted: PR-2 parks at a drop-off; the walking loop starts and ends there and the parked
    # rover is the safe haven for the walk-back rule (and one more radio node).
    drop, dp = None, None
    if req.rover.enabled and stops:
        dp = _drive(req.rover.drive)
        if req.rover.dropoff is not None:
            drop = {**req.rover.dropoff.model_dump(), "auto": False}
        else:
            drop = pr.choose_dropoff(s, hab, stops, p, dp)
            if drop is None:
                raise HTTPException(409, f"{pr.NAME} cannot reach a level parking spot near the stops with its limits "
                                         f"(max slope {dp.max_slope:g} deg). Place the drop-off by hand or turn the rover off.")
    base = {"lon": drop["lon"], "lat": drop["lat"]} if drop else hab
    base_name = pr.NAME if drop else "Hab"
    returning = req.return_to_habitat or drop is not None
    pts = [base] + stops + ([base] if returning else [])
    if len(pts) < 2:
        raise HTTPException(422, "Add at least one stop")
    wbk = s.walkback((base["lon"], base["lat"]), p)
    observers = [(hab["lon"], hab["lat"], req.radio.habitat_mast_m)] + [(r.lon, r.lat, r.height_m) for r in req.radio.relays]
    if drop:
        observers.append((base["lon"], base["lat"], req.rover.antenna_m))
    com = s.comms(observers, req.radio.suit_antenna_m)

    legs_out, legs_eval = [], []
    names = [base_name] + [st.name for st in req.stops] + ([base_name] if returning else [])
    for i, (a, b) in enumerate(zip(pts[:-1], pts[1:])):
        res = _route(s, a, b, p, req.algorithm, req.astar_weight)
        if not res.cells:
            raise HTTPException(409, f"No safe route from {names[i]} to {names[i + 1]} with the current limits "
                                     f"(max slope {p.max_slope:g} deg). Move the stop or relax the limits.")
        ev = _leg_arrays(s, res, p, mult, hz, com["grid"], wbk["field"])
        ev["label"] = f"{names[i]} → {names[i + 1]}"
        legs_eval.append(ev)
        keep = simplify_cells(res.cells)
        ll = ev["lonlat"][keep]
        legs_out.append({
            "from": names[i], "to": names[i + 1], "engine": res.engine,
            "compute_ms": round(res.compute_ms, 1), "expansions": res.expansions,
            "dist_m": round(float(ev["d"][-1]), 1), "time_s": round(float(ev["t"][-1]), 1),
            "ascent_m": round(float(np.clip(ev["dz"], 0, None).sum()), 1),
            "descent_m": round(float(-np.clip(ev["dz"], None, 0).sum()), 1),
            "max_slope": round(float(ev["slope"].max()), 1),
            "bearing_deg": round(_bearing(pts[i], pts[i + 1]), 1),
            "path": [[round(float(a_), 7), round(float(b_), 7)] for a_, b_ in ll],
            "warnings": res.warnings,
        })

    drive_legs, drive_evals, rv_info, cabin = [], [], None, None
    if drop:
        drive_legs, drive_evals = _drive_legs(s, hab, base, dp, req.astar_weight)
        rv_info = {"name": pr.NAME, "suitport_min": req.rover.suitport_min,
                   "out_s": float(drive_evals[0]["t"][-1]), "out_m": float(drive_evals[0]["d"][-1]),
                   "back_s": float(drive_evals[1]["t"][-1]), "back_m": float(drive_evals[1]["d"][-1])}
        r4, c4 = s.grid4.lonlat_to_rowcol(base["lon"], base["lat"])
        sh = float(np.asarray(sample_bilinear(s.shield4, np.array([r4]), np.array([c4]))).ravel()[0])
        cabin = {"met_w": pr.CABIN_MET_W, "gcr_factor": pr.CABIN_GCR_FACTOR, "sep_factor": pr.CABIN_SEP_FACTOR,
                 "shield": sh if math.isfinite(sh) else 0.0}
    rows, events, total_s = eva.build_timeline(legs_eval, stops, suit, rover=rv_info)
    start = _parse_utc(req.start_utc) if req.start_utc else _default_start(s.grid.lon0)
    lat0, lon0 = s.grid.lat0, s.grid.lon0
    track = _sun_track(s, start, total_s * 1.4)  # long enough for the slow-walking dispersion too
    _mark_sunlight(s, rows, track)
    route_conf = _route_confidence(s, rows)
    load_steps = _sample_steps(events, stops, req)
    rock_cost = []
    with climate.calibrated(_climate_cal(s)), _site_climate(s):
        sim, summary = eva.simulate(rows, events, total_s, suit, start, lat0, lon0, req.sep_active, p.flat_speed,
                                    load_kg=p.load_kg, cabin=cabin, load_steps=load_steps)
        margins = _margin_range(s, legs_eval, stops, suit, rv_info, start, req, p, cabin, track)
        # the cost of a rock (feature C4): the margin each stop's samples take, by planning without them
        stop_evs = [e for e in events if e["kind"] == "stop"]
        for e, st in zip(stop_evs, stops):
            mine = [x for x in load_steps if abs(x[0] - float(e["t1"])) < 1e-6]
            if not mine:
                continue
            others = [x for x in load_steps if abs(x[0] - float(e["t1"])) >= 1e-6]
            _, s2 = eva.simulate(rows, events, total_s, suit, start, lat0, lon0, req.sep_active, p.flat_speed,
                                 load_kg=p.load_kg, cabin=cabin, load_steps=others)
            rock_cost.append({"stop": st.get("name"), "id": st.get("id"), "kg": mine[0][1],
                              "margin_cost_min": round(s2["min_margin_min"] - summary["min_margin_min"], 2),
                              "carried_min": round((total_s - float(e["t1"])) / 60.0, 1)})

    mt0 = mars24.mars_time(start)
    rise_set = mars24.sunrise_sunset_ltst(mt0, lat0)
    # sunset over the real terrain where the EVA ends: the hab, or PR-2 parked at its drop-off
    sun_haven = s.sun_times(base["lon"], base["lat"], start)
    sunset_t = None
    if sun_haven.get("sunset_utc"):
        sunset_t = (datetime.fromisoformat(sun_haven["sunset_utc"]) - start).total_seconds()
    elif rise_set:
        sunset_t = (mars24.utc_for_ltst(start, lon0, rise_set[1]) - start).total_seconds()
    if sunset_t is not None and sunset_t < 0:
        sunset_t += mars24.MARS_SOL_DAYS * 86400
    haven = f"the rover ({pr.NAME})" if drop else "the hab"
    go, issues = eva.go_no_go(summary, sim, events, rows, sunset_t, p, haven=haven)
    for L in drive_legs:
        for w in L["warnings"]:
            issues.insert(0, {"level": "caution", "text": f"{pr.NAME}: {w}"})
    extra = []
    pess = margins.get("pessimistic", {})
    if pess and pess["min_margin_min"] < 0 <= summary["min_margin_min"]:
        extra.append({"level": "caution", "kind": "uncertainty",
                      "text": f"With a 20 % higher metabolic rate and 12 % slower walking the {pess['limiting']} margin runs out "
                              f"({pess['min_margin_min']:.0f} min): the plan has little room for a bad day"})
    if summary.get("shade_min", 0) >= 10:
        extra.append({"level": "info", "kind": "sun",
                      "text": f"{summary['shade_min']:.0f} min in terrain shadow while the sun is up: the suit heater adds "
                              f"{summary.get('shade_heater_wh', 0):.0f} Wh"})
    dist_total = sum(L["dist_m"] for L in legs_out)
    if route_conf.get("terrain_low_m", 0) > 0.15 * dist_total:
        extra.append({"level": "info", "kind": "uncertainty",
                      "text": f"{route_conf['terrain_low_m']:.0f} m of the route crosses terrain where our DTM and the rover team's "
                              f"disagree (slopes uncertain by up to {route_conf.get('slope_unc_p95_deg') or 0:.0f} deg): check those stretches in the images"})
    if extra:
        issues = [i for i in issues if i["level"] != "ok"] + extra
    sw = _space_weather(s, req, start, events, total_s, haven=(base["lon"], base["lat"]))
    sw_issue = _sw_issue(sw, haven)
    if sw_issue:
        issues = [i for i in issues if i["level"] != "ok"]
        issues.insert(0, sw_issue)
        if sw_issue["level"] == "nogo":
            go = False
    eg, ig = eva.suited_window(events)
    glare_chk = glarelib.check(start, lat0, lon0, legs_out, events)  # sun in your eyes (feature B5)
    gi = glarelib.issue(glare_chk, legs_out)
    if gi:
        issues = [i for i in issues if i["level"] != "ok"] + [gi]
    pace_notes = pacelib.for_plan(s, rows, legs_out)  # pace notes and the strip map (feature D3)

    for e in events:
        for k in ("t0", "t1"):
            when = start + timedelta(seconds=e[k])
            e[k + "_utc"] = when.isoformat()
            e[k + "_ltst"] = round(mars24.local_true_solar_time(mars24.mars_time(when), lon0), 4)
    for e, st in zip([e for e in events if e["kind"] == "stop"], stops):
        e["light"] = _stop_light(s, st["lon"], st["lat"], track, e["t0"], e["t1"])
        sci = _science_at(s, st["lon"], st["lat"])
        if sci:
            e["science"] = sci
        sc = s.scouted_at(st["lon"], st["lat"])
        if sc:
            e["scouted"] = sc

    # decimated profile for charts and the 3D walk
    step = max(1, len(rows) // 1800)
    prof_rows = rows[::step] + ([rows[-1]] if (len(rows) - 1) % step else [])
    profile = {k: [] for k in ("d", "t", "z", "slope", "grade", "lon", "lat", "hazard", "comms", "walkback_min", "shield", "sand", "leg", "working",
                               "sunlit", "terrain_conf", "sand_conf")}
    for r in prof_rows:
        profile["d"].append(round(r["d"], 1))
        profile["t"].append(round(r["t"], 1))
        profile["z"].append(round(r["z"], 2))
        profile["slope"].append(round(r["slope"], 1))
        profile["grade"].append(round(r["grade"], 3))
        profile["lon"].append(round(r["lon"], 7))
        profile["lat"].append(round(r["lat"], 7))
        profile["hazard"].append(r["hazard"])
        profile["comms"].append(r["comms"])
        profile["walkback_min"].append(round(r["walkback_s"] / 60, 1) if math.isfinite(r["walkback_s"]) else None)
        profile["shield"].append(round(r["shield"], 4))
        profile["sand"].append(round(r["sand"], 3))
        profile["leg"].append(r["leg"])
        profile["working"].append(r["working"])
        profile["sunlit"].append(1 if r.get("sunlit", True) else 0)
        tc = r.get("terrain_conf")
        profile["terrain_conf"].append(round(tc, 2) if tc is not None else None)
        profile["sand_conf"].append(round(r.get("sand_conf", 1.0), 2))

    walk_s = sum(L["time_s"] for L in legs_out)
    totals = {
        "dist_m": round(sum(L["dist_m"] for L in legs_out), 1),
        "walk_s": round(walk_s, 1),
        "stop_s": round(sum(e["t1"] - e["t0"] for e in events if e["kind"] == "stop"), 1),
        "total_s": round(total_s, 1),
        "ascent_m": round(sum(L["ascent_m"] for L in legs_out), 1),
        "descent_m": round(sum(L["descent_m"] for L in legs_out), 1),
        "max_slope": max(L["max_slope"] for L in legs_out),
        "max_walkback_min": round(max((v for v in profile["walkback_min"] if v is not None), default=0), 1),
        "comms_dead_fraction": round(sum(1 for r in rows if r["comms"] == 0) / max(1, len(rows)), 3),
        "dose_usv": summary["dose_usv"],
        "min_margin_min": summary["min_margin_min"],
        "min_margin_t": summary["min_margin_t"],
        "limiting": summary["limiting"],
        "max_ppco2_mmhg": summary.get("max_ppco2_mmhg", 0.0),
        "suit_p_kpa": eva.SUIT_P_KPA,
        "ppco2_limits_mmhg": {"caution": eva.PPCO2_CAUTION, "warning": eva.PPCO2_WARNING, "limit": eva.PPCO2_LIMIT},
        "start_utc": start.isoformat(),
        "end_utc": (start + timedelta(seconds=total_s)).isoformat(),
        "start_ltst": round(mars24.local_true_solar_time(mt0, lon0), 4),
        "sunset_t": sunset_t,
        "sunrise_ltst": rise_set[0] if rise_set else None, "sunset_ltst": rise_set[1] if rise_set else None,
        "go": go,
        "compute_ms": round((time.perf_counter() - t_start) * 1000, 1),
        "mission_sol": mars24.mission_sol(mt0, lon0, s.cfg["rover"].get("landing_msd_local", 0)),
        "algorithm": req.algorithm,
        "rover": drop is not None,
        "drive_m": round(sum(L["dist_m"] for L in drive_legs), 1),
        "drive_s": round(sum(L["time_s"] for L in drive_legs), 1),
        "suit_s": round(ig["t1"] - eg["t0"], 1),
        "sun_horizon": "terrain" if sun_haven.get("sunset_utc") and s.horizon is not None else "flat",
        "terrain_sunrise_ltst": sun_haven.get("sunrise_ltst"), "terrain_sunset_ltst": sun_haven.get("sunset_ltst"),
        "shade_min": summary.get("shade_min", 0.0), "shade_heater_wh": summary.get("shade_heater_wh", 0.0),
        "margin_range_min": [margins["pessimistic"]["min_margin_min"], margins["optimistic"]["min_margin_min"]] if margins else None,
        "margin_cases": margins,
        "route_confidence": route_conf,
    }
    rover_out = {"enabled": False, "name": pr.NAME}
    if drop:
        rover_out = {"enabled": True, "name": pr.NAME, "dropoff": drop, "legs": drive_legs,
                     "track": pr.track(drive_evals, [events[0]["t0"], events[-1]["t0"]]),
                     "drive": dp.to_dict(), "limits": dp.limits(), "suitport_min": req.rover.suitport_min,
                     "antenna_m": req.rover.antenna_m,
                     "cabin": {k: v for k, v in cabin.items() if k != "shield"}}
    return {"legs": legs_out, "events": events, "profile": profile, "sim": sim, "totals": totals, "issues": issues,
            "walk": p.to_dict(), "suit": suit.to_dict(), "rings": wbk["rings"],
            "comms": {k: v for k, v in com.items() if k != "grid"}, "rover": rover_out, "space_weather": sw,
            "sun": {"haven": sun_haven, "haven_name": pr.NAME if drop else "Hab", "shade": _shade_runs(rows)},
            "glare": glare_chk, "pace_notes": pace_notes,
            "samples": {"per_stop": rock_cost, "kg_per_stop": req.sample_kg_per_stop,
                        "total_kg": round(sum(x[1] for x in load_steps), 2)},
            "tags": s.tags}


def _drive_legs(s, hab: dict, drop: dict, dp: "pr.DriveParams", weight: float):
    """PR-2's drive out to the drop-off and back, routed with the rover's own limits."""
    mult_d = s.multiplier(dp)
    legs, evals = [], []
    for a, b, na, nb in ((hab, drop, "Hab", f"{pr.NAME} drop-off"), (drop, hab, f"{pr.NAME} drop-off", "Hab")):
        res = _route(s, a, b, dp, "astar", max(1.0, weight))
        if not res.cells:
            raise HTTPException(409, f"{pr.NAME} has no safe drive from {na} to {nb} (max slope {dp.max_slope:g} deg, "
                                     f"boulders over {dp.BOULDER_MAX:g} m). Move the drop-off or turn the rover off.")
        ev = evaluate_cells(res.cells, s.z2, s.slope2, mult_d, s.grid2.res, dp)
        rc = np.asarray(res.cells, dtype=float)
        lon, lat = s.grid2.rowcol_to_lonlat(rc[:, 0], rc[:, 1])
        ev["lonlat"] = np.column_stack([lon, lat])
        evals.append(ev)
        keep = simplify_cells(res.cells)
        ll = ev["lonlat"][keep]
        warn = [w.replace("A stop sits on no-go terrain; the route ends at the nearest safe spot",
                          f"{nb} is not drivable; the drive ends at the nearest drivable spot") for w in res.warnings]
        legs.append({
            "from": na, "to": nb, "engine": res.engine, "mode": "drive",
            "compute_ms": round(res.compute_ms, 1), "expansions": res.expansions,
            "dist_m": round(float(ev["d"][-1]), 1), "time_s": round(float(ev["t"][-1]), 1),
            "ascent_m": round(float(np.clip(ev["dz"], 0, None).sum()), 1),
            "descent_m": round(float(-np.clip(ev["dz"], None, 0).sum()), 1),
            "max_slope": round(float(ev["slope"].max()), 1),
            "bearing_deg": round(_bearing(a, b), 1),
            "path": [[round(float(a_), 7), round(float(b_), 7)] for a_, b_ in ll],
            "warnings": warn,
        })
    return legs, evals


@app.post("/api/sites/{site_id}/traverse-sheet", response_class=HTMLResponse)
def traverse_sheet_html(site_id: str, req: PlanRequest):
    """Printable Apollo-style traverse sheet (photomap + stations + timeline) for this plan."""
    from types import SimpleNamespace
    s = _site(site_id)
    p = plan(site_id, req)
    known = {str(st.get("id")): st for st in s.cfg.get("stops", [])}
    stops = [{**known.get(str(st.id), {}), **st.model_dump()} for st in req.stops]
    cfg = {**s.cfg, "stops": stops, "habitat": {**s.cfg.get("habitat", {}), **req.habitat.model_dump()}}
    view = SimpleNamespace(cfg=cfg, grid=s.grid, dir=s.dir)
    return HTMLResponse(traverse_sheet.render_html(view, p, p.get("walk")))


def _bearing(a: dict, b: dict) -> float:
    lat1, lat2 = math.radians(a["lat"]), math.radians(b["lat"])
    dlon = math.radians(b["lon"] - a["lon"])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return math.degrees(math.atan2(y, x)) % 360


# ------------------------------------------------------------- ways home (feature A1)
FLOW_TILE_K = 3  # map tiles sample a picture drawn at 3 px per 4 m cell (1.3 m pixels)
WALK_Q = ("flat_speed", "max_slope", "caution_slope", "max_rough", "sand_penalty", "hazard_aversion", "load_kg")


def _havens(s, havens: str | None, hab_lon: float | None = None, hab_lat: float | None = None) -> list[dict]:
    """Havens from 'lon,lat,name;...', else the hab (from hab_lon/hab_lat, else the site config)."""
    if hab_lon is not None and hab_lat is not None:
        default = [{"lon": float(hab_lon), "lat": float(hab_lat), "name": "Hab"}]
    else:
        default = [s.habitat_haven()]
    return flowlib.parse_havens(havens, default)


def _flow_tile_source(tree):
    """The network drawn once at FLOW_TILE_K px per cell, with the grid that places it (tiles sample it)."""
    with tree.lock:
        hit = getattr(tree, "_tile_src", None)
        if hit is None:
            H, W = tree.shape
            k = FLOW_TILE_K
            img = tree.render(wh=(W * k, H * k))
            g4 = tree.grid
            hit = (np.asarray(img), SiteGrid(g4.lon0, g4.lat0, g4.x_min, g4.y_max, g4.res / k, W * k, H * k))
            tree._tile_src = hit
    return hit


@app.get("/api/sites/{site_id}/ways-home")
def ways_home(site_id: str, havens: str | None = None, hab_lon: float | None = None, hab_lat: float | None = None,
              min_acc: int = Query(0, ge=0), n_gateways: int = Query(6, ge=0, le=12), gateway_frac: float = Query(0.05, gt=0, le=0.5),
              flat_speed: float | None = None, max_slope: float | None = None, caution_slope: float | None = None,
              max_rough: float | None = None, sand_penalty: float | None = None, hazard_aversion: float | None = None,
              load_kg: float | None = None):
    """The ways-home network: its trunks as streams (for the animated layer), the gateways, the basins per haven."""
    s = _site(site_id)
    p = _walk_from_query(dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
                              sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg))
    tree = s.flow(_havens(s, havens, hab_lon, hab_lat), p)
    min_acc = min_acc or max(40, int(0.0015 * tree.n_reach))
    return {"havens": tree.havens, "gateways": tree.gateways(n=n_gateways, min_frac=gateway_frac), "basins": tree.basins(),
            **tree.stats(), **tree.streams_json(min_acc)}


@app.get("/api/sites/{site_id}/ways-home/path")
def ways_home_path(site_id: str, lon: float, lat: float, havens: str | None = None, hab_lon: float | None = None,
                   hab_lat: float | None = None, flat_speed: float | None = None, max_slope: float | None = None,
                   caution_slope: float | None = None, max_rough: float | None = None, sand_penalty: float | None = None,
                   hazard_aversion: float | None = None, load_kg: float | None = None):
    """Lost? Walk downstream: the fastest way home from a point, following the ways-home tree to the nearest haven."""
    s = _site(site_id)
    p = _walk_from_query(dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
                              sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg))
    return s.flow(_havens(s, havens, hab_lon, hab_lat), p).path_home(lon, lat)


# ------------------------------------------------------------- skyline fix (feature B1)
class SkylineFixRequest(BaseModel):
    """Simulate the helmet's skyline at a true position and fix the position from it."""
    lon: float
    lat: float
    noise_deg: float = Field(0.5, ge=0, le=5)
    heading_err_deg: float = Field(4.0, ge=-180, le=180)
    heading_known: bool = True
    prior_m: float | None = Field(None, ge=10, le=5000)  # dead-reckoning uncertainty (1 sigma) around the true point
    seed: int | None = None


def _skyline(s):
    if s.skyline is None:
        raise HTTPException(404, "This site has no stored horizon (sky-view step not built)")
    return s.skyline


@app.get("/api/sites/{site_id}/skyline/profile")
def skyline_profile(site_id: str, lon: float, lat: float):
    """The stored skyline at a point (horizon elevation every 15 deg) and the named features on it."""
    s = _site(site_id)
    idx = _skyline(s)
    r, c = (int(round(float(v))) for v in s.grid4.lonlat_to_rowcol(lon, lat))
    if not (0 <= r < idx.shape[0] and 0 <= c < idx.shape[1]):
        raise HTTPException(422, "outside the site")
    p = idx.profile(r, c)
    return {"az": [round(k * 360.0 / idx.n_az, 1) for k in range(idx.n_az)], "elev": [round(float(v), 2) for v in p],
            "features": skylib.features(s, lon, lat)}


@app.post("/api/sites/{site_id}/skyline/fix")
def skyline_fix(site_id: str, req: SkylineFixRequest):
    """Where am I? The helmet's skyline at the true point (simulated: stored skyline + noise + heading error) matched
    against every 4 m cell. Returns the fix, its 95 % circle, the error against the truth and a likelihood picture."""
    import base64
    s = _site(site_id)
    idx = _skyline(s)
    r, c = (int(round(float(v))) for v in s.grid4.lonlat_to_rowcol(req.lon, req.lat))
    if not (0 <= r < idx.shape[0] and 0 <= c < idx.shape[1]):
        raise HTTPException(422, "outside the site")
    rng = np.random.default_rng(req.seed)
    obs = idx.observe(r, c, req.noise_deg, req.heading_err_deg, rng)
    prior = None
    if req.prior_m:
        pr, pc = r + rng.normal(0, req.prior_m / idx.grid.res), c + rng.normal(0, req.prior_m / idx.grid.res)
        prior = (pr, pc, float(req.prior_m))
    fx = idx.locate(obs, heading_known=req.heading_known, heading_tol_deg=abs(req.heading_err_deg) + 6.0, prior=prior)
    err = math.hypot(fx["row"] - r, fx["col"] - c) * idx.grid.res
    png = idx.likelihood_png(obs, heading_known=req.heading_known)
    b0 = s.grid4.bounds_lonlat()
    return {"truth": {"lon": req.lon, "lat": req.lat}, "fix": fx, "error_m": round(err, 1),
            "observed": [round(float(v), 2) for v in obs], "stored_at_fix": [round(float(v), 2) for v in idx.profile(fx["row"], fx["col"])],
            "az": [round(k * 360.0 / idx.n_az, 1) for k in range(idx.n_az)], "features": skylib.features(s, req.lon, req.lat),
            "likelihood_png": "data:image/png;base64," + base64.b64encode(png).decode(),
            "bounds": [[b0[1], b0[0]], [b0[3], b0[2]]]}


_skyline_checks: dict = {}


@app.get("/api/sites/{site_id}/skyline/check")
def skyline_check(site_id: str, n: int = Query(200, ge=20, le=1000), noise_deg: float = Query(0.5, ge=0, le=3),
                  heading_known: bool = True):
    """feature B1 acceptance check: the median fix error over n random walkable cells, with noise and a heading error."""
    s = _site(site_id)
    key = (site_id, n, noise_deg, heading_known)
    if key not in _skyline_checks:
        hab = s.habitat_haven()
        walk = np.isfinite(s.walkback((hab["lon"], hab["lat"]), WalkParams())["field"])
        _skyline_checks[key] = skylib.evaluate(_skyline(s), n=n, noise_deg=noise_deg, heading_known=heading_known, walkable=walk)
    return _skyline_checks[key]


# ------------------------------------------------------------- flood the crater (A4)
@app.get("/api/sites/{site_id}/lake")
def lake(site_id: str, level: float, points: str | None = None):
    """The ancient lake at `level` m: share of the site under water and the depth over the hab, the stops or any
    'lon,lat,name;...' points."""
    s = _site(site_id)
    pts = flowlib.parse_havens(points, []) if points else []
    if not pts:
        h = s.cfg.get("habitat") or {}
        pts = ([{"lon": h["lon"], "lat": h["lat"], "name": "Hab"}] if h else []) + \
              [{"lon": st["lon"], "lat": st["lat"], "name": st["name"]} for st in s.cfg.get("stops", [])]
    lk = s.cfg.get("lake") or {}
    return {**lakelib.stats(s, level, pts), "levels": lk.get("levels", []), "source": lk.get("source"), "note": lk.get("note")}


# ------------------------------------------------------------- the interplanetary map (A5) and Ask Earth (D2)
def _donki_sims() -> list:
    """The WSA-ENLIL simulations of the last month (spaceweather's disk cache; [] offline)."""
    try:
        files = sorted(spaceweather.CACHE.glob("WSAEnlilSimulations_*.json"), key=lambda f: f.stat().st_mtime)
        return json.loads(files[-1].read_text()) if files else []
    except Exception:
        return []


@app.get("/api/orrery")
def orrery(utc: str | None = None):
    """Sun, Earth and Mars now, the light time between them (and over two years), and the recent DONKI CMEs as cones."""
    # the CME list comes from the DONKI cache that /api/spaceweather keeps fresh (never wait on the network here)
    return orrerylib.snapshot(_parse_utc(utc), _donki_sims())


@app.get("/api/ask-earth")
def ask_earth(utc: str | None = None, think_min: float = Query(10.0, ge=0, le=240)):
    """When an answer from Earth can arrive: there and back at the speed of light, plus thinking time."""
    return orrerylib.ask_earth(_parse_utc(utc), think_min)


# ------------------------------------------------------------- habitat and suit, live (D1)
@app.websocket("/ws/live/{site_id}")
async def live_ws(ws: WebSocket, site_id: str):
    await ws.accept()
    h = livelib.hub(site_id)
    role = "console"
    try:
        hello = json.loads(await ws.receive_text())
        role = "helmet" if hello.get("role") == "helmet" else "console"
        h.clients[ws] = role
        await ws.send_text(json.dumps({"type": "welcome", "role": role, "status": {k: v for k, v in h.status().items() if k != "last"},
                                       "last": h.last if role == "console" else None,
                                       "history": list(h.history)[-240:] if role == "console" else [],
                                       "light_time_s": round(orrerylib.light_time_s(datetime.now(timezone.utc)), 1)}))
        await h.send_to("console", {"type": "presence", "clients": h.roles()})
        while True:
            msg = json.loads(await ws.receive_text())
            if role == "helmet" and msg.get("type") == "telemetry":
                await h.telemetry(livelib.clean_telemetry(msg))
            elif role == "console":
                cmd = livelib.clean_command(msg)
                if cmd:
                    await h.command(cmd)
    except (WebSocketDisconnect, ValueError, RuntimeError):
        pass
    finally:
        h.clients.pop(ws, None)
        try:
            await h.send_to("console", {"type": "presence", "clients": h.roles()})
        except Exception:
            pass


@app.get("/api/live/{site_id}")
def live_status(site_id: str):
    """The live link without WebSockets: who is connected and the latest telemetry."""
    return livelib.hub(site_id).status()


@app.post("/api/live/{site_id}/telemetry")
async def live_telemetry(site_id: str, msg: dict):
    await livelib.hub(site_id).telemetry(livelib.clean_telemetry(msg))
    return {"ok": True}


@app.post("/api/live/{site_id}/command")
async def live_command(site_id: str, msg: dict):
    cmd = livelib.clean_command(msg)
    if not cmd:
        raise HTTPException(422, "type: waypoint {lon, lat, name} | message {text} | clear_waypoint")
    return await livelib.hub(site_id).command(cmd)


@app.get("/api/live/{site_id}/inbox")
def live_inbox(site_id: str, after: int = 0):
    """Commands for a helmet that polls instead of holding a WebSocket."""
    return {"items": [m for m in livelib.hub(site_id).inbox if m["id"] > after]}


# ------------------------------------------------------------- shrinking world, partner down, caches (A3, B3, B4)
def _minutes_at_egress(suit, p: WalkParams) -> float:
    """Minutes of the limiting consumable at the brisk return-walk rate with full tanks (eva.simulate's rule)."""
    ret_met = 420.0 * (1.0 + p.load_kg / 145.0)
    o2 = suit.o2_kg * 1000.0 / (ret_met * eva.O2_G_PER_WH + suit.o2_leak_g_h) * 60.0
    co2 = suit.co2_capacity_g / (ret_met * eva.O2_G_PER_WH / 32.0 * eva.RQ * 44.0) * 60.0
    water = suit.water_kg / (0.32 * ret_met / 300.0) * 60.0
    batt = suit.battery_wh / (suit.base_load_w + 12.0) * 60.0
    return float(min(o2, co2, water, batt))


def _rescue_field(s, havens, p, rover_lon=None, rover_lat=None):
    key = f"rescue|{flowlib.havens_key(havens)}|{p.key()}|{rover_lon},{rover_lat}"

    def build():
        base = {"lon": float(rover_lon), "lat": float(rover_lat)} if rover_lon is not None and rover_lat is not None else None
        res = envlib.rescue(s, havens, p, base, pr.DriveParams() if base else None)
        res["_rgba"] = np.asarray(envlib.rescue_rgba(res))
        return res
    return s.fields.get(key, build)


@app.get("/api/sites/{site_id}/envelope")
def envelope(site_id: str, lon: float, lat: float, havens: str | None = None, hab_lon: float | None = None,
             hab_lat: float | None = None, minutes_left: float = Query(120.0, ge=0, le=1000),
             return_factor: float = Query(1.25, ge=1, le=3), reserve_min: float = Query(30.0, ge=0, le=120),
             flat_speed: float | None = None, max_slope: float | None = None, caution_slope: float | None = None,
             max_rough: float | None = None, sand_penalty: float | None = None, hazard_aversion: float | None = None,
             load_kg: float | None = None):
    """The shrinking world (feature A3): from the crew's position, the minutes of oxygen each cell needs (walk there,
    walk to the nearest haven at the return factor, keep the reserve), as a PNG the client thresholds as the oxygen
    drops; and which havens drop out when."""
    import base64
    s = _site(site_id)
    p = _walk_from_query(dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
                              sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg))
    env = envlib.envelope(s, (lon, lat), _havens(s, havens, hab_lon, hab_lat), p, return_factor, reserve_min)
    b = s.grid4.bounds_lonlat()
    return {"needed_png": "data:image/png;base64," + base64.b64encode(envlib.encode_minutes(env["needed"])).decode(),
            "shape": list(env["needed"].shape), "bounds": [[b[1], b[0]], [b[3], b[2]]],
            "havens": env["havens"], "walkable_cells": env["walkable_cells"], "cell_ha": env["cell_ha"],
            "return_factor": return_factor, "reserve_min": reserve_min, "stats": envlib.envelope_stats(env, minutes_left),
            "egress_minutes": round(_minutes_at_egress(eva.SuitParams(), p), 1), "compute_ms": env["compute_ms"]}


@app.post("/api/sites/{site_id}/rescue")
def rescue_check(site_id: str, req: PlanRequest):
    """Partner down (feature B3): the worst point of the planned route for bringing an injured crew member back
    into pressure, by buddy carry or by PR-2."""
    s = _site(site_id)
    p = _walk(req.walk)
    pl = plan(site_id, req)
    havens = [{"lon": req.habitat.lon, "lat": req.habitat.lat, "name": "Hab"}]
    rv = None
    if pl["rover"].get("enabled"):
        d = pl["rover"]["dropoff"]
        havens.append({"lon": d["lon"], "lat": d["lat"], "name": pr.NAME})
        rv = (d["lon"], d["lat"])
    else:
        rv = (req.habitat.lon, req.habitat.lat)  # PR-2 waits at the hab and can drive out
    res = _rescue_field(s, havens, p, rv[0], rv[1])
    ll = np.array([[a, b] for L in pl["legs"] for a, b in L["path"]])
    out = envlib.rescue_on_route(s, res, ll)
    out.update({"carry_ok_share": res.get("carry_ok_share"), "pr2_share": res.get("pr2_share"), "rover_lon": rv[0], "rover_lat": rv[1],
                "havens": havens, "carry_speed_factor": envlib.CARRY_SPEED_FACTOR, "carry_max_slope": envlib.CARRY_MAX_SLOPE})
    if out.get("worst_lon") is not None:
        cp = envlib.carry_params(p)
        out["carry_path"] = s.flow(havens, cp).path_home(out["worst_lon"], out["worst_lat"])
    return out


class CacheRequest(BaseModel):
    habitat: LonLat
    havens: str | None = None
    walk: dict = {}
    k: int = Field(3, ge=1, le=6)
    budget_min: float = Field(envlib.EMERGENCY_O2_MIN, ge=5, le=120)
    route: list[list[float]] | None = None  # [[lon, lat], ...]: cover the route instead of the whole site


@app.post("/api/sites/{site_id}/caches")
def caches(site_id: str, req: CacheRequest):
    """Caches at the gateways (feature B4): where k emergency oxygen caches put the most ground (or route) within
    budget_min of a haven, and the coverage before and after."""
    s = _site(site_id)
    p = _walk(req.walk)
    hv = flowlib.parse_havens(req.havens, [{"lon": req.habitat.lon, "lat": req.habitat.lat, "name": "Hab"}])
    route = np.array(req.route, float) if req.route else None
    out = envlib.place_caches(s, hv, p, k=req.k, budget_min=req.budget_min, route_lonlat=route)
    after = hv + [{"lon": c["lon"], "lat": c["lat"], "name": c["name"]} for c in out["caches"]]
    out["coverage_site_before"] = envlib.coverage(s, hv, p, req.budget_min, route)
    out["coverage_site_after"] = envlib.coverage(s, after, p, req.budget_min, route)
    return out


# ------------------------------------------------------------- HUD failure card (B2) and grid references (G5)
@app.post("/api/sites/{site_id}/fallback-card", response_class=HTMLResponse)
def fallback_card_html(site_id: str, req: PlanRequest):
    """Printable card for walking home with the visor dark: shadow clock, pace count, landmarks, grid references,
    and a skyline sketch at every station."""
    s = _site(site_id)
    p = plan(site_id, req)
    p["_hab"] = req.habitat.model_dump()
    return HTMLResponse(fallbacklib.render_html(s, p, [st.model_dump() for st in req.stops]))


@app.post("/api/sites/{site_id}/fallback-card.json")
def fallback_card_json(site_id: str, req: PlanRequest):
    """The fallback card's numbers, for the helmet's HUD-failure drill."""
    s = _site(site_id)
    p = plan(site_id, req)
    p["_hab"] = req.habitat.model_dump()
    return {"legs": fallbacklib.leg_aids(s, p), "stations": fallbacklib.station_skylines(s, [st.model_dump() for st in req.stops]),
            "pace_m": fallbacklib.PACE_M, "grid_m": fallbacklib.GRID_M,
            "hab_ref": fallbacklib.gridref(s, req.habitat.lon, req.habitat.lat)}


@app.get("/api/sites/{site_id}/grid-ref")
def grid_ref(site_id: str, lon: float, lat: float):
    """Apollo-style grid reference of a point ('K7', said 'Kilo seven')."""
    return fallbacklib.gridref(_site(site_id), lon, lat)


@app.get("/api/sites/{site_id}/grid-lines")
def grid_lines(site_id: str):
    """The site's lettered and numbered grid (250 m squares) as lines and labels."""
    return fallbacklib.grid_lines(_site(site_id))


# ------------------------------------------------------------- layer tower (feature A2)
_tower_cache: dict = {}
_tower_lock = threading.Lock()


@app.get("/api/sites/{site_id}/tower")
def tower_sheets(site_id: str):
    """The sheets of the layer tower for this site, bottom first, with their mission and instrument."""
    s = _site(site_id)
    cat = {x["id"]: x for x in _layer_catalog(s)}
    out = []
    for sh in towerlib.sheets_for(s):
        c = cat.get(sh["id"], {})
        name = s.cfg.get("basemap", {}).get("name", "HiRISE colour mosaic") if sh["id"] == "optical" else c.get("name", sh["id"])
        out.append({**sh, "name": name, "source": c.get("source") or (s.cfg.get("basemap", {}).get("attribution") if sh["id"] == "optical" else None),
                    "legend": c.get("legend")})
    return {"sheets": out, "site": s.cfg.get("name"), "size_m": s.meta.get("size_m")}


@app.get("/api/sites/{site_id}/tower/{layer}.jpg")
def tower_sheet(site_id: str, layer: str, size: int = Query(1024, ge=256, le=2048), havens: str | None = None,
                hab_lon: float | None = None, hab_lat: float | None = None,
                flat_speed: float | None = None, max_slope: float | None = None, caution_slope: float | None = None,
                max_rough: float | None = None, sand_penalty: float | None = None, hazard_aversion: float | None = None,
                load_kg: float | None = None):
    """One sheet of the tower: the layer composed over the site imagery (opaque layers as they are)."""
    s = _site(site_id)
    q = dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope, max_rough=max_rough,
             sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg, havens=havens)
    key = (site_id, layer, size, hab_lon, hab_lat, tuple(sorted((k, v) for k, v in q.items() if v is not None)), s.meta.get("built_utc"))
    with _tower_lock:
        hit = _tower_cache.pop(key, None)
        if hit is not None:
            _tower_cache[key] = hit
    if hit is None:
        ov = None if layer == "optical" else _layer_on_grid(s, layer, size, q, hab_lon, hab_lat)
        hit = towerlib.jpeg(towerlib.compose(s, layer, size, ov))
        with _tower_lock:
            _tower_cache[key] = hit
            while len(_tower_cache) > 40:
                _tower_cache.pop(next(iter(_tower_cache)))
    return Response(hit, media_type="image/jpeg", headers=DYN_HEADERS)


@app.post("/api/sites/{site_id}/walkback")
def walkback(site_id: str, req: WalkbackRequest):
    s = _site(site_id)
    p = _walk(req.walk)
    wbk = s.walkback((req.habitat.lon, req.habitat.lat), p)
    return {"rings": wbk["rings"], "max_min": round(wbk["max_min"], 1), "reachable_fraction": round(wbk["reachable_fraction"], 3),
            "compute_ms": round(wbk["compute_ms"], 1)}


@app.post("/api/sites/{site_id}/viewshed")
def viewshed(site_id: str, req: ViewshedRequest):
    s = _site(site_id)
    observers = [(req.habitat.lon, req.habitat.lat, req.radio.habitat_mast_m)] + [(r.lon, r.lat, r.height_m) for r in req.radio.relays]
    c = s.comms(observers, req.radio.suit_antenna_m)
    return {k: (round(v, 4) if isinstance(v, float) else v) for k, v in c.items() if k != "grid"}


@app.get("/api/sites/{site_id}/query")
def query(site_id: str, lon: float, lat: float, hab_lon: float | None = None, hab_lat: float | None = None,
          obs: str | None = None, tgt: float = 2.0, flat_speed: float | None = None, max_slope: float | None = None,
          caution_slope: float | None = None, max_rough: float | None = None, sand_penalty: float | None = None,
          hazard_aversion: float | None = None, load_kg: float | None = None, utc: str | None = None):
    s = _site(site_id)
    if not s.grid.contains_lonlat(lon, lat):
        return {"inside": False}
    v = {k: (None if not np.isfinite(x) else round(float(x), 4)) for k, x in s.sample(lon, lat).items()}
    p = _walk_from_query(dict(flat_speed=flat_speed, max_slope=max_slope, caution_slope=caution_slope,
                              max_rough=max_rough, sand_penalty=sand_penalty, hazard_aversion=hazard_aversion, load_kg=load_kg))
    r2, c2 = (int(round(x)) for x in s.grid2.lonlat_to_rowcol(lon, lat))
    r2 = min(max(r2, 0), s.grid2.height - 1)
    c2 = min(max(c2, 0), s.grid2.width - 1)
    v["hazard"] = int(s.hazard(p)[r2, c2])
    if s.boulder2 is not None:
        v["boulder_m"] = round(float(s.boulder2[r2, c2]), 2)
    if s.crism:
        r4i, c4i = (int(round(float(x))) for x in s.grid4.lonlat_to_rowcol(lon, lat))
        v["crism"] = {}
        for kind, c in s.crism.items():
            px = c["rgba"][min(max(r4i, 0), c["rgba"].shape[0] - 1), min(max(c4i, 0), c["rgba"].shape[1] - 1)]
            bands = c["meta"].get("bands", [])
            v["crism"][kind] = {"name": c["meta"].get("name"), "rgb": [int(px[0]), int(px[1]), int(px[2])], "strength": round(int(px[3]) / 255.0, 2),
                                "dominant": bands[int(np.argmax(px[:3]))] if bands and px[3] > 60 else None}
    geo = s.geology_at(lon, lat)
    if geo:
        v["geology"] = geo
    if s.sand_parts:
        v["sand_why"] = sandlib.explain({k: float(a[r2, c2]) for k, a in s.sand_parts.items()})
    sci = _science_at(s, lon, lat)
    if sci:
        v["science_info"] = sci
    sc = s.scouted_at(lon, lat)
    if sc:
        v["scouted"] = sc
    if s.horizon is not None:
        st = s.sun_times(lon, lat, _parse_utc(utc))
        v["sun"] = {k: st.get(k) for k in ("sunrise_ltst", "sunset_ltst", "flat_sunrise_ltst", "flat_sunset_ltst", "horizon_deg")}
    from pipeline import trek as _trek
    v["trek_url"] = _trek.open_url(lon, lat)
    v["grid_ref"] = fallbacklib.gridref(s, lon, lat)
    v["gcr_usv_h"] = round(climate.gcr_usv_per_h(v.get("shield") or 0), 2)
    if hab_lon is not None and hab_lat is not None:
        f = s.walkback((hab_lon, hab_lat), p)["field"]
        r4, c4 = s.grid4.lonlat_to_rowcol(lon, lat)
        val = float(_sample_field(f, r4, c4)[0])
        v["walkback_min"] = round(val / 60, 1) if np.isfinite(val) else None
        # feature A3 time bank: minutes the crew could spend here (default suit, out from the hab and back)
        try:
            eg = _minutes_at_egress(eva.SuitParams(), p)
            tb = envlib.time_bank(s, {"lon": hab_lon, "lat": hab_lat, "name": "Hab"}, p, eg, lon, lat)
            v["time_bank_min"] = tb
            v["egress_minutes"] = round(eg, 1)
        except Exception:  # never let the extra number break Inspect
            pass
    if obs:
        c = s.comms(_parse_observers(obs), tgt)["grid"]
        v["comms"] = int(c[r2, c2])
    v["inside"] = True
    return v


# ----------------------------------------------------------------- conditions
@app.get("/api/sites/{site_id}/conditions")
def conditions(site_id: str, utc: str | None = None):
    s = _site(site_id)
    with climate.calibrated(_climate_cal(s)), _site_climate(s):
        return _conditions(s, utc)


def _conditions(s, utc: str | None):
    when = _parse_utc(utc)
    lat, lon = s.grid.lat0, s.grid.lon0
    mt = mars24.mars_time(when)
    lmst = mars24.local_mean_solar_time(mt, lon)
    ltst = mars24.local_true_solar_time(mt, lon)
    elev, az, _ = mars24.sun_position(mt, lat, lon)
    tau = climate.dust_tau(mt.ls)
    rs = mars24.sunrise_sunset_ltst(mt, lat)
    sun = {"elevation": round(elev, 2), "azimuth": round(az, 2), "toa_wm2": round(mars24.solar_flux_top_of_atmosphere(mt), 1),
           "surface_wm2": {k: round(v, 1) for k, v in climate.surface_flux(mars24.solar_flux_top_of_atmosphere(mt), elev, tau).items()},
           "sunrise_ltst": rs[0] if rs else None, "sunset_ltst": rs[1] if rs else None,
           "daylight_left_h": round(max(0.0, rs[1] - ltst), 2) if rs and rs[0] <= ltst <= rs[1] else 0.0}
    if rs:
        sun["sunrise_utc"] = mars24.utc_for_ltst(when, lon, rs[0]).isoformat()
        sun["sunset_utc"] = mars24.utc_for_ltst(when, lon, rs[1]).isoformat()
    tmin, tmax = climate.air_temp_range(mt.ls, tau)
    curve = {"ltst": [], "sun_elev": [], "air_c": [], "ground_c": []}
    for h in np.arange(0, 24.01, 0.25):
        t_utc = mars24.utc_for_ltst(when, lon, float(h % 24))
        m2 = mars24.mars_time(t_utc)
        e2, _, _ = mars24.sun_position(m2, lat, lon)
        curve["ltst"].append(float(h))
        curve["sun_elev"].append(round(e2, 2))
        curve["air_c"].append(round(climate.air_temp_c(mt.ls, float(h), tau), 1))
        curve["ground_c"].append(round(climate.ground_temp_c(mt.ls, float(h), tau), 1))
    hab = s.cfg.get("habitat") or {"lon": lon, "lat": lat}
    hab_shield = float(s.sample(hab["lon"], hab["lat"])["shield"])
    if s.horizon is not None:
        ts = s.sun_times(hab["lon"], hab["lat"], when)
        sun.update({"terrain_sunrise_ltst": ts.get("sunrise_ltst"), "terrain_sunset_ltst": ts.get("sunset_ltst"),
                    "terrain_sunrise_utc": ts.get("sunrise_utc"), "terrain_sunset_utc": ts.get("sunset_utc"),
                    "hab_horizon_deg": ts.get("horizon_deg")})
        if ts.get("sunrise_ltst") is not None and ts["sunrise_ltst"] <= ltst <= ts["sunset_ltst"]:
            sun["daylight_left_h"] = round(max(0.0, ts["sunset_ltst"] - ltst), 2)
    return {
        "utc": when.isoformat(), "msd": round(mt.msd, 5), "mtc": mars24.hours_to_hms(mt.mtc),
        "ls": round(mt.ls, 2), "mars_year": mt.mars_year, "season": mars24.season_name(mt.ls, lat),
        "sol": mars24.mission_sol(mt, lon, s.cfg["rover"].get("landing_msd_local", 0)),
        "lmst": mars24.hours_to_hms(lmst), "ltst": mars24.hours_to_hms(ltst), "ltst_h": round(ltst, 4),
        "eot_min": round(mt.eot_deg * 4, 1), "helio_au": round(mt.helio_au, 4), "declination": round(mt.declination, 2),
        "sun": sun,
        "weather": {"air_c": round(climate.air_temp_c(mt.ls, ltst, tau), 1), "ground_c": round(climate.ground_temp_c(mt.ls, ltst, tau), 1),
                    "air_min_c": round(tmin, 1), "air_max_c": round(tmax, 1), "pressure_pa": round(climate.pressure_pa(mt.ls, ltst)),
                    "tau": round(tau, 2), "uv_index": climate.uv_index(elev, tau), "wind_ms": round(climate.wind_ms(ltst), 1),
                    "model": ("Season means of Curiosity REMS measurements (%d sols at Ls %.0f-%.0f°, all Mars years), "
                              "with a modelled daily cycle; wind, dust and UV are modelled" % (cal["n_sols"], cal["ls_window"][0], cal["ls_window"][1]))
                    if (cal := climate.calibration(mt.ls)) else "Climatology model (typical for the season and hour), not a forecast",
                    "calibrated": bool(climate.calibration(mt.ls))},
        "radiation": {"gcr_usv_h": round(climate.gcr_usv_per_h(0), 2), "gcr_msv_day": round(climate.gcr_usv_per_h(0) * 24 / 1000, 3),
                      "hab_site_shield": round(hab_shield, 4), "site_shield": s.meta.get("shield_stats"),
                      "may2024_event_ugy": 8100, "career_limit_msv": 600},
        "sol_curve": curve,
    }


@app.get("/api/sites/{site_id}/weather/live")
def live_weather(site_id: str):
    """Measured weather from the site's rover (Curiosity REMS), with a same-season forecast."""
    s = _site(site_id)
    mission = s.cfg["rover"].get("raw_images_mission", "")
    mt = mars24.mars_time(datetime.now(timezone.utc))
    sol = mars24.mission_sol(mt, s.grid.lon0, s.cfg["rover"].get("landing_msd_local", 0))
    try:
        with _site_climate(s):  # compare the measurements with *this* site's model
            return weather_live.summary(mission, sol)
    except Exception as e:  # offline and no cache yet
        return {"available": False, "reason": f"weather feed unavailable ({type(e).__name__})"}


@app.get("/api/spaceweather")
def space_weather():
    return spaceweather.summary()


@app.get("/api/rover/{mission}/images")
def rover_imgs(mission: str, sol: int, sol_end: int | None = None, per_page: int = Query(48, ge=1, le=100)):
    if mission not in ("msl", "mars2020"):
        raise HTTPException(404)
    try:
        return rover_images.images(mission, sol, sol_end if sol_end is not None else sol, per_page)
    except Exception as e:
        raise HTTPException(502, f"raw image feed unavailable: {type(e).__name__}")


MINERAL_SHORT = {"hyd": "Sulfate", "phy": "Clay", "fem": "Iron-oxide", "maf": "Mafic"}


def _suggestion_name(s, kind: str, sci: dict, r: int, c: int, letter: str) -> str:
    """"Clay ridge A", "Sulfate outcrop B", "NHjf/Njf contact C": what makes the place interesting, then a letter."""
    mineral = ""
    if any(x["kind"] == "mineral" for x in sci["reasons"]):
        ki = int(s.science["mineral_kind"][r, c])
        if ki == 255:
            w = s.science["mineral_kind"][max(0, r - 3):r + 4, max(0, c - 3):c + 4]
            w = w[w != 255]
            ki = int(np.bincount(w).argmax()) if w.size else 255
        mineral = MINERAL_SHORT.get(scilib.KINDS[ki], "") if ki != 255 else ""
    if kind == "contact":
        codes = next(x.get("units", []) for x in sci["reasons"] if x["kind"] == "contact")
        base = f"{'/'.join(codes)} contact" if len(codes) == 2 else "Contact"
    else:
        noun = {"ridge": "ridge", "hollow": "hollow", "outcrop": "outcrop"}[kind]
        base = f"{mineral} {noun}" if mineral else noun.capitalize()
    return f"{base} {letter}"


@app.post("/api/sites/{site_id}/suggest-stops")
def suggest_stops(site_id: str, req: SuggestRequest):
    """Science stops inside the safe walk-back range, best first, each with its reasons, rock unit and mineral signal."""
    from scipy import ndimage
    s = _site(site_id)
    if not s.science:
        raise HTTPException(404, "This site has no science layer yet (python -m pipeline.build_site <site> --only science meta)")
    t0 = time.perf_counter()
    p = _walk(req.walk)
    hv = req.haven or req.habitat
    wb = s.walkback((hv.lon, hv.lat), p)["field"]
    score = s.science["score"]
    H, W = score.shape
    wb2 = np.full((H, W), np.inf, np.float32)
    rep = np.repeat(np.repeat(wb, 2, axis=0), 2, axis=1)
    wb2[:min(H, rep.shape[0]), :min(W, rep.shape[1])] = rep[:H, :W]
    hz = s.hazard(p)
    ok = np.isfinite(wb2) & (wb2 <= req.max_walkback_min * 60.0) & (hz <= 2)
    val = ndimage.uniform_filter(np.where(ok, score, 0.0).astype(np.float32), 7)  # ~14 m patches, not single cells
    val[~ok] = 0.0
    rr, cc = np.ogrid[:H, :W]
    sep = req.min_sep_m / s.grid2.res
    for lon, lat in [(req.habitat.lon, req.habitat.lat)] + [(st.lon, st.lat) for st in req.stops]:
        r, c = s.grid2.lonlat_to_rowcol(lon, lat)
        val[(rr - r) ** 2 + (cc - c) ** 2 < sep ** 2] = 0.0
    out = []
    hx, hy = s.grid2.lonlat_to_xy(hv.lon, hv.lat)
    for i in range(req.n):
        k = int(np.argmax(val))
        r, c = divmod(k, W)
        if val[r, c] < 0.15:
            break
        lon, lat = (float(v) for v in s.grid2.rowcol_to_lonlat(r, c))
        sci = _science_at(s, lon, lat) or {"reasons": [], "score": float(score[r, c])}
        kinds = [x["kind"] for x in sci["reasons"]]
        kind = next((k for k in ("ridge", "hollow", "contact") if k in kinds), "outcrop")
        unit = s.geology_at(lon, lat)
        name = _suggestion_name(s, kind, sci, r, c, chr(ord("A") + i))
        x, y = s.grid2.lonlat_to_xy(lon, lat)
        out.append({
            "id": f"SUG{i + 1}", "name": name, "kind": kind, "lon": round(lon, 7), "lat": round(lat, 7),
            "dwell_min": STOP_DWELL[kind], "tasks": STOP_TASKS[kind],
            "science": "; ".join(x_["text"] for x_ in sci["reasons"]) or "Strongest science signal within reach",
            "score": round(float(val[r, c]), 2), "reasons": sci["reasons"],
            "walkback_min": round(float(wb2[r, c]) / 60.0, 1), "dist_m": round(float(math.hypot(float(x) - float(hx), float(y) - float(hy)))),
            "slope": round(float(s.slope2[r, c]), 1), "hazard": int(hz[r, c]), "sand": round(float(s.sand2[r, c]), 2),
            "unit": {"code": unit["code"], "name": unit["name"], "color": unit["color"]} if unit else None,
            "scouted": s.scouted_at(lon, lat),
        })
        val[(rr - r) ** 2 + (cc - c) ** 2 < sep ** 2] = 0.0
    return {"suggestions": out, "max_walkback_min": req.max_walkback_min, "min_sep_m": req.min_sep_m,
            "haven": "PR-2" if req.haven else "hab", "compute_ms": round((time.perf_counter() - t0) * 1000, 1)}


# ------------------------------------------------------------- crew-tagged map (C2)
class TagRequest(BaseModel):
    kind: str
    lon: float
    lat: float
    note: str = ""
    by: str = "EV1"
    radius_m: float | None = None


def _clear_site_caches(site):
    """Crew tags changed the cost grids: drop every cached route, plan picture and dynamic drape for this site."""
    with _route_lock:
        for k in [k for k in _route_cache if k[0] == site.id]:
            _route_cache.pop(k, None)
    with _overlay_lock:
        for k in [k for k in _overlay_cache if k[0] == site.id and not _is_static_overlay(k[1])]:
            _overlay_cache.pop(k, None)
    with _tower_lock:
        for k in [k for k in _tower_cache if k[0] == site.id]:
            _tower_cache.pop(k, None)


def _tag_site(site_id: str):
    s = _site(site_id)
    if _clear_site_caches not in s.on_change:
        s.on_change.append(_clear_site_caches)
    return s


@app.get("/api/sites/{site_id}/tags")
def tags_list(site_id: str):
    s = _tag_site(site_id)
    return {"tags": s.tags, "version": s.tag_key}


@app.post("/api/sites/{site_id}/tags")
def tags_add(site_id: str, req: TagRequest):
    """Look at a spot and press once: a hazard closes a small disc of ground for routing; a find is a stop for later."""
    s = _tag_site(site_id)
    if not s.grid.contains_lonlat(req.lon, req.lat):
        raise HTTPException(422, "outside the site")
    try:
        tag = tagslib.add(DATA_DIR, site_id, req.kind, req.lon, req.lat, req.note, req.by, req.radius_m)
    except ValueError as e:
        raise HTTPException(422, str(e))
    s.set_tags(tagslib.load(DATA_DIR, site_id))
    return {"tag": tag, "tags": s.tags, "version": s.tag_key}


@app.delete("/api/sites/{site_id}/tags/{tag_id}")
def tags_delete(site_id: str, tag_id: str):
    s = _tag_site(site_id)
    n = tagslib.delete(DATA_DIR, site_id, None if tag_id == "all" else tag_id)
    s.set_tags(tagslib.load(DATA_DIR, site_id))
    return {"deleted": n, "tags": s.tags, "version": s.tag_key}


# ------------------------------------------------------------- scout first (C1)
@app.post("/api/sites/{site_id}/scout")
def scout(site_id: str, req: PlanRequest):
    """The route's stretches on uncertain terrain or sand, a helicopter flight over them, and the plan checked again
    as if the flight had happened (simulated: inside the swath the data is taken as confirmed)."""
    s = _site(site_id)
    before = plan(site_id, req)
    runs = scoutlib.stretches(before["profile"])
    pad = req.habitat.model_dump()
    fp = scoutlib.flight_plan(s.grid.lonlat_to_xy, s.grid.xy_to_lonlat, pad, runs)
    frac = scoutlib.scouted_fraction(before["profile"], runs)
    after_req = req.model_copy(update={"speed_dispersion_scale": max(0.0, 1.0 - 0.5 * min(1.0, frac * 2.0)) if runs else 1.0})
    after = plan(site_id, after_req) if runs else before
    rc = before["totals"].get("route_confidence") or {}
    return {"stretches": runs, "flight": fp, "scouted_route_fraction": round(frac, 3),
            "before": {"margin_range_min": before["totals"]["margin_range_min"], "terrain_low_m": rc.get("terrain_low_m"),
                       "sand_unsure_m": rc.get("sand_unsure_m"), "go": before["totals"]["go"]},
            "after": {"margin_range_min": after["totals"]["margin_range_min"], "terrain_low_m": 0 if runs else rc.get("terrain_low_m"),
                      "sand_unsure_m": 0 if runs else rc.get("sand_unsure_m"), "go": after["totals"]["go"],
                      "speed_dispersion_scale": after_req.speed_dispersion_scale},
            "simulated": True}


# ------------------------------------------------------------- the cost of a rock: debrief (C4)
class DebriefRequest(PlanRequest):
    track: list[list[float]] | None = None  # [[eva_t_s, lon, lat], ...] recorded by the live link (feature D1)


@app.post("/api/sites/{site_id}/debrief", response_class=HTMLResponse)
def debrief(site_id: str, req: DebriefRequest):
    """The EVA debrief: walked against planned, time at each station, and a passport for every sample (with its
    price in minutes of margin)."""
    from types import SimpleNamespace
    s = _site(site_id)
    pl = plan(site_id, PlanRequest(**{k: v for k, v in req.model_dump().items() if k != "track"}))
    stops = [st.model_dump() for st in req.stops]
    svg = ""
    try:
        known = {str(st.get("id")): st for st in s.cfg.get("stops", [])}
        view = SimpleNamespace(cfg={**s.cfg, "stops": [{**known.get(str(st["id"]), {}), **st} for st in stops],
                                    "habitat": {**s.cfg.get("habitat", {}), **req.habitat.model_dump()}}, grid=s.grid, dir=s.dir)
        extra = None
        if req.track and len(req.track) > 1:  # the walk as flown, in red over the plan
            extra = [(np.array([t[1] for t in req.track]), np.array([t[2] for t in req.track]), "#e11d48")]
        svg = traverse_sheet.render_svg(view, pl, 900, extra_lines=extra)
    except Exception:
        svg = ""
    return HTMLResponse(debrieflib.render_html(s, pl, stops, _science_at, req.track, svg))


# ------------------------------------------------------------- beat the planner (G3)
class SketchRequest(BaseModel):
    points: list[list[float]]  # [[lon, lat], ...] the route you drew
    walk: dict = {}


def _line_cells(r0, c0, r1, c1):
    """8-connected cells from (r0, c0) to (r1, c1) (Bresenham)."""
    cells = []
    dr, dc = abs(r1 - r0), abs(c1 - c0)
    sr, sc = (1 if r1 > r0 else -1), (1 if c1 > c0 else -1)
    err = dc - dr
    r, c = r0, c0
    while True:
        cells.append((r, c))
        if r == r1 and c == c1:
            break
        e2 = 2 * err
        if e2 > -dr:
            err -= dr
            c += sc
        if e2 < dc:
            err += dc
            r += sr
    return cells


@app.post("/api/sites/{site_id}/score-route")
def score_route(site_id: str, req: SketchRequest):
    """Your sketched route, scored with the same walking model as the planner, against A* between its ends."""
    s = _site(site_id)
    p = _walk(req.walk)
    if len(req.points) < 2:
        raise HTTPException(422, "Draw at least two points")
    mult = s.multiplier(p)
    g2 = s.grid2
    cells = []
    rc = [tuple(int(round(float(v))) for v in g2.lonlat_to_rowcol(lon, lat)) for lon, lat in req.points]
    for (r0, c0), (r1, c1) in zip(rc[:-1], rc[1:]):
        seg = _line_cells(r0, c0, r1, c1)
        cells.extend(seg if not cells else seg[1:])
    cells = [(min(max(r, 0), g2.height - 1), min(max(c, 0), g2.width - 1)) for r, c in cells]
    nogo = np.array([not np.isfinite(mult[r, c]) for r, c in cells])
    mult_pen = np.where(np.isfinite(mult), mult, 8.0)  # walking through no-go ground: counted, and very slow
    ev = evaluate_cells(cells, s.z2, s.slope2, mult_pen, g2.res, p)
    hz = s.hazard(p)
    hzv = np.array([hz[r, c] for r, c in cells])
    seg_m = np.diff(np.asarray(ev["d"], float), prepend=0.0)
    yours = {"time_s": round(float(ev["t"][-1]), 1), "dist_m": round(float(ev["d"][-1]), 1),
             "ascent_m": round(float(np.clip(ev["dz"], 0, None).sum()), 1), "max_slope": round(float(np.max(ev["slope"])), 1),
             "nogo_m": round(float(seg_m[nogo].sum()), 1), "hazard_m": round(float(seg_m[hzv >= 3].sum()), 1)}
    a, b = req.points[0], req.points[-1]
    res = _route(s, {"lon": a[0], "lat": a[1]}, {"lon": b[0], "lat": b[1]}, p, "astar", 1.0)
    best = None
    if res.cells:
        evb = evaluate_cells(res.cells, s.z2, s.slope2, mult, g2.res, p)
        keep = simplify_cells(res.cells)
        rcb = np.asarray(res.cells, float)[keep]
        lon, lat = g2.rowcol_to_lonlat(rcb[:, 0], rcb[:, 1])
        best = {"time_s": round(float(evb["t"][-1]), 1), "dist_m": round(float(evb["d"][-1]), 1),
                "ascent_m": round(float(np.clip(evb["dz"], 0, None).sum()), 1), "max_slope": round(float(np.max(evb["slope"])), 1),
                "path": [[round(float(x), 7), round(float(y), 7)] for x, y in zip(lon, lat)]}
    score = None
    if best:
        score = int(round(1000 * best["time_s"] / max(yours["time_s"], 1.0))) - int(yours["nogo_m"] * 20) - int(yours["hazard_m"] * 2)
    verdict = ("You beat the planner!" if score and score > 1000 else "Within 5 % of the planner: well walked" if score and score >= 950
               else "The planner wins this one" if score is not None else "No safe route between your ends")
    if yours["nogo_m"] > 0:
        verdict += f" (but {yours['nogo_m']:.0f} m of your line crosses no-go ground)"
    return {"yours": yours, "planner": best, "score": score, "verdict": verdict}


class AutoplanRequest(BaseModel):
    """Plan it for me (feature C3)."""
    habitat: LonLat
    stops: list[Stop] = []
    walk: dict = {}
    suit: dict = {}
    suit_budget_min: float = Field(240.0, ge=60, le=480)
    user_suit_min: float | None = None
    start_utc: str | None = None
    space_weather: str = "off"
    verify: bool = True


@app.post("/api/sites/{site_id}/autoplan")
def autoplan(site_id: str, req: AutoplanRequest):
    """Three EVAs (safe, balanced, bold) that collect the most science inside the time in suits asked for, stops in
    the best order, each checked by the real planner; and the planner's science at the user's own time in suits."""
    s = _site(site_id)
    if not s.science:
        raise HTTPException(404, "This site has no science layer yet")
    p = _walk(req.walk)
    hab = req.habitat.model_dump()

    def suggest(site, lon, lat, r, c, letter):
        sci = _science_at(site, lon, lat) or {"reasons": [], "score": 0.0}
        kinds = [x["kind"] for x in sci["reasons"]]
        kind = next((k for k in ("ridge", "hollow", "contact") if k in kinds), "outcrop")
        return {"name": _suggestion_name(site, kind, sci, r, c, letter), "kind": kind, "tasks": STOP_TASKS[kind],
                "science": "; ".join(x["text"] for x in sci["reasons"][:2])}

    out = autoplanlib.plan_variants(s, hab, p, req.suit_budget_min, [st.model_dump() for st in req.stops], suggest=suggest,
                                    user_suit_min=req.user_suit_min)
    if req.verify:
        for v in out["variants"]:
            if not v["stops"]:
                v["plan"] = None
                continue
            stops = [Stop(**{k: st.get(k) for k in ("id", "name", "lon", "lat", "dwell_min", "kind", "tasks") if st.get(k) is not None})
                     for st in v["stops"]]
            preq = PlanRequest(habitat=req.habitat, stops=stops, walk=req.walk, suit=req.suit, start_utc=req.start_utc,
                               space_weather=req.space_weather)
            try:
                pl = plan(site_id, preq)
                t = pl["totals"]
                v["plan"] = {"go": t["go"], "min_margin_min": t["min_margin_min"], "suit_min": round(t["suit_s"] / 60.0, 1),
                             "dist_m": t["dist_m"], "max_walkback_min": t["max_walkback_min"], "limiting": t["limiting"],
                             "issues": [i for i in pl["issues"] if i["level"] in ("nogo", "caution", "nogo-soft")][:4],
                             "path": [pt for L in pl["legs"] for pt in L["path"][::3]]}
            except HTTPException as e:
                v["plan"] = {"go": False, "error": e.detail}
    return out


@app.get("/api/sites/{site_id}/sun")
def sun_at(site_id: str, lon: float, lat: float, utc: str | None = None):
    """Terrain sunrise and sunset at a point (and the flat-horizon times), its horizon profile, and the sun now."""
    s = _site(site_id)
    when = _parse_utc(utc)
    st = s.sun_times(lon, lat, when)
    e, a, _ = mars24.sun_position(mars24.mars_time(when), s.grid.lat0, s.grid.lon0)
    return {**st, "now": {"utc": when.isoformat(), "sun_elev": round(e, 2), "sun_az": round(a, 1),
                          "sunlit": bool(s.sunlit(lon, lat, e, a))}}


@app.get("/api/sites/{site_id}/ingenuity")
def ingenuity_flights(site_id: str):
    """Ingenuity's flights near the site (no paths: those are in ingenuity.geojson)."""
    s = _site(site_id)
    return {"flights": [{k: v for k, v in f.items() if k != "path"} for f in s.ingenuity], "meta": s.meta.get("ingenuity")}


@app.get("/api/ingenuity/images")
def ingenuity_images(sol: int, per_page: int = Query(24, ge=1, le=100)):
    """Ingenuity's own photos from a flight sol (colour RTE camera first, then the downward navigation camera)."""
    try:
        return rover_images.ingenuity(sol, per_page)
    except Exception as e:
        raise HTTPException(502, f"raw image feed unavailable: {type(e).__name__}")


@app.get("/api/sites/{site_id}/rover/nearest")
def rover_nearest(site_id: str, lon: float, lat: float, n: int = 3):
    s = _site(site_id)
    p = s.dir / "rover_waypoints.geojson"
    if not p.exists():
        return {"items": []}
    fc = json.loads(p.read_text())
    feats = sorted(fc["features"], key=lambda f: f["properties"]["sol"] or 0)
    if not feats:
        return {"items": []}
    lons = np.array([f["geometry"]["coordinates"][0] for f in feats])
    lats = np.array([f["geometry"]["coordinates"][1] for f in feats])
    x, y = s.grid.lonlat_to_xy(lons, lats)
    x0, y0 = s.grid.lonlat_to_xy(lon, lat)
    d = np.hypot(x - x0, y - y0)
    out = []
    for k in np.argsort(d)[:n]:
        f = feats[int(k)]
        sol = f["properties"]["sol"]
        nxt = feats[int(k) + 1]["properties"]["sol"] if int(k) + 1 < len(feats) else sol
        out.append({"sol": sol, "sol_end": max(sol, min(nxt - 1, sol + 2)) if nxt else sol, "distance_m": round(float(d[k]), 1),
                    "lon": float(lons[k]), "lat": float(lats[k]), "elev_dtm": f["properties"].get("elev_dtm")})
    return {"items": out}


# ---------------------------------------------------------------- web app
DIST = ROOT / "web" / "dist"


class _WebFiles(StaticFiles):
    """web/dist. The hashed assets may be cached, but index.html is revalidated on every load: without that the browser
    kept a cached index.html pointing at the previous build's bundle, so a rebuilt planner never showed."""

    async def get_response(self, path, scope):
        resp = await super().get_response(path, scope)
        if resp.headers.get("content-type", "").startswith("text/html"):
            resp.headers["Cache-Control"] = "no-cache"
        return resp


if DIST.exists():
    app.mount("/", _WebFiles(directory=DIST, html=True), name="web")
