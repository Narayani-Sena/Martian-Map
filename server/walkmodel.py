"""How fast a suited astronaut walks on Mars terrain, and what it costs them.

Speed: Tobler's hiking function, rescaled to a suited flat-ground speed.
    v(S) = v_flat * exp(-3.5 * (|S + 0.05| - 0.05)),  S = rise/run
Fastest on a gentle 5 % downhill, ~40 % of flat speed on a 15 deg climb.

Terrain cost multiplier (>= 1, inf = no-go) adds a safety margin for steep,
rough or sandy cells so routes keep clear of hazards rather than skimming them.

Metabolic rate (watts) drives the oxygen / CO2 / battery / water simulation.
Carried equipment (tools, sample bags, instruments) slows the walker a little and
raises the metabolic cost in proportion to the total mass moved (Pandolf-style).
All numbers are planning assumptions and are shown in the app.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, fields

import numpy as np

from marsgeo.constants import MARS_GRAVITY

TOBLER_K = 3.5
TOBLER_OPT = -0.05
SPEED_FACTOR_MAX = math.exp(TOBLER_K * abs(TOBLER_OPT))  # ~1.19 (gentle downhill)

CREW_MASS_KG = 80.0
SUIT_MASS_KG = 65.0  # Mars-class suit + life support backpack
LOAD_SPEED_K = 0.004  # -0.4 % walking speed per kg carried (gentle in 0.38 g, but mass still has inertia)
BOULDER_NO_GO_M = 2.0  # boulders this wide are walked around, never over


@dataclass(frozen=True)
class WalkParams:
    flat_speed: float = 0.8  # m/s on level, smooth ground in a suit (~2.9 km/h)
    max_slope: float = 25.0  # deg: cells steeper than this are no-go
    caution_slope: float = 15.0  # deg: safety penalty starts here
    max_rough: float = 0.55  # m RMS (plane-fit residual over 5 m): blockier ground is no-go
    sand_penalty: float = 0.6  # +60 % time in (likely) loose sand
    hazard_aversion: float = 1.0  # 0 = shortest-time, 2 = very cautious
    load_kg: float = 8.0  # tools, sample bags and instruments carried (Earth-mass kg)

    # Mobility hooks shared by the router, the walk-back field and leg evaluation. Class attributes
    # (not fields), so a vehicle (server/rover.py DriveParams) can bring its own limits.
    BOULDER_MAX = BOULDER_NO_GO_M  # m: cells with a boulder this wide are no-go
    BOULDER_PAD = 0  # cells of clearance kept around those boulders
    BOULDER_COST = 1.2  # extra cost per metre of boulder over 0.5 m

    @classmethod
    def from_dict(cls, d: dict | None) -> "WalkParams":
        d = d or {}
        kw = {}
        for f in fields(cls):
            if f.name in d and d[f.name] is not None:
                kw[f.name] = float(d[f.name])
        p = cls(**kw)
        if not (0.2 <= p.flat_speed <= 2.5):
            raise ValueError("flat_speed must be 0.2-2.5 m/s")
        if not (5 <= p.max_slope <= 45):
            raise ValueError("max_slope must be 5-45 deg")
        if not (0 <= p.load_kg <= 60):
            raise ValueError("load_kg must be 0-60 kg")
        return p

    def key(self) -> str:
        return "w" + "_".join(f"{getattr(self, f.name):g}" for f in fields(self))

    def to_dict(self) -> dict:
        return asdict(self)

    def v_flat(self) -> float:
        """Flat-ground speed actually achieved with the carried load (m/s)."""
        return self.flat_speed / (1.0 + LOAD_SPEED_K * self.load_kg)

    def grade_factor(self, grade):
        """Speed relative to flat ground on a grade (rise/run); Tobler for walkers."""
        return speed_factor(grade)

    def max_factor(self) -> float:
        """Largest grade_factor anywhere (keeps the A* heuristic admissible)."""
        return SPEED_FACTOR_MAX


def speed_factor(grade):
    """Tobler speed relative to flat ground (array or scalar)."""
    return np.exp(-TOBLER_K * (np.abs(np.asarray(grade, dtype=float) - TOBLER_OPT) - abs(TOBLER_OPT)))


def cell_multiplier(p: WalkParams, slope: np.ndarray, rough: np.ndarray, sand: np.ndarray,
                    boulder: np.ndarray | None = None) -> np.ndarray:
    span = max(1e-3, p.max_slope - p.caution_slope)
    over = np.clip((slope - p.caution_slope) / span, 0.0, None)
    m = 1.0 + p.hazard_aversion * (1.5 * over ** 2 + 2.0 * np.clip(rough - 0.15, 0.0, None)) + p.sand_penalty * sand
    if boulder is not None:
        pad = int(getattr(p, "BOULDER_PAD", 0))
        if pad > 0:  # a wide vehicle needs clearance on both sides of a boulder
            from scipy import ndimage
            boulder = ndimage.maximum_filter(boulder, size=2 * pad + 1)
        m = m + p.hazard_aversion * getattr(p, "BOULDER_COST", 1.2) * np.clip(boulder - 0.5, 0.0, None)
    m = m.astype(np.float32)
    nogo = (slope > p.max_slope) | (rough > p.max_rough) | ~np.isfinite(slope)
    if boulder is not None:
        nogo |= boulder >= getattr(p, "BOULDER_MAX", BOULDER_NO_GO_M)
    m[nogo] = np.inf
    return m


def isotropic_seconds_per_meter(p: WalkParams, slope_deg: np.ndarray, mult: np.ndarray) -> np.ndarray:
    """Direction-free cost for algorithms that only know a cost per cell (MCP).

    Uses the mean of the up- and down-hill travel times along the steepest direction.
    """
    s = np.tan(np.radians(slope_deg))
    t = 0.5 / (p.v_flat() * p.grade_factor(s)) + 0.5 / (p.v_flat() * p.grade_factor(-s))
    return (t * mult).astype(np.float64)


def step_time(dist: float, dz: float, m_a: float, m_b: float, p: WalkParams) -> float:
    grade = dz / dist
    return dist / (p.v_flat() * float(p.grade_factor(grade))) * 0.5 * (m_a + m_b)


# ------------------------------------------------------------------ metabolism
def metabolic_watts(speed, grade, working: bool = False, load_kg: float = 0.0):
    """Metabolic rate in watts for a suited astronaut on Mars.

    Standing ~180 W, brisk level walking ~400 W, plus the work of lifting body +
    suit + load against Mars gravity (25 % muscle efficiency). The walking term
    scales with the total mass moved. Field work ~330 W (Apollo EVA averages were
    ~250-300 W), a little more when handling heavy kit.
    """
    if working:
        return 330.0 + 1.2 * load_kg
    speed = np.asarray(speed, dtype=float)
    grade = np.asarray(grade, dtype=float)
    mass = CREW_MASS_KG + SUIT_MASS_KG + load_kg
    weight_n = mass * MARS_GRAVITY
    base = 180.0 + 230.0 * (speed / 0.8) * (mass / (CREW_MASS_KG + SUIT_MASS_KG))
    lift = np.where(grade > 0, weight_n * speed * grade / 0.25, weight_n * speed * (-grade) * 0.3)
    return base + lift
