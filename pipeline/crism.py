"""CRISM mineral-indicator maps for a site (MRO Compact Reconnaissance Imaging Spectrometer).

Source: the map-projected summary-parameter *browse* composites that ship with CRISM's MTRDR
products on the PDS Geosciences Node, found through the PDS Orbital Data Explorer REST API.
Each composite puts three spectral parameters in R, G and B, e.g. HYD = (SINDEX2, BD2100_2,
BD1900_2): polyhydrated sulfates, monohydrated sulfates, bound water.

The labels describe an equirectangular grid centred on the equator, so a pixel's longitude and
latitude come straight from MAP_RESOLUTION (pixels per degree) and the corner coordinates.
Every observation is resampled onto the site's 4 m grid and the observations are mosaicked
(full-resolution FRT beats half-resolution HRL, larger site coverage on top).
"""

from __future__ import annotations

import io
import json
import logging
import re
from pathlib import Path

import numpy as np
from PIL import Image

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


def to_grid(rgba: np.ndarray, lab: dict, grid: SiteGrid):
    """Resample a CRISM browse image onto the site grid. Returns (rgb float HxWx3, valid HxW bool)."""
    rows, cols = np.mgrid[0:grid.height, 0:grid.width]
    x, y = grid.rowcol_to_xy(rows, cols)
    lon, lat = grid.xy_to_lonlat(x, y)
    c = (lon - lab["west"]) * lab["res"] - 0.5
    r = (lab["north"] - lat) * lab["res"] - 0.5
    h, w = rgba.shape[:2]
    ri = np.clip(np.rint(r).astype(int), 0, h - 1)
    ci = np.clip(np.rint(c).astype(int), 0, w - 1)
    inside = (r >= -0.5) & (r <= h - 0.5) & (c >= -0.5) & (c <= w - 0.5)
    valid = inside & (rgba[ri, ci, 3] > 0)
    rgb = np.stack([sample_bilinear(rgba[..., k].astype(np.float32), r, c, fill=0.0) for k in range(3)], axis=-1)
    return np.nan_to_num(rgb), valid


def build(out_dir: Path, grid4: SiteGrid, bbox, cache: Path, kinds=KINDS, notes: dict | None = None) -> dict:
    """notes: per-site description per kind (config `crism_notes`), replacing the Gale text in ABOUT."""
    prods = find_products(bbox)
    log.info("CRISM: %d MTRDR observations overlap the site", len(prods))
    meta = {"source": "MRO CRISM MTRDR browse products, PDS Geosciences Node (via ODE REST)", "layers": {}}
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
            rgb, valid = to_grid(img, lab, grid4)
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
            "products": [{"pdsid": t[2], "coverage": round(t[1], 3)} for t in reversed(stack)],
            "coverage": round(float((out[..., 3] > 0).mean()), 3),
        }
        log.info("CRISM %s: %d observations, %.0f %% of the site covered", kind, len(stack), meta["layers"][kind.lower()]["coverage"] * 100)
    (out_dir / "crism_meta.json").write_text(json.dumps(meta, indent=2))
    return meta
