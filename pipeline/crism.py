"""CRISM mineral-indicator maps for a site (MRO Compact Reconnaissance Imaging Spectrometer).

Source: the map-projected summary-parameter *browse* composites that ship with CRISM's MTRDR
products on the PDS Geosciences Node, found through the PDS Orbital Data Explorer REST API.
Each composite puts three spectral parameters in R, G and B, e.g. HYD = (SINDEX2, BD2100_2,
BD1900_2): polyhydrated sulfates, monohydrated sulfates, bound water.

The labels describe an equirectangular grid centred on the equator, so a pixel's longitude and
latitude come straight from MAP_RESOLUTION (pixels per degree) and the corner coordinates.
Every observation is resampled onto the site's 4 m grid and the observations are mosaicked
(full-resolution FRT beats half-resolution HRL, larger site coverage on top).

Registration: as delivered, the browse products sit 100-300 m off the HiRISE terrain (they are placed
from the spacecraft's pointing). Each observation's enhanced true-colour browse (TRU, or the IR albedo
IRA) is phase-correlated with the site's HiRISE colour mosaic at 16 m, and the shift that lines them
up is applied to every mineral composite of that observation. A shift is used only when it clearly
improves the match (correlation after >= 0.2 and at least 0.1 better than before, under 600 m).
"""

from __future__ import annotations

import io
import json
import logging
import re
from pathlib import Path

import numpy as np
from PIL import Image

from scipy import ndimage

from marsgeo.grid import SiteGrid, sample_bilinear
from marsgeo.net import session

log = logging.getLogger(__name__)

ODE = "https://oderest.rsl.wustl.edu/live2/"
KINDS = ("HYD", "PHY", "MAF", "FEM")

ABOUT = {
    "HYD": ("CRISM hydrated minerals & sulfates",
            "Red = polyhydrated sulfates, green = monohydrated sulfates (e.g. kieserite), blue = bound water. "
            "Mount Sharp's boxwork lies in its sulfate-bearing layers; the ridges are thought to be fractures "
            "cemented by minerals that groundwater left behind."),
    "PHY": ("CRISM clays (phyllosilicates)",
            "Red = Fe/Mg clays, green = Al clays, blue = bound water. Clays form in long-lived liquid water; "
            "Curiosity drilled clay-rich layers lower on Mount Sharp."),
    "MAF": ("CRISM mafic (volcanic) minerals",
            "Red = olivine, green = low-calcium pyroxene, blue = high-calcium pyroxene. Mostly the dark "
            "basaltic sand that fills hollows and drifts against ridges."),
    "FEM": ("CRISM iron minerals",
            "Iron-bearing minerals: red = crystalline ferric oxides such as hematite, green and blue = other "
            "ferric and ferrous absorptions. Hematite marked Vera Rubin Ridge on Curiosity's way up."),
}


def find_products(bbox) -> list[dict]:
    """MTRDR products overlapping bbox = (lon_min, lat_min, lon_max, lat_max), with their browse files."""
    params = {"query": "product", "results": "fp", "output": "JSON", "target": "mars", "ihid": "MRO",
              "iid": "CRISM", "pt": "MTRDR", "westernlon": bbox[0], "easternlon": bbox[2],
              "minlat": bbox[1], "maxlat": bbox[3], "limit": 100}
    js = session().get(ODE, params=params, timeout=120).json()
    prods = js.get("ODEResults", {}).get("Products", {}).get("Product", [])
    prods = prods if isinstance(prods, list) else [prods]
    out = []
    for p in prods:
        files = p.get("Product_files", {}).get("Product_file", [])
        files = files if isinstance(files, list) else [files]
        browse: dict = {}
        for f in files:
            m = re.match(r".*_BR(\w{3})J_MTR3\.(PNG|LBL)$", str(f.get("FileName", "")).upper())
            if m:
                browse.setdefault(m.group(1), {})[m.group(2).lower()] = f.get("URL")
        out.append({"pdsid": str(p.get("pdsid", "")).lower(), "browse": browse})
    return out


def parse_label(txt: str) -> dict:
    def num(key):
        m = re.search(r"^\s*%s\s*=\s*([-+0-9.]+)" % key, txt, re.M)
        return float(m.group(1)) if m else None
    bands = []
    m = re.search(r"BAND_NAME\s*=\s*\(([^)]*)\)", txt, re.S)
    if m:
        bands = [b.strip().strip('"') for b in m.group(1).split(",")]
    lab = {"lines": int(num("LINES") or 0), "samples": int(num("LINE_SAMPLES") or 0), "res": num("MAP_RESOLUTION"),
           "north": num("MAXIMUM_LATITUDE"), "south": num("MINIMUM_LATITUDE"),
           "west": num("WESTERNMOST_LONGITUDE"), "east": num("EASTERNMOST_LONGITUDE"), "bands": bands}
    if None in (lab["res"], lab["north"], lab["west"]):
        raise ValueError("label lacks map projection keywords")
    return lab


def _fetch(url: str, cache: Path) -> bytes:
    cache.mkdir(parents=True, exist_ok=True)
    p = cache / url.rsplit("/", 1)[-1].lower()
    if p.exists() and p.stat().st_size > 0:
        return p.read_bytes()
    r = session().get(url, timeout=120)
    r.raise_for_status()
    p.write_bytes(r.content)
    return r.content


def to_grid(rgba: np.ndarray, lab: dict, grid: SiteGrid, shift_m=(0.0, 0.0)):
    """Resample a CRISM browse image onto the site grid. Returns (rgb float HxWx3, valid HxW bool).

    shift_m = (east, north): where the browse image shows the ground relative to where it really is (from
    register()); the ground at a site point is read that far away in the image."""
    rows, cols = np.mgrid[0:grid.height, 0:grid.width]
    x, y = grid.rowcol_to_xy(rows, cols)
    lon, lat = grid.xy_to_lonlat(x + shift_m[0], y + shift_m[1])
    c = (lon - lab["west"]) * lab["res"] - 0.5
    r = (lab["north"] - lat) * lab["res"] - 0.5
    h, w = rgba.shape[:2]
    ri = np.clip(np.rint(r).astype(int), 0, h - 1)
    ci = np.clip(np.rint(c).astype(int), 0, w - 1)
    inside = (r >= -0.5) & (r <= h - 0.5) & (c >= -0.5) & (c <= w - 0.5)
    valid = inside & (rgba[ri, ci, 3] > 0)
    rgb = np.stack([sample_bilinear(rgba[..., k].astype(np.float32), r, c, fill=0.0) for k in range(3)], axis=-1)
    return np.nan_to_num(rgb), valid


REG_CELL = 4          # registration on 16 m cells (4 x the 4 m grid): about one CRISM FRT pixel
REG_MAX_M = 600.0
REG_MIN_AFTER = 0.2
REG_MIN_GAIN = 0.1


def _ncc(a: np.ndarray, b: np.ndarray, m: np.ndarray) -> float:
    x = a[m] - a[m].mean()
    y = b[m] - b[m].mean()
    den = float(np.sqrt((x * x).sum() * (y * y).sum()))
    return float((x * y).sum() / den) if den > 0 else 0.0


def register(gray: np.ndarray, valid: np.ndarray, ref: np.ndarray, res: float, cell: int = REG_CELL) -> dict | None:
    """The shift that lines a CRISM image (on the site grid) up with a reference image of the same ground.

    gray, valid: the CRISM browse resampled onto the grid (to_grid without a shift); ref: the HiRISE colour mosaic as
    grey on the same grid. Both are averaged to `cell` x `cell` blocks, high-passed (albedo gradients and the two
    stretches differ) and phase-correlated over the part of the site the observation covers. Returns
    {east_m, north_m, ncc_before, ncc_after, used}: (east, north) is where the image shows the ground relative to
    where it is; `used` is False when the match is not clearly better (the shift is then not applied)."""
    from .team_dem import phase_correlation

    H, W = (gray.shape[0] // cell) * cell, (gray.shape[1] // cell) * cell

    def down(a):
        return a[:H, :W].reshape(H // cell, cell, W // cell, cell).mean(axis=(1, 3))

    a, b = down(ref.astype(np.float64)), down(gray.astype(np.float64))
    v = down(valid.astype(np.float64)) > 0.99
    rows = np.flatnonzero(v.mean(axis=1) > 0.6)
    cols = np.flatnonzero(v.mean(axis=0) > 0.6)
    if len(rows) < 24 or len(cols) < 24:
        return None
    a, b, v = a[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1], b[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1], v[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1]
    if v.mean() < 0.5:
        return None

    def hp(x):
        x = np.where(v, x, np.median(x[v]))
        return x - ndimage.gaussian_filter(x, 3.0)

    ha, hb = hp(a), hp(b)
    dr, dc, _ = phase_correlation(ha, hb)
    shifted = ndimage.shift(hb, (-dr, -dc), order=1, mode="nearest")
    before, after = _ncc(ha, hb, v), _ncc(ha, shifted, v)
    east, north = dc * cell * res, -dr * cell * res
    used = bool(after >= REG_MIN_AFTER and after - before >= REG_MIN_GAIN and np.hypot(east, north) <= REG_MAX_M)
    return {"east_m": round(float(east), 1), "north_m": round(float(north), 1),
            "ncc_before": round(before, 3), "ncc_after": round(after, 3), "used": used}


def _registration(p: dict, grid4: SiteGrid, ref: np.ndarray | None, cache: Path) -> dict | None:
    """register() for one observation, from its true-colour browse (or the IR albedo when there is none)."""
    if ref is None:
        return None
    for kind in ("TRU", "IRA"):
        u = p["browse"].get(kind, {})
        if "png" not in u or "lbl" not in u:
            continue
        try:
            lab = parse_label(_fetch(u["lbl"], cache).decode("latin-1"))
            img = np.asarray(Image.open(io.BytesIO(_fetch(u["png"], cache))).convert("RGBA"))
        except Exception as e:
            log.warning("CRISM %s %s (registration) skipped: %s", p["pdsid"], kind, e)
            continue
        rgb, valid = to_grid(img, lab, grid4)
        r = register(rgb.mean(axis=2), valid, ref, grid4.res)
        if r is not None:
            r["from"] = kind
            return r
    return None


def reference_gray(texture: Path, grid4: SiteGrid) -> np.ndarray | None:
    """The site's HiRISE colour mosaic (texture_4096.jpg, already in the terrain's frame) as grey on the 4 m grid."""
    if not texture.exists():
        return None
    Image.MAX_IMAGE_PIXELS = None
    im = Image.open(texture).convert("L").resize((grid4.width, grid4.height), Image.BOX)
    return np.asarray(im, np.float32)


def build(out_dir: Path, grid4: SiteGrid, bbox, cache: Path, kinds=KINDS, notes: dict | None = None,
          reference: Path | None = None) -> dict:
    """notes: per-site description per kind (config `crism_notes`), replacing the Gale text in ABOUT.
    reference: the site's HiRISE colour mosaic, to register each observation to (see register())."""
    prods = find_products(bbox)
    log.info("CRISM: %d MTRDR observations overlap the site", len(prods))
    meta = {"source": "MRO CRISM MTRDR browse products, PDS Geosciences Node (via ODE REST)", "layers": {},
            "registration": {}}
    ref = reference_gray(reference, grid4) if reference is not None else None
    shifts = {}
    for p in prods:
        r = _registration(p, grid4, ref, cache)
        if r is not None:
            meta["registration"][p["pdsid"]] = r
            if r["used"]:
                shifts[p["pdsid"]] = (r["east_m"], r["north_m"])
            log.info("CRISM %s: registered %+.0f m east, %+.0f m north (correlation %.2f -> %.2f)%s", p["pdsid"],
                     r["east_m"], r["north_m"], r["ncc_before"], r["ncc_after"], "" if r["used"] else ", not used")
    for kind in kinds:
        stack = []
        for p in prods:
            u = p["browse"].get(kind, {})
            if "png" not in u or "lbl" not in u:
                continue
            try:
                lab = parse_label(_fetch(u["lbl"], cache).decode("latin-1"))
                img = np.asarray(Image.open(io.BytesIO(_fetch(u["png"], cache))).convert("RGBA"))
            except Exception as e:  # one broken product should not sink the layer
                log.warning("CRISM %s %s skipped: %s", p["pdsid"], kind, e)
                continue
            rgb, valid = to_grid(img, lab, grid4, shifts.get(p["pdsid"], (0.0, 0.0)))
            cov = float(valid.mean())
            if cov < 0.02:
                continue
            full_res = 0 if p["pdsid"].startswith("hrl") else 1
            stack.append((full_res, cov, p["pdsid"], rgb, valid, lab))
        if not stack:
            continue
        stack.sort(key=lambda t: (t[0], t[1]))  # paint the lowest priority first, the best ends on top
        out = np.zeros((grid4.height, grid4.width, 4), np.uint8)
        covered = np.zeros((grid4.height, grid4.width), bool)
        for _, cov, pid, rgb, valid, lab in stack:
            out[valid, :3] = np.clip(rgb[valid], 0, 255).astype(np.uint8)
            covered |= valid
        # Opacity follows how much stronger than *typical for this site* the signal is, so a layer
        # whose browse stretch is bright everywhere (iron) still shows contrast. A faint veil marks
        # pixels with data but no notable signal; pixels without data stay fully transparent.
        signal = out[..., :3].max(axis=2).astype(np.float32)
        lo, hi = np.percentile(signal[covered], [50, 98]) if covered.any() else (0.0, 255.0)
        alpha = 35.0 + 220.0 * np.clip((signal - lo) / max(hi - lo, 1.0), 0.0, 1.0)
        out[..., 3] = np.where(covered, alpha, 0).astype(np.uint8)
        Image.fromarray(out, "RGBA").save(out_dir / f"crism_{kind.lower()}.png", optimize=True)
        name, about = ABOUT.get(kind, (f"CRISM {kind}", ""))
        about = (notes or {}).get(kind, about)
        meta["layers"][kind.lower()] = {
            "name": name, "about": about, "bands": stack[-1][5]["bands"],
            "products": [{"pdsid": t[2], "coverage": round(t[1], 3),
                          "shift_m": list(shifts.get(t[2], (0.0, 0.0)))} for t in reversed(stack)],
            "coverage": round(float((out[..., 3] > 0).mean()), 3),
        }
        log.info("CRISM %s: %d observations, %.0f %% of the site covered", kind, len(stack), meta["layers"][kind.lower()]["coverage"] * 100)
    (out_dir / "crism_meta.json").write_text(json.dumps(meta, indent=2))
    return meta
