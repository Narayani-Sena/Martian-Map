"""Scout first (feature C1): fly a helicopter over the stretches where GO depends on uncertain data.

The plan already knows where it stands on shaky data: terrain where our DTM and the rover team's disagree, and
possibly sandy ground where the sand clues disagree (data-use item D7). Here those stretches of the route are listed,
a helicopter flight is planned over them (Ingenuity scouted Seitah for Perseverance's drivers in 2021), and the plan
is checked again as if the flight had happened: inside the camera's swath the confidence is raised and the walking
speed is better known, so the margin range narrows.

The flight's result is SIMULATED (a perfect look at the ground); the app says so. Helicopter numbers follow
Ingenuity: 10 m up, 5 m/s, at most ~700 m of ground track per flight; its navigation camera saw about 1.4x its
altitude to either side.
"""

from __future__ import annotations

import math

import numpy as np

ALT_M = 10.0
SPEED_MS = 5.0
MAX_FLIGHT_M = 700.0
SWATH_HALF_M = 1.4 * ALT_M
TAKEOFF_S = 30.0


def stretches(profile: dict, min_len_m: float = 8.0, merge_gap_m: float = 25.0) -> list[dict]:
    """Runs of the route on uncertain data: terrain confidence < 0.5, or likely sand (>= 0.3) the clues disagree on."""
    d = np.asarray(profile["d"], float)
    tc = np.array([v if v is not None else 1.0 for v in profile["terrain_conf"]], float)
    sc = np.asarray(profile["sand_conf"], float)
    sand = np.asarray(profile["sand"], float)
    bad_t = tc < 0.5
    bad_s = (sand >= 0.3) & (sc < 0.3)
    bad = bad_t | bad_s
    out = []
    i, n = 0, len(d)
    while i < n:
        if bad[i]:
            j = i
            while j + 1 < n:
                if bad[j + 1]:
                    j += 1
                    continue
                # bridge a short gap to the next uncertain sample (one flight line, not many)
                k = j + 1
                while k < n and not bad[k] and d[k] - d[j] <= merge_gap_m:
                    k += 1
                if k < n and bad[k] and d[k] - d[j] <= merge_gap_m:
                    j = k
                    continue
                break
            if d[j] - d[i] >= min_len_m:
                kind = "terrain and sand" if bad_t[i:j + 1].any() and bad_s[i:j + 1].any() else ("terrain" if bad_t[i:j + 1].any() else "sand")
                pts = [[profile["lon"][k], profile["lat"][k]] for k in range(i, j + 1)]
                out.append({"d0": round(float(d[i]), 1), "d1": round(float(d[j]), 1), "length_m": round(float(d[j] - d[i]), 1),
                            "kind": kind, "path": pts, "leg": int(profile["leg"][i])})
            i = j + 1
        else:
            i += 1
    return out


def flight_plan(xy_of, lonlat_of, pad: dict, runs: list[dict]) -> dict:
    """Fly from the pad over every stretch (nearest first) and back; split into flights of <= MAX_FLIGHT_M."""
    if not runs:
        return {"flights": [], "total_m": 0.0, "air_s": 0.0}
    px, py = (float(v) for v in xy_of(pad["lon"], pad["lat"]))
    todo = list(range(len(runs)))
    cur = (px, py)
    track = [cur]
    while todo:
        k = min(todo, key=lambda i: math.hypot(float(xy_of(*runs[i]["path"][0])[0]) - cur[0], float(xy_of(*runs[i]["path"][0])[1]) - cur[1]))
        todo.remove(k)
        for lon, lat in runs[k]["path"][::2] + [runs[k]["path"][-1]]:
            x, y = (float(v) for v in xy_of(lon, lat))
            track.append((x, y))
        cur = track[-1]
    track.append((px, py))
    # split into flights: each flight leaves the pad's side of the track and comes back down where it ends
    flights, cur_f, length = [], [track[0]], 0.0
    for a, b in zip(track[:-1], track[1:]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if length + seg > MAX_FLIGHT_M and len(cur_f) > 1:
            flights.append(cur_f)
            cur_f, length = [a], 0.0
        cur_f.append(b)
        length += seg
    flights.append(cur_f)
    out, total = [], 0.0
    for f in flights:
        L = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(f[:-1], f[1:]))
        total += L
        ll = [[round(float(v), 7) for v in lonlat_of(x, y)] for x, y in f]
        out.append({"path": ll, "length_m": round(L, 1), "air_s": round(L / SPEED_MS + TAKEOFF_S, 0)})
    return {"flights": out, "total_m": round(total, 1), "air_s": round(sum(f["air_s"] for f in out), 0),
            "altitude_m": ALT_M, "swath_half_m": SWATH_HALF_M, "speed_ms": SPEED_MS}


def scouted_fraction(profile: dict, runs: list[dict]) -> float:
    """Share of the route's length the flight covers (the uncertain stretches)."""
    d = np.asarray(profile["d"], float)
    total = max(float(d[-1]), 1.0) if len(d) else 1.0
    return min(1.0, sum(r["length_m"] for r in runs) / total)
