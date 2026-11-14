"""Rover-assisted EVA: the pressurized rover PR-2 drives the crew out and back.

The crew rides in shirt-sleeves, egresses through the rover's suitports at a drop-off point,
walks its stations, and climbs back in. Three things change compared with a walk from the hab:

* drive legs use the rover's own limits (gentler slopes, smoother ground, no big boulders,
  a wide track) and speed, routed with the same A* as the walkers;
* suit consumables are only used between suitport egress and ingress;
* the safe haven for the walk-back rule is the parked rover, not the hab, and the rover's mast
  is one more radio node.

The planning numbers follow NASA's Small Pressurized Rover / Space Exploration Vehicle
concepts (suitports, ~10 km/h top speed, water-wall storm shelter) and are shown in the app.
"""

from __future__ import annotations

from dataclasses import dataclass, fields

import numpy as np

from .walkmodel import WalkParams

NAME = "PR-2"
SUITPORT_MIN = 10.0  # suitport egress or ingress (the hab airlock takes 15)
ANTENNA_M = 3.5  # the rover's radio mast: a relay for the walkers near it
CABIN_MET_W = 120.0  # seated crew; the suits hang on the suitports and are topped up
CABIN_GCR_FACTOR = 0.7  # pressure hull + kit: ~30 % less cosmic-ray dose than outside
CABIN_SEP_FACTOR = 0.1  # the water-wall storm shelter stops ~90 % of a solar particle event
PARK_MAX_SLOPE = 8.0  # deg: level enough to park and work the suitports
STANDOFF_M = 40.0  # park at least this far from a science stop (tracks, outgassing)


@dataclass(frozen=True)
class DriveParams(WalkParams):
    """PR-2 mobility limits (planning values)."""

    flat_speed: float = 2.0  # m/s cruise over unprepared ground (~7 km/h; the SPR tops out near 10)
    max_slope: float = 20.0
    caution_slope: float = 12.0
    max_rough: float = 0.35  # metre-scale relief the suspension can take
    sand_penalty: float = 1.5  # wheels dig into loose sand (Spirit's fate)
    hazard_aversion: float = 1.0
    load_kg: float = 0.0

    BOULDER_MAX = 1.0  # m: ground clearance; wider boulders are driven around
    BOULDER_PAD = 1  # ~4 m track: keep one 2 m cell of clearance around them
    BOULDER_COST = 2.5

    @classmethod
    def from_dict(cls, d: dict | None) -> "DriveParams":
        d = d or {}
        p = cls(**{f.name: float(d[f.name]) for f in fields(cls) if d.get(f.name) is not None})
        if not (0.3 <= p.flat_speed <= 4.0):
            raise ValueError("rover speed must be 0.3-4 m/s")
        if not (5 <= p.max_slope <= 30):
            raise ValueError("rover max_slope must be 5-30 deg")
        return p

    def key(self) -> str:
        return "d" + "_".join(f"{getattr(self, f.name):g}" for f in fields(self))

    def v_flat(self) -> float:
        return self.flat_speed

    def grade_factor(self, grade):
        """Power-limited on climbs, brake-limited on descents: ~40 % speed at 20 deg up."""
        g = np.asarray(grade, dtype=float)
        return 1.0 / (1.0 + np.where(g >= 0, 4.0 * g, -3.0 * g))

    def max_factor(self) -> float:
        return 1.0

    def limits(self) -> dict:
        return {"boulder_max_m": self.BOULDER_MAX, "clearance_cells": self.BOULDER_PAD}


def choose_dropoff(site, hab: dict, stops: list[dict], walk: WalkParams, drive: DriveParams) -> dict | None:
    """Where to park: a level spot the rover can reach that keeps the walking short.

    Score per 4 m cell (seconds): walk out to the first stop and back from the last one, plus half the
    walk from the farthest stop (the walk-back rule), plus a quarter of the drive time (driving costs
    no suit consumables but still uses daylight). Straight-line walking with a 1.3 detour factor.
    """
    if not stops:
        return None
    g4 = site.grid4
    drive_s = site.walkback((hab["lon"], hab["lat"]), drive)["field"]
    H, W = drive_s.shape
    slope4 = site.slope2[: H * 2: 2, : W * 2: 2][:H, :W]
    ok = np.isfinite(drive_s) & (slope4 < PARK_MAX_SLOPE)
    rr, cc = np.nonzero(ok)
    if rr.size == 0:
        return None
    srs = [g4.lonlat_to_rowcol(st["lon"], st["lat"]) for st in stops]
    d = np.stack([g4.res * np.hypot(rr - sr, cc - sc) for sr, sc in srs])  # (stops, cells) metres
    keep = d.min(axis=0) >= STANDOFF_M
    if not keep.any():
        return None
    rr, cc, d = rr[keep], cc[keep], d[:, keep]
    v = walk.v_flat() / 1.3
    score = (d[0] + d[-1]) / v + 0.5 * d.max(axis=0) / v + 0.25 * drive_s[rr, cc]
    k = int(np.argmin(score))
    lon, lat = g4.rowcol_to_lonlat(float(rr[k]), float(cc[k]))
    return {"lon": round(float(lon), 7), "lat": round(float(lat), 7), "auto": True,
            "drive_s": round(float(drive_s[rr[k], cc[k]]), 1), "farthest_stop_m": round(float(d[:, k].max()), 1)}


def track(legs: list[dict], t0s: list[float], max_pts: int = 400) -> dict:
    """Rover position over the EVA clock: [{t, lonlat}] per drive leg -> flat t/lon/lat lists."""
    out = {"t": [], "lon": [], "lat": []}
    for ev, t0 in zip(legs, t0s):
        n = len(ev["t"])
        step = max(1, n // max_pts)
        idx = list(range(0, n, step))
        if idx[-1] != n - 1:
            idx.append(n - 1)
        for i in idx:
            out["t"].append(round(t0 + float(ev["t"][i]), 1))
            out["lon"].append(round(float(ev["lonlat"][i][0]), 7))
            out["lat"].append(round(float(ev["lonlat"][i][1]), 7))
    return out
