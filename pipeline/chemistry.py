"""Rover chemistry at the targets (feature E2): what the rocks at a stop are made of.

Gale: ChemCam LIBS major-oxide compositions (the MOC tables, PLS + ICA, the team's calibration after Clegg et al.
2017) from the PDS Geosciences Node, one row per laser point, with the oxide weight percents, the distance to the
target and the spacecraft clock. Jezero: SuperCam LIBS major-oxide compositions (supercam_libs_moc.csv in the
SuperCam bundle's derived-spectra collection, calibration after Anderson et al. 2022), one row per point, the sol and
target in the file name. A row has no position, so each target is placed where the rover stood on that sol (the last
waypoint on or before it): both instruments reach about 7 m, so a pin is good to roughly 10 m, and the app says so.
Targets of the same sol are spread on a small ring round that point so they can be told apart.
"""

from __future__ import annotations

import csv
import io
import json
import math
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

from marsgeo import mars24
from marsgeo.grid import SiteGrid

MOC_DIR = "https://pds-geosciences.wustl.edu/msl/msl-m-chemcam-libs-4_5-rdr-v1/mslccm_1xxx/data/moc/"
SUPERCAM_MOC = "https://pds-geosciences.wustl.edu/m2020/urn-nasa-pds-mars2020_supercam/data_derived_spectra/supercam_libs_moc.csv"
OXIDES = ("SiO2", "TiO2", "Al2O3", "FeOT", "MgO", "CaO", "Na2O", "K2O", "MnO")
J2000 = datetime(2000, 1, 1, 11, 58, 55, 816000, tzinfo=timezone.utc)   # MSL's spacecraft clock counts from here
RING_M = 4.0
CAL_TARGET = re.compile(r"(?i)^\s*(scct|ccct|cct\b|cal[ _-]?target|calib)")
SOURCE = ("ChemCam LIBS major-oxide compositions (MOC), MSL ChemCam RDR, PDS Geosciences Node "
          "(NASA/JPL-Caltech/LANL/CNES/IRAP)")
SOURCE_SUPERCAM = ("SuperCam LIBS major-oxide compositions (supercam_libs_moc.csv), Mars 2020 SuperCam bundle, "
                   "PDS Geosciences Node (NASA/JPL-Caltech/LANL/CNES/IRAP)")


def sol_of_sclk(sclk: float, lon_east: float, landing_msd_local: int) -> int:
    """Curiosity's mission sol for a spacecraft clock reading (seconds since J2000)."""
    utc = J2000 + timedelta(seconds=float(sclk))
    return mars24.mission_sol(mars24.mars_time(utc), lon_east, landing_msd_local)


def moc_files(listing_html: str, sol0: int, sol1: int) -> list[str]:
    """The MOC tables whose sol range overlaps sol0..sol1, from the archive's directory listing."""
    out = []
    for a, b in sorted({(int(x), int(y)) for x, y in re.findall(r"moc_(\d+)_(\d+)\.csv", listing_html)}):
        if b >= sol0 and a <= sol1:
            out.append(f"moc_{a}_{b}.csv")
    return out


def parse_moc(text: str) -> list[dict]:
    """Rows of one MOC table: {target, sclk, oxides{...}, total, dist_m}. The table starts after a block of test-set
    quartiles; its header line begins with "File,Target"."""
    lines = text.splitlines()
    try:
        hi = next(i for i, ln in enumerate(lines) if ln.startswith("File,Target"))
    except StopIteration:
        return []
    rows = []
    for rec in csv.DictReader(io.StringIO("\n".join(lines[hi:]))):
        m = re.search(r"CL5_(\d{9})", rec.get("File") or "")
        if not m:
            continue
        try:
            ox = {k: float(rec[k]) for k in OXIDES}
            total = float(rec.get("Sum of Oxides") or "nan")
            dist = float(rec.get("Distance (m)") or "nan")
        except (TypeError, ValueError, KeyError):
            continue
        rows.append({"target": (rec.get("Target") or "").strip(), "sclk": int(m.group(1)), "oxides": ox, "total": total, "dist_m": dist})
    return rows


def parse_supercam(text: str) -> list[dict]:
    """Rows of SuperCam's MOC table: {target, sol, oxides{...}, total, dist_m}. The header line begins with
    "cdr_fname"; a file name looks like scam_0012_0668002890_477_cl1_scam15210_maaz_____01p (sol 12, target maaz)."""
    lines = text.splitlines()
    try:
        hi = next(i for i, ln in enumerate(lines) if ln.startswith("cdr_fname,"))
    except StopIteration:
        return []
    rows = []
    for rec in csv.DictReader(io.StringIO("\n".join(lines[hi:]))):
        m = re.match(r"scam_(\d{4})_\d+_\d+_cl\d_scam\d+_(.+?)_*\d+p$", (rec.get("cdr_fname") or "").strip())
        if not m:
            continue
        try:
            ox = {k: float(rec[k]) for k in OXIDES if rec.get(k) not in (None, "")}
            total = float(rec.get("Total") or "nan")
            dist = float(rec.get("distance_mm") or "nan") / 1000.0
        except (TypeError, ValueError):
            continue
        name = m.group(2).strip("_").replace("_", " ").title()
        rows.append({"target": name, "sol": int(m.group(1)), "oxides": ox, "total": total, "dist_m": dist})
    return rows


def group_targets(rows: list[dict], lon_east: float, landing_msd_local: int) -> list[dict]:
    """Points -> targets: the mean composition of each (target, sol), with the spread of SiO2 between points.
    A row gives its sol, or a spacecraft clock (ChemCam) to work it out from."""
    groups: dict = {}
    for r in rows:
        if CAL_TARGET.match(r["target"]):   # the rover's own calibration targets, not Mars rocks
            continue
        sol = r["sol"] if r.get("sol") is not None else sol_of_sclk(r["sclk"], lon_east, landing_msd_local)
        groups.setdefault((r["target"], sol), []).append(r)
    out = []
    for (name, sol), rs in groups.items():
        keys = [k for k in OXIDES if all(k in r["oxides"] for r in rs)]
        ox = {k: round(float(np.mean([r["oxides"][k] for r in rs])), 2) for k in keys}
        tot = [r["total"] for r in rs if math.isfinite(r["total"])]
        dist = [r["dist_m"] for r in rs if math.isfinite(r["dist_m"])]
        out.append({"name": name, "sol": int(sol), "n_points": len(rs), "oxides": ox,
                    "sio2_spread": round(float(np.std([r["oxides"]["SiO2"] for r in rs])), 2),
                    "total": round(float(np.mean(tot)), 1) if tot else None,
                    "dist_m": round(float(np.mean(dist)), 2) if dist else None})
    out.sort(key=lambda t: (t["sol"], t["name"]))
    return out


def rover_position(waypoints: list[tuple[int, float, float]], sol: int) -> tuple[float, float] | None:
    """Where the rover stood on a sol: the last waypoint on or before it (waypoints sorted by sol)."""
    best = None
    for s, lon, lat in waypoints:
        if s > sol:
            break
        best = (lon, lat)
    return best


def place(targets: list[dict], waypoints: list[tuple[int, float, float]], grid: SiteGrid) -> list[dict]:
    """Give each target the rover's position on its sol (inside the site only), spread on a ring per sol."""
    lon0, lat0, lon1, lat1 = grid.bounds_lonlat()
    by_sol: dict = {}
    for t in targets:
        p = rover_position(waypoints, t["sol"])
        if p is None or not (lon0 <= p[0] <= lon1 and lat0 <= p[1] <= lat1):
            continue
        by_sol.setdefault(t["sol"], []).append((t, p))
    out = []
    for sol, items in by_sol.items():
        n = len(items)
        for k, (t, (lon, lat)) in enumerate(items):
            x, y = grid.lonlat_to_xy(lon, lat)
            if n > 1:
                a = 2.0 * math.pi * k / n
                x, y = x + RING_M * math.sin(a), y + RING_M * math.cos(a)
            plon, plat = grid.xy_to_lonlat(x, y)
            out.append({**t, "lon": round(float(plon), 7), "lat": round(float(plat), 7),
                        "rover_lon": round(float(lon), 7), "rover_lat": round(float(lat), 7)})
    out.sort(key=lambda t: (t["sol"], t["name"]))
    return out


def load_waypoints(path: Path) -> list[tuple[int, float, float]]:
    fc = json.loads(path.read_text(encoding="utf-8"))
    out = []
    for f in fc.get("features", []):
        sol = (f.get("properties") or {}).get("sol")
        c = (f.get("geometry") or {}).get("coordinates") or []
        if sol is None or len(c) < 2:
            continue
        out.append((int(sol), float(c[0]), float(c[1])))
    out.sort(key=lambda w: w[0])
    return out


def build(out_dir: Path, cfg: dict, grid: SiteGrid, cache: Path, session=None) -> dict | None:
    """chemistry.json: the rover's LIBS targets whose sol puts it inside the site (ChemCam at Gale, SuperCam at
    Jezero). None for other missions or without the rover's waypoints."""
    mission = cfg.get("mission")
    if mission not in ("MSL", "M20"):
        return None
    wp_path = out_dir / "rover_waypoints.geojson"
    if not wp_path.exists():
        return None
    wps = load_waypoints(wp_path)
    lon0, lat0, lon1, lat1 = grid.bounds_lonlat()
    sols = [s for s, lon, lat in wps if lon0 <= lon <= lon1 and lat0 <= lat <= lat1]
    if not sols:
        return None
    if session is None:
        from marsgeo.net import session as _s
        session = _s()
    cache.mkdir(parents=True, exist_ok=True)

    def fetch(url: str, name: str) -> str:
        p = cache / name
        if not p.exists():
            r = session.get(url, timeout=180)
            r.raise_for_status()
            p.write_bytes(r.content)
        return p.read_text(encoding="utf-8", errors="replace")

    rows = []
    if mission == "MSL":
        files = moc_files(session.get(MOC_DIR, timeout=60).text, min(sols), max(sols))
        for name in files:
            rows.extend(parse_moc(fetch(MOC_DIR + name, name)))
        instrument, source, rover = "ChemCam LIBS", SOURCE, "Curiosity"
    else:
        files = ["supercam_libs_moc.csv"]
        rows = [r for r in parse_supercam(fetch(SUPERCAM_MOC, files[0])) if min(sols) - 1 <= r["sol"] <= max(sols) + 1]
        instrument, source, rover = "SuperCam LIBS", SOURCE_SUPERCAM, "Perseverance"
    landing = int(cfg["rover"].get("landing_msd_local", 0))
    targets = place(group_targets(rows, grid.lon0, landing), wps, grid)
    doc = {"instrument": instrument, "source": source, "files": files, "oxides": list(OXIDES), "rover": rover,
           "placement": f"Each target is drawn where {rover} stood on that sol (the laser reaches about 7 m); "
                        "targets of one sol are spread on a 4 m ring.",
           "sols": [min(sols), max(sols)], "targets": targets}
    (out_dir / "chemistry.json").write_text(json.dumps(doc, indent=1), encoding="utf-8")
    return {"instrument": doc["instrument"], "n_targets": len(targets), "files": files,
            "sols": [min(t["sol"] for t in targets), max(t["sol"] for t in targets)] if targets else None}
