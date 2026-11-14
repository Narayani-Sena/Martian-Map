"""Mission patch (feature G1): a patch for each EVA, drawn from the route's own shape, the site and the crew names.

A round embroidered-style patch: the walk as a bold line over a Mars disc, the stops as stars, the habitat as a
small dome, the site and EVA number along the top of the ring and the crew and sol along the bottom. No agency
insignia: the route is the emblem.
"""

from __future__ import annotations

from html import escape

import numpy as np


def _fit(xy: np.ndarray, cx: float, cy: float, radius: float) -> np.ndarray:
    """Scale and centre site metres (x east, y north) into a circle of the given radius, north up."""
    lo, hi = xy.min(0), xy.max(0)
    mid = (lo + hi) / 2
    # fit the farthest point from the bounding-box centre, so a long thin walk uses the whole disc
    span = float(np.max(np.hypot(*(xy - mid).T))) or 1.0
    k = radius / span
    return np.stack([cx + (xy[:, 0] - mid[0]) * k, cy - (xy[:, 1] - mid[1]) * k], 1)


def _star(x: float, y: float, r: float) -> str:
    pts = []
    for i in range(10):
        a = np.pi / 2 + i * np.pi / 5
        rr = r if i % 2 == 0 else r * 0.45
        pts.append(f"{x + rr * np.cos(a):.1f},{y - rr * np.sin(a):.1f}")
    return " ".join(pts)


def render_svg(site, route, stops=(), habitat=None, crew=("EV1", "EV2"), sol=None, eva_no: int = 1,
               dist_km: float | None = None, suit_min: float | None = None, size: int = 360, uid: str = "p") -> str:
    cfg = site.cfg
    c = size / 2
    r_out, r_in = size * 0.47, size * 0.355
    pts = np.asarray(route, float).reshape(-1, 2)
    allpts = [pts] + ([np.asarray(stops, float).reshape(-1, 2)] if len(stops) else []) + ([np.asarray([habitat], float)] if habitat is not None else [])
    every = np.concatenate([a for a in allpts if len(a)]) if any(len(a) for a in allpts) else np.zeros((1, 2))
    x, y = site.grid.lonlat_to_xy(every[:, 0], every[:, 1])
    xy = _fit(np.stack([np.asarray(x), np.asarray(y)], 1), c, c + r_in * 0.19, r_in * 0.55)
    n_r = len(pts)
    route_xy = xy[:n_r]
    stop_xy = xy[n_r:n_r + len(stops)] if len(stops) else np.zeros((0, 2))
    hab_xy = xy[-1] if habitat is not None else None
    d = " ".join(f"{'M' if i == 0 else 'L'}{p[0]:.1f},{p[1]:.1f}" for i, p in enumerate(route_xy))

    site_name = (cfg.get("short_name") or cfg.get("name") or cfg.get("id", "")).upper()
    top = f"{site_name} · EVA-{eva_no}"
    names = [str(n).strip().upper() for n in crew if str(n).strip()][:4] or ["EV1", "EV2"]
    bottom = " · ".join(names) + (f" · SOL {sol}" if sol is not None else "")
    facts = " · ".join(s for s in (f"{dist_km:.2f} KM" if dist_km else "", f"{int(suit_min // 60)} H {int(suit_min % 60):02d}" if suit_min else "") if s)
    fs = size * 0.052 if max(len(top), len(bottom)) < 30 else size * 0.044
    band, cap = (r_in + r_out) / 2, fs * 0.72
    t_r, b_r = band - cap / 2, band + cap / 2  # text baselines, so the letters sit in the middle of the ring band
    stars_bg = "".join(f'<circle cx="{c + dx * size:.1f}" cy="{c + dy * size:.1f}" r="{rr:.1f}" fill="#fff6e8" opacity="{o}"/>'
                       for dx, dy, rr, o in ((-0.17, -0.22, 1.6, 0.9), (0.14, -0.25, 1.2, 0.7), (0.21, -0.2, 1.0, 0.6),
                                             (-0.23, -0.19, 0.9, 0.5), (0.02, -0.29, 1.1, 0.8), (-0.06, -0.24, 0.8, 0.6)))
    stop_marks = "".join(f'<polygon points="{_star(px, py, size * 0.03)}" fill="#ffd27a" stroke="#3a1606" stroke-width="1.4"/>'
                         for px, py in stop_xy)
    hab = ""
    if hab_xy is not None:
        hx, hy, s = hab_xy[0], hab_xy[1], size * 0.022
        hab = (f'<path d="M{hx - s * 1.3:.1f},{hy + s * 0.7:.1f} A{s * 1.3:.1f},{s * 1.3:.1f} 0 0 1 {hx + s * 1.3:.1f},{hy + s * 0.7:.1f} Z" '
               f'fill="#f4f7fb" stroke="#1a2333" stroke-width="1.4"/>')
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}" role="img" aria-label="EVA patch: {escape(top)}, {escape(bottom)}">
<defs>
  <radialGradient id="{uid}-mars" cx="50%" cy="62%" r="62%"><stop offset="0" stop-color="#e3773d"/><stop offset=".55" stop-color="#b5481f"/><stop offset="1" stop-color="#5a1f0f"/></radialGradient>
  <linearGradient id="{uid}-sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0b1330"/><stop offset=".27" stop-color="#3a2a4a"/><stop offset=".335" stop-color="#c98a6a" stop-opacity=".55"/><stop offset=".36" stop-color="#c98a6a" stop-opacity="0"/></linearGradient>
  <path id="{uid}-top" d="M{c - t_r:.1f},{c:.1f} A{t_r:.1f},{t_r:.1f} 0 0 1 {c + t_r:.1f},{c:.1f}"/>
  <path id="{uid}-bot" d="M{c - b_r:.1f},{c:.1f} A{b_r:.1f},{b_r:.1f} 0 0 0 {c + b_r:.1f},{c:.1f}"/>
  <clipPath id="{uid}-disc"><circle cx="{c}" cy="{c}" r="{r_in:.1f}"/></clipPath>
</defs>
<circle cx="{c}" cy="{c}" r="{c - 1:.1f}" fill="#0f1522"/>
<circle cx="{c}" cy="{c}" r="{c - size * 0.012:.1f}" fill="none" stroke="#d9a441" stroke-width="{size * 0.012:.1f}"/>
<circle cx="{c}" cy="{c}" r="{c - size * 0.03:.1f}" fill="none" stroke="#d9a441" stroke-width="1.2" stroke-dasharray="3 3" opacity=".75"/>
<g clip-path="url(#{uid}-disc)">
  <circle cx="{c}" cy="{c}" r="{r_in:.1f}" fill="url(#{uid}-mars)"/>
  <rect x="0" y="0" width="{size}" height="{size}" fill="url(#{uid}-sky)"/>
  {stars_bg}
  <path d="{d}" fill="none" stroke="#2a0d04" stroke-width="{size * 0.034:.1f}" stroke-linejoin="round" stroke-linecap="round" opacity=".55"/>
  <path d="{d}" fill="none" stroke="#fff3df" stroke-width="{size * 0.016:.1f}" stroke-linejoin="round" stroke-linecap="round"/>
  {stop_marks}{hab}
</g>
<circle cx="{c}" cy="{c}" r="{r_in:.1f}" fill="none" stroke="#d9a441" stroke-width="{size * 0.011:.1f}"/>
<text font-family="Arial Black, Arial, Helvetica, sans-serif" font-weight="900" font-size="{fs:.1f}" letter-spacing="{size * 0.006:.1f}" fill="#f4e9d2">
  <textPath href="#{uid}-top" startOffset="50%" text-anchor="middle">{escape(top)}</textPath></text>
<text font-family="Arial Black, Arial, Helvetica, sans-serif" font-weight="900" font-size="{fs:.1f}" letter-spacing="{size * 0.006:.1f}" fill="#f4e9d2">
  <textPath href="#{uid}-bot" startOffset="50%" text-anchor="middle">{escape(bottom)}</textPath></text>
{f'<text x="{c}" y="{c + r_in * 0.86:.1f}" text-anchor="middle" font-family="Consolas, monospace" font-size="{size * 0.034:.1f}" font-weight="700" fill="#ffe7c2" opacity=".9">{escape(facts)}</text>' if facts else ''}
</svg>"""
