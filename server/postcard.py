"""Arrival postcards (feature G2): what the crew sees as they reach each stop, rendered from the terrain model at the
arrival time and sun, beside the rover's own photo from the nearest place it stood.

The renderer marches one ray per image column over the height field (the 1 m DTM close by, the 2 m DTM across the
site, the 200 m regional model beyond it, with Mars' curvature), keeps the first terrain sample that rises above each
pixel, colours it from the HiRISE colour image (the regional mosaic far away), shades it for the sun at that moment
with the terrain shadows, and fades it into a dusty Martian sky with the blue glow Mars has around its sun.
"""

from __future__ import annotations

import base64
import io
import math
import time
from datetime import datetime

import numpy as np
from PIL import Image

from marsgeo import mars24
from marsgeo.grid import sample_bilinear

MARS_R = 3389500.0
EYE_M = 1.7
_cache: dict = {}


def _site_assets(site) -> dict:
    key = (site.cfg.get("id"), str(site.dir))
    a = _cache.get(key)
    if a is not None:
        return a
    tex_p = site.dir / "texture_4096.jpg"
    if not tex_p.exists():
        tex_p = site.dir / "texture_2048.jpg"
    tex = np.asarray(Image.open(tex_p).convert("RGB"), np.uint8)
    reg, rgrid = site.regional
    rtex = None
    if reg is not None and (site.dir / "regional_texture.jpg").exists():
        rtex = np.asarray(Image.open(site.dir / "regional_texture.jpg").convert("RGB"), np.uint8)
    a = {"tex": tex, "reg": reg, "rgrid": rgrid, "rtex": rtex}
    _cache[key] = a
    return a


def _normals(z: np.ndarray, res: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    zf = np.where(np.isfinite(z), z, np.nanmean(z)).astype(np.float32)
    g_row, g_col = np.gradient(zf, res)
    nx, ny, nz = -g_col, g_row, np.ones_like(zf)  # rows run south, so dz/dy = -dz/drow
    ln = np.sqrt(nx * nx + ny * ny + 1.0)
    return nx / ln, ny / ln, nz / ln


def _shade(n, sun_el: float, sun_az: float, lit: np.ndarray | None) -> np.ndarray:
    e, a = math.radians(sun_el), math.radians(sun_az)
    s = (math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))
    lam = np.clip(n[0] * s[0] + n[1] * s[1] + n[2] * s[2], 0.0, 1.0)
    if sun_el <= 0:
        lam = lam * 0.0
    if lit is not None:
        lam = lam * lit
    return (0.34 + 0.86 * lam).astype(np.float32)  # Mars' dusty sky lights the shadows more than Earth's



def _sun_vector(sun_el: float, sun_az: float) -> tuple[float, float, float]:
    e, a = math.radians(sun_el), math.radians(sun_az)
    return (math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))


def _lambert_at(z: np.ndarray, rows: np.ndarray, cols: np.ndarray, res: float, sun_v) -> np.ndarray:
    """Cosine of the sun's angle to the ground at fractional (row, col), from central differences."""
    dzdx = (sample_bilinear(z, rows, cols + 1) - sample_bilinear(z, rows, cols - 1)) / (2 * res)
    dzdrow = (sample_bilinear(z, rows + 1, cols) - sample_bilinear(z, rows - 1, cols)) / (2 * res)
    nx, ny = -dzdx, dzdrow  # rows run south
    ln = np.sqrt(nx * nx + ny * ny + 1.0)
    lam = (nx * sun_v[0] + ny * sun_v[1] + sun_v[2]) / ln
    return np.clip(np.nan_to_num(lam, nan=0.6), 0.0, 1.0).astype(np.float32)


def _light(lam: np.ndarray, sun_el: float) -> np.ndarray:
    """Ambient (Mars' dusty sky lights the shadows more than Earth's) plus sunlight."""
    return (0.36 + (0.84 * lam if sun_el > 0 else 0.0 * lam)).astype(np.float32)


def _tex_bilinear(tex: np.ndarray, fx: np.ndarray, fy: np.ndarray) -> np.ndarray:
    h, w = tex.shape[:2]
    fx = np.clip(fx, 0, w - 1.001)
    fy = np.clip(fy, 0, h - 1.001)
    x0 = np.floor(fx).astype(int)
    y0 = np.floor(fy).astype(int)
    ax = (fx - x0)[:, None]
    ay = (fy - y0)[:, None]
    t = tex.astype(np.float32) if tex.dtype != np.float32 else tex
    top = t[y0, x0] * (1 - ax) + t[y0, x0 + 1] * ax
    bot = t[y0 + 1, x0] * (1 - ax) + t[y0 + 1, x0 + 1] * ax
    return top * (1 - ay) + bot * ay


def _hash(i: np.ndarray, j: np.ndarray) -> np.ndarray:
    return (np.sin(i * 127.1 + j * 311.7) * 43758.5453) % 1.0 * 2.0 - 1.0


def _noise(x: np.ndarray, y: np.ndarray, scale: float) -> np.ndarray:
    """Smooth value noise in [-1, 1] at a given scale (metres)."""
    xs, ys = x / scale, y / scale
    x0, y0 = np.floor(xs), np.floor(ys)
    fx, fy = xs - x0, ys - y0
    u, v = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a = _hash(x0, y0) * (1 - u) + _hash(x0 + 1, y0) * u
    b = _hash(x0, y0 + 1) * (1 - u) + _hash(x0 + 1, y0 + 1) * u
    return a * (1 - v) + b * v


def _detail(x: np.ndarray, y: np.ndarray, d: np.ndarray) -> np.ndarray:
    """Brightness texture for the near ground (dusty regolith), fading out by ~80 m.
    It is decoration for the eye, not data: the images cannot resolve anything this small."""
    wgt = np.clip(1.0 - d / 80.0, 0.0, 1.0)
    grain = 0.09 * _noise(x, y, 0.35) + 0.07 * _noise(x + 17.3, y - 4.1, 1.4) + 0.05 * _noise(x - 3.7, y + 9.2, 5.0)
    return (1.0 + wgt * grain).astype(np.float32)


def _grade(col: np.ndarray) -> np.ndarray:
    """A gentle contrast and saturation lift for the soft HiRISE colour mosaic."""
    mean = col.mean(axis=1, keepdims=True)
    col = mean + (col - mean) * 1.18
    return np.clip((col - 128.0) * 1.08 + 128.0, 0, 255)


def _draw_flag(im: Image.Image, site, flag: tuple, x0: float, y0: float, ze: float, heading: float, focal: float, hz_row: float):
    from PIL import ImageDraw
    lon, lat, label = flag
    fx, fy = (float(v) for v in site.grid.lonlat_to_xy(lon, lat))
    dx, dy = fx - x0, fy - y0
    dist = math.hypot(dx, dy)
    rel = math.radians(((math.degrees(math.atan2(dx, dy)) - heading + 180) % 360) - 180)
    if dist < 1.0 or abs(rel) > math.radians(80):
        return
    r1, c1 = site.grid.xy_to_rowcol(fx, fy)
    zf = float(sample_bilinear(site.dem1, np.array([r1]), np.array([c1]))[0])
    if not np.isfinite(zf):
        return
    depth = dist * math.cos(rel)
    sx = im.width / 2 + math.tan(rel) * focal
    base = hz_row - (zf - ze) / depth * focal
    top = hz_row - (zf + 2.2 - ze) / depth * focal
    if not (0 <= sx < im.width):
        return
    dr = ImageDraw.Draw(im)
    pw = max(1, int(round(0.05 / depth * focal)))
    dr.line([(sx, base), (sx, top)], fill=(245, 245, 245), width=pw)
    fl = max(8.0, 0.9 / depth * focal)
    dr.polygon([(sx, top), (sx + fl * 1.4, top + fl * 0.45), (sx, top + fl * 0.9)], fill=(255, 128, 40), outline=(90, 30, 10))
    dr.text((sx + fl * 1.6, top - 2), label, fill=(255, 245, 230), stroke_width=2, stroke_fill=(40, 20, 10))


def arrival_viewpoint(path, back_m: float = 16.0):
    """Where the crew stands a few steps before the stop, and the heading to it: (lon, lat, heading)."""
    a = np.asarray(path, float)
    end = a[-1]
    lat0 = math.radians(end[1])
    dx = (a[:, 0] - end[0]) * math.cos(lat0) * 59274.0
    dy = (a[:, 1] - end[1]) * 59274.0
    dd = np.hypot(dx, dy)
    idx = np.flatnonzero(dd >= back_m)
    k = int(idx[-1]) if idx.size else 0
    lon, lat = float(a[k, 0]), float(a[k, 1])
    hd = math.degrees(math.atan2(-dx[k], -dy[k])) % 360.0 if dd[k] > 0.5 else heading_into(path)
    return lon, lat, hd

def sun_at(site, when: datetime) -> tuple[float, float]:
    el, az, _ = mars24.sun_position(mars24.mars_time(when), site.grid.lat0, site.grid.lon0)
    return float(el), float(az)


def heading_into(path, back_m: float = 18.0) -> float:
    """Compass heading of the last stretch of a [lon, lat] path (the way the crew arrives)."""
    a = np.asarray(path, float)
    if len(a) < 2:
        return 0.0
    lat0 = math.radians(a[-1, 1])
    dx = (a[:, 0] - a[-1, 0]) * math.cos(lat0) * 59274.0
    dy = (a[:, 1] - a[-1, 1]) * 59274.0
    d = np.hypot(dx, dy)
    k = int(np.flatnonzero(d >= back_m)[-1]) if np.any(d >= back_m) else 0
    return math.degrees(math.atan2(-dx[k], -dy[k])) % 360.0


def render(site, lon: float, lat: float, heading: float, when: datetime, w: int = 640, h: int = 300,
           hfov: float = 70.0, horizon_frac: float = 0.4, flag: tuple | None = None) -> Image.Image:
    A = _site_assets(site)
    g1, g2 = site.grid, site.grid2
    sun_el, sun_az = sun_at(site, when)
    x0, y0 = (float(v) for v in g1.lonlat_to_xy(lon, lat))
    r0, c0 = g1.xy_to_rowcol(x0, y0)
    z_ground = float(sample_bilinear(site.dem1, np.array([r0]), np.array([c0]))[0])
    if not np.isfinite(z_ground):
        z_ground = float(sample_bilinear(site.z2, *g2.xy_to_rowcol(x0, y0))) if np.isfinite(site.z2).any() else 0.0
    ze = z_ground + EYE_M

    # terrain shadow for this sun (4 m grid, sampled smoothly); the regional model is shaded per sample too
    lit4 = 1.0 - (site.shadow_grid(sun_el, sun_az) > 0).astype(np.float32)
    reg, rgrid = A["reg"], A["rgrid"]
    sun_v = _sun_vector(sun_el, sun_az)

    # rays: one per column, distances growing ~1.1 % a step
    focal = (w / 2) / math.tan(math.radians(hfov / 2))
    cols = np.arange(w)
    ang = np.degrees(np.arctan((cols - (w - 1) / 2) / focal))
    az = np.radians(heading + ang)
    dirx, diry = np.sin(az), np.cos(az)
    cosang = np.cos(np.radians(ang))
    max_d = 60000.0 if reg is not None else math.hypot(g1.width * g1.res, g1.height * g1.res)
    ds = [1.0]
    while ds[-1] < max_d:
        ds.append(ds[-1] + max(0.12, ds[-1] * 0.011))
    d = np.asarray(ds)[:, None]
    X = x0 + d * dirx[None, :]
    Y = y0 + d * diry[None, :]
    K = d.shape[0]
    Z = np.full((K, w), -np.inf, np.float32)
    C = np.zeros((K, w, 3), np.float32)

    # site: 1 m model close by, 2 m beyond; colour and shading interpolated, so the ground stays smooth up close
    r2, c2 = g2.xy_to_rowcol(X, Y)
    inside = (r2 >= 1) & (r2 <= g2.height - 2) & (c2 >= 1) & (c2 <= g2.width - 2)
    near = inside & (d < 220.0)
    far = inside & ~near
    lam = np.zeros((K, w), np.float32)
    if near.any():
        r1, c1 = g1.xy_to_rowcol(X[near], Y[near])
        Z[near] = sample_bilinear(site.dem1, r1, c1)
        lam[near] = _lambert_at(site.dem1, r1, c1, g1.res, sun_v)
    if far.any():
        Z[far] = sample_bilinear(site.z2, r2[far], c2[far])
        lam[far] = _lambert_at(site.z2, r2[far], c2[far], g2.res, sun_v)
    if inside.any():
        th, tw = A["tex"].shape[:2]
        fx = (X[inside] - g1.x_min) / (g1.width * g1.res) * tw - 0.5
        fy = (g1.y_max - Y[inside]) / (g1.height * g1.res) * th - 0.5
        lit = sample_bilinear(lit4, r2[inside] / 2.0 - 0.25, c2[inside] / 2.0 - 0.25, fill=1.0)
        sh = _light(lam[inside] * np.where(np.isfinite(lit), lit, 1.0), sun_el)
        col = _tex_bilinear(A["tex"], fx, fy)
        col = _grade(col)
        C[inside] = col * (sh * _detail(X[inside], Y[inside], np.broadcast_to(d, (K, w))[inside]))[:, None]
    # beyond the site: the regional model, if there is one
    if reg is not None:
        lonx, latx = g1.xy_to_lonlat(X, Y)
        rr, rc = rgrid.lonlat_to_rowcol(lonx, latx)
        out = ~inside & (rr >= 1) & (rr <= reg.shape[0] - 2) & (rc >= 1) & (rc <= reg.shape[1] - 2)
        if out.any():
            Z[out] = sample_bilinear(reg, rr[out], rc[out])
            sh = _light(_lambert_at(reg, rr[out], rc[out], rgrid.res, sun_v), sun_el)
            if A["rtex"] is not None:
                th, tw = A["rtex"].shape[:2]
                col = _tex_bilinear(A["rtex"], (rc[out] + 0.5) / reg.shape[1] * tw - 0.5, (rr[out] + 0.5) / reg.shape[0] * th - 0.5)
            else:
                col = np.full((int(out.sum()), 3), (176, 112, 80), np.float32)
            C[out] = col * sh[:, None]
    Z = np.where(np.isfinite(Z), Z, -np.inf)

    # projection with Mars' curvature; the first sample above each pixel row wins
    drop = (d * d) / (2 * MARS_R)
    hz_row = h * horizon_frac
    yproj = hz_row - (Z - drop - ze) / (d * cosang[None, :]) * focal
    yproj = np.where(np.isfinite(yproj), yproj, np.inf)
    run = np.minimum.accumulate(yproj, axis=0)
    rows = np.arange(h)

    # sky: dusty butterscotch at the horizon, darker above, a blue glow around the sun
    alt = np.degrees(np.arctan((hz_row - rows) / focal))[:, None]
    t = np.clip(alt / 35.0, 0, 1)
    horizon_c = np.array([214, 168, 128], np.float32)
    zenith_c = np.array([128, 92, 82], np.float32)
    sky = horizon_c * (1 - t[..., None]) + zenith_c * t[..., None]
    sky = np.broadcast_to(sky, (h, w, 3)).copy()
    pix_az = np.radians(heading + ang)[None, :]
    pa, se, sa = np.radians(alt), math.radians(sun_el), math.radians(sun_az)
    cosg = np.sin(pa) * math.sin(se) + np.cos(pa) * math.cos(se) * np.cos(pix_az - sa)
    gam = np.degrees(np.arccos(np.clip(cosg, -1, 1)))
    if sun_el > -4:
        glow = np.exp(-gam / 9.0) * (0.55 if sun_el < 25 else 0.3)
        sky = sky * (1 - glow[..., None]) + np.array([150, 185, 230], np.float32) * glow[..., None]
        sky = np.where((gam < 0.25)[..., None], np.array([255, 252, 240], np.float32), sky)
        sky = sky + (np.exp(-gam / 1.2) * 90)[..., None]

    img = sky
    haze_c = horizon_c
    for c in range(w):
        m = run[:, c]
        k = np.searchsorted(-m, -rows, side="left")  # first step whose terrain reaches up to this row
        hit = k < K
        if not hit.any():
            continue
        kk = k[hit]
        dist = d[kk, 0]
        hz = 1.0 - np.exp(-dist / 14000.0)
        img[hit, c] = C[kk, c] * (1 - hz[:, None]) + haze_c * hz[:, None]
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    if flag is not None:
        _draw_flag(im, site, flag, x0, y0, ze, heading, focal, hz_row)
    return im


def data_uri(im: Image.Image, quality: int = 86) -> str:
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def compass(deg: float) -> str:
    names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
    return names[int(((deg % 360) + 22.5) // 45) % 8]


def sun_words(sun_el: float, sun_az: float, heading: float) -> str:
    if sun_el <= 0:
        return "the sun is down"
    rel = (sun_az - heading + 180) % 360 - 180
    where = "ahead" if abs(rel) < 35 else "behind you" if abs(rel) > 145 else ("to your right" if rel > 0 else "to your left")
    return f"sun {sun_el:.0f}° high in the {compass(sun_az)}, {where}"


def pick_photo(items: list[dict]) -> dict | None:
    """The best rover photo of a sol for a postcard: a colour mast camera first, then a navigation camera."""
    def rank(it):
        cam = (it.get("camera") or "") + " " + (it.get("instrument") or "")
        for i, key in enumerate(("Mastcam-Z", "Mastcam", "MAST", "Navcam", "NAV")):
            if key.lower() in cam.lower():
                return i
        return 9
    good = sorted(items, key=rank)
    return good[0] if good else None


class Budget:
    """A wall-clock budget for slow network calls, so a page never waits long on the raw image feed."""

    def __init__(self, seconds: float):
        self.end = time.monotonic() + seconds

    def left(self) -> float:
        return max(0.0, self.end - time.monotonic())


# ------------------------------------------------------------------ postcards for a plan
def _nearest_rover_sols(site, lon: float, lat: float):
    import json
    p = site.dir / "rover_waypoints.geojson"
    if not p.exists():
        return None
    feats = sorted(json.loads(p.read_text())["features"], key=lambda f: f["properties"].get("sol") or 0)
    if not feats:
        return None
    lons = np.array([f["geometry"]["coordinates"][0] for f in feats])
    lats = np.array([f["geometry"]["coordinates"][1] for f in feats])
    x, y = site.grid.lonlat_to_xy(lons, lats)
    x0, y0 = site.grid.lonlat_to_xy(lon, lat)
    dist = np.hypot(np.asarray(x) - float(x0), np.asarray(y) - float(y0))
    k = int(np.argmin(dist))
    sol = feats[k]["properties"]["sol"]
    nxt = feats[k + 1]["properties"]["sol"] if k + 1 < len(feats) else sol
    return {"sol": sol, "sol_end": max(sol, min((nxt or sol) - 1, sol + 2)), "distance_m": float(dist[k])}


def rover_photo(site, lon: float, lat: float, budget: Budget) -> dict | None:
    """The rover's own photo from the waypoint nearest the stop, or None if the feed is slow or empty."""
    from concurrent.futures import ThreadPoolExecutor
    from concurrent.futures import TimeoutError as FutTimeout

    from . import rover_images
    mission = (site.cfg.get("rover") or {}).get("raw_images_mission")
    near = _nearest_rover_sols(site, lon, lat)
    if not mission or not near or budget.left() <= 0.2:
        return None
    pool = ThreadPoolExecutor(max_workers=1)
    fut = pool.submit(rover_images.landscapes, mission, near["sol"], near["sol_end"])
    pool.shutdown(wait=False)  # a slow feed finishes in the background and is cached for next time
    try:
        items = fut.result(timeout=budget.left())
    except (FutTimeout, Exception):
        return None
    best = items[0] if items else None  # already ranked: looking out over the terrain, widest frame first
    if not best:
        return None
    rover = (site.cfg.get("rover") or {}).get("name") or site.cfg.get("rover_name") or "the rover"
    return {**best, "distance_m": round(near["distance_m"]), "rover": rover}


def _hm(ltst_h) -> str:
    if ltst_h is None:
        return "—"
    m = int(round(float(ltst_h) * 60)) % (24 * 60)
    return f"{m // 60:02d}:{m % 60:02d}"


def cards_for_plan(site, plan: dict, w: int = 640, h: int = 300, photos: bool = True, budget_s: float = 8.0) -> list[dict]:
    from datetime import timedelta
    start = datetime.fromisoformat(plan["totals"]["start_utc"].replace("Z", "+00:00"))
    stops = [e for e in plan["events"] if e["kind"] == "stop"]
    legs = plan.get("legs") or []
    budget = Budget(budget_s)
    out = []
    for i, ev in enumerate(stops):
        if i >= len(legs) or len(legs[i]["path"]) < 2:
            continue
        path = legs[i]["path"]
        lon, lat, hd = arrival_viewpoint(path)
        when = start + timedelta(seconds=float(ev["t0"]))
        im = render(site, lon, lat, hd, when, w=w, h=h, flag=(path[-1][0], path[-1][1], ev["name"]))
        el, az = sun_at(site, when)
        t = int(ev["t0"] // 60)
        out.append({"n": i + 1, "name": ev["name"], "img": data_uri(im), "t_plus": f"T+{t // 60}:{t % 60:02d}",
                    "ltst": _hm(ev.get("t0_ltst")), "sun": sun_words(el, az, hd), "heading": round(hd),
                    "photo": rover_photo(site, path[-1][0], path[-1][1], budget) if photos else None})
    return out


def render_html(site, plan: dict, cards: list[dict], patch_svg_for=None) -> str:
    from html import escape
    cfg = site.cfg
    tt = plan["totals"]
    blocks = []
    for c in cards:
        ph = c.get("photo")
        if ph:
            photo = (f'<a href="{escape(ph["url"])}" target="_blank" rel="noreferrer"><img src="{escape(ph["url"])}" alt="{escape(ph.get("title") or "")}" referrerpolicy="no-referrer"></a>'
                     f'<div class="pcap">{escape(ph["rover"])} · {escape(ph.get("camera") or "")} · sol {ph.get("sol")} · {ph["distance_m"]} m from the stop</div>')
        else:
            photo = '<div class="nophoto">No rover photo to hand: the raw image feed did not answer in time, or no rover stood near here.</div>'
        stamp = patch_svg_for(c["n"]) if patch_svg_for else ""
        blocks.append(f"""<section class="card"><div class="render"><img src="{c['img']}" alt="Rendered arrival view at {escape(c['name'])}"><span class="tag">RENDERED FROM HIRISE TERRAIN</span></div>
<div class="photo">{photo}</div>
<div class="cap"><div class="stamp">{stamp}</div><b>{c['n']}. {escape(c['name'])}</b><br>Arriving {c['t_plus']} · {c['ltst']} local solar time · walking {c['heading']}° · {escape(c['sun'])}.
<span class="dim">Left: what the crew should see a few steps before the stop, rendered from the terrain model and the HiRISE colour image for this sun. Right: the rover's own photo from the nearest place it stood.</span></div></section>""")
    body = "".join(blocks) or "<p>No stops to show.</p>"
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Arrival postcards · {escape(cfg.get('name', ''))}</title>
<style>
body {{ margin: 0; padding: 24px; background: #141821; color: #ece6dc; font-family: Georgia, 'Times New Roman', serif; }}
h1 {{ font: 800 22px/1.2 Arial, Helvetica, sans-serif; letter-spacing: .1em; margin: 0 auto 4px; max-width: 1080px; }}
.sub {{ color: #b9b0a4; font: 13px Arial, Helvetica, sans-serif; margin: 0 auto 20px; max-width: 1080px; }}
.card {{ background: #f6efe3; color: #2a2119; border-radius: 10px; padding: 12px; margin: 0 auto 24px; max-width: 1080px;
  box-shadow: 0 12px 30px rgba(0, 0, 0, .45); display: grid; grid-template-columns: minmax(0, 640fr) minmax(0, 400fr); gap: 12px; }}
.card img {{ width: 100%; border-radius: 6px; display: block; }}
.render {{ position: relative; }}
.tag {{ position: absolute; left: 8px; top: 8px; background: rgba(0, 0, 0, .55); color: #fff; font: 700 10px Arial, sans-serif; padding: 3px 7px; border-radius: 4px; letter-spacing: .08em; }}
.photo img {{ height: 300px; object-fit: cover; }}
.pcap {{ font: 11px Arial, sans-serif; color: #6b5d4f; margin-top: 4px; }}
.nophoto {{ height: 100%; min-height: 160px; display: grid; place-items: center; text-align: center; padding: 16px; border: 2px dashed #c9b9a3; border-radius: 6px; color: #7a6a58; font: 13px Arial, sans-serif; }}
.cap {{ grid-column: 1 / -1; font-size: 16px; line-height: 1.45; }}
.cap b {{ font: 800 15px Arial, sans-serif; letter-spacing: .05em; }}
.dim {{ display: block; color: #7a6a58; font: 12px Arial, sans-serif; margin-top: 4px; }}
.stamp {{ float: right; margin: 0 0 6px 12px; padding: 4px; border: 2px dashed #b59a76; border-radius: 4px; background: #fff8ec; }}
.stamp svg {{ width: 74px; height: 74px; display: block; }}
@media print {{ body {{ background: #fff; color: #111; padding: 0; }} .card {{ box-shadow: none; break-inside: avoid; border: 1px solid #ccc; }} }}
@media (max-width: 760px) {{ .card {{ grid-template-columns: 1fr; }} .photo img {{ height: auto; }} }}
</style></head><body>
<h1>ARRIVAL POSTCARDS · {escape(cfg.get('short_name') or cfg.get('name', ''))}</h1>
<div class="sub">Sol {tt.get('mission_sol')} · egress {escape(str(tt.get('start_utc', ''))[:16].replace('T', ' '))} UTC · {tt['dist_m'] / 1000:.2f} km · generated by Martian Map (not a NASA product). Terrain: HiRISE DTM (USGS) and colour (NASA/JPL/UArizona); rover photos: NASA/JPL-Caltech raw image feeds.</div>
{body}
</body></html>"""
