"""When the HUD fails (feature B2) and how to say where you are over the radio (G5).

Mars has no global magnetic field, so a compass is useless, and there is no GPS. If the visor display dies, the
crew walks home with a paper card, as Apollo crews navigated with cuff maps. For every leg the card gives:

* a **shadow clock**: where your shadow points if you hold the heading ("shadow at your 4 o'clock"),
* a **landmark clock**: where a big landmark stands (Mount Sharp's summit, the hab),
* a **pace count** (a pace is two steps),
* the **grid references** of the leg's ends, and at every station a **skyline sketch** to recognise it by.

Grid references follow Apollo traverse maps: lettered columns west to east, numbered rows north to south, 250 m
squares, so a position can be said over the radio ("Kilo seven").
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from html import escape

import numpy as np

from marsgeo import mars24

GRID_M = 250.0
PACE_M = 1.5  # one pace = two suited steps of ~0.75 m (planning assumption, printed on the card)
NATO = ["Alfa", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliett", "Kilo", "Lima", "Mike",
        "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"]
NUM = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
       "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]


# ------------------------------------------------------------------ G5: grid references
def grid_spec(site) -> dict:
    g = site.grid
    w = g.width * g.res
    h = g.height * g.res
    n_cols = int(math.ceil(w / GRID_M))
    n_rows = int(math.ceil(h / GRID_M))
    return {"cell_m": GRID_M, "cols": n_cols, "rows": n_rows, "x_min": g.x_min, "y_max": g.y_max}


def gridref(site, lon: float, lat: float) -> dict:
    """'K7' and how to say it ('Kilo seven'), plus where in the square (a 3 x 3 keypad: 1 = north-west ... 9)."""
    sp = grid_spec(site)
    x, y = (float(v) for v in site.grid.lonlat_to_xy(lon, lat))
    cx = (x - sp["x_min"]) / GRID_M
    ry = (sp["y_max"] - y) / GRID_M
    ci, ri = int(math.floor(cx)), int(math.floor(ry))
    inside = 0 <= ci < sp["cols"] and 0 <= ri < sp["rows"]
    ci_c, ri_c = min(max(ci, 0), sp["cols"] - 1), min(max(ri, 0), sp["rows"] - 1)
    col = chr(ord("A") + ci_c)
    row = ri_c + 1
    kx = min(2, max(0, int((cx - ci) * 3)))
    ky = min(2, max(0, int((ry - ri) * 3)))
    key = ky * 3 + kx + 1
    return {"ref": f"{col}{row}", "say": f"{NATO[ord(col) - 65]} {NUM[row] if row < len(NUM) else row}", "col": col, "row": row,
            "keypad": key, "ref_fine": f"{col}{row}-{key}", "inside": inside}


def grid_lines(site) -> dict:
    """The grid as lines (lon/lat) and square labels, for the map."""
    sp = grid_spec(site)
    g = site.grid
    x0, y1 = sp["x_min"], sp["y_max"]
    x1, y0 = x0 + sp["cols"] * GRID_M, y1 - sp["rows"] * GRID_M
    lines = []
    for k in range(sp["cols"] + 1):
        x = x0 + k * GRID_M
        lon, lat = g.xy_to_lonlat(np.array([x, x]), np.array([y0, y1]))
        lines.append([[float(lon[0]), float(lat[0])], [float(lon[1]), float(lat[1])]])
    for k in range(sp["rows"] + 1):
        y = y1 - k * GRID_M
        lon, lat = g.xy_to_lonlat(np.array([x0, x1]), np.array([y, y]))
        lines.append([[float(lon[0]), float(lat[0])], [float(lon[1]), float(lat[1])]])
    cols = []
    for k in range(sp["cols"]):
        lon, lat = g.xy_to_lonlat(x0 + (k + 0.5) * GRID_M, y1)
        cols.append({"label": chr(65 + k), "lon": float(lon), "lat": float(lat)})
    rows = []
    for k in range(sp["rows"]):
        lon, lat = g.xy_to_lonlat(x0, y1 - (k + 0.5) * GRID_M)
        rows.append({"label": str(k + 1), "lon": float(lon), "lat": float(lat)})
    return {**sp, "lines": lines, "col_labels": cols, "row_labels": rows}


# ------------------------------------------------------------------ B2: per-leg aids
def clock(rel_deg: float) -> int:
    """Relative bearing -> clock position (12 = straight ahead, 3 = right)."""
    h = int(round((rel_deg % 360.0) / 30.0)) % 12
    return 12 if h == 0 else h


def _bearing(site, a, b) -> float:
    x0, y0 = site.grid.lonlat_to_xy(a[0], a[1])
    x1, y1 = site.grid.lonlat_to_xy(b[0], b[1])
    return math.degrees(math.atan2(float(x1 - x0), float(y1 - y0))) % 360.0


def leg_aids(site, plan: dict) -> list[dict]:
    start = datetime.fromisoformat(plan["totals"]["start_utc"])
    lat0, lon0 = site.grid.lat0, site.grid.lon0
    walks = [e for e in plan["events"] if e["kind"] == "walk"]
    hab = plan.get("_hab") or site.cfg.get("habitat")
    feats = site.cfg.get("skyline_features", [])
    out = []
    for leg, ev in zip(plan["legs"], walks):
        tm = (float(ev["t0"]) + float(ev["t1"])) / 2.0
        el, az, _ = mars24.sun_position(mars24.mars_time(start + timedelta(seconds=tm)), lat0, lon0)
        head = float(leg["bearing_deg"])
        a = leg["path"][0]
        b = leg["path"][-1]
        mid = leg["path"][len(leg["path"]) // 2]
        shadow = None if el < 4.0 else clock(az + 180.0 - head)
        sun = None if el < 0.0 else clock(az - head)
        marks = []
        for f in feats:
            marks.append({"name": f["name"], "clock": clock(_bearing(site, mid, (f["lon"], f["lat"])) - head)})
        if hab:
            hb = _bearing(site, mid, (hab["lon"], hab["lat"]))
            x0, y0 = site.grid.lonlat_to_xy(mid[0], mid[1])
            x1, y1 = site.grid.lonlat_to_xy(hab["lon"], hab["lat"])
            marks.append({"name": "Hab", "clock": clock(hb - head), "dist_m": round(float(math.hypot(x1 - x0, y1 - y0)))})
        out.append({
            "from": leg["from"], "to": leg["to"], "heading_deg": round(head), "dist_m": round(float(leg["dist_m"])),
            "paces": int(round(float(leg["dist_m"]) / PACE_M)), "time_min": round(float(leg["time_s"]) / 60.0),
            "sun_elev": round(float(el), 1), "sun_az": round(float(az)), "shadow_clock": shadow, "sun_clock": sun,
            "landmarks": marks, "start_ref": gridref(site, a[0], a[1]), "end_ref": gridref(site, b[0], b[1]),
            "t0_ltst": ev.get("t0_ltst"),
        })
    return out


def station_skylines(site, stops: list[dict]) -> list[dict]:
    """The stored skyline at each station (24 directions) and the named features on it."""
    from . import skyline as sk
    idx = site.skyline
    out = []
    for st in stops:
        r, c = (int(round(float(v))) for v in site.grid4.lonlat_to_rowcol(st["lon"], st["lat"]))
        prof = idx.profile(min(max(r, 0), idx.shape[0] - 1), min(max(c, 0), idx.shape[1] - 1)) if idx is not None else None
        out.append({"name": st.get("name", "Stop"), "ref": gridref(site, st["lon"], st["lat"]),
                    "elev": [round(float(v), 2) for v in prof] if prof is not None else None,
                    "features": sk.features(site, st["lon"], st["lat"])})
    return out


def skyline_svg(elev: list[float] | None, features: list[dict], w: int = 300, h: int = 64) -> str:
    """A small skyline sketch: horizon height against compass direction, N at the left edge."""
    if not elev:
        return ""
    n = len(elev)
    top = max(4.0, max(elev) + 1.0)
    base = h - 14

    def P(az, e):
        return az / 360.0 * w, base - max(0.0, e) / top * (base - 4)
    pts = [P(k * 360.0 / n, elev[k]) for k in range(n)] + [P(360.0, elev[0])]
    path = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    s = [f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" class="sky">',
         f'<polygon points="0,{base} {path} {w},{base}" fill="#d9c7b3" stroke="#3b2a1d" stroke-width="1.2"/>',
         f'<line x1="0" y1="{base}" x2="{w}" y2="{base}" stroke="#3b2a1d" stroke-width="0.8"/>']
    for k, lab in enumerate("NESW"):
        x = k * w / 4.0
        s.append(f'<text x="{x + 2:.0f}" y="{h - 3}" font-size="9" fill="#444">{lab}</text>')
    for f in features:
        x = f["az"] / 360.0 * w
        s.append(f'<line x1="{x:.1f}" y1="2" x2="{x:.1f}" y2="{base}" stroke="#b42318" stroke-width="0.8" stroke-dasharray="2 2"/>')
        s.append(f'<text x="{min(w - 60, x + 2):.0f}" y="10" font-size="8.5" fill="#b42318">{escape(f["name"].split(" (")[0])}</text>')
    s.append("</svg>")
    return "".join(s)


def render_html(site, plan: dict, stops: list[dict]) -> str:
    """The printable fallback card: one row per leg, one skyline sketch per station."""
    legs = leg_aids(site, plan)
    sky = station_skylines(site, stops)
    rows = []
    for L in legs:
        marks = "; ".join(f"{escape(m['name'].split(' (')[0])} at {m['clock']} o'clock" + (f" ({m['dist_m']} m)" if m.get("dist_m") else "")
                          for m in L["landmarks"])
        sh = f"{L['shadow_clock']} o'clock" if L["shadow_clock"] else "none (sun low)"
        rows.append(f"<tr><td><b>{escape(L['from'])} → {escape(L['to'])}</b><br><span class=m>{L['start_ref']['ref']} → {L['end_ref']['ref']}"
                    f"</span></td><td class=big>{L['heading_deg']:03d}°</td><td class=big>{L['paces']}</td><td>{L['dist_m']} m · {L['time_min']} min</td>"
                    f"<td class=big>{sh}</td><td>{marks}</td></tr>")
    cards = []
    for st in sky:
        cards.append(f"<div class=st><div class=sth><b>{escape(st['name'])}</b> <span>{st['ref']['ref']} · “{st['ref']['say']}”</span></div>"
                     f"{skyline_svg(st['elev'], st['features'])}</div>")
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Fallback card · {escape(site.cfg.get('short_name', ''))}</title>
<style>
body{{font:13px/1.35 'Segoe UI',Inter,system-ui,sans-serif;color:#111;margin:18px;background:#fff}}
h1{{font-size:18px;margin:0 0 2px;letter-spacing:.04em}} .sub{{color:#555;margin-bottom:12px}}
table{{border-collapse:collapse;width:100%;margin-bottom:14px}} th,td{{border:1px solid #999;padding:5px 7px;vertical-align:top;text-align:left}}
th{{background:#eee;font-size:11px;text-transform:uppercase;letter-spacing:.06em}} td.big{{font:700 17px/1.1 Consolas,monospace;text-align:center}}
.m{{font:11px Consolas,monospace;color:#555}} .grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}}
.st{{border:1px solid #999;padding:6px 8px}} .sth{{display:flex;justify-content:space-between;margin-bottom:4px}} .sth span{{font:11px Consolas,monospace;color:#555}}
.note{{font-size:11.5px;color:#333;border-left:3px solid #b42318;padding:4px 8px;background:#fff6f4;margin-bottom:12px}}
@media print{{body{{margin:8mm}}}}
</style></head><body>
<h1>HUD FAILURE · FALLBACK CARD</h1>
<div class="sub">{escape(site.cfg.get('name', ''))} · EVA starts {escape(plan['totals']['start_utc'][:16].replace('T', ' '))} UTC · sol {plan['totals'].get('mission_sol', '')}</div>
<div class="note"><b>No compass works on Mars</b> (no global magnetic field) and there is no GPS. Hold the <b>shadow clock</b>: keep your shadow at the
given clock position (12 = straight ahead) and you hold the heading. Count paces (1 pace = 2 steps ≈ {PACE_M:g} m). Say your position by grid
square ({GRID_M:g} m squares, columns A→ west to east, rows 1→ north to south, keypad 1-9 inside a square). If lost: walk downstream on the
ways-home network, toward the hab's mast.</div>
<table><tr><th>Leg · grid</th><th>Heading</th><th>Paces</th><th>Distance</th><th>Shadow</th><th>Landmarks</th></tr>{''.join(rows)}</table>
<div class="grid">{''.join(cards)}</div>
</body></html>"""
