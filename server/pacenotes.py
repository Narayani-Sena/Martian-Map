"""Pace notes (feature D3): a co-driver's notes built from the route's profile.

"60 m: boulders left, keep right, then 12 degrees up for 40 m". Each walking leg is read from start to end:
climbs and descents steeper than 8 deg, hazardous or sandy ground, boulders of a metre or more within 12 m of the
line (and on which side), terrain shadow, radio shadow and turns sharper than 35 deg. The same events, as bands at
their distance, make the strip map on the cuff.
"""

from __future__ import annotations

import math

import numpy as np

STEEP_DEG = 8.0
TURN_DEG = 35.0
BOULDER_M = 1.0
BOULDER_NEAR_M = 12.0


def _runs(mask: np.ndarray, d: np.ndarray, min_len: float) -> list[tuple[float, float, int, int]]:
    out = []
    i = 0
    n = len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j + 1 < n and mask[j + 1]:
                j += 1
            if d[j] - d[i] >= min_len:
                out.append((float(d[i]), float(d[j]), i, j))
            i = j + 1
        else:
            i += 1
    return out


def leg_notes(rows: list[dict], boulders_xy: np.ndarray | None, xy_of, round_to: int = 10) -> list[dict]:
    """Notes for one leg's rows (dicts with d, slope, grade, hazard, sand, comms, sunlit, lon, lat)."""
    if len(rows) < 2:
        return []
    d = np.array([r["d"] for r in rows]) - rows[0]["d"]
    grade = np.array([r["grade"] for r in rows])
    slope_dir = np.degrees(np.arctan(grade))
    hz = np.array([r["hazard"] for r in rows])
    sand = np.array([r["sand"] for r in rows])
    comms = np.array([r["comms"] for r in rows])
    shade = np.array([not r.get("sunlit", True) for r in rows])
    xs, ys = xy_of(np.array([r["lon"] for r in rows]), np.array([r["lat"] for r in rows]))
    notes = []

    def add(at, kind, text):
        notes.append({"d": round(at / round_to) * round_to, "kind": kind, "text": text})

    # smooth the grade over ~10 m so single cells don't make notes
    k = max(1, int(round(10.0 / max(1e-6, np.median(np.diff(d)) if len(d) > 2 else 2.0))))
    sm = np.convolve(slope_dir, np.ones(k) / k, mode="same")
    for a, b, i, j in _runs(sm > STEEP_DEG, d, 15.0):
        add(a, "climb", f"{np.max(sm[i:j + 1]):.0f}° up for {b - a:.0f} m")
    for a, b, i, j in _runs(sm < -STEEP_DEG, d, 15.0):
        add(a, "descent", f"{-np.min(sm[i:j + 1]):.0f}° down for {b - a:.0f} m, short steps")
    for a, b, i, j in _runs(hz >= 3, d, 6.0):
        add(a, "hazard", f"hazardous ground for {b - a:.0f} m, slow")
    for a, b, i, j in _runs(sand >= 0.6, d, 15.0):
        add(a, "sand", f"loose sand for {b - a:.0f} m")
    for a, b, i, j in _runs(comms == 0, d, 15.0):
        add(a, "radio", f"radio shadow for {b - a:.0f} m")
    for a, b, i, j in _runs(shade, d, 20.0):
        add(a, "shade", f"terrain shadow for {b - a:.0f} m")
    # turns: heading change over ~15 m
    hd = np.degrees(np.arctan2(np.gradient(xs), np.gradient(ys)))
    step = max(2, int(round(15.0 / max(1e-6, np.median(np.diff(d)) if len(d) > 2 else 2.0))))
    last_turn = -1e9
    for i in range(step, len(d) - step, step):
        dh = (hd[min(len(d) - 1, i + step)] - hd[i - step] + 180.0) % 360.0 - 180.0
        if abs(dh) >= TURN_DEG and d[i] - last_turn > 25.0:
            add(d[i], "turn", f"{'right' if dh > 0 else 'left'} {abs(dh):.0f}°")
            last_turn = d[i]
    # boulders near the line, and on which side
    if boulders_xy is not None and len(boulders_xy):
        big = boulders_xy[boulders_xy[:, 2] >= BOULDER_M]
        if len(big):
            seen = set()
            for i in range(0, len(d), 3):
                dx = big[:, 0] - xs[i]
                dy = big[:, 1] - ys[i]
                near = np.flatnonzero(dx * dx + dy * dy <= BOULDER_NEAR_M ** 2)
                if near.size == 0:
                    continue
                j = int(near[np.argmax(big[near, 2])])
                key = (round(float(big[j, 0]) / 15), round(float(big[j, 1]) / 15))
                if key in seen:
                    continue
                seen.add(key)
                hx, hy = math.sin(math.radians(hd[i])), math.cos(math.radians(hd[i]))
                side = "left" if hx * dy[j] - hy * dx[j] > 0 else "right"
                add(d[i], "boulder", f"{big[j, 2]:.1f} m boulder {side}, keep {'right' if side == 'left' else 'left'}")
    notes.sort(key=lambda n: n["d"])
    # merge notes at the same distance: "60 m: boulder left, keep right, then 12° up for 40 m"
    merged = []
    for n in notes:
        if merged and n["d"] - merged[-1]["d"] <= 10:
            merged[-1]["text"] += f", then {n['text']}"
            merged[-1]["kinds"].append(n["kind"])
        else:
            merged.append({**n, "kinds": [n["kind"]]})
    return merged


def for_plan(site, rows: list[dict], legs: list[dict]) -> list[dict]:
    """Pace notes for every walking leg of a plan (rows from eva.build_timeline)."""
    b = site.boulders
    bxy = None
    if b is not None and len(b):
        bxy = np.asarray(b[:, :3], float)  # x, y (site metres), diameter
    out = []
    for i, L in enumerate(legs):
        lr = [r for r in rows if r["leg"] == i and not r.get("working")]
        notes = leg_notes(lr, bxy, site.grid.lonlat_to_xy)
        out.append({"leg": i, "from": L["from"], "to": L["to"], "dist_m": L["dist_m"],
                    "notes": [{"d": n["d"], "text": f"{n['d']:.0f} m: {n['text']}", "kinds": n["kinds"]} for n in notes]})
    return out
