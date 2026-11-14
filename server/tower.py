"""Layer tower (feature A2): one picture per data layer, for the exploded stack.

The brief asks for "a layered, integrated view". The tower shows it literally: every sheet is a real layer of
this site (the HiRISE mosaic, the terrain model, THEMIS, CRISM, the derived hazard and science layers and the
integrated plan), stacked with its mission and instrument, then let fall back into one surface. Sheets that are
transparent analysis layers are drawn over the site imagery, darkened, so each sheet reads on its own.
"""

from __future__ import annotations

import io

import numpy as np
from PIL import Image, ImageEnhance

# Which sheets make the tower (bottom first): (layer id, kind, title, instrument line).
SHEETS = [
    ("optical", "OPTICAL", "HiRISE colour mosaic, 25 cm · Mars Reconnaissance Orbiter"),
    ("elevation", "TOPOGRAPHIC", "HiRISE stereo terrain model, 1 m · MRO / USGS"),
    ("thermal", "THERMAL", "THEMIS night infrared, 100 m · Mars Odyssey"),
    ("crism_hyd", "SPECTRAL", "CRISM hydrated minerals and sulfates · MRO"),
    ("geology", "GEOLOGY", "USGS geologic map units"),
    ("hazard", "DERIVED · HAZARD", "slope, roughness, sand, boulders from the layers below"),
    ("science", "DERIVED · SCIENCE", "science opportunity: minerals, contacts, ridges, rover samples"),
    ("ways_home", "INTEGRATED · THE PLAN", "ways home, route and go / no-go from everything below"),
]
OPAQUE = {"optical", "elevation", "thermal"}


def sheets_for(site) -> list[dict]:
    """The tower for this site: only the layers it has (geology only where the map has more than one unit here)."""
    out = []
    for lid, kind, line in SHEETS:
        if lid == "thermal" and site.thermal4 is None:
            continue
        if lid.startswith("crism_"):
            if not site.crism:
                continue
            if lid[6:] not in site.crism:
                lid = f"crism_{next(iter(site.crism))}"
        if lid == "geology":
            gm = site.geology_meta or {}
            if site.geology2 is None or len([u for u in gm.get("units", []) if u.get("share", 0) > 0]) < 2:
                continue
        if lid == "science" and not site.science:
            continue
        out.append({"id": lid, "kind": kind, "line": line})
    return out


def base_image(site, size: int, darken: float = 1.0) -> Image.Image:
    im = Image.open(site.dir / "texture_2048.jpg").convert("RGB")
    if im.size != (size, size):
        im = im.resize((size, size), Image.LANCZOS)
    if darken != 1.0:
        im = ImageEnhance.Brightness(im).enhance(darken)
    return im


def hillshade_rgb(site, size: int) -> np.ndarray:
    hs = Image.fromarray(np.asarray(site.hillshade1)).convert("L").resize((size, size), Image.BILINEAR)
    return np.asarray(hs, np.float32) / 255.0


def compose(site, layer: str, size: int, overlay: Image.Image | None) -> Image.Image:
    """The sheet picture: opaque layers as they are (elevation shaded by the relief), transparent ones over the
    imagery darkened to 45 %."""
    if layer == "optical" or overlay is None:
        return base_image(site, size)
    ov = overlay.convert("RGBA").resize((size, size), Image.BILINEAR)
    if layer == "elevation":
        a = np.asarray(ov, np.float32)[..., :3]
        shade = hillshade_rgb(site, size)[..., None]
        rgb = np.clip(a * (0.35 + 0.85 * shade), 0, 255).astype(np.uint8)
        return Image.fromarray(rgb, "RGB")
    if layer in OPAQUE:
        bg = Image.new("RGB", (size, size), (0, 0, 0))
        bg.paste(ov, (0, 0), ov)
        return bg
    base = base_image(site, size, 0.45).convert("RGBA")
    return Image.alpha_composite(base, ov).convert("RGB")


def jpeg(im: Image.Image, quality: int = 86) -> bytes:
    buf = io.BytesIO()
    im.convert("RGB").save(buf, "JPEG", quality=quality, optimize=True)
    return buf.getvalue()
