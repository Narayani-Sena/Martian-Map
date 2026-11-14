"""Mars24 sun clock: time, season and sun position anywhere on Mars.

Implements the algorithm from NASA GISS "Mars24 Sunclock - Algorithm and
Worked Examples" (Allison & McEwen 2000, Planet. Space Sci. 48, 215).
https://www.giss.nasa.gov/tools/mars24/help/algorithm.html

Conventions used here (they differ from the paper's west longitudes):
  * longitudes are planetocentric and east-positive,
  * hour angle H is positive in the afternoon (sun west of the meridian),
  * azimuth is degrees clockwise from north.

The same algorithm is mirrored in web/src/lib/mars24.js for the live clock.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

# TT - UTC = 32.184 s + leap seconds (37 since 2017-01-01; none announced since).
TT_MINUS_UTC_S = 69.184

_PBS = (  # perturbations by other planets: (A, tau, phi)
    (0.0071, 2.2353, 49.409),
    (0.0057, 2.7543, 168.173),
    (0.0039, 1.1177, 191.837),
    (0.0037, 15.7866, 21.736),
    (0.0021, 2.1354, 15.704),
    (0.0020, 2.4694, 95.528),
    (0.0018, 32.8493, 49.095),
)

MARS_SOL_DAYS = 1.0274912517  # mean solar day in Earth days


@dataclass
class MarsTime:
    jd_ut: float
    jd_tt: float
    dt_j2000: float  # days since J2000 (TT)
    msd: float  # Mars Sol Date
    mtc: float  # Coordinated Mars Time (hours at the prime meridian)
    ls: float  # areocentric solar longitude (deg) = Mars season
    eot_deg: float  # equation of time (deg); LTST = LMST + EOT/15
    subsolar_lon: float  # east longitude of the subsolar point (deg)
    declination: float  # solar declination (deg)
    helio_au: float  # Sun-Mars distance (AU)
    mean_anomaly: float
    mars_year: int  # Clancy et al. Mars Year (MY1 began 1955-04-11)


def _to_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def julian_date_ut(dt: datetime) -> float:
    dt = _to_utc(dt)
    return 2440587.5 + dt.timestamp() / 86400.0


def mars_time(dt: datetime) -> MarsTime:
    jd_ut = julian_date_ut(dt)
    jd_tt = jd_ut + TT_MINUS_UTC_S / 86400.0
    d = jd_tt - 2451545.0

    m = (19.3871 + 0.52402073 * d) % 360.0
    alpha_fms = (270.3871 + 0.524038496 * d) % 360.0
    pbs = sum(a * math.cos(math.radians(0.985626 * d / tau + phi)) for a, tau, phi in _PBS)
    mr = math.radians(m)
    nu_m = ((10.691 + 3.0e-7 * d) * math.sin(mr) + 0.623 * math.sin(2 * mr) + 0.050 * math.sin(3 * mr)
            + 0.005 * math.sin(4 * mr) + 0.0005 * math.sin(5 * mr) + pbs)
    ls = (alpha_fms + nu_m) % 360.0
    lsr = math.radians(ls)
    eot = 2.861 * math.sin(2 * lsr) - 0.071 * math.sin(4 * lsr) + 0.002 * math.sin(6 * lsr) - nu_m

    msd = (jd_tt - 2451549.5) / MARS_SOL_DAYS + 44796.0 - 0.0009626
    mtc = (24.0 * msd) % 24.0

    # subsolar point: where LTST = 12h.  LTST(lon) = MTC + lon/15 + EOT/15
    subsolar_lon = ((12.0 - mtc) * 15.0 - eot + 180.0) % 360.0 - 180.0
    decl = math.degrees(math.asin(0.42565 * math.sin(lsr))) + 0.25 * math.sin(lsr)
    helio = 1.5236 * (1.00436 - 0.09309 * math.cos(mr) - 0.004336 * math.cos(2 * mr)
                      - 0.00031 * math.cos(3 * mr) - 0.00003 * math.cos(4 * mr))

    # Mars Year: MY1 began at Ls=0 on 1955-04-11 (JD 2435208.5); one year = 686.9725 d.
    my = int(math.floor((jd_tt - 2435208.5) / 686.9725 + 1 - _ls_fraction_correction(ls, jd_tt)))
    return MarsTime(jd_ut, jd_tt, d, msd, mtc, ls, eot, subsolar_lon, decl, helio, m, my)


def _ls_fraction_correction(ls: float, jd_tt: float) -> float:
    """Snap the Mars-year count to the actual Ls=0 crossing.

    The mean-year estimate can be off by a few days near Ls=0; compare the
    fractional year with Ls to decide which side of the boundary we're on.
    """
    frac = ((jd_tt - 2435208.5) / 686.9725) % 1.0
    if ls > 300 and frac < 0.1:
        return 1.0  # still the previous Mars year
    if ls < 60 and frac > 0.9:
        return -1.0  # new Mars year already started
    return 0.0


def local_mean_solar_time(mt: MarsTime, lon_east: float) -> float:
    return (mt.mtc + lon_east / 15.0) % 24.0


def local_true_solar_time(mt: MarsTime, lon_east: float) -> float:
    return (mt.mtc + lon_east / 15.0 + mt.eot_deg / 15.0) % 24.0


def sun_position(mt: MarsTime, lat: float, lon_east: float):
    """Return (elevation_deg, azimuth_deg_from_north, hour_angle_deg)."""
    ltst = local_true_solar_time(mt, lon_east)
    h = math.radians((ltst - 12.0) * 15.0)
    phi = math.radians(lat)
    dec = math.radians(mt.declination)
    sin_alt = math.sin(phi) * math.sin(dec) + math.cos(phi) * math.cos(dec) * math.cos(h)
    alt = math.degrees(math.asin(max(-1.0, min(1.0, sin_alt))))
    az = math.degrees(math.atan2(-math.cos(dec) * math.sin(h),
                                 math.sin(dec) * math.cos(phi) - math.cos(dec) * math.sin(phi) * math.cos(h)))
    return alt, az % 360.0, math.degrees(h)


def solar_flux_top_of_atmosphere(mt: MarsTime) -> float:
    """W/m^2 at Mars' distance (solar constant 1361 W/m^2 at 1 AU)."""
    return 1361.0 / (mt.helio_au ** 2)


def sunrise_sunset_ltst(mt: MarsTime, lat: float, horizon_deg: float = -0.25):
    """LTST hours of sunrise and sunset for the sol, or None for polar day/night.

    horizon_deg accounts for the sun's radius (~0.18 deg at Mars); refraction is negligible.
    """
    phi = math.radians(lat)
    dec = math.radians(mt.declination)
    c = (math.sin(math.radians(horizon_deg)) - math.sin(phi) * math.sin(dec)) / (math.cos(phi) * math.cos(dec))
    if c <= -1 or c >= 1:
        return None
    h0 = math.degrees(math.acos(c)) / 15.0
    return 12.0 - h0, 12.0 + h0


def utc_for_ltst(day_hint: datetime, lon_east: float, ltst_target: float) -> datetime:
    """UTC time on the sol containing day_hint whose LTST equals ltst_target."""
    t = _to_utc(day_hint)
    for _ in range(6):
        mt = mars_time(t)
        cur = local_true_solar_time(mt, lon_east)
        diff = ((ltst_target - cur + 12.0) % 24.0) - 12.0  # hours (Mars), shortest way
        if abs(diff) < 1e-5:
            break
        t = t + timedelta(seconds=diff * 3600.0 * MARS_SOL_DAYS)
    return t


def local_sol_number(mt: MarsTime, lon_east: float) -> float:
    """Local Mars Sol Date: MSD shifted so the sol starts at local midnight (LMST)."""
    return mt.msd + lon_east / 360.0


def mission_sol(mt: MarsTime, lon_east: float, landing_msd_local: int) -> int:
    """Mission sol number given the local MSD integer of the landing sol (sol 0)."""
    return int(math.floor(local_sol_number(mt, lon_east))) - landing_msd_local


def season_name(ls: float, lat: float) -> str:
    north = ["spring", "summer", "autumn", "winter"]
    south = ["autumn", "winter", "spring", "summer"]
    q = int(ls // 90) % 4
    return (north if lat >= 0 else south)[q]


def hours_to_hms(hours: float) -> str:
    hours %= 24.0
    h = int(hours)
    m = int((hours - h) * 60)
    s = int(round(((hours - h) * 60 - m) * 60))
    if s == 60:
        s, m = 0, m + 1
    if m == 60:
        m, h = 0, (h + 1) % 24
    return f"{h:02d}:{m:02d}:{s:02d}"
