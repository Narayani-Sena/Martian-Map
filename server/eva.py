"""Turn a set of route legs into a full EVA timeline with consumables, sun and dose.

The suit model is deliberately simple and every constant is a named parameter,
so the UI can show (and change) what the plan assumes.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, fields
from datetime import datetime, timedelta, timezone

import numpy as np

from marsgeo import mars24
from marsgeo.grid import sample_bilinear

from . import climate
from .walkmodel import metabolic_watts

O2_G_PER_WH = 3600.0 / 20100.0 * 1.429  # ~0.256 g O2 per Wh metabolic (20.1 kJ per litre O2)
RQ = 0.85  # respiratory quotient (mol CO2 per mol O2)

# Suit atmosphere (NASA-STD-3001 Vol 2 [V2 11035/11036] asks suits to show and alarm on these).
# A pure-oxygen suit at 4.3 psi like the EMU and xEMU. Planning assumptions, mirrored in godot/scripts/core/suit_model.gd.
SUIT_P_KPA = 29.6          # suit pressure
PPH2O_KPA = 1.6            # water vapour in the helmet
MMHG_PER_KPA = 7.50062
# Inspired CO2 (PICO2) alarm levels, mmHg. NASA's contingency limit is 20 mmHg for up to 1 h [V2 11040];
# the suit inlet stays under 2 mmHg in normal operation [V2 11039 rationale].
PPCO2_CAUTION = 8.0
PPCO2_WARNING = 15.0
PPCO2_LIMIT = 20.0


def ppco2_mmhg(met_w: float, scrubber_load_pct: float) -> float:
    """Inspired CO2 partial pressure: helmet washout (grows with the CO2 you breathe out) plus breakthrough
    once the scrubber passes ~70 % of its capacity."""
    washout = 1.6 * max(0.0, met_w) / 300.0
    x = max(0.0, (scrubber_load_pct - 70.0) / 30.0)
    return washout + 20.0 * x * x


def ppo2_kpa(p_suit_kpa: float, ppco2: float) -> float:
    return p_suit_kpa - PPH2O_KPA - ppco2 / MMHG_PER_KPA


@dataclass(frozen=True)
class SuitParams:
    o2_kg: float = 0.68  # usable primary O2
    o2_leak_g_h: float = 5.0
    battery_wh: float = 1100.0
    base_load_w: float = 85.0  # fans, pump, radio, HUD
    co2_capacity_g: float = 760.0  # scrubber capacity
    water_kg: float = 3.6  # cooling feedwater
    reserve_min: float = 30.0  # always keep this much on top of the walk back
    return_factor: float = 1.25  # walk-back time x this, for a slower tired return
    airlock_min: float = 15.0  # egress and ingress, each

    @classmethod
    def from_dict(cls, d: dict | None) -> "SuitParams":
        d = d or {}
        return cls(**{f.name: float(d[f.name]) for f in fields(cls) if d.get(f.name) is not None})

    def to_dict(self):
        return asdict(self)


def heater_w(air_c: float) -> float:
    return float(np.clip((-45.0 - air_c) * 1.6, 0.0, 70.0))


# Sunlight the suit absorbs: absorptivity ~0.2 (white outer layer) x ~0.6 m2 facing the sun, times the direct
# beam. In terrain shadow that heat is missing; once the air is below about -10 C the suit is losing heat, so the
# heater has to make it up (fully below -30 C).
SUIT_SUN_GAIN_M2 = 0.12


def shade_heater_w(air_c: float, direct_wm2: float) -> float:
    """Extra heater power while the suit is in terrain shadow (the sunlight it no longer absorbs)."""
    cold = float(np.clip((-10.0 - air_c) / 20.0, 0.0, 1.0))
    return cold * SUIT_SUN_GAIN_M2 * max(0.0, direct_wm2)


# Planning dispersions for the margin range [V2 10161: automated advice shows its uncertainty]. Metabolic rate
# varies about +-20 % between crew members and days (Apollo EVA averages ran 230-300 W for similar work);
# suited walking speed about +-12 % (terrain, fatigue).
DISPERSIONS = {"pessimistic": {"met": 1.2, "speed": 0.88}, "optimistic": {"met": 0.85, "speed": 1.1}}


def build_timeline(legs_eval: list[dict], stops: list[dict], suit: SuitParams, rover: dict | None = None):
    """Merge legs (walking) and stops (working) into one sample list.

    legs_eval[i] has arrays d, t, z, grade, slope, lonlat (N,2), shield, comms, walkback_s, hazard, sand.
    stops[i] is the stop reached at the end of leg i (None for the final return).
    rover (optional): {"name", "out_s", "out_m", "back_s", "back_m", "suitport_min"} - the crew drives
    out in the pressurized rover, uses its suitports instead of the hab airlock, and drives back.
    Rows cover the suited part only; the drives are events (and the rover's own track).
    """
    rows = []  # dicts per sample
    events = []
    lock_s = suit.airlock_min * 60.0
    t_off = 0.0
    if rover:
        lock_s = float(rover["suitport_min"]) * 60.0
        events.append({"kind": "drive", "leg": "out", "name": f"Drive Hab → drop-off ({rover['name']})", "t0": 0.0,
                       "t1": float(rover["out_s"]), "dist_m": float(rover["out_m"])})
        t_off = float(rover["out_s"])
        events.append({"kind": "egress", "name": f"Suitport egress ({rover['name']})", "t0": t_off, "t1": t_off + lock_s})
    else:
        events.append({"kind": "egress", "name": "Egress (airlock)", "t0": 0.0, "t1": lock_s})
    t_off += lock_s
    d_off = 0.0
    for i, L in enumerate(legs_eval):
        n = len(L["d"])
        events.append({"kind": "walk", "leg": i, "name": L.get("label", f"Leg {i + 1}"), "t0": t_off,
                       "t1": t_off + float(L["t"][-1]), "dist_m": float(L["d"][-1])})
        for k in range(n):
            rows.append({
                "t": t_off + float(L["t"][k]), "d": d_off + float(L["d"][k]), "z": float(L["z"][k]),
                "grade": float(L["grade"][k]), "slope": float(L["slope"][k]),
                "lon": float(L["lonlat"][k][0]), "lat": float(L["lonlat"][k][1]),
                "shield": float(L["shield"][k]), "comms": int(L["comms"][k]), "walkback_s": float(L["walkback_s"][k]),
                "hazard": int(L["hazard"][k]), "sand": float(L["sand"][k]), "leg": i, "working": False, "sunlit": True,
            })
        t_off += float(L["t"][-1])
        d_off += float(L["d"][-1])
        st = stops[i] if i < len(stops) else None
        if st is not None:
            dwell = float(st.get("dwell_min", 20)) * 60.0
            events.append({"kind": "stop", "id": st.get("id"), "name": st.get("name", "Stop"), "t0": t_off,
                           "t1": t_off + dwell, "tasks": st.get("tasks", [])})
            last = dict(rows[-1])
            last.update({"t": t_off + dwell, "working": True})
            rows.append(last)
            t_off += dwell
    ingress = f"Suitport ingress ({rover['name']})" if rover else "Ingress (airlock)"
    events.append({"kind": "ingress", "name": ingress, "t0": t_off, "t1": t_off + lock_s})
    t_end = t_off + lock_s
    if rover:
        events.append({"kind": "drive", "leg": "back", "name": f"Drive drop-off → Hab ({rover['name']})", "t0": t_end,
                       "t1": t_end + float(rover["back_s"]), "dist_m": float(rover["back_m"])})
        t_end += float(rover["back_s"])
    return rows, events, t_end


def suited_window(events: list[dict]) -> tuple[dict, dict]:
    """The egress and ingress events that bracket the time spent in suits."""
    eg = next(e for e in events if e["kind"] == "egress")
    ig = next(e for e in reversed(events) if e["kind"] == "ingress")
    return eg, ig


def simulate(rows: list[dict], events: list[dict], total_s: float, suit: SuitParams, start: datetime,
             lat: float, lon: float, sep_active: bool, flat_speed: float, dt_s: float = 30.0, load_kg: float = 0.0,
             cabin: dict | None = None, met_scale: float = 1.0, load_steps: list | None = None):
    """Integrate consumables on a uniform time grid.

    cabin (rover-assisted EVAs): {"met_w", "gcr_factor", "sep_factor", "shield"} for the time spent riding in
    the pressurized rover. The suits are not used then, so their consumables stay full.
    rows[k]["sunlit"] False = the crew is in terrain shadow there (server/site_store.Site.sunlit): no direct sun
    on the suit, so the heater makes up the missing warmth when it is cold.
    met_scale: multiplies the crew's metabolic rate (planning dispersions).
    load_steps: [(t_s, kg)] mass added at those times (samples bagged at the end of each stop, feature C4).
    """
    steps = sorted(load_steps or [])

    def load_at(t):
        return load_kg + sum(kg for t0, kg in steps if t >= t0)
    ts = np.arange(0.0, total_s + dt_s, dt_s)
    rt = np.array([r["t"] for r in rows])
    n_rows = len(rows)
    eg, ig = suited_window(events)
    cabin = cabin or {"met_w": 120.0, "gcr_factor": 0.7, "sep_factor": 0.1, "shield": 0.0}

    def state_at(t):
        # A stop is two rows at the same spot: arrival (walking) then departure (working=True).
        if t < eg["t0"] or t >= ig["t1"]:
            return "cabin", None
        if t < eg["t1"] or t >= ig["t0"]:
            return "airlock", None
        k = int(np.searchsorted(rt, t, side="right")) - 1
        k = max(0, min(k, n_rows - 1))
        if k + 1 < n_rows and rows[k + 1]["working"]:
            return "work", k
        return "walk", k

    o2 = suit.o2_kg * 1000.0
    co2 = 0.0
    batt = suit.battery_wh
    water = suit.water_kg
    dose = 0.0
    out = {k: [] for k in ("t", "o2_pct", "battery_pct", "co2_pct", "water_pct", "met_w", "air_c", "sun_elev",
                           "ltst", "dose_usv", "margin_min", "need_min", "limit_min", "state",
                           "p_suit_kpa", "ppo2_kpa", "ppco2_mmhg", "shade", "heater_w")}
    min_margin, min_margin_t, limiting = 1e9, 0.0, None
    max_ppco2, max_ppco2_t = 0.0, 0.0
    shade_s, shade_wh = 0.0, 0.0
    for t in ts:
        st, k = state_at(t)
        lk = load_at(t)
        when = start + timedelta(seconds=float(t))
        mt = mars24.mars_time(when)
        ltst = mars24.local_true_solar_time(mt, lon)
        elev, _, _ = mars24.sun_position(mt, lat, lon)
        tau = climate.dust_tau(mt.ls)
        air = climate.air_temp_c(mt.ls, ltst, tau)
        if st == "walk":
            r0 = rows[k]
            r1 = rows[min(k + 1, len(rows) - 1)]
            seg_t = max(1e-6, r1["t"] - r0["t"])
            v = min(2.0, max(0.05, (r1["d"] - r0["d"]) / seg_t))
            met = float(metabolic_watts(v, r0["grade"], load_kg=lk)) * met_scale
        elif st == "work":
            met = float(metabolic_watts(0.0, 0.0, working=True, load_kg=lk)) * met_scale
        elif st == "cabin":
            met = float(cabin["met_w"])
        else:
            met = 200.0 * met_scale
        shaded = st in ("walk", "work") and elev > -0.25 and not rows[k].get("sunlit", True)
        heat = heater_w(air)
        if shaded:
            direct = climate.surface_flux(mars24.solar_flux_top_of_atmosphere(mt), elev, tau)["direct"]
            extra = shade_heater_w(air, direct)
            heat += extra
            shade_s += dt_s
            shade_wh += extra * dt_s / 3600.0
        lights = elev < 3 or (shaded and elev < 10)  # dim: helmet lights on
        load = suit.base_load_w + heat + (12.0 if lights else 0.0)
        h = dt_s / 3600.0
        if st != "cabin":  # riding in the rover: the suits hang on the suitports, topped up
            o2 -= (met * O2_G_PER_WH + suit.o2_leak_g_h) * h
            co2 += met * O2_G_PER_WH / 32.0 * RQ * 44.0 * h
            batt -= load * h
            water -= 0.32 * (met / 300.0) * h
        if st == "cabin":
            sh = float(cabin["shield"])
            rate = climate.gcr_usv_per_h(sh) * float(cabin["gcr_factor"])
            if sep_active:
                rate += 600.0 * (1 - min(0.95, sh * 2.5)) * float(cabin["sep_factor"])
        else:
            shield = rows[k]["shield"] if k is not None else 0.6
            rate = climate.gcr_usv_per_h(shield)
            if sep_active:
                rate += 600.0 * (1 - min(0.95, shield * 2.5))
        dose += rate * h
        # how long each consumable lasts at a brisk return-walk rate
        ret_met = 420.0 * (1.0 + lk / 145.0)  # brisk return walk, carrying the samples home
        left = {
            "O2": o2 / (ret_met * O2_G_PER_WH + suit.o2_leak_g_h) * 60.0,
            "Battery": batt / (suit.base_load_w + heater_w(air) + 12.0) * 60.0,
            "CO2 scrubber": (suit.co2_capacity_g - co2) / (ret_met * O2_G_PER_WH / 32.0 * RQ * 44.0) * 60.0,
            "Water": water / (0.32 * ret_met / 300.0) * 60.0,
        }
        lim_name = min(left, key=left.get)
        wb = rows[k]["walkback_s"] if (k is not None and st not in ("airlock", "cabin")) else 0.0
        if not math.isfinite(wb):
            wb = 4 * 3600.0
        need = wb / 60.0 * suit.return_factor + suit.reserve_min
        margin = left[lim_name] - need
        if eg["t1"] <= t < ig["t0"] and margin < min_margin:
            min_margin, min_margin_t, limiting = margin, float(t), lim_name
        out["t"].append(float(t))
        out["o2_pct"].append(max(0.0, o2 / (suit.o2_kg * 1000.0) * 100))
        out["battery_pct"].append(max(0.0, batt / suit.battery_wh * 100))
        out["co2_pct"].append(min(100.0, co2 / suit.co2_capacity_g * 100))
        out["water_pct"].append(max(0.0, water / suit.water_kg * 100))
        out["met_w"].append(round(met, 1))
        out["air_c"].append(round(air, 1))
        out["sun_elev"].append(round(elev, 2))
        out["ltst"].append(round(ltst, 4))
        out["dose_usv"].append(round(dose, 2))
        out["margin_min"].append(round(margin, 1))
        out["need_min"].append(round(need, 1))
        out["limit_min"].append(round(left[lim_name], 1))
        out["state"].append(st)
        load_pct = min(100.0, co2 / suit.co2_capacity_g * 100)
        pc = ppco2_mmhg(met, load_pct) if st != "cabin" else 0.0
        if st != "cabin" and pc > max_ppco2:
            max_ppco2, max_ppco2_t = pc, float(t)
        out["p_suit_kpa"].append(SUIT_P_KPA)
        out["ppco2_mmhg"].append(round(pc, 2))
        out["ppo2_kpa"].append(round(ppo2_kpa(SUIT_P_KPA, pc), 2))
        out["shade"].append(1 if shaded else 0)
        out["heater_w"].append(round(heat, 1))
    return out, {"min_margin_min": round(min_margin, 1), "min_margin_t": min_margin_t, "limiting": limiting,
                 "dose_usv": round(dose, 1), "max_ppco2_mmhg": round(max_ppco2, 1), "max_ppco2_t": max_ppco2_t,
                 "shade_min": round(shade_s / 60.0, 1), "shade_heater_wh": round(shade_wh, 1)}


def go_no_go(summary: dict, sim: dict, events: list[dict], rows: list[dict], sunset_t: float | None,
             p_walk, wb_limit_min: float = 120.0, haven: str = "the hab"):
    issues = []
    go = True
    _, ig = suited_window(events)
    if summary["min_margin_min"] < 0:
        go = False
        issues.append({"level": "nogo", "text": f"Consumables margin goes negative ({summary['limiting']} short by "
                                                f"{-summary['min_margin_min']:.0f} min) - shorten the EVA"})
    elif summary["min_margin_min"] < 20:
        issues.append({"level": "caution", "text": f"Thin consumables margin: {summary['min_margin_min']:.0f} min ({summary['limiting']})"})
    if sunset_t is not None and ig["t1"] > sunset_t - 1800:
        go = False if ig["t1"] > sunset_t else go
        issues.append({"level": "nogo" if ig["t1"] > sunset_t else "caution",
                       "text": "EVA ends after sunset" if ig["t1"] > sunset_t else "EVA ends within 30 min of sunset"})
    elif sunset_t is not None and events[-1]["t1"] > sunset_t:
        issues.append({"level": "caution", "text": "The rover drives home after sunset (night driving on headlights)"})
    pc = float(summary.get("max_ppco2_mmhg", 0.0))
    if pc > PPCO2_LIMIT:
        go = False
        issues.append({"level": "nogo", "text": f"Inspired CO2 reaches {pc:.0f} mmHg as the scrubber fills - above NASA's "
                                                f"{PPCO2_LIMIT:.0f} mmHg contingency limit; shorten the EVA or carry a fresh cartridge"})
    elif pc > PPCO2_WARNING:
        issues.append({"level": "caution", "text": f"Inspired CO2 reaches {pc:.0f} mmHg late in the EVA (scrubber near capacity)"})
    wb = [r["walkback_s"] for r in rows if math.isfinite(r["walkback_s"])]
    if wb and max(wb) / 60 > wb_limit_min:
        issues.append({"level": "caution", "text": f"Farthest point is {max(wb) / 60:.0f} min from {haven} (limit {wb_limit_min:.0f})"})
    hz = sum(1 for r in rows if r["hazard"] >= 3)
    if hz:
        issues.append({"level": "caution", "text": f"{hz * 2} m of route crosses hazardous terrain (class 3+)"})
    dead = [r for r in rows if r["comms"] == 0]
    if rows and dead:
        frac = len(dead) / len(rows)
        issues.append({"level": "caution" if frac < 0.3 else "nogo-soft",
                       "text": f"{frac * 100:.0f}% of the route has no radio line of sight to the hab - add a relay"})
    if not issues:
        issues.append({"level": "ok", "text": "All checks passed"})
    return go, issues
