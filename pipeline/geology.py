"""Geologic units from the USGS-NASA Planetary Geologic Mapping Program, on the site's 2 m grid.

The USGS publishes each map of the program as a public ArcGIS feature service (the "Interactive map" data
release linked from the map's publication page). We ask the service for the unit polygons that touch the
site, have the server reproject them to Mars 2000 sphere longitude/latitude (the maps use their own
Transverse Mercator or Robinson projections), and fill them onto the analysis grid with the map's own colours.

    Jezero: Sun & Stack (2020), USGS SIM 3464, 1:75,000
    Gale:   Tanaka et al. (2014), USGS SIM 3292 (global map), 1:20,000,000

Outputs: geology_2m.npy (uint8; 0 = not mapped, k = units[k-1]) and geology_meta.json.
"""

from __future__ import annotations

import hashlib
import json
import logging
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw

from marsgeo.grid import SiteGrid
from marsgeo.net import session

log = logging.getLogger("pipeline.geology")

# Geographic Mars 2000 sphere (IAU 49900); the service reprojects into it on request.
GCS_MARS = ('GEOGCS["GCS_Mars_2000_Sphere",DATUM["D_Mars_2000_Sphere",SPHEROID["Mars_2000_Sphere",3396190.0,0.0]],'
            'PRIMEM["Reference_Meridian",0.0],UNIT["Degree",0.0174532925199433]]')

# Field names differ between maps; the first one present wins.
FIELDS = {
    "code": ("symbol_noSub", "symbol", "Unit"),
    "key": ("unit", "Unit"),   # the field the map's renderer colours by
    "name": ("name", "UnitDesc"),
    "description": ("Unit_Description", "PrimaryCharacteristics"),
    "more": ("Additional_Characteristics", "AdditionalCharacteristics"),
    "interpretation": ("Unit_Interpretation", "Interpretation"),
}


def _pick(attrs: dict, kind: str) -> str:
    for f in FIELDS[kind]:
        v = attrs.get(f)
        if v not in (None, ""):
            return str(v).strip()
    return ""


def _get_json(url: str, params: dict, cache: Path) -> dict:
    """GET JSON through the on-disk cache (the services are public but we only need them once)."""
    key = hashlib.sha1((url + json.dumps(params, sort_keys=True)).encode()).hexdigest()[:16]
    p = cache / f"{key}.json"
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    r = session().get(url, params=params, timeout=120)
    r.raise_for_status()
    d = r.json()
    if "error" in d:
        raise RuntimeError(f"{url}: {d['error']}")
    cache.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d), encoding="utf-8")
    return d


def fetch(service: str, bbox, cache: Path) -> tuple[dict, list[dict]]:
    """The layer description (renderer colours) and the unit features touching bbox, rings in lon/lat."""
    layer = _get_json(service, {"f": "json"}, cache)
    lon0, lat0, lon1, lat1 = bbox
    sr = json.dumps({"wkt": GCS_MARS})
    q = _get_json(service.rstrip("/") + "/query", {
        "f": "json", "where": "1=1", "outFields": "*", "returnGeometry": "true",
        "geometry": json.dumps({"xmin": lon0, "ymin": lat0, "xmax": lon1, "ymax": lat1, "spatialReference": {"wkt": GCS_MARS}}),
        "geometryType": "esriGeometryEnvelope", "inSR": sr, "outSR": sr, "spatialRel": "esriSpatialRelIntersects",
        "geometryPrecision": 7,
    }, cache)
    return layer, q.get("features", [])


def _colors(layer: dict) -> dict:
    """renderer value -> (hex colour, label)."""
    r = (layer.get("drawingInfo") or {}).get("renderer") or {}
    out = {}
    for u in r.get("uniqueValueInfos", []):
        c = (u.get("symbol") or {}).get("color") or [160, 160, 160, 255]
        out[str(u.get("value"))] = ("#%02x%02x%02x" % tuple(int(x) for x in c[:3]), str(u.get("label") or ""))
    return out


def rasterize(features: list[dict], grid: SiteGrid) -> tuple[np.ndarray, list[int]]:
    """Fill each feature's rings (even-odd, so holes and islands come out right) onto grid.

    Returns the per-cell feature index + 1 (0 = none) and, per feature, its number of cells.
    Larger features are drawn first so a small unit inside a big one is never painted over.
    """
    h, w = grid.height, grid.width
    out = np.zeros((h, w), np.uint16)
    areas = []
    order = sorted(range(len(features)), key=lambda i: -float(features[i]["attributes"].get("Shape__Area") or 0.0))
    for i in order:
        rings = (features[i].get("geometry") or {}).get("rings") or []
        mask = Image.new("1", (w, h), 0)
        for ring in rings:
            if len(ring) < 3:
                continue
            pts = np.asarray(ring, dtype=float)
            rr, cc = grid.lonlat_to_rowcol(pts[:, 0], pts[:, 1])
            # PIL pixel (x, y) covers [x, x+1); grid cell centres sit at integer row/col
            poly = [(float(c) + 0.5, float(r) + 0.5) for r, c in zip(rr, cc)]
            ring_img = Image.new("1", (w, h), 0)
            ImageDraw.Draw(ring_img).polygon(poly, fill=1)
            mask = ImageChops.logical_xor(mask, ring_img)
        m = np.asarray(mask, dtype=bool)
        out[m] = i + 1
        areas.append(0)
    for i in range(len(features)):
        areas[i] = int((out == i + 1).sum())
    return out, areas


def build(out_dir: Path, grid2: SiteGrid, bbox, cfg: dict, cache: Path) -> dict | None:
    """cfg: the site's "geology" block: service, map, citation, scale, url, note."""
    layer, feats = fetch(cfg["service"], bbox, cache)
    if not feats:
        log.warning("geology: the map has no units over this site")
        return None
    colors = _colors(layer)
    feat_idx, cells = rasterize(feats, grid2)
    # one entry per unit (several polygons can share a unit)
    units: list[dict] = []
    by_code: dict[str, int] = {}
    lut = np.zeros(len(feats) + 1, np.uint8)
    total = grid2.width * grid2.height
    for i, f in enumerate(feats):
        a = f["attributes"]
        code = _pick(a, "code") or _pick(a, "key")
        if code not in by_code:
            col, label = colors.get(_pick(a, "key"), ("#a0a0a0", ""))
            desc = _pick(a, "description")
            more = _pick(a, "more")
            units.append({"code": code, "name": _pick(a, "name") or label or code, "color": col,
                          "description": desc + ((" " + more) if more else ""),
                          "interpretation": _pick(a, "interpretation"), "cells": 0})
            by_code[code] = len(units)
        k = by_code[code]
        lut[i + 1] = k
        units[k - 1]["cells"] += cells[i]
    grid_u8 = lut[feat_idx]
    for u in units:
        u["share"] = round(u.pop("cells") / total, 4)
    units_present = [u for u in units if u["share"] > 0]
    np.save(out_dir / "geology_2m.npy", grid_u8)
    meta = {"map": cfg.get("map", ""), "citation": cfg.get("citation", ""), "scale": cfg.get("scale", ""),
            "url": cfg.get("url", ""), "note": cfg.get("note", ""), "service": cfg["service"],
            "coverage": round(float((grid_u8 > 0).mean()), 4), "units": units}
    (out_dir / "geology_meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    log.info("geology: %d polygons, %d units on the site (%s), coverage %.0f %%", len(feats), len(units_present),
             ", ".join(f"{u['code']} {u['share']:.0%}" for u in units_present), meta["coverage"] * 100)
    return meta


def legend(meta: dict) -> dict:
    """Class legend for the units that cover at least a sliver of the site, biggest first."""
    present = [(i + 1, u) for i, u in enumerate(meta.get("units", [])) if u.get("share", 0) > 0]
    present.sort(key=lambda t: -t[1]["share"])
    return {"classes": [[f"{u['code']} · {u['name']}", u["color"]] for _, u in present]}


def colors_rgba(meta: dict, alpha: int = 200) -> np.ndarray:
    """Palette indexed like geology_2m.npy (index 0 transparent)."""
    out = [(0, 0, 0, 0)]
    for u in meta.get("units", []):
        h = u["color"].lstrip("#")
        out.append((int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), alpha))
    return np.array(out, np.uint8)


def load(site_dir: Path):
    """(grid uint8, meta) or (None, None) for a site built without it."""
    p, m = site_dir / "geology_2m.npy", site_dir / "geology_meta.json"
    if not (p.exists() and m.exists()):
        return None, None
    return np.load(p).astype(np.uint8), json.loads(m.read_text(encoding="utf-8"))
