"""Plan it for me (feature C3): three EVAs that collect the most science inside the margins, stops in the best order.

Today the planner walks the stops in the order given, and the default EVA uses about half the suit. Here:

1. Candidates: the strongest places on the science-opportunity layer (pipeline/science.py) inside the walk-back
   limit, kept 150 m apart, plus the crew's own stops (it may keep, reorder or drop them).
2. Walking times between every pair, on the 4 m walking graph (one multi-source Dijkstra; direction-aware, so
   up and down hill differ).
3. An orienteering search: randomised cheapest-insertion by science per minute, then 2-opt, best of many restarts,
   under a time-in-suits budget (airlock both ways + walking + work at each stop) and a walk-back limit.
4. Each EVA is then planned for real (A* routes, suit simulation, GO / NO-GO).

Variants: safe (75 % of the time asked for, walk-back <= 30 min), balanced (90 %, <= 45 min), bold (100 %, <= 60 min).
"""

from __future__ import annotations

import math
import random
import time

import numpy as np
from scipy import ndimage
from scipy.sparse.csgraph import dijkstra

from . import envelope as envlib
from .walkmodel import WalkParams

VARIANTS = [
    {"id": "safe", "name": "Safe", "budget_frac": 0.75, "wb_limit_min": 30.0},
    {"id": "balanced", "name": "Balanced", "budget_frac": 0.90, "wb_limit_min": 45.0},
    {"id": "bold", "name": "Bold", "budget_frac": 1.00, "wb_limit_min": 60.0},
]
DWELL = {"ridge": 30, "hollow": 20, "contact": 30, "outcrop": 25}


def candidates(site, hab: dict, p: WalkParams, user_stops: list[dict], max_wb_min: float, n: int = 14, min_sep_m: float = 150.0,
               suggest=None) -> list[dict]:
    """Science candidates inside the walk-back limit (best first) plus the user's own stops."""
    sc = site.science["score"]
    H, W = sc.shape
    wb = site.walkback((hab["lon"], hab["lat"]), p)["field"]
    wb2 = np.repeat(np.repeat(wb, 2, axis=0), 2, axis=1)[:H, :W]
    hz = site.hazard(p)
    ok = np.isfinite(wb2) & (wb2 <= max_wb_min * 60.0) & (hz <= 2)
    val = ndimage.uniform_filter(np.where(ok, sc, 0.0).astype(np.float32), 7)
    val[~ok] = 0.0
    rr, cc = np.ogrid[:H, :W]
    sep = min_sep_m / site.grid2.res
    r0, c0 = site.grid2.lonlat_to_rowcol(hab["lon"], hab["lat"])
    val[(rr - r0) ** 2 + (cc - c0) ** 2 < (60.0 / site.grid2.res) ** 2] = 0.0
    out = []
    for st in user_stops:
        r, c = (int(round(float(v))) for v in site.grid2.lonlat_to_rowcol(st["lon"], st["lat"]))
        r, c = min(max(r, 0), H - 1), min(max(c, 0), W - 1)
        s = float(ndimage.uniform_filter(sc[max(0, r - 6):r + 7, max(0, c - 6):c + 7].astype(np.float32), 7).max()) if sc.size else 0.0
        out.append({**st, "score": round(max(s, 0.05), 3), "dwell_min": float(st.get("dwell_min", 20)), "source": "yours"})
        val[(rr - r) ** 2 + (cc - c) ** 2 < sep ** 2] = 0.0
    k = 0
    while len(out) < n + len(user_stops):
        i = int(np.argmax(val))
        r, c = divmod(i, W)
        if val[r, c] < 0.12:
            break
        lon, lat = (float(v) for v in site.grid2.rowcol_to_lonlat(r, c))
        info = suggest(site, lon, lat, r, c, chr(ord("A") + k)) if suggest else {"name": f"Site {chr(65 + k)}", "kind": "outcrop"}
        out.append({"id": f"AP{k + 1}", "name": info["name"], "kind": info["kind"], "lon": round(lon, 7), "lat": round(lat, 7),
                    "dwell_min": float(DWELL.get(info["kind"], 25)), "tasks": info.get("tasks", []), "score": round(float(val[r, c]), 3),
                    "science": info.get("science", ""), "source": "science layer"})
        val[(rr - r) ** 2 + (cc - c) ** 2 < sep ** 2] = 0.0
        k += 1
    return out


def time_matrix(site, pts: list[dict], p: WalkParams, limit_s: float = 4 * 3600.0) -> np.ndarray:
    """Minutes to walk from pts[i] to pts[j] on the 4 m graph (inf = no way)."""
    G = envlib.graphs(site)
    g, mult4 = G.get(p)
    H, W = mult4.shape
    idx = []
    for q in pts:
        r, c = (int(round(float(v))) for v in site.grid4.lonlat_to_rowcol(q["lon"], q["lat"]))
        r, c = envlib.snap_passable(mult4, r, c)
        idx.append(r * W + c)
    d = dijkstra(g.T.tocsr(), directed=True, indices=idx, limit=limit_s)  # forward: from each point to every cell
    return (d[:, idx] / 60.0).astype(np.float64)


def _route_time(order: list[int], T: np.ndarray, dwell: np.ndarray) -> float:
    path = [0] + order + [0]
    return float(sum(T[a, b] for a, b in zip(path[:-1], path[1:])) + dwell[order].sum())


def _two_opt(order: list[int], T: np.ndarray) -> list[int]:
    best = order[:]
    improved = True
    while improved and len(best) >= 3:
        improved = False
        for i in range(len(best) - 1):
            for j in range(i + 1, len(best)):
                cand = best[:i] + best[i:j + 1][::-1] + best[j + 1:]
                if _route_time(cand, T, np.zeros(T.shape[0])) + 1e-9 < _route_time(best, T, np.zeros(T.shape[0])):
                    best, improved = cand, True
    return best


def orienteer(T: np.ndarray, score: np.ndarray, dwell: np.ndarray, budget_min: float, allowed: np.ndarray,
              restarts: int = 160, seed: int = 11) -> tuple[list[int], float, float]:
    """Order of candidate indices (1..n; 0 = the hab) maximising the science collected within budget_min."""
    rng = random.Random(seed)
    n = T.shape[0]
    best, best_s, best_t = [], 0.0, 0.0
    for rep in range(restarts):
        order: list[int] = []
        noise = 0.0 if rep == 0 else 0.35
        while True:
            cur_t = _route_time(order, T, dwell)
            pick = None
            for c in range(1, n):
                if c in order or not allowed[c] or score[c] <= 0:
                    continue
                path = [0] + order + [0]
                for k in range(len(path) - 1):
                    a, b = path[k], path[k + 1]
                    dt = T[a, c] + dwell[c] + T[c, b] - T[a, b]
                    if not math.isfinite(dt) or cur_t + dt > budget_min:
                        continue
                    ratio = score[c] / max(dt, 1.0) * (1.0 + noise * (rng.random() - 0.5))
                    if pick is None or ratio > pick[0]:
                        pick = (ratio, c, k)
            if pick is None:
                break
            order.insert(pick[2], pick[1])
            order = _two_opt(order, T)
        s = float(score[order].sum()) if order else 0.0
        t = _route_time(order, T, dwell)
        if s > best_s + 1e-9 or (abs(s - best_s) <= 1e-9 and t < best_t):
            best, best_s, best_t = order, s, t
    return best, best_s, best_t


def plan_variants(site, hab: dict, p: WalkParams, suit_budget_min: float, user_stops: list[dict], airlock_min: float = 15.0,
                  suggest=None, user_suit_min: float | None = None) -> dict:
    t0 = time.perf_counter()
    cands = candidates(site, hab, p, user_stops, max(v["wb_limit_min"] for v in VARIANTS), suggest=suggest)
    pts = [{"lon": hab["lon"], "lat": hab["lat"]}] + cands
    T = time_matrix(site, pts, p)
    score = np.array([0.0] + [c["score"] for c in cands])
    dwell = np.array([0.0] + [c["dwell_min"] for c in cands])
    wb = np.array([0.0] + [T[i, 0] for i in range(1, len(pts))])  # walk back from each stop to the hab
    out = []
    for v in VARIANTS:
        budget = suit_budget_min * v["budget_frac"] - 2 * airlock_min
        allowed = wb <= v["wb_limit_min"]
        order, s, t = orienteer(T, score, dwell, budget, allowed)
        out.append({**v, "order": order, "stops": [cands[i - 1] for i in order], "science": round(s, 3),
                    "est_suit_min": round(t + 2 * airlock_min, 1), "budget_min": round(budget + 2 * airlock_min, 1)})
    same = None
    if user_suit_min:  # the acceptance check: the planner's science at the same time in suits as the hand-picked EVA
        order, s, t = orienteer(T, score, dwell, user_suit_min - 2 * airlock_min, wb <= 60.0)
        user_score = float(sum(c["score"] for c in cands if c["source"] == "yours"))
        same = {"user_suit_min": round(user_suit_min, 1), "user_science": round(user_score, 3), "planner_science": round(s, 3),
                "planner_stops": [cands[i - 1]["name"] for i in order], "est_suit_min": round(t + 2 * airlock_min, 1)}
    return {"variants": out, "candidates": cands, "same_time": same, "suit_budget_min": suit_budget_min,
            "compute_ms": round((time.perf_counter() - t0) * 1000.0, 1)}
