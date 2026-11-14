"""The cost of a rock and the EVA debrief (feature C4).

Samples add mass as the EVA goes on, so each one has a price in minutes of margin (computed by the planner: the
same EVA without that stop's samples). Each sample gets a passport: place and grid square, map unit, mineral
signal, time and sun, mass, the nearest rover photo and the crew's voice note. The debrief page puts the walk as
flown against the plan (when a track was recorded by the live link, feature D1), the time at each station and
what was collected.
"""

from __future__ import annotations

import math
from html import escape

import numpy as np

from marsgeo import mars24

from . import fallback


def _hm(h):
    return mars24.hours_to_hms(h)[:5] if h is not None else "—"


def passports(site, plan: dict, stops: list[dict], science_at) -> list[dict]:
    costs = {c.get("id") or c.get("stop"): c for c in (plan.get("samples") or {}).get("per_stop", [])}
    stop_evs = [e for e in plan["events"] if e["kind"] == "stop"]
    out = []
    for k, (st, ev) in enumerate(zip(stops, stop_evs)):
        sci = science_at(site, st["lon"], st["lat"]) or {"reasons": []}
        unit = site.geology_at(st["lon"], st["lat"])
        c = costs.get(st.get("id")) or costs.get(st.get("name")) or {}
        light = ev.get("light") or {}
        out.append({
            "id": f"{st.get('id', 'S')}-{k + 1:02d}", "stop": st.get("name", "Stop"), "lon": st["lon"], "lat": st["lat"],
            "grid": fallback.gridref(site, st["lon"], st["lat"]),
            "unit": f"{unit['code']} · {unit['name']}" if unit else "—",
            "signal": "; ".join(r["text"] for r in sci["reasons"][:2]) or "no strong orbital signal",
            "t0_ltst": ev.get("t0_ltst"), "t1_ltst": ev.get("t1_ltst"), "sun": light.get("note", ""),
            "kg": c.get("kg", 0.0), "margin_cost_min": c.get("margin_cost_min"), "carried_min": c.get("carried_min"),
            "note": st.get("note") or "",
        })
    return out


def actual_at_stations(track: list[list[float]] | None, stops: list[dict], xy_of, radius_m: float = 20.0) -> list[dict | None]:
    """From a recorded track [[t_s, lon, lat], ...]: when the crew was within radius_m of each stop."""
    if not track:
        return [None] * len(stops)
    a = np.asarray(track, float)
    x, y = xy_of(a[:, 1], a[:, 2])
    out = []
    for st in stops:
        sx, sy = xy_of(st["lon"], st["lat"])
        near = np.hypot(x - float(sx), y - float(sy)) <= radius_m
        if not near.any():
            out.append(None)
            continue
        t = a[near, 0]
        out.append({"t0": float(t.min()), "t1": float(t.max()), "min": round(float(t.max() - t.min()) / 60.0, 1)})
    return out


def track_stats(track, xy_of, plan) -> dict | None:
    if not track or len(track) < 2:
        return None
    a = np.asarray(track, float)
    x, y = xy_of(a[:, 1], a[:, 2])
    walked = float(np.hypot(np.diff(x), np.diff(y)).sum())
    # cross-track error against the planned path
    pp = np.array([pt for L in plan["legs"] for pt in L["path"]], float)
    px, py = xy_of(pp[:, 0], pp[:, 1])
    step = max(1, len(x) // 400)
    errs = [float(np.min(np.hypot(px - xi, py - yi))) for xi, yi in zip(x[::step], y[::step])]
    return {"walked_m": round(walked, 1), "planned_m": plan["totals"]["dist_m"], "mean_off_m": round(float(np.mean(errs)), 1),
            "max_off_m": round(float(np.max(errs)), 1), "duration_min": round(float(a[-1, 0] - a[0, 0]) / 60.0, 1)}


def render_html(site, plan: dict, stops: list[dict], science_at, track=None, map_svg: str = "") -> str:
    pp = passports(site, plan, stops, science_at)
    act = actual_at_stations(track, stops, site.grid.lonlat_to_xy)
    ts = track_stats(track, site.grid.lonlat_to_xy, plan)
    t = plan["totals"]
    rows = []
    for p, a, ev in zip(pp, act, [e for e in plan["events"] if e["kind"] == "stop"]):
        planned = f"{_hm(ev.get('t0_ltst'))}–{_hm(ev.get('t1_ltst'))} ({round((ev['t1'] - ev['t0']) / 60)} min)"
        actual = f"{round(a['min'])} min on station" if a else ("not visited" if track else "no track recorded")
        rows.append(f"<tr><td><b>{escape(p['stop'])}</b><br><span class=m>{p['grid']['ref_fine']}</span></td><td>{planned}</td><td>{actual}</td></tr>")
    cards = []
    for p in pp:
        cost = f"{p['margin_cost_min']:.1f} min of margin" if p["margin_cost_min"] is not None else "—"
        cards.append(f"""<div class=pp><div class=pph><b>SAMPLE {escape(p['id'])}</b><span>{escape(p['stop'])}</span></div>
<dl><dt>Place</dt><dd>{abs(p['lat']):.5f}°{'S' if p['lat'] < 0 else 'N'} {p['lon']:.5f}°E · square {p['grid']['ref_fine']} (“{p['grid']['say']}”)</dd>
<dt>Map unit</dt><dd>{escape(p['unit'])}</dd><dt>Signal</dt><dd>{escape(p['signal'])}</dd>
<dt>Time</dt><dd>{_hm(p['t0_ltst'])}–{_hm(p['t1_ltst'])} LTST</dd><dt>Sun</dt><dd>{escape(p['sun'])}</dd>
<dt>Mass</dt><dd>{p['kg']:.1f} kg · carried {p['carried_min'] or 0:.0f} min · costs <b>{cost}</b></dd>
<dt>Voice note</dt><dd>{escape(p['note']) or '<i>none recorded</i>'}</dd></dl></div>""")
    walk = (f"<p>Walked <b>{ts['walked_m']:.0f} m</b> against {ts['planned_m']:.0f} m planned, on average {ts['mean_off_m']:.0f} m off the line "
            f"(at most {ts['max_off_m']:.0f} m), over {ts['duration_min']:.0f} min of track.</p>") if ts else \
        "<p class=dim>No track was recorded (open the habitat console in the Earth link panel while the helmet walks to record one). The page shows the plan.</p>"
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>EVA debrief · {escape(site.cfg.get('short_name', ''))}</title>
<style>body{{font:13px/1.4 'Segoe UI',Inter,system-ui,sans-serif;color:#111;margin:18px;background:#fff}} h1{{font-size:19px;margin:0}}
.sub{{color:#555;margin:2px 0 12px}} table{{border-collapse:collapse;width:100%;margin:8px 0 14px}} th,td{{border:1px solid #aaa;padding:5px 7px;text-align:left;vertical-align:top}}
th{{background:#eee;font-size:11px;text-transform:uppercase;letter-spacing:.05em}} .m{{font:11px Consolas,monospace;color:#555}} .dim{{color:#666}}
.grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}} .pp{{border:1.5px solid #333;border-radius:6px;padding:8px 10px}}
.pph{{display:flex;justify-content:space-between;border-bottom:1px solid #ccc;padding-bottom:4px;margin-bottom:4px}} .pph span{{color:#555}}
dl{{display:grid;grid-template-columns:86px 1fr;gap:2px 8px;margin:0;font-size:12px}} dt{{color:#666}} dd{{margin:0}}
.kpi{{display:flex;gap:16px;margin:6px 0 10px}} .kpi div{{border:1px solid #bbb;border-radius:6px;padding:6px 10px}} .kpi b{{display:block;font-size:17px}}
@media print{{body{{margin:8mm}}}}</style></head><body>
<h1>EVA DEBRIEF</h1><div class=sub>{escape(site.cfg.get('name', ''))} · sol {t.get('mission_sol', '')} · {escape(t['start_utc'][:16].replace('T', ' '))} UTC</div>
<div class=kpi><div><b>{t['dist_m'] / 1000:.2f} km</b>planned walk</div><div><b>{round(t['suit_s'] / 60)} min</b>in suits</div>
<div><b>{(plan.get('samples') or {}).get('total_kg', 0):.1f} kg</b>of samples</div><div><b>{t['min_margin_min']:.0f} min</b>worst margin (with the samples)</div></div>
<h3>Walked against planned</h3>{walk}{map_svg}
<h3>Time at each station</h3><table><tr><th>Station</th><th>Planned</th><th>Actual</th></tr>{''.join(rows)}</table>
<h3>What was collected: sample passports</h3><p class=dim>Samples add mass as the EVA goes on. Each one's price is the margin the
same EVA would keep without it (the suit works harder carrying it home).</p><div class=grid>{''.join(cards)}</div></body></html>"""
