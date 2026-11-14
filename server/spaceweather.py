"""Space weather from NASA's DONKI (via api.nasa.gov), cached on disk.

DONKI's WSA-ENLIL simulations predict when coronal mass ejections (CMEs)
reach each planet and spacecraft - including Mars. We combine those with
recent solar flares and solar energetic particle (SEP) events into a simple
EVA status: GREEN / AMBER / RED.

DEMO_KEY allows ~30 requests/hour per IP, so responses are cached for 3 hours.
Set NASA_API_KEY (free at https://api.nasa.gov) for higher limits.
"""

from __future__ import annotations

import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from marsgeo.net import get_json

API = "https://api.nasa.gov/DONKI"
CACHE = Path(__file__).resolve().parents[1] / "data" / "cache" / "donki"
TTL_S = 3 * 3600


def _key() -> str:
    return os.environ.get("NASA_API_KEY", "DEMO_KEY")


def _parse(ts: str | None):
    if not ts:
        return None
    ts = ts.replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


_fail_until: dict[str, float] = {}
_memo: dict = {"t": 0.0, "data": None}
_memo_lock = threading.Lock()
_pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="donki")
FEED_WAIT_S = 25.0  # never keep a client waiting longer than this for one feed
MEMO_S = 600.0


def _latest_cache(endpoint: str):
    files = sorted(CACHE.glob(f"{endpoint}_*.json"), key=lambda f: f.stat().st_mtime) if CACHE.exists() else []
    if not files:
        return None
    try:
        return json.loads(files[-1].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _fetch(endpoint: str, start: datetime, end: datetime):
    s, e = start.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d")
    path = CACHE / f"{endpoint}_{s}_{e}.json"
    if time.time() < _fail_until.get(endpoint, 0.0) and not path.exists():
        cached = _latest_cache(endpoint)
        if cached is not None:
            return cached
        raise TimeoutError(f"{endpoint} failed recently; retrying in a few minutes")
    try:
        return get_json(f"{API}/{endpoint}", cache_path=path, ttl_s=TTL_S,
                        params={"startDate": s, "endDate": e, "api_key": _key()}, timeout=20) or []
    except Exception:
        _fail_until[endpoint] = time.time() + 600  # negative cache: don't hammer a slow feed
        cached = _latest_cache(endpoint)
        if cached is not None:
            return cached
        raise


def mars_arrivals(sims: list, now: datetime) -> list[dict]:
    """Predicted CME arrivals at Mars from WSA-ENLIL simulations; the latest simulation of each CME wins."""
    arrivals: dict[str, dict] = {}
    for sim in sims:
        done = _parse(sim.get("modelCompletionTime"))
        cmes = sim.get("cmeInputs") or []
        cme_id = (cmes[0].get("cmeid") if cmes else None) or sim.get("simulationID")
        speed = cmes[0].get("speed") if cmes else None
        for imp in sim.get("impactList") or []:
            if (imp.get("location") or "").lower() != "mars":
                continue
            arr = _parse(imp.get("arrivalTime"))
            if arr is None:
                continue
            prev = arrivals.get(cme_id)
            if prev is None or (done and prev["_done"] and done > prev["_done"]):
                arrivals[cme_id] = {"cme": cme_id, "arrival": arr.isoformat(), "glancing": bool(imp.get("isGlancingBlow")),
                                    "speed_kms": speed, "link": sim.get("link"), "_done": done}
    mars = sorted(arrivals.values(), key=lambda a: a["arrival"])
    for a in mars:
        a.pop("_done", None)
        a["hours_from_now"] = round((_parse(a["arrival"][:16]) - now).total_seconds() / 3600, 1)
    return mars


def summary(now: datetime | None = None) -> dict:
    """EVA space-weather status. Memoised for 10 minutes; each feed is fetched in parallel
    and a slow feed is reported as an error instead of blocking the response."""
    if now is None:
        with _memo_lock:
            if _memo["data"] is not None and time.time() - _memo["t"] < MEMO_S:
                return _memo["data"]
        out = _summary(datetime.now(timezone.utc))
        with _memo_lock:
            _memo.update(t=time.time(), data=out)
        return out
    return _summary(now)


def _summary(now: datetime) -> dict:
    start = (now - timedelta(days=30)).replace(hour=0, minute=0, second=0, microsecond=0)
    end = now
    errors = []
    sims, flares, seps = [], [], []
    jobs = {name: _pool.submit(_fetch, name, start, end) for name in ("WSAEnlilSimulations", "FLR", "SEP")}
    deadline = time.time() + FEED_WAIT_S
    for name, target in (("WSAEnlilSimulations", sims), ("FLR", flares), ("SEP", seps)):
        try:
            target.extend(jobs[name].result(timeout=max(0.1, deadline - time.time())))
        except Exception as ex:  # offline, rate limited, slow...
            errors.append(f"{name}: {type(ex).__name__}")

    mars = mars_arrivals(sims, now)

    big_flares = []
    for f in flares:
        cls = f.get("classType") or ""
        if cls[:1] in ("M", "X"):
            peak = _parse(f.get("peakTime"))
            big_flares.append({"class": cls, "peak": peak.isoformat() if peak else None,
                               "hours_ago": round((now - peak).total_seconds() / 3600, 1) if peak else None,
                               "region": f.get("activeRegionNum"), "link": f.get("link")})
    big_flares.sort(key=lambda f: f["peak"] or "", reverse=True)

    sep_list = []
    for s in seps:
        t = _parse(s.get("eventTime"))
        sep_list.append({"time": t.isoformat() if t else None, "hours_ago": round((now - t).total_seconds() / 3600, 1) if t else None,
                         "instruments": [i.get("displayName") for i in (s.get("instruments") or [])][:3], "link": s.get("link")})
    sep_list.sort(key=lambda s: s["time"] or "", reverse=True)

    status, reasons = "GREEN", []
    for a in mars:
        h = a["hours_from_now"]
        if -24 <= h <= 6:
            status = "RED"
            reasons.append(f"CME {'(glancing) ' if a['glancing'] else ''}at Mars {'now' if abs(h) < 1 else (f'{-h:.0f} h ago' if h < 0 else f'in {h:.0f} h')}")
        elif 6 < h <= 72 and status != "RED":
            status = "AMBER"
            reasons.append(f"CME predicted to reach Mars in {h:.0f} h")
    if any(s["hours_ago"] is not None and s["hours_ago"] <= 48 for s in sep_list) and status == "GREEN":
        status = "AMBER"
        reasons.append("Solar energetic particle event in the last 48 h (Mars may be connected)")
    if any(f["class"].startswith("X") and f["hours_ago"] is not None and f["hours_ago"] <= 24 for f in big_flares) and status == "GREEN":
        status = "AMBER"
        reasons.append("X-class flare in the last 24 h")
    reasons = list(dict.fromkeys(reasons))  # two CMEs on one arrival time read as one reason
    if not reasons:
        reasons.append("No CME arrivals predicted at Mars in the next 72 h")
    return {
        "status": status,
        "reasons": reasons,
        "mars_arrivals": mars[-8:],
        "flares": big_flares[:10],
        "seps": sep_list[:6],
        "simulations_checked": len(sims),
        "fetched_utc": now.isoformat(),
        "errors": errors,
        "source": "NASA DONKI (CCMC) via api.nasa.gov",
        "key": "DEMO_KEY" if _key() == "DEMO_KEY" else "personal",
        "cache_age_min": _cache_age_min(),
    }


def _cache_age_min():
    if not CACHE.exists():
        return None
    files = list(CACHE.glob("WSAEnlilSimulations_*.json"))
    if not files:
        return None
    newest = max(f.stat().st_mtime for f in files)
    return round((time.time() - newest) / 60, 1)


# ------------------------------------------------------------------ the planner's check
# DONKI's arrival times are WSA-ENLIL model forecasts. At Earth they miss by about 10 h on average (mean absolute
# error of the CCMC predictions, Wold et al. 2018, J. Space Weather Space Clim. 8, A17; Riley et al. 2018, Space
# Weather 16, 1245). Nobody scores them at Mars, where a CME has further to travel, so the planner treats every
# predicted arrival as a window of +/- 12 h around the forecast.
ARRIVAL_UNCERTAINTY_H = 12.0
_plan_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="donki-plan")
_plan_job = {"f": None}


def arrivals_for_plan(max_wait_s: float = 2.5, now: datetime | None = None) -> tuple[list[dict] | None, dict]:
    """Mars CME arrivals for the planner without making a plan wait on DONKI.

    The 10-minute memo if fresh; else a live fetch for up to max_wait_s (it carries on in the background and
    fills the memo); else the newest cached WSA-ENLIL response on disk. Returns (arrivals or None, source info).
    """
    now = now or datetime.now(timezone.utc)
    with _memo_lock:
        data = _memo["data"] if _memo["data"] is not None and time.time() - _memo["t"] < MEMO_S else None
    if data is None:
        f = _plan_job["f"]
        if f is None or f.done():
            f = _plan_job["f"] = _plan_pool.submit(summary)
        try:
            data = f.result(timeout=max_wait_s)
        except Exception:
            data = None
    if data is not None and not any(e.startswith("WSAEnlilSimulations") for e in data.get("errors", [])):
        return list(data.get("mars_arrivals", [])), {"source": "live", "fetched_utc": data.get("fetched_utc"),
                                                      "cache_age_min": data.get("cache_age_min")}
    cached = _latest_cache("WSAEnlilSimulations")
    if cached is not None:
        return mars_arrivals(cached, now), {"source": "cache", "cache_age_min": _cache_age_min()}
    return None, {"source": "unavailable"}


def plan_check(arrivals: list[dict], start: datetime, suited: tuple[float, float], total_s: float,
               uncertainty_h: float = ARRIVAL_UNCERTAINTY_H) -> dict:
    """Compare the suited window (seconds after `start`) with predicted CME arrivals at Mars.

    Per arrival: the forecast time and its +/- uncertainty window relative to the EVA start, whether the forecast
    falls inside the suited window ("inside") or only its uncertainty window overlaps it ("window"), and the level:
    a full hit forecast during the suited time is NO-GO, a possible full hit or a glancing blow during it is a
    caution, and a possible glancing blow is advisory.
    """
    t_on, t_off = suited
    out, worst = [], "ok"
    rank = {"ok": 0, "info": 1, "caution": 2, "nogo": 3}
    for a in arrivals:
        when = _parse(str(a.get("arrival", ""))[:19])
        if when is None:
            continue
        t = (when - start).total_seconds()
        w0, w1 = t - uncertainty_h * 3600, t + uncertainty_h * 3600
        glancing = bool(a.get("glancing"))
        if t_on <= t <= t_off:
            overlap = "inside"
            level = "caution" if glancing else "nogo"
        elif w0 <= t_off and w1 >= t_on:
            overlap = "window"
            level = "info" if glancing else "caution"
        else:
            overlap, level = None, "ok"
        # keep arrivals that matter to this EVA or come within two sols of it, for the timeline
        if overlap or (-48 * 3600 <= t <= total_s + 48 * 3600):
            out.append({"cme": a.get("cme"), "arrival": when.isoformat(), "glancing": glancing,
                        "speed_kms": a.get("speed_kms"), "link": a.get("link"),
                        "t_rel_s": round(t, 1), "t0_rel_s": round(w0, 1), "t1_rel_s": round(w1, 1),
                        "overlap": overlap, "level": level})
        if rank[level] > rank[worst]:
            worst = level
    return {"arrivals": out, "level": worst, "uncertainty_h": uncertainty_h}


def is_clear(arrivals: list[dict], start: datetime, suited: tuple[float, float],
             uncertainty_h: float = ARRIVAL_UNCERTAINTY_H) -> bool:
    """True when no arrival window (glancing or not) touches the suited window."""
    return plan_check(arrivals, start, suited, suited[1], uncertainty_h)["level"] == "ok"
