"""When something fails out there (feature A3, B3, B4).

A3 · The shrinking world. In a suit-leak or CO2 drill, where can the crew still walk to *and* get home from?
     needed(c) = walk from the crew to c + (walk from c to the nearest haven) x return factor + reserve.
     The world is every cell with needed(c) <= the minutes of oxygen left; as the oxygen drops, it tightens, and
     the havens drop out one by one. In normal use the same sum from the hab gives a time bank per place: the
     minutes the crew could spend there.
B3 · Partner down. Minutes until an injured crew member is back in pressure: carried home by the other (slow,
     gentle slopes only), or PR-2 driving out to the nearest drivable cell to meet them.
B4 · Caches at the gateways. Where a few emergency oxygen bottles (or relays) do the most good: the places that
     put the most of the site within a short emergency walk of a haven. The candidates are the ways-home
     gateways (A1) and other high-flow cells; the pick is greedy on real walk-back fields.

All times are planning estimates from the same walking model as the route planner; nothing here is a medical or
operational rule.
"""

from __future__ import annotations

import io
import math
import time
from dataclasses import replace

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.sparse.csgraph import dijkstra

from . import walkback as wb
from .walkmodel import WalkParams

# Buddy carry: one suited astronaut carrying (or dragging on a litter) another. Planning numbers: a third of normal
# walking speed, and only gentle slopes.
CARRY_SPEED_FACTOR = 0.33
CARRY_MAX_SLOPE = 14.0
CARRY_CAUTION_SLOPE = 7.0
RESCUE_LIMIT_MIN = 60.0  # flag routes where an injured crew member could be more than an hour from pressure
EMERGENCY_O2_MIN = 30.0  # Apollo's Oxygen Purge System gave about 30 minutes: the emergency walk-back budget


def snap_passable(mult4: np.ndarray, r: int, c: int, rad: int = 25) -> tuple[int, int]:
    """The nearest cell (within rad) that is not no-go."""
    H, W = mult4.shape
    r = min(max(r, 0), H - 1)
    c = min(max(c, 0), W - 1)
    if np.isfinite(mult4[r, c]):
        return r, c
    r0, r1, c0, c1 = max(0, r - rad), min(H, r + rad + 1), max(0, c - rad), min(W, c + rad + 1)
    yy, xx = np.nonzero(np.isfinite(mult4[r0:r1, c0:c1]))
    if yy.size == 0:
        return r, c
    k = int(np.argmin((yy + r0 - r) ** 2 + (xx + c0 - c) ** 2))
    return int(yy[k] + r0), int(xx[k] + c0)


class Graphs:
    """The 4 m walking graph per set of limits (built once, ~0.5 s), and the fields computed on it."""

    def __init__(self, site):
        self.site = site
        self._g: dict = {}

    def get(self, p: WalkParams):
        k = p.key()
        if k not in self._g:
            mult4 = wb.coarsen_multiplier(self.site.multiplier(p))
            self._g[k] = (wb.reverse_graph(self.site.z4, mult4, self.site.grid4.res, p), mult4)
            while len(self._g) > 3:
                self._g.pop(next(iter(self._g)))
        return self._g[k]

    def forward(self, lon: float, lat: float, p: WalkParams) -> np.ndarray:
        """Seconds to walk from (lon, lat) to every cell."""
        key = f"fwd|{lon:.6f},{lat:.6f}|{p.key()}"
        return self.site.fields.get(key, lambda: self._forward(lon, lat, p))

    def _forward(self, lon, lat, p):
        g, mult4 = self.get(p)
        r, c = (int(round(float(v))) for v in self.site.grid4.lonlat_to_rowcol(lon, lat))
        r, c = snap_passable(mult4, r, c)
        return wb.forward_field(self.site.z4, mult4, self.site.grid4.res, (r, c), p, graph=g)

    def to_point(self, lon: float, lat: float, p: WalkParams) -> np.ndarray:
        """Seconds to walk from every cell to (lon, lat) (Dijkstra on the reversed graph)."""
        key = f"rev|{lon:.6f},{lat:.6f}|{p.key()}"
        return self.site.fields.get(key, lambda: self._to_point(lon, lat, p))

    def _to_point(self, lon, lat, p):
        g, mult4 = self.get(p)
        r, c = (int(round(float(v))) for v in self.site.grid4.lonlat_to_rowcol(lon, lat))
        r, c = snap_passable(mult4, r, c)
        H, W = mult4.shape
        return dijkstra(g, directed=True, indices=r * W + c).reshape(H, W).astype(np.float32)


def graphs(site) -> Graphs:
    g = getattr(site, "_graphs", None)
    if g is None:
        g = site._graphs = Graphs(site)
    return g


def encode_minutes(m: np.ndarray) -> bytes:
    """Minutes (float, inf = impossible) as a PNG the browser can read back: R = high byte, G = low byte of
    minutes x 10 (up to 6,553 min), A = 0 where impossible."""
    fin = np.isfinite(m)
    v = np.clip(np.where(fin, m, 0) * 10.0, 0, 65535).astype(np.uint16)
    rgba = np.zeros(m.shape + (4,), np.uint8)
    rgba[..., 0] = (v >> 8).astype(np.uint8)
    rgba[..., 1] = (v & 255).astype(np.uint8)
    rgba[..., 3] = np.where(fin, 255, 0).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, "PNG", compress_level=6)
    return buf.getvalue()


# ------------------------------------------------------------------ A3: the shrinking world
def envelope(site, crew: tuple[float, float], havens: list[dict], p: WalkParams, return_factor: float = 1.25,
             reserve_min: float = 30.0) -> dict:
    t0 = time.perf_counter()
    G = graphs(site)
    out_s = G.forward(crew[0], crew[1], p)
    tree = site.flow(havens, p)
    back_s = tree.dist
    needed = out_s / 60.0 + back_s / 60.0 * return_factor + reserve_min
    walkable = np.isfinite(back_s)
    hv = []
    for h, (r, c) in zip(havens, tree.haven_rc):
        o = float(out_s[r, c]) / 60.0
        hv.append({"name": h["name"], "lon": h["lon"], "lat": h["lat"], "walk_min": round(o, 1) if math.isfinite(o) else None,
                   "needs_min": round(o * return_factor + reserve_min, 1) if math.isfinite(o) else None})
    res = site.grid4.res
    return {"needed": needed.astype(np.float32), "walkable_cells": int(walkable.sum()), "cell_ha": res * res / 1e4,
            "havens": hv, "return_factor": return_factor, "reserve_min": reserve_min,
            "compute_ms": round((time.perf_counter() - t0) * 1000.0, 1)}


def envelope_stats(env: dict, minutes_left: float) -> dict:
    inside = env["needed"] <= minutes_left
    n = int(inside.sum())
    return {"minutes_left": minutes_left, "area_ha": round(n * env["cell_ha"], 1),
            "share_of_walkable": round(n / max(1, env["walkable_cells"]), 3),
            "havens_in_reach": [h["name"] for h in env["havens"] if h["needs_min"] is not None and h["needs_min"] <= minutes_left]}


def time_bank(site, hab: dict, p: WalkParams, minutes_at_egress: float, lon: float, lat: float,
              return_factor: float = 1.25, reserve_min: float = 30.0) -> float | None:
    """Minutes the crew could spend at (lon, lat): what is left after walking there from the hab and back home."""
    G = graphs(site)
    out_s = G.forward(hab["lon"], hab["lat"], p)
    back_s = site.flow([hab], p).dist
    r, c = (int(round(float(v))) for v in site.grid4.lonlat_to_rowcol(lon, lat))
    H, W = out_s.shape
    if not (0 <= r < H and 0 <= c < W):
        return None
    o, b = float(out_s[r, c]), float(back_s[r, c])
    if not (math.isfinite(o) and math.isfinite(b)):
        return None
    return round(minutes_at_egress - o / 60.0 - b / 60.0 * return_factor - reserve_min, 1)


# ------------------------------------------------------------------ B3: partner down
def carry_params(p: WalkParams) -> WalkParams:
    return replace(p, flat_speed=max(0.2, p.flat_speed * CARRY_SPEED_FACTOR), max_slope=CARRY_MAX_SLOPE,
                   caution_slope=CARRY_CAUTION_SLOPE, hazard_aversion=max(1.5, p.hazard_aversion), load_kg=0.0)


def rescue(site, havens: list[dict], p: WalkParams, rover_base: dict | None, drive=None, suitport_min: float = 10.0,
           airlock_min: float = 15.0) -> dict:
    """Minutes until an injured crew member is back in pressure, from every cell: the faster of a buddy carry to
    the nearest haven and PR-2 driving out to meet them."""
    t0 = time.perf_counter()
    cp = carry_params(p)
    carry = site.flow(havens, cp).dist / 60.0 + airlock_min  # carried home, then through the airlock / suitport
    best = carry.copy()
    mode = np.where(np.isfinite(carry), 1, 0).astype(np.uint8)  # 0 none, 1 carry, 2 PR-2
    out = {"carry_ok_share": round(float(np.isfinite(carry).mean()), 3)}
    if rover_base is not None and drive is not None:
        G = graphs(site)
        dfield = G.forward(rover_base["lon"], rover_base["lat"], drive) / 60.0  # PR-2 to every drivable cell
        drivable = np.isfinite(dfield)
        # meet at the nearest drivable cell: carry the short way there (straight line at carry speed)
        dist_px, (ir, ic) = ndimage.distance_transform_edt(~drivable, return_indices=True)
        hop_min = dist_px * site.grid4.res / (cp.v_flat() * 60.0)
        meet_drive = dfield[ir, ic]
        pr2 = np.maximum(meet_drive, hop_min) + suitport_min + 2.0  # whoever arrives first waits; 2 min to load
        pr2 = np.where(dist_px * site.grid4.res > 400, np.inf, pr2)  # more than 400 m from any drivable ground: no
        better = pr2 < best
        best = np.where(better, pr2, best)
        mode = np.where(better & np.isfinite(pr2), 2, mode).astype(np.uint8)
        out["pr2_share"] = round(float((mode == 2).mean()), 3)
    out.update({"minutes": best.astype(np.float32), "mode": mode, "compute_ms": round((time.perf_counter() - t0) * 1000.0, 1)})
    return out


def rescue_on_route(site, res: dict, rows_lonlat: np.ndarray) -> dict:
    """The worst case along a route: the point where an injured crew member would be longest from pressure."""
    r, c = site.grid4.lonlat_to_rowcol(rows_lonlat[:, 0], rows_lonlat[:, 1])
    H, W = res["minutes"].shape
    ri = np.clip(np.rint(r).astype(int), 0, H - 1)
    ci = np.clip(np.rint(c).astype(int), 0, W - 1)
    v = res["minutes"][ri, ci]
    m = res["mode"][ri, ci]
    fin = np.isfinite(v)
    if not fin.any():
        return {"worst_min": None}
    k = int(np.argmax(np.where(fin, v, -1)))
    return {"worst_min": round(float(v[k]), 1), "worst_lon": float(rows_lonlat[k, 0]), "worst_lat": float(rows_lonlat[k, 1]),
            "worst_mode": {1: "buddy carry", 2: "PR-2 rescue"}.get(int(m[k]), "none"),
            "unreachable_points": int((~fin).sum()), "limit_min": RESCUE_LIMIT_MIN,
            "level": "ok" if v[k] <= RESCUE_LIMIT_MIN else "caution"}


RESCUE_LEGEND = {"unit": "minutes until an injured crew member is back in pressure", "stops": [[15, "#1a9850"], [30, "#a6d96a"], [45, "#fee08b"],
                                                                                                [60, "#fdae61"], [90, "#d73027"], [150, "#67001f"]]}


def rescue_rgba(res: dict, size: int | None = None) -> Image.Image:
    from .tiles import LUTS, lut, _hex
    ramp = lut([(0.0, _hex("1a9850", 120)), (0.1, _hex("a6d96a", 130)), (0.2, _hex("fee08b", 150)), (0.3, _hex("fdae61", 170)),
                (0.45, _hex("d73027", 190)), (1.0, _hex("67001f", 210))])
    m = res["minutes"]
    idx = np.clip(np.nan_to_num(m, nan=1e9, posinf=1e9) / 200.0 * 255, 0, 255).astype(np.uint8)
    rgba = ramp[idx]
    rgba[~np.isfinite(m)] = (40, 0, 30, 170)
    # PR-2 cells get a fine hatch so the two modes read apart
    yy, xx = np.mgrid[0:m.shape[0], 0:m.shape[1]]
    hatch = (res["mode"] == 2) & (((yy + xx) // 3) % 2 == 0)
    rgba[hatch, 3] = np.minimum(255, rgba[hatch, 3].astype(int) + 60).astype(np.uint8)
    im = Image.fromarray(rgba, "RGBA")
    return im.resize((size, size), Image.NEAREST) if size else im


# ------------------------------------------------------------------ B4: caches at the gateways
def place_caches(site, havens: list[dict], p: WalkParams, k: int = 3, budget_min: float = EMERGENCY_O2_MIN,
                 route_lonlat: np.ndarray | None = None, n_candidates: int = 14) -> dict:
    """Greedy placement of k caches that put the most ground (or route) within budget_min of a haven."""
    t0 = time.perf_counter()
    tree = site.flow(havens, p)
    back = tree.dist / 60.0
    walkable = np.isfinite(back)
    H, W = back.shape
    if route_lonlat is not None and len(route_lonlat):
        r, c = site.grid4.lonlat_to_rowcol(route_lonlat[:, 0], route_lonlat[:, 1])
        target = np.zeros((H, W), bool)
        target[np.clip(np.rint(r).astype(int), 0, H - 1), np.clip(np.rint(c).astype(int), 0, W - 1)] = True
        objective = "route"
    else:
        target = walkable
        objective = "site"
    n_t = max(1, int(target.sum()))
    # candidates: gateways at several thresholds, plus the highest-flow cells far from home
    cands = []
    for frac in (0.05, 0.025, 0.012):
        for g in tree.gateways(n=8, min_frac=frac, min_minutes=budget_min * 0.4, min_sep_m=180.0):
            if all(math.hypot(g["lon"] - x["lon"], g["lat"] - x["lat"]) > 1e-4 for x in cands):
                cands.append({"lon": g["lon"], "lat": g["lat"], "from": f"gateway ({round(g['share'] * 100)} % of the site)",
                              "minutes": g["minutes"]})
    cands = cands[:n_candidates]
    G = graphs(site)
    fields = [G.to_point(cd["lon"], cd["lat"], p) / 60.0 for cd in cands]
    cur = back.copy()
    before = float((target & (cur <= budget_min)).sum()) / n_t
    picked = []
    for _ in range(k):
        best_gain, best_j = 0.0, -1
        base = float((target & (cur <= budget_min)).sum())
        for j, f in enumerate(fields):
            if any(pk["j"] == j for pk in picked):
                continue
            gain = float((target & (np.minimum(cur, f) <= budget_min)).sum()) - base
            if gain > best_gain:
                best_gain, best_j = gain, j
        if best_j < 0:
            break
        cur = np.minimum(cur, fields[best_j])
        cd = cands[best_j]
        picked.append({"j": best_j, "name": f"Cache {len(picked) + 1}", "lon": cd["lon"], "lat": cd["lat"], "why": cd["from"],
                       "minutes_from_home": cd["minutes"], "gain_share": round(best_gain / n_t, 3),
                       "gain_ha": round(best_gain * site.grid4.res ** 2 / 1e4, 1) if objective == "site" else None})
    after = float((target & (cur <= budget_min)).sum()) / n_t
    for pk in picked:
        pk.pop("j")
    return {"caches": picked, "objective": objective, "budget_min": budget_min, "coverage_before": round(before, 3),
            "coverage_after": round(after, 3), "candidates": len(cands), "compute_ms": round((time.perf_counter() - t0) * 1000.0, 1)}


def coverage(site, havens: list[dict], p: WalkParams, budget_min: float, route_lonlat: np.ndarray | None = None) -> dict:
    back = site.flow(havens, p).dist / 60.0
    ok = back <= budget_min
    out = {"site": round(float(ok.sum()) / max(1, int(np.isfinite(back).sum())), 3), "area_ha": round(float(ok.sum()) * site.grid4.res ** 2 / 1e4, 1)}
    if route_lonlat is not None and len(route_lonlat):
        r, c = site.grid4.lonlat_to_rowcol(route_lonlat[:, 0], route_lonlat[:, 1])
        H, W = back.shape
        v = back[np.clip(np.rint(r).astype(int), 0, H - 1), np.clip(np.rint(c).astype(int), 0, W - 1)]
        out["route"] = round(float((v <= budget_min).mean()), 3)
    return out
