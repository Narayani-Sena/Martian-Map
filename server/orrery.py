"""The interplanetary map (feature A5, D2): Sun, Earth and Mars where they are, the light time between them, and
each DONKI CME as a cone leaving the Sun.

Planet positions use JPL's "Approximate Positions of the Planets" (Standish; Keplerian elements and rates, valid
1800-2050, good to a few arcminutes), which is plenty for a map and for the light time (seconds).

CME directions: DONKI gives each CME's longitude in Stonyhurst coordinates (0 = the Sun-Earth line, positive =
solar west). Seen from the north ecliptic pole solar west points along increasing heliocentric longitude, so a
CME's heliocentric ecliptic longitude is Earth's plus the CME longitude (the small tilt between the solar equator
and the ecliptic is ignored for the map). The front moves out at the measured speed from 21.5 solar radii.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone

AU_KM = 149_597_870.7
C_KMS = 299_792.458
LIGHT_S_PER_AU = AU_KM / C_KMS  # ~499.0 s
R_SUN_AU = 695_700.0 / AU_KM

# a (AU), e, I (deg), L (deg), long. perihelion (deg), long. node (deg), and their rates per Julian century
ELEMENTS = {
    "earth": ((1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0.0),
              (0.00000562, -0.00004392, -0.01294668, 35999.37244981, 0.32327364, 0.0)),
    "mars": ((1.52371034, 0.09339410, 1.84969142, -4.55343205, -23.94362959, 49.55953891),
             (0.00001847, 0.00007882, -0.00813131, 19140.30268499, 0.44441088, -0.29257343)),
}


def _jd(when: datetime) -> float:
    return when.timestamp() / 86400.0 + 2440587.5


def planet_xyz(name: str, when: datetime) -> tuple[float, float, float]:
    """Heliocentric ecliptic J2000 position (AU)."""
    T = (_jd(when) - 2451545.0) / 36525.0
    el0, rate = ELEMENTS[name]
    a, e, inc, L, wbar, node = (x + r * T for x, r in zip(el0, rate))
    M = math.radians((L - wbar + 180.0) % 360.0 - 180.0)
    w = math.radians(wbar - node)
    inc, node = math.radians(inc), math.radians(node)
    E = M + e * math.sin(M)
    for _ in range(8):  # Newton on Kepler's equation
        E -= (E - e * math.sin(E) - M) / (1.0 - e * math.cos(E))
    xp, yp = a * (math.cos(E) - e), a * math.sqrt(1.0 - e * e) * math.sin(E)
    cw, sw, cO, sO, ci, si = math.cos(w), math.sin(w), math.cos(node), math.sin(node), math.cos(inc), math.sin(inc)
    x = (cw * cO - sw * sO * ci) * xp + (-sw * cO - cw * sO * ci) * yp
    y = (cw * sO + sw * cO * ci) * xp + (-sw * sO + cw * cO * ci) * yp
    z = (sw * si) * xp + (cw * si) * yp
    return x, y, z


def light_time_s(when: datetime) -> float:
    """One-way light time Earth <-> Mars (s)."""
    ex, ey, ez = planet_xyz("earth", when)
    mx, my, mz = planet_xyz("mars", when)
    return math.dist((ex, ey, ez), (mx, my, mz)) * LIGHT_S_PER_AU


def orbit(name: str, when: datetime, n: int = 180) -> list[list[float]]:
    """One full orbit (x, y AU) through the planet's current position."""
    period_d = 365.256 if name == "earth" else 686.98
    return [[round(v, 5) for v in planet_xyz(name, when + timedelta(days=period_d * k / n))[:2]] for k in range(n + 1)]


def _parse(ts):
    if not ts:
        return None
    ts = ts.replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(ts[:19], fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def cmes_from_sims(sims: list, now: datetime, days_back: float = 10.0) -> list[dict]:
    """CMEs DONKI simulated in the last `days_back` days: launch, direction, width, speed, where each was predicted
    to arrive (Mars among them)."""
    out: dict[str, dict] = {}
    for sim in sims:
        for c in sim.get("cmeInputs") or []:
            cid = c.get("CMEID") or sim.get("simulationID")
            t21 = _parse(c.get("time21_5")) or _parse(c.get("cmeStartTime"))
            if t21 is None or (now - t21).total_seconds() > days_back * 86400 or c.get("speed") is None:
                continue
            impacts = [{"location": i.get("location"), "arrival": i.get("arrivalTime"), "glancing": bool(i.get("isGlancingBlow"))}
                       for i in sim.get("impactList") or []]
            prev = out.get(cid)
            if prev is None or len(impacts) >= len(prev["impacts"]):
                out[cid] = {"id": cid, "t21_5": t21.isoformat(), "lon_stonyhurst": float(c.get("longitude") or 0.0),
                            "lat": float(c.get("latitude") or 0.0), "half_angle": float(c.get("halfAngle") or 30.0),
                            "speed_kms": float(c["speed"]), "impacts": impacts,
                            "mars": next((i for i in impacts if (i["location"] or "").lower() == "mars"), None),
                            "earth_gb": bool(sim.get("isEarthGB")), "link": sim.get("link")}
    return sorted(out.values(), key=lambda x: x["t21_5"])


def cme_front_au(cme: dict, when: datetime) -> float | None:
    t21 = _parse(cme["t21_5"])
    dt = (when - t21).total_seconds()
    if dt < 0:
        return None
    return 21.5 * R_SUN_AU + cme["speed_kms"] * dt / AU_KM


def snapshot(now: datetime, sims: list | None = None) -> dict:
    """Everything the orrery inset draws, at `now`."""
    e = planet_xyz("earth", now)
    m = planet_xyz("mars", now)
    lt = light_time_s(now)
    lam_e = math.degrees(math.atan2(e[1], e[0])) % 360.0
    lam_m = math.degrees(math.atan2(m[1], m[0])) % 360.0
    cmes = []
    for c in cmes_from_sims(sims or [], now):
        lam = (lam_e + c["lon_stonyhurst"]) % 360.0
        # angle between the CME's centre line and Mars: inside the half-angle means it is heading Mars' way
        off = abs((lam - lam_m + 180.0) % 360.0 - 180.0)
        cmes.append({**c, "lon_ecliptic": round(lam, 1), "front_au_now": cme_front_au(c, now),
                     "mars_offset_deg": round(off, 1), "toward_mars": off <= c["half_angle"] + 5.0})
    # light time over the next two years (it swings between ~3 and ~22 minutes)
    curve = [[k, round(light_time_s(now + timedelta(days=k)) / 60.0, 2)] for k in range(0, 731, 10)]
    conj = min(curve, key=lambda kv: -kv[1])
    opp = min(curve, key=lambda kv: kv[1])
    return {"utc": now.isoformat(), "earth": [round(v, 5) for v in e[:2]], "mars": [round(v, 5) for v in m[:2]],
            "sun_earth_au": round(math.hypot(*e), 4), "sun_mars_au": round(math.hypot(*m), 4),
            "earth_mars_au": round(lt / LIGHT_S_PER_AU, 4), "light_time_s": round(lt, 1), "light_time_min": round(lt / 60.0, 2),
            "lon_earth": round(lam_e, 2), "lon_mars": round(lam_m, 2),
            "elongation_deg": round(abs((lam_m - lam_e + 180.0) % 360.0 - 180.0), 1),
            "earth_orbit": orbit("earth", now), "mars_orbit": orbit("mars", now), "cmes": cmes,
            "light_time_curve_min": curve, "next_max_light_min": {"in_days": conj[0], "minutes": conj[1]},
            "next_min_light_min": {"in_days": opp[0], "minutes": opp[1]}}


def ask_earth(now: datetime, think_min: float = 10.0) -> dict:
    """D2: when an answer from Earth can arrive (there and back at light speed, plus thinking time)."""
    lt = light_time_s(now)
    total = 2.0 * lt + think_min * 60.0
    return {"one_way_s": round(lt, 1), "think_min": think_min, "round_trip_s": round(2 * lt, 1), "answer_after_s": round(total, 1),
            "answer_utc": (now + timedelta(seconds=total)).isoformat()}
