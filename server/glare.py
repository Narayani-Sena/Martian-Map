"""Sun in your eyes (feature B5): per leg, the sun against the heading.

* Low sun ahead (below 25 deg, within 35 deg of the heading): glare in the visor, rocks and holes hide in it.
* Sun right behind (within 25 deg of straight back, above 10 deg): flat light. With no shadows the relief
  disappears; Apollo crews met this walking down-sun ("zero-phase" washout).

The planner reports the minutes of each and tries the same loop walked the other way round.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import numpy as np

from marsgeo import mars24

GLARE_ELEV_MAX = 25.0
GLARE_HALF_DEG = 35.0
FLAT_HALF_DEG = 25.0
FLAT_ELEV_MIN = 10.0


def _rel(a: float, b: float) -> float:
    return (a - b + 180.0) % 360.0 - 180.0


def classify(sun_el: float, sun_az: float, heading: float) -> str | None:
    if sun_el <= 0:
        return None
    rel = _rel(sun_az, heading)
    if sun_el < GLARE_ELEV_MAX and abs(rel) <= GLARE_HALF_DEG:
        return "glare"
    if sun_el > FLAT_ELEV_MIN and abs(_rel(rel, 180.0)) <= FLAT_HALF_DEG:
        return "flat"
    return None


def _headings(path: list) -> np.ndarray:
    a = np.asarray(path, float)
    if len(a) < 2:
        return np.zeros(len(a))
    lat = np.radians(a[:, 1])
    d_lon = np.radians(np.diff(a[:, 0]))
    y = np.sin(d_lon) * np.cos(lat[1:])
    x = np.cos(lat[:-1]) * np.sin(lat[1:]) - np.sin(lat[:-1]) * np.cos(lat[1:]) * np.cos(d_lon)
    h = np.degrees(np.arctan2(y, x)) % 360.0
    return np.append(h, h[-1])


def leg_minutes(start: datetime, lat0: float, lon0: float, legs: list[dict], t0s: list[float], step_m: float = 20.0) -> list[dict]:
    """Minutes of glare and flat light on each leg (walking at the leg's average pace, sampled every step_m)."""
    out = []
    for L, t0 in zip(legs, t0s):
        path = L["path"]
        a = np.asarray(path, float)
        if len(a) < 2:
            out.append({"glare_min": 0.0, "flat_min": 0.0})
            continue
        heads = _headings(path)
        seg = np.hypot(np.diff(a[:, 0]) * np.cos(np.radians(lat0)), np.diff(a[:, 1])) * 59274.0  # deg -> m, roughly (Mars)
        dist = np.concatenate([[0.0], np.cumsum(seg)])
        total = max(dist[-1], 1.0)
        pace = float(L["time_s"]) / total
        g = f = 0.0
        for d in np.arange(0.0, total, step_m):
            k = min(int(np.searchsorted(dist, d, side="right")) - 1, len(heads) - 1)
            when = start + timedelta(seconds=float(t0 + d * pace))
            el, az, _ = mars24.sun_position(mars24.mars_time(when), lat0, lon0)
            kind = classify(el, az, float(heads[k]))
            if kind == "glare":
                g += step_m * pace
            elif kind == "flat":
                f += step_m * pace
        out.append({"glare_min": round(float(g) / 60.0, 1), "flat_min": round(float(f) / 60.0, 1)})
    return out


def check(start: datetime, lat0: float, lon0: float, legs: list[dict], events: list[dict]) -> dict:
    walks = [e for e in events if e["kind"] == "walk"]
    t0s = [float(e["t0"]) for e in walks]
    fwd = leg_minutes(start, lat0, lon0, legs, t0s)
    # the same loop the other way: legs reversed, each walked backwards, starting when the first leg started
    rev_legs = [{**L, "path": L["path"][::-1]} for L in legs[::-1]]
    gaps = [float(b["t0"]) - float(a["t1"]) for a, b in zip(walks[:-1], walks[1:])][::-1]  # stops, mirrored
    t = t0s[0] if t0s else 0.0
    rt0 = []
    for i, L in enumerate(rev_legs):
        rt0.append(t)
        t += float(L["time_s"]) + (gaps[i] if i < len(gaps) else 0.0)
    rev = leg_minutes(start, lat0, lon0, rev_legs, rt0)
    g1, f1 = sum(x["glare_min"] for x in fwd), sum(x["flat_min"] for x in fwd)
    g2, f2 = sum(x["glare_min"] for x in rev), sum(x["flat_min"] for x in rev)
    return {"legs": fwd, "glare_min": round(g1, 1), "flat_min": round(f1, 1), "reversed": {"glare_min": round(g2, 1), "flat_min": round(f2, 1)},
            "reverse_better": bool((g2 + 0.5 * f2) + 2.0 < (g1 + 0.5 * f1))}


def issue(chk: dict, legs: list[dict]) -> dict | None:
    if chk["glare_min"] < 3 and chk["flat_min"] < 5:
        return None
    worst = max(range(len(chk["legs"])), key=lambda i: chk["legs"][i]["glare_min"] + 0.5 * chk["legs"][i]["flat_min"])
    L = legs[worst]
    parts = []
    if chk["glare_min"] >= 3:
        parts.append(f"{chk['glare_min']:.0f} min walking into a low sun (glare in the visor)")
    if chk["flat_min"] >= 5:
        parts.append(f"{chk['flat_min']:.0f} min with the sun straight behind (flat light hides the relief)")
    text = "; ".join(parts) + f", most on {L['from']} → {L['to']}"
    if chk["reverse_better"]:
        r = chk["reversed"]
        text += f". Walked the other way round: {r['glare_min']:.0f} min glare, {r['flat_min']:.0f} min flat light"
    return {"level": "info", "kind": "sun_glare", "text": text}
