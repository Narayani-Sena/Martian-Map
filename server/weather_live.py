"""Measured weather from Curiosity's REMS station (mars.nasa.gov weather feed), cached on disk.

REMS sols reach the public feed with a lag of weeks, so besides the latest measured sol we also
report what Curiosity measured at the *same season one Mars year ago*: for planning an EVA that is
the best data-based forecast we can make. The climatology model used by /conditions is compared
with the measurements so the app can show how far off it is.
"""

from __future__ import annotations

import time
from pathlib import Path

from marsgeo.net import get_json

from . import climate

FEEDS = {"msl": "https://mars.nasa.gov/rss/api/?feed=weather&category=msl&feedtype=json",
         # Perseverance MEDA: the feed exists but (late 2026) publishes only "--" placeholders
         "mars2020": "https://mars.nasa.gov/rss/api/?feed=weather&category=mars2020&feedtype=json"}
INSTRUMENTS = {"msl": "REMS (Rover Environmental Monitoring Station) on Curiosity",
               "mars2020": "MEDA (Mars Environmental Dynamics Analyzer) on Perseverance"}
SOURCES = {"msl": "mars.nasa.gov MSL weather feed (REMS team, CAB/INTA-CSIC and NASA/JPL)",
           "mars2020": "mars.nasa.gov Mars 2020 weather feed (MEDA team, CAB/INTA-CSIC and NASA/JPL)"}
STALE_SOLS = 300  # older than this, the feed has stopped rather than lagging
CACHE = Path(__file__).resolve().parents[1] / "data" / "cache" / "weather"
TTL_S = 6 * 3600
MARS_YEAR_SOLS = 668.6


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_rows(js: dict) -> list[dict]:
    rows = []
    for s in js.get("soles") or js.get("sols") or []:
        sol = _num(s.get("sol"))
        if sol is None:
            continue
        rows.append({
            "sol": int(sol), "date": s.get("terrestrial_date"), "ls": _num(s.get("ls")),
            "min_c": _num(s.get("min_temp")), "max_c": _num(s.get("max_temp")),
            "ground_min_c": _num(s.get("min_gts_temp")), "ground_max_c": _num(s.get("max_gts_temp")),
            "pressure_pa": _num(s.get("pressure")), "opacity": s.get("atmo_opacity"),
            "uv": s.get("local_uv_irradiance_index"), "sunrise": s.get("sunrise"), "sunset": s.get("sunset"),
        })
    rows.sort(key=lambda r: r["sol"])
    return rows


def summarize(rows: list[dict], current_sol: int, n_recent: int = 120) -> dict:
    """Latest measured sol, a recent series, the same season last Mars year, and model-vs-measured."""
    valid = [r for r in rows if r["min_c"] is not None and r["max_c"] is not None]
    if not valid:
        return {"available": False, "reason": "no measured sols in the feed"}
    latest = valid[-1]
    target = current_sol - MARS_YEAR_SOLS
    window = [r for r in valid if abs(r["sol"] - target) <= 5]
    last_year = None
    if window:
        def mean(k):
            vals = [r[k] for r in window if r[k] is not None]
            return round(sum(vals) / len(vals), 1) if vals else None
        mid = min(window, key=lambda r: abs(r["sol"] - target))
        last_year = {"sol_from": window[0]["sol"], "sol_to": window[-1]["sol"], "ls": mid["ls"], "date": mid["date"],
                     "min_c": mean("min_c"), "max_c": mean("max_c"), "ground_min_c": mean("ground_min_c"),
                     "ground_max_c": mean("ground_max_c"), "pressure_pa": mean("pressure_pa"), "opacity": mid["opacity"]}
    model = None
    if latest["ls"] is not None:
        lo, hi = climate.air_temp_range(latest["ls"])
        model = {"ls": latest["ls"], "min_c": round(lo, 1), "max_c": round(hi, 1),
                 "error_min_c": round(lo - latest["min_c"], 1), "error_max_c": round(hi - latest["max_c"], 1)}
    recent = valid[-n_recent:]
    return {
        "available": True,
        "instrument": "REMS (Rover Environmental Monitoring Station) on Curiosity",
        "latest": latest,
        "lag_sols": max(0, current_sol - latest["sol"]),
        "stale": current_sol - latest["sol"] > STALE_SOLS,
        "current_sol": current_sol,
        "same_season_last_year": last_year,
        "model_vs_measured": model,
        "recent": {k: [r[k] for r in recent] for k in ("sol", "min_c", "max_c", "pressure_pa")},
        "source": "mars.nasa.gov MSL weather feed (REMS team, CAB/INTA-CSIC and NASA/JPL)",
    }


_parsed: dict = {}  # mission -> {"mtime", "checked", "rows"}
_clim: dict = {}    # (mission, Ls rounded, half width, rows id) -> ls_climatology result
RECHECK_S = 120.0   # how often the on-disk cache file is looked at again (it changes every TTL_S at most)


def rows_for(mission: str) -> list[dict]:
    """Parsed feed rows, kept in memory and re-read only when the on-disk cache file changes.

    The EVA simulation asks for the climatology at every step (~350 per plan); reading and parsing the
    multi-megabyte feed each time made one plan take ~50 s, about 80 % of it in json.loads.
    """
    path = CACHE / f"{mission}_weather.json"
    now = time.time()
    entry = _parsed.get(mission)
    if entry is not None and now - entry["checked"] < RECHECK_S:
        return entry["rows"]
    mtime = path.stat().st_mtime if path.exists() else None
    if entry is not None and mtime is not None and mtime == entry["mtime"] and now - mtime < TTL_S:
        entry["checked"] = now
        return entry["rows"]
    js = get_json(FEEDS[mission], cache_path=path, ttl_s=TTL_S, timeout=60)
    entry = _parsed[mission] = {"mtime": path.stat().st_mtime if path.exists() else None, "checked": now,
                                "rows": parse_rows(js)}
    return entry["rows"]


def ls_climatology(mission: str, ls: float, half_width: float = 4.0) -> dict | None:
    """Mean measured conditions at this season (Ls +/- half_width) over every Mars year in the feed.

    Memoised per 0.01° of Ls: an EVA spans a few hundredths of a degree, so a plan needs one or two of these.
    """
    if mission not in FEEDS:
        return None
    rows = rows_for(mission)
    key = (mission, round(ls % 360.0, 2), half_width, id(rows))
    if key in _clim:
        hit = _clim[key]
        return dict(hit) if hit is not None else None
    sel = [r for r in rows if r["ls"] is not None and r["min_c"] is not None and r["max_c"] is not None
           and abs((r["ls"] - ls + 180.0) % 360.0 - 180.0) <= half_width]
    out = None
    if len(sel) >= 5:
        def mean(k):
            vals = [r[k] for r in sel if r[k] is not None]
            return round(sum(vals) / len(vals), 1) if vals else None
        out = {"min_c": mean("min_c"), "max_c": mean("max_c"), "ground_min_c": mean("ground_min_c"),
               "ground_max_c": mean("ground_max_c"), "pressure_pa": mean("pressure_pa"), "n_sols": len(sel),
               "ls_window": [round((ls - half_width) % 360, 1), round((ls + half_width) % 360, 1)]}
    if len(_clim) > 2048:
        _clim.clear()
    _clim[key] = out
    return dict(out) if out is not None else None


def summary(mission: str, current_sol: int) -> dict:
    if mission not in FEEDS:
        return {"available": False, "reason": f"no public weather feed for {mission}"}
    out = summarize(rows_for(mission), current_sol)
    if out.get("available"):
        out.update(mission=mission, instrument=INSTRUMENTS.get(mission, out["instrument"]),
                   source=SOURCES.get(mission, out["source"]))
    return out
