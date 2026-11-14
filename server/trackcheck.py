"""Ground truth from the rover: how much of the rover's real drive inside the site our walking map calls passable.

A rover only drives where its team judged the ground safe, so its track is a sample of ground that is known to be
crossable. Every metre of that track our hazard map calls no-go is a false alarm (or a position error), and the
share of the track in each hazard class, set against the share of the whole site in that class, says whether the
classes pick out the ground a real vehicle chose to cross.

The rover's track is in the site's map frame already (pipeline/rover.py moved it by the measured frame shift).
Rover positions still carry a metre or two of error, so the check is also made with a tolerance: the easiest class
within `tolerance_m` of each point.
"""

from __future__ import annotations

import json

import numpy as np

from .walkmodel import BOULDER_NO_GO_M, WalkParams

CLASSES = ["easy", "moderate", "difficult", "hazardous", "no-go"]
STEP_M = 1.0          # the track is sampled every metre
MAX_SPOTS = 60        # no-go stretches returned for the map


def track_lines(site_dir) -> list[np.ndarray]:
    """The rover's track inside the site as (lon, lat) polylines."""
    p = site_dir / "rover_traverse.geojson"
    if not p.exists():
        return []
    fc = json.loads(p.read_text())
    out = []
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        coords = g.get("coordinates") or []
        parts = [coords] if g.get("type") == "LineString" else coords if g.get("type") == "MultiLineString" else []
        for c in parts:
            if len(c) >= 2:
                out.append(np.asarray(c, float)[:, :2])
    return out


def densify(xy: np.ndarray, step: float = STEP_M) -> tuple[np.ndarray, np.ndarray]:
    """Points every `step` metres along a polyline (segment midpoints) and the length each stands for."""
    seg = np.diff(xy, axis=0)
    seg_len = np.hypot(seg[:, 0], seg[:, 1])
    pts, w = [], []
    for i, L in enumerate(seg_len):
        if not L > 0:
            continue
        n = max(1, int(np.ceil(L / step)))
        t = (np.arange(n) + 0.5) / n
        pts.append(xy[i] + seg[i] * t[:, None])
        w.append(np.full(n, L / n))
    if not pts:
        return np.zeros((0, 2)), np.zeros(0)
    return np.concatenate(pts), np.concatenate(w)


def _reasons(site, p: WalkParams) -> dict[str, np.ndarray]:
    """Why a 2 m cell is no-go: one boolean grid per cause (a cell can have several)."""
    r = {"slope": (site.slope2 > p.max_slope) | ~np.isfinite(site.slope2),
         "roughness": site.rough2 > p.max_rough}
    if site.boulder2 is not None:
        r["boulder"] = site.boulder2 >= BOULDER_NO_GO_M
    return r


def check(site, p: WalkParams | None = None, tolerance_m: float = 2.0) -> dict:
    """Shares of the rover's track per hazard class (exact and within `tolerance_m`), against the whole site."""
    p = p or WalkParams()
    rover = site.cfg.get("rover_name") or "the rover"
    lines = track_lines(site.dir)
    if not lines:
        return {"available": False, "rover": rover, "note": f"No {rover} track inside this site."}
    from scipy import ndimage

    g = site.grid2
    haz = site.hazard(p)
    H, W = haz.shape
    k = max(0, int(round(tolerance_m / g.res)))
    haz_tol = ndimage.minimum_filter(haz, size=2 * k + 1) if k else haz
    reasons = _reasons(site, p)

    total = 0.0
    by = np.zeros(5)
    by_tol = np.zeros(5)
    why = {name: 0.0 for name in list(reasons) + ["crew tag"]}
    spots = []
    longest = 0.0
    for line in lines:
        x, y = g.lonlat_to_xy(line[:, 0], line[:, 1])
        pts, w = densify(np.column_stack([x, y]))
        if not len(pts):
            continue
        r, c = g.xy_to_rowcol(pts[:, 0], pts[:, 1])
        ri, ci = np.rint(r).astype(int), np.rint(c).astype(int)
        inside = (ri >= 0) & (ri < H) & (ci >= 0) & (ci < W)
        pts, w, ri, ci = pts[inside], w[inside], ri[inside], ci[inside]
        if not len(pts):
            continue
        cls = haz[ri, ci]
        total += float(w.sum())
        by += np.bincount(cls, weights=w, minlength=5)[:5]
        by_tol += np.bincount(haz_tol[ri, ci], weights=w, minlength=5)[:5]
        nogo = cls == 4
        tagged = nogo.copy()
        for name, grid in reasons.items():
            hit = nogo & grid[ri, ci]
            why[name] += float(w[hit].sum())
            tagged &= ~grid[ri, ci]
        why["crew tag"] += float(w[tagged].sum())
        # stretches of consecutive no-go points along the drive
        edges = np.flatnonzero(np.diff(np.concatenate([[0], nogo.astype(np.int8), [0]])))
        for a, b in zip(edges[::2], edges[1::2]):
            length = float(w[a:b].sum())
            longest = max(longest, length)
            mid = (a + b - 1) // 2
            cause = [n for n, grid in reasons.items() if grid[ri[mid], ci[mid]]] or ["crew tag"]
            lon, lat = g.xy_to_lonlat(pts[mid, 0], pts[mid, 1])
            spots.append({"lon": round(float(lon), 7), "lat": round(float(lat), 7), "length_m": round(length, 1),
                          "cause": cause, "slope_deg": round(float(site.slope2[ri[mid], ci[mid]]), 1),
                          "boulder_m": (round(float(site.boulder2[ri[mid], ci[mid]]), 1)
                                        if site.boulder2 is not None else None)})
    if total <= 0:
        return {"available": False, "rover": rover, "note": f"No {rover} track inside this site."}

    valid = np.isfinite(site.slope2)
    site_share = np.bincount(haz[valid].ravel(), minlength=5)[:5] / max(1, int(valid.sum()))
    track_share = by / total
    track_tol = by_tol / total
    spots.sort(key=lambda s: -s["length_m"])
    nogo_site = float(site_share[4])
    nogo_track = float(track_share[4])
    return {
        "available": True,
        "rover": rover,
        "mission": site.cfg.get("mission"),
        "track_m": round(total, 1),
        "lines": len(lines),
        "tolerance_m": tolerance_m,
        "classes": CLASSES,
        "track_share": [round(float(v), 4) for v in track_share],
        "track_share_tolerant": [round(float(v), 4) for v in track_tol],
        "site_share": [round(float(v), 4) for v in site_share],
        "passable_share": round(1.0 - nogo_track, 4),
        "passable_share_tolerant": round(1.0 - float(track_tol[4]), 4),
        # how much rarer no-go ground is under the wheels than across the site (> 1: the map and the drivers agree)
        "nogo_rarity": round(nogo_site / nogo_track, 1) if nogo_track > 0 else None,
        "nogo_m_by_cause": {k: round(v, 1) for k, v in why.items() if v > 0},
        "longest_nogo_m": round(longest, 1),
        "spots": spots[:MAX_SPOTS],
        "limits": {"max_slope_deg": p.max_slope, "max_rough_m": p.max_rough, "boulder_no_go_m": BOULDER_NO_GO_M},
        "summary": summary_line(rover, total, 1.0 - nogo_track, 1.0 - float(track_tol[4]), nogo_site, nogo_track,
                                tolerance_m),
    }


def summary_line(rover: str, total_m: float, passable: float, passable_tol: float, nogo_site: float,
                 nogo_track: float, tol: float) -> str:
    s = (f"{rover} drove {total_m / 1000:.2f} km inside this site; our walking map calls {passable * 100:.1f} % of "
         f"that track passable ({passable_tol * 100:.1f} % within {tol:g} m, allowing for position error). ")
    if nogo_track > 0:
        s += (f"No-go ground covers {nogo_site * 100:.0f} % of the site but {nogo_track * 100:.1f} % of the track: "
              f"{nogo_site / nogo_track:.0f} times rarer where the rover chose to drive.")
    else:
        s += f"None of the track crosses no-go ground ({nogo_site * 100:.0f} % of the site is no-go)."
    return s
