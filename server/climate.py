"""Approximate surface climate for a low-latitude Mars site (shaped on Gale crater, adapted per site).

This is a *climatology* model (typical conditions for the season and hour),
not a forecast. Shapes and ranges follow published REMS (Curiosity) results:
air ~-85 C before dawn to ~-5 C mid-afternoon in southern summer (perihelion,
Ls ~250-270), ~10 C colder in winter; pressure ~730-905 Pa over the year as
the polar CO2 caps grow and shrink; dustier skies in the perihelion season.

Other sites (set with `with at_site(lat, elev_m):`): surface pressure scales with elevation
(scale height 11.1 km), and the seasonal temperature swing follows the site's own noon
insolation (latitude and Mars' eccentric orbit) instead of Gale's southern-summer phase.
"""

from __future__ import annotations

import contextvars
import math
from contextlib import contextmanager

import numpy as np

# Optional per-request calibration: fn(ls) -> {min_c, max_c, ground_min_c, ground_max_c, pressure_pa} or None.
# Set with `with calibrated(fn):` for sites that have measured weather (Gale: Curiosity REMS).
_CAL = contextvars.ContextVar("climate_calibration", default=None)


@contextmanager
def calibrated(fn):
    token = _CAL.set(fn)
    try:
        yield
    finally:
        _CAL.reset(token)


def calibration(ls: float):
    fn = _CAL.get()
    if fn is None:
        return None
    try:
        return fn(ls)
    except Exception:  # feed missing/offline -> fall back to the model
        return None

# Where the request's site is: (latitude deg, elevation m). None = Gale itself.
_SITE = contextvars.ContextVar("climate_site", default=None)
GALE_LAT, GALE_ELEV_M = -4.6, -4500.0
SCALE_HEIGHT_M = 11100.0
OBLIQUITY, ECC, LS_PERIHELION = 25.19, 0.0934, 251.0


@contextmanager
def at_site(lat: float, elev_m: float):
    token = _SITE.set((float(lat), float(elev_m)))
    try:
        yield
    finally:
        _SITE.reset(token)


def _noon_insolation(ls: float, lat: float) -> float:
    """Relative noon insolation: sun height at noon times the 1/r^2 of Mars' orbit."""
    dec = math.asin(math.sin(math.radians(OBLIQUITY)) * math.sin(math.radians(ls)))
    inv_r2 = ((1 + ECC * math.cos(math.radians(ls - LS_PERIHELION))) / (1 - ECC * ECC)) ** 2
    return max(0.0, math.cos(math.radians(lat) - dec)) * inv_r2


_SEASON_CACHE: dict = {}


def _season_for_lat(ls: float, lat: float) -> float:
    """Season factor (about -1..+1) from the site's insolation, scaled like Gale's swing."""
    key = round(lat, 1)
    if key not in _SEASON_CACHE:
        grid = [_noon_insolation(x, lat) for x in range(0, 360, 5)]
        gale = [_noon_insolation(x, GALE_LAT) for x in range(0, 360, 5)]
        _SEASON_CACHE[key] = (sum(grid) / len(grid), (max(gale) - min(gale)) / 2)
    mean, half = _SEASON_CACHE[key]
    return max(-1.4, min(1.4, (_noon_insolation(ls, lat) - mean) / half))


# Daily-mean surface pressure through the year (Ls deg, Pa), shaped like REMS at Gale.
_P_TABLE = [(0, 845), (30, 830), (60, 800), (90, 765), (120, 735), (150, 725), (180, 760),
            (210, 830), (240, 895), (260, 905), (290, 880), (330, 850), (360, 845)]

GCR_MSV_PER_DAY = 0.64  # RAD at Gale, Hassler et al. 2014 (solar-cycle average)
SOLAR_MAX_FACTOR = 0.85  # GCR is ~15 % lower near solar maximum (2024-2026)


def _season(ls: float) -> float:
    """+1 near perihelion / southern summer (warm at Gale), -1 at aphelion; per site elsewhere."""
    site = _SITE.get()
    if site is None or abs(site[0] - GALE_LAT) < 1.5:
        return math.cos(math.radians(ls - 260.0))
    return _season_for_lat(ls, site[0])


def dust_tau(ls: float) -> float:
    def bump(center, width, amp):
        d = (ls - center + 180) % 360 - 180
        return amp * math.exp(-(d / width) ** 2)
    return 0.45 + bump(240, 45, 0.45) + bump(320, 20, 0.25)


def _diurnal(t: float, tmin: float, tmax: float, t_lo: float = 5.8, t_hi: float = 14.2) -> float:
    t %= 24.0
    if t_lo <= t <= t_hi:
        f = (1 - math.cos(math.pi * (t - t_lo) / (t_hi - t_lo))) / 2
    else:
        dt = (t - t_hi) % 24.0
        span = 24.0 - (t_hi - t_lo)
        f = 1 - (1 - math.exp(-3 * dt / span)) / (1 - math.exp(-3))
    return tmin + (tmax - tmin) * f


def air_temp_range(ls: float, tau: float | None = None):
    c = calibration(ls)
    if c and c.get("min_c") is not None and c.get("max_c") is not None:
        return c["min_c"], c["max_c"]
    tau = dust_tau(ls) if tau is None else tau
    s = _season(ls)
    tmax = -12.0 + 10.0 * s - 6.0 * (tau - 0.5)
    tmin = -80.0 + 7.0 * s + 5.0 * (tau - 0.5)
    return tmin, tmax


def air_temp_c(ls: float, ltst: float, tau: float | None = None) -> float:
    tmin, tmax = air_temp_range(ls, tau)
    return _diurnal(ltst, tmin, tmax)


def ground_temp_c(ls: float, ltst: float, tau: float | None = None) -> float:
    c = calibration(ls)
    if c and c.get("ground_min_c") is not None and c.get("ground_max_c") is not None:
        return _diurnal(ltst, c["ground_min_c"], c["ground_max_c"], 5.6, 12.9)
    tmin, tmax = air_temp_range(ls, tau)
    return _diurnal(ltst, tmin - 6.0, tmax + 18.0, 5.6, 12.9)


def pressure_pa(ls: float, ltst: float) -> float:
    c = calibration(ls)
    if c and c.get("pressure_pa"):
        p = float(c["pressure_pa"])
    else:
        xs, ys = zip(*_P_TABLE)
        p = float(np.interp(ls % 360.0, xs, ys))
        site = _SITE.get()
        if site is not None:  # same column of air, lower or higher up
            p *= math.exp(-(site[1] - GALE_ELEV_M) / SCALE_HEIGHT_M)
    return p * (1 + 0.055 * math.cos(2 * math.pi * (ltst - 7.0) / 24) + 0.02 * math.cos(4 * math.pi * (ltst - 9.5) / 24))


def wind_ms(ltst: float) -> float:
    return 3.0 + 4.0 * max(0.0, math.sin(math.pi * (ltst - 9.0) / 10.0))


def surface_flux(toa: float, sun_elev_deg: float, tau: float) -> dict:
    """Very simple direct + diffuse split (W/m^2)."""
    mu = math.sin(math.radians(max(sun_elev_deg, 0.0)))
    if mu <= 0:
        return {"direct": 0.0, "diffuse": 0.0, "total": 0.0}
    direct = toa * mu * math.exp(-tau / max(mu, 0.05))
    diffuse = toa * mu * 0.35 * (1 - math.exp(-tau / max(mu, 0.05)))
    return {"direct": direct, "diffuse": diffuse, "total": direct + diffuse}


def uv_index(sun_elev_deg: float, tau: float) -> float:
    mu = math.sin(math.radians(max(sun_elev_deg, 0.0)))
    return round(24.0 * mu * math.exp(-0.6 * tau / max(mu, 0.05)), 1)


def gcr_usv_per_h(shield_fraction: float = 0.0) -> float:
    return GCR_MSV_PER_DAY * SOLAR_MAX_FACTOR * 1000.0 / 24.0 * (1.0 - shield_fraction)
