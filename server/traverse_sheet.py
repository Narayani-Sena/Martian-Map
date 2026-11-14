"""Apollo-style traverse sheet: a printable photomap with the route and stations, plus the tables a
crew would carry (station timeline, tasks, consumables, contingencies).

Apollo 15-17 crews carried traverse maps (orbital photo, planned route, numbered stations, times)
and cuff checklists. This renders the same for a Martian Map plan: an SVG map on a HiRISE photo
base with 10 m contours, and a print-ready HTML page around it.
"""

from __future__ import annotations

import base64
import io
import json
import math
from html import escape

import numpy as np
from PIL import Image, ImageEnhance

from marsgeo import mars24

STOP_COLORS = {"hollow": "#e08e0b", "ridge": "#d4521a", "depot": "#b8860b", "outcrop": "#c2410c", "custom": "#9b4dca"}


def _hm(h: float) -> str:
    return mars24.hours_to_hms(h)[:5]


def _dur(s: float) -> str:
    m = int(round(s / 60.0))
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def _tplus(s: float) -> str:
    m = int(round(s / 60.0))
    return f"T+{m // 60}:{m % 60:02d}"


def _xy(site, lon, lat):
    x, y = site.grid.lonlat_to_xy(np.asarray(lon, float), np.asarray(lat, float))
    return np.atleast_1d(x), np.atleast_1d(y)


def shelters_for(site, plan: dict) -> list[dict]:
    """Shelters during this EVA: on a rover-assisted EVA the pressurized rover is parked at the drop-off."""
    shelters = [dict(sh) for sh in site.cfg.get("shelters", [])]
    rv = plan.get("rover") or {}
    if rv.get("enabled"):
        drop = rv["dropoff"]
        movable = [sh for sh in shelters if sh.get("kind") == "rover"]
        if movable:
            movable[0].update(lon=drop["lon"], lat=drop["lat"], note="Parked at the drop-off")
        else:
            shelters.append({"id": rv.get("name", "PR"), "name": f"Pressurized rover {rv.get('name', '')}", "kind": "rover",
                             "lon": drop["lon"], "lat": drop["lat"]})
    return shelters


def render_svg(site, plan: dict, width_px: int = 1080, extra_lines: list | None = None) -> str:
    """extra_lines: [(lon array, lat array, colour)] drawn over the route (the debrief's walked track)."""
    g = site.grid
    prof = plan["profile"]
    rx, ry = _xy(site, prof["lon"], prof["lat"])
    hab = site.cfg.get("habitat", {})
    hx, hy = _xy(site, hab.get("lon", g.lon0), hab.get("lat", g.lat0))
    stops = site.cfg.get("stops", [])
    shelters = shelters_for(site, plan)
    rv = plan.get("rover") or {}
    drives = []
    for L in rv.get("legs", []) if rv.get("enabled") else []:
        a = np.asarray(L["path"], float)
        if a.ndim == 2 and len(a) >= 2:
            drives.append(_xy(site, a[:, 0], a[:, 1]))
    xs = list(rx) + list(hx)
    ys = list(ry) + list(hy)
    for dx, dy in drives:
        xs += list(dx)
        ys += list(dy)
    for sh in shelters:
        sx, sy = _xy(site, sh["lon"], sh["lat"])
        xs += list(sx)
        ys += list(sy)
    margin = 110.0
    x0, x1 = min(xs) - margin, max(xs) + margin
    y0, y1 = min(ys) - margin, max(ys) + margin
    x0, x1 = max(x0, g.x_min), min(x1, g.x_max)
    y0, y1 = max(y0, g.y_min), min(y1, g.y_max)
    scale = width_px / (x1 - x0)
    height_px = int(round((y1 - y0) * scale))

    def P(x, y):
        return (x - x0) * scale, (y1 - y) * scale

    # photo base: the HiRISE drape cropped to the traverse, lightened so the ink reads
    tex = Image.open(site.dir / "texture_4096.jpg").convert("RGB")
    tw, th = tex.size
    u0, u1 = (x0 - g.x_min) / (g.width * g.res) * tw, (x1 - g.x_min) / (g.width * g.res) * tw
    v0, v1 = (g.y_max - y1) / (g.height * g.res) * th, (g.y_max - y0) / (g.height * g.res) * th
    photo = tex.crop((int(u0), int(v0), int(math.ceil(u1)), int(math.ceil(v1)))).resize((width_px, height_px), Image.LANCZOS)
    photo = ImageEnhance.Color(photo).enhance(0.55)
    photo = Image.blend(photo, Image.new("RGB", photo.size, (255, 255, 255)), 0.22)
    buf = io.BytesIO()
    photo.save(buf, "JPEG", quality=84)
    b64 = base64.b64encode(buf.getvalue()).decode()

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width_px} {height_px}" width="100%" '
           f'style="font-family:Arial,Helvetica,sans-serif;background:#fff">',
           f'<image href="data:image/jpeg;base64,{b64}" x="0" y="0" width="{width_px}" height="{height_px}"/>']

    # 10 m contours (index contours every 50 m thicker, with labels)
    cpath = site.dir / "contours.geojson"
    if cpath.exists():
        for f in json.loads(cpath.read_text()).get("features", []):
            elev = float(f["properties"].get("elev", 0.0))
            idx = bool(f["properties"].get("index", False))
            geom = f["geometry"]
            lines = geom["coordinates"] if geom["type"] == "MultiLineString" else [geom["coordinates"]]
            for line in lines:
                a = np.asarray(line, float)
                if a.shape[0] < 2:
                    continue
                lx, ly = _xy(site, a[:, 0], a[:, 1])
                keep = (lx > x0 - 50) & (lx < x1 + 50) & (ly > y0 - 50) & (ly < y1 + 50)
                if not keep.any():
                    continue
                pts = " ".join(f"{P(px, py)[0]:.1f},{P(px, py)[1]:.1f}" for px, py in zip(lx, ly))
                out.append(f'<polyline points="{pts}" fill="none" stroke="#7a4a21" stroke-opacity="{0.75 if idx else 0.4}" '
                           f'stroke-width="{1.4 if idx else 0.7}"/>')
                if idx:
                    k = int(np.argmax(keep)) + int(keep.sum() // 2)
                    k = min(k, len(lx) - 1)
                    tx, ty = P(lx[k], ly[k])
                    if 10 < tx < width_px - 40 and 10 < ty < height_px - 10:
                        out.append(f'<text x="{tx:.0f}" y="{ty:.0f}" font-size="10" fill="#5a3412" stroke="#fff" stroke-width="2.5" '
                                   f'paint-order="stroke">{elev:.0f} m</text>')

    # walk-back rings
    rings = plan.get("rings", {})
    for f in (rings or {}).get("features", []):
        mins = f.get("properties", {}).get("minutes")
        geom = f.get("geometry", {})
        lines = geom.get("coordinates", []) if geom.get("type") == "MultiLineString" else [geom.get("coordinates", [])]
        for line in lines:
            a = np.asarray(line, float)
            if a.ndim != 2 or a.shape[0] < 6:
                continue
            lx, ly = _xy(site, a[:, 0], a[:, 1])
            pts = " ".join(f"{P(px, py)[0]:.1f},{P(px, py)[1]:.1f}" for px, py in zip(lx, ly))
            out.append(f'<polyline points="{pts}" fill="none" stroke="#1d7a3a" stroke-width="1.2" stroke-dasharray="5 4" stroke-opacity="0.8"/>')
        if lines and len(lines[0]) > 6:
            a = np.asarray(lines[0], float)
            lx, ly = _xy(site, a[:1, 0], a[:1, 1])
            tx, ty = P(lx[0], ly[0])
            out.append(f'<text x="{tx:.0f}" y="{ty:.0f}" font-size="10" fill="#1d7a3a" stroke="#fff" stroke-width="2.5" paint-order="stroke">{mins} min</text>')

    # rover drives: white casing + dark green dashes (out and back usually share most of the track)
    for dx, dy in drives:
        dp_ = " ".join(f"{P(px, py)[0]:.1f},{P(px, py)[1]:.1f}" for px, py in zip(dx, dy))
        out.append(f'<polyline points="{dp_}" fill="none" stroke="#fff" stroke-width="7" stroke-linejoin="round" stroke-opacity="0.9"/>')
        out.append(f'<polyline points="{dp_}" fill="none" stroke="#14532d" stroke-width="3.5" stroke-dasharray="10 6" stroke-linejoin="round"/>')

    # route: white casing + blue line + direction arrows every ~120 m
    rp = " ".join(f"{P(px, py)[0]:.1f},{P(px, py)[1]:.1f}" for px, py in zip(rx, ry))
    out.append(f'<polyline points="{rp}" fill="none" stroke="#fff" stroke-width="6" stroke-linejoin="round"/>')
    out.append(f'<polyline points="{rp}" fill="none" stroke="#0b5fff" stroke-width="3" stroke-linejoin="round"/>')
    for lon_a, lat_a, col in extra_lines or []:
        ex, ey = _xy(site, lon_a, lat_a)
        ep = " ".join(f"{a:.1f},{b:.1f}" for a, b in (P(x_, y_) for x_, y_ in zip(ex, ey)))
        out.append(f'<polyline points="{ep}" fill="none" stroke="{col}" stroke-width="2.5" stroke-dasharray="6 3" stroke-linejoin="round"/>')
    d = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(rx), np.diff(ry)))])
    for target in np.arange(60.0, d[-1], 120.0):
        i = int(np.searchsorted(d, target))
        if 0 < i < len(rx):
            ax, ay = P(rx[i], ry[i])
            bx, by = P(rx[i - 1], ry[i - 1])
            ang = math.degrees(math.atan2(ay - by, ax - bx))
            out.append(f'<path d="M -6 -5 L 6 0 L -6 5 Z" fill="#0b5fff" stroke="#fff" stroke-width="1" '
                       f'transform="translate({ax:.1f},{ay:.1f}) rotate({ang:.1f})"/>')

    # shelters, habitat and stations
    for sh in shelters:
        sx, sy = _xy(site, sh["lon"], sh["lat"])
        px, py = P(sx[0], sy[0])
        parked = rv.get("enabled") and sh.get("kind") == "rover"
        if parked:  # the rover itself, at the drop-off: a rounded box like a vehicle symbol
            out.append(f'<rect x="{px - 14:.1f}" y="{py - 8:.1f}" width="28" height="16" rx="5" fill="#14532d" stroke="#fff" stroke-width="2"/>')
            out.append(f'<text x="{px:.1f}" y="{py + 4:.1f}" font-size="9" font-weight="800" text-anchor="middle" fill="#fff">{escape(sh.get("id", "PR"))}</text>')
            label = f"{escape(sh.get('id', 'PR'))} drop-off · shelter"
        else:
            out.append(f'<path d="M {px:.1f} {py - 9:.1f} L {px + 9:.1f} {py + 7:.1f} L {px - 9:.1f} {py + 7:.1f} Z" fill="#1d7a3a" stroke="#fff" stroke-width="1.5"/>')
            label = f"{escape(sh.get('id', 'PR'))} shelter"
        out.append(f'<text x="{px + 17:.0f}" y="{py + 5:.0f}" font-size="12" font-weight="700" fill="#14532d" stroke="#fff" '
                   f'stroke-width="3" paint-order="stroke">{label}</text>')
    px, py = P(hx[0], hy[0])
    out.append(f'<rect x="{px - 9:.1f}" y="{py - 9:.1f}" width="18" height="18" fill="#0b5fff" stroke="#fff" stroke-width="2"/>')
    out.append(f'<text x="{px + 13:.0f}" y="{py + 5:.0f}" font-size="13" font-weight="800" fill="#0b2a7a" stroke="#fff" '
               f'stroke-width="3" paint-order="stroke">HAB</text>')
    arrivals = {str(e.get("id")): e for e in plan["events"] if e["kind"] == "stop"}
    for i, s in enumerate(stops, start=1):
        sx, sy = _xy(site, s["lon"], s["lat"])
        px, py = P(sx[0], sy[0])
        col = STOP_COLORS.get(s.get("kind", "custom"), "#9b4dca")
        e = arrivals.get(str(s.get("id")))
        sub = f"{_tplus(e['t0'])} · {_dur(e['t1'] - e['t0'])}" if e else ""
        out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="12" fill="{col}" stroke="#fff" stroke-width="2.5"/>')
        out.append(f'<text x="{px:.1f}" y="{py + 4.5:.1f}" font-size="13" font-weight="800" text-anchor="middle" fill="#fff">{i}</text>')
        out.append(f'<text x="{px + 16:.0f}" y="{py - 2:.0f}" font-size="13" font-weight="800" fill="#222" stroke="#fff" stroke-width="3.5" '
                   f'paint-order="stroke">STA {i} · {escape(s.get("name", ""))}</text>')
        out.append(f'<text x="{px + 16:.0f}" y="{py + 13:.0f}" font-size="11" fill="#333" stroke="#fff" stroke-width="3" paint-order="stroke">{sub}</text>')

    # north arrow and scale bar
    out.append(f'<g transform="translate({width_px - 46},{46})"><circle r="24" fill="#fff" fill-opacity="0.85" stroke="#222"/>'
               '<path d="M 0 -18 L 7 6 L 0 1 L -7 6 Z" fill="#222"/><text y="20" font-size="11" font-weight="800" text-anchor="middle">N</text></g>')
    bar_m = 200 if (x1 - x0) > 900 else 100
    bw = bar_m * scale
    out.append(f'<g transform="translate(20,{height_px - 28})"><rect x="-8" y="-16" width="{bw + 64:.0f}" height="34" fill="#fff" fill-opacity="0.85"/>'
               f'<rect x="0" y="0" width="{bw / 2:.1f}" height="6" fill="#222"/><rect x="{bw / 2:.1f}" y="0" width="{bw / 2:.1f}" height="6" fill="#fff" stroke="#222"/>'
               f'<text x="0" y="-4" font-size="11">0</text><text x="{bw:.0f}" y="-4" font-size="11" text-anchor="middle">{bar_m} m</text>'
               f'<text x="{bw + 10:.0f}" y="7" font-size="10" fill="#444">contours 10 m</text></g>')
    out.append("</svg>")
    return "\n".join(out)


def render_html(site, plan: dict, walk: dict | None = None, crew=("EV1", "EV2"), postcards: bool = True, postcard_site=None) -> str:
    cfg = site.cfg
    tt = plan["totals"]
    sim = plan["sim"]
    prof = plan["profile"]
    svg = render_svg(site, plan)
    stops = {str(s.get("id")): s for s in cfg.get("stops", [])}
    shelters = shelters_for(site, plan)
    rv = plan.get("rover") or {}
    riding = bool(rv.get("enabled"))
    haven = f"{rv.get('name', 'the rover')} (parked at the drop-off)" if riding else "the hab"
    ingress = next((e for e in reversed(plan["events"]) if e["kind"] == "ingress"), plan["events"][-1])

    def shelter_dist(lon, lat):
        if not shelters:
            return None
        x, y = _xy(site, lon, lat)
        best = min(shelters, key=lambda sh: float(np.hypot(*(np.array(_xy(site, sh["lon"], sh["lat"])).ravel() - np.array([x[0], y[0]])))))
        sx, sy = _xy(site, best["lon"], best["lat"])
        return best.get("id", "PR"), float(np.hypot(sx[0] - x[0], sy[0] - y[0]))

    rows = []
    n = 0
    for e in plan["events"]:
        if e["kind"] != "stop":
            continue
        n += 1
        s = stops.get(str(e.get("id")), {})
        k = int(np.searchsorted(np.asarray(prof["t"]), e["t0"]))
        k = min(max(k, 0), len(prof["t"]) - 1)
        wb = prof["walkback_min"][k]
        sd = shelter_dist(s.get("lon", 0), s.get("lat", 0)) if s else None
        tasks = "".join(f"<li>&#9744; {escape(t)}</li>" for t in e.get("tasks", []) if t)
        rows.append(f"<tr><td class='sta'>{n}</td><td><b>{escape(e['name'])}</b><br><span class='dim'>{escape(s.get('kind', ''))}</span></td>"
                    f"<td class='mono'>{_tplus(e['t0'])}<br>{_hm(e['t0_ltst'])} LTST</td><td class='mono'>{_dur(e['t1'] - e['t0'])}</td>"
                    f"<td class='mono'>{'—' if wb is None else f'{wb:.0f} min'}</td>"
                    f"<td class='mono'>{'—' if not sd else f'{sd[0]} {sd[1]:.0f} m'}</td>"
                    f"<td><ul>{tasks}</ul><div class='dim'>{escape(s.get('science', ''))}</div></td></tr>")

    tl = "".join(f"<tr><td class='mono'>{_tplus(e['t0'])}</td><td class='mono'>{_hm(e['t0_ltst'])}</td><td>{escape(e['kind'].upper())}</td>"
                 f"<td>{escape(e['name'])}</td><td class='mono'>{_dur(e['t1'] - e['t0'])}</td></tr>" for e in plan["events"])

    def first_last(key):
        return f"{sim[key][0]:.0f} % &rarr; {sim[key][-1]:.0f} %"

    rules = [
        f"Planned ingress by {_hm(ingress['t1_ltst'])} LTST; sunset {_hm(tt['sunset_ltst']) if tt.get('sunset_ltst') else '—'} LTST.",
        f"TURN BACK at once if the return margin reaches 0 (plan minimum {tt['min_margin_min']:.0f} min, limited by {tt['limiting']}).",
        f"No slopes above {(walk or plan.get('walk', {})).get('max_slope', 25):.0f}&deg;; walk around boulders of 2 m and more.",
        f"Farthest point is {tt['max_walkback_min']:.0f} min from {escape(haven)}.",
        (f"Solar storm / SEP alert: stop work and get into {escape(rv.get('name', 'the rover'))}'s water-wall shelter." if riding else
         "Solar storm / SEP alert: stop work and go to the hab" + (" or " + ", ".join(escape(s.get('name', 'shelter')) for s in shelters) if shelters else "") + "."),
        (f"No radio line of sight on {tt['comms_dead_fraction'] * 100:.0f} % of the route: report before and after the shadow."
         if tt["comms_dead_fraction"] > 0 else "Radio line of sight on the whole route."),
    ]
    if riding:
        lims = rv.get("limits", {})
        rules.insert(1, f"{escape(rv.get('name', 'PR'))} drives out {tt['drive_m'] / 2000:.2f} km and back ({_dur(tt['drive_s'])} in the cab): "
                        f"slopes under {rv.get('drive', {}).get('max_slope', 20):.0f}&deg;, around boulders of {lims.get('boulder_max_m', 1):g} m and more. "
                        f"Suitport egress and ingress {rv.get('suitport_min', 10):.0f} min each.")
    rules_html = "".join(f"<li>{r}</li>" for r in rules)
    go = "GO" if tt["go"] else "NO-GO"
    patch_svg = ""
    try:  # the EVA's patch (feature G1), drawn from this route
        from . import patch as patchlib
        legs = plan.get("legs") or []
        route = [pt for L in legs for pt in L["path"]]
        if len(route) > 1:
            stop_pts = [L["path"][-1] for L in legs[:-1]] if len(legs) > 1 else []
            patch_svg = patchlib.render_svg(site, route, stop_pts, legs[0]["path"][0], crew, tt.get("mission_sol"), 1,
                                            tt["dist_m"] / 1000, tt.get("suit_s", tt["total_s"]) / 60, size=150, uid="ts")
    except Exception:
        patch_svg = ""
    cards_html = ""
    if postcards:
        try:  # arrival postcards (feature G2), page 3
            from . import postcard as postcardlib
            cards = postcardlib.cards_for_plan(postcard_site or site, plan, w=520, h=230, photos=True, budget_s=6.0)
            cells = []
            for c in cards:
                ph = c.get("photo")
                pimg = (f"<img src='{escape(ph['url'])}' referrerpolicy='no-referrer' style='width:100%;height:150px;object-fit:cover'>"
                        f"<div class='dim'>{escape(ph['rover'])} · {escape(ph.get('camera') or '')} · sol {ph.get('sol')} · {ph['distance_m']} m away</div>") if ph else "<div class='dim'>(no rover photo to hand)</div>"
                cells.append(f"<div class='pc'><img src='{c['img']}' style='width:100%'><div><b>{c['n']}. {escape(c['name'])}</b> · arrive {c['t_plus']} · {c['ltst']} LTST · {escape(c['sun'])}</div>{pimg}</div>")
            if cells:
                cards_html = ("<div class='page2'><h2 style='margin:0 0 6px;font-size:15px'>ARRIVAL POSTCARDS</h2>"
                              "<div class='dim' style='margin-bottom:6px'>Rendered from the HiRISE terrain and colour for the arrival time and sun, a few steps before each stop; the rover's own photo from the nearest place it stood.</div>"
                              f"<div class='pcs'>{''.join(cells)}</div></div>")
        except Exception:
            cards_html = ""
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Traverse sheet · {escape(cfg['name'])}</title>
<style>
@page {{ size: A4 landscape; margin: 9mm; }}
body {{ font-family: Arial, Helvetica, sans-serif; color: #111; margin: 0; padding: 14px; background: #fff; }}
h1 {{ font-size: 20px; margin: 0; letter-spacing: .5px; }}
.head {{ display: flex; justify-content: space-between; border-bottom: 3px solid #111; padding-bottom: 6px; margin-bottom: 8px; }}
.go {{ display: inline-block; padding: 2px 10px; border-radius: 4px; color: #fff; background: {'#1d7a3a' if tt['go'] else '#b3261e'}; font-weight: 800; }}
.grid {{ display: grid; grid-template-columns: 1.55fr 1fr; gap: 12px; align-items: start; }}
table {{ border-collapse: collapse; width: 100%; font-size: 11px; }}
th, td {{ border: 1px solid #999; padding: 4px 5px; vertical-align: top; text-align: left; }}
th {{ background: #eee; }}
.mono {{ font-family: Consolas, 'Courier New', monospace; white-space: nowrap; }}
.sta {{ font-size: 18px; font-weight: 800; text-align: center; }}
.dim {{ color: #555; font-size: 10px; }}
ul {{ margin: 0; padding-left: 0; list-style: none; }}
.box {{ border: 1.5px solid #111; border-radius: 6px; padding: 6px 9px; margin-bottom: 8px; font-size: 11px; }}
.box ol {{ margin: 4px 0 0; padding-left: 18px; }}
.page2 {{ page-break-before: always; }}
.foot {{ font-size: 9px; color: #555; margin-top: 8px; }}
.pcs {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }}
.pc {{ border: 1px solid #999; border-radius: 6px; padding: 6px; font-size: 11px; break-inside: avoid; }}
.pc img {{ display: block; border-radius: 4px; margin-bottom: 4px; }}
</style></head><body>
<div class="head"><div style="display:flex;gap:12px;align-items:center">{patch_svg}<div><h1>EVA TRAVERSE SHEET</h1><div>{escape(cfg['name'])} · {escape(cfg.get('region', ''))}</div></div></div>
<div style="text-align:right"><div><span class="go">{go}</span> &nbsp;<b>Sol {tt['mission_sol']}</b> · egress {_hm(tt['start_ltst'])} LTST ({escape(tt['start_utc'][:16].replace('T', ' '))} UTC)</div>
<div>{tt['dist_m'] / 1000:.2f} km walked{f" + {tt['drive_m'] / 1000:.2f} km by rover" if riding else ""} · {_dur(tt.get('suit_s', tt['total_s']))} suited · climb {tt['ascent_m']:.0f} m · dose {tt['dose_usv']:.0f} &micro;Sv · carried {(walk or plan.get('walk', {})).get('load_kg', 0):.0f} kg</div></div></div>
<div class="grid"><div>{svg}</div>
<div><div class="box"><b>FLIGHT RULES</b><ol>{rules_html}</ol></div>
<div class="box"><b>CONSUMABLES (plan)</b><br>O&#8322; {first_last('o2_pct')} · battery {first_last('battery_pct')}<br>CO&#8322; scrubber {first_last('co2_pct')} · water {first_last('water_pct')}<br>
Minimum return margin <b>{tt['min_margin_min']:.0f} min</b> at {_tplus(tt['min_margin_t'])} ({escape(str(tt['limiting']))})</div>
<table><tr><th>T+</th><th>LTST</th><th>Phase</th><th>Event</th><th>Length</th></tr>{tl}</table></div></div>
<div class="page2"><table><tr><th>Sta</th><th>Station</th><th>Arrive</th><th>Work</th><th>Walk-back</th><th>Nearest shelter</th><th>Tasks &amp; science</th></tr>{''.join(rows)}</table>
<div class="foot">Generated by Martian Map (not a NASA product). Map base: HiRISE colour mosaic (NASA/JPL/UArizona) on the HiRISE 1 m DTM (USGS); contours every 10 m.
Route by A* over slope, roughness, loose sand and boulders detected in HiRISE shadows. Times are Local True Solar Time at the site (Mars24). Inspired by Apollo 15-17 traverse maps and cuff checklists.</div></div>
{cards_html}
</body></html>"""
