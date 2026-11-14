"""Loose-sand likelihood (0..1) on the 2 m grid, and how far its clues agree.

Each clue is a robust z-score over the site (median 0, the 10-90 % spread scaled to 1), so the model reads
"sandier than this site's typical ground". They are added in logit space, like a small logistic regression:

    clue                          weight  why
    THEMIS night IR, cold          2.0    low thermal inertia: loose sand and dust cool fast at night (100 m pixels)
    HiRISE dark (~25 m scale)      0.3    basaltic sand is darker than the bedrock around it
    hollow (TPI, 15 m radius)      0.5    wind-blown sand collects in hollows (Gale's boxwork hollows)
    dark spot within that (2 m)    0.3    the local drift itself
    steeper than 25 deg           -1 per 5 deg   loose sand does not stay on steep ground
    USGS bedform / dune unit       +1.5   where the geologic map has one (Jezero: Aeb, 1:75,000)
    intercept                     -3.5    about one cell in ten is loose sand on an average site

Regional clues (thermal, dark, geology) set the share of loose sand in each ~100 m patch; local clues (hollow,
dark spot, steep) decide which 2 m cells inside the patch hold it (see combine). The thermal and darkness weights
and the intercept were fitted (logistic regression, spatial cross-validation:
train on one half of the site, test on the other) against Jezero's mapped eolian-bedform unit: night IR alone
separates it with a held-out AUC of 0.81, against 0.71 for the old hand-tuned score. THEMIS *day* IR was tested
and left out: its contrast depends on the afternoon hour of the images (Jezero's bedforms are cooler than rock in
the mosaic, the opposite of a midday image, even after removing slope and brightness effects), so its sign does
not carry from site to site. The local weights (hollow, dark spot, steep) are physical priors.

Confidence is the share of the clue evidence (the absolute logit contributions) that points the same way as the
result, rescaled so 1 = every clue agrees and 0 = evenly split.
"""

from __future__ import annotations

import numpy as np
from PIL import Image
from scipy import ndimage

WEIGHTS = {"thermal": 2.0, "dark": 0.3, "hollow": 0.5, "dark_local": 0.3, "geology": 1.5}
INTERCEPT = -3.5
STEEP_DEG, STEEP_PER = 25.0, 5.0
LABELS = {"thermal": "cold at night (THEMIS)", "dark": "dark in HiRISE colour", "hollow": "in a hollow",
          "dark_local": "dark local patch", "geology": "mapped dune/bedform unit"}
AGAINST = {"thermal": "warm at night, like rock (THEMIS)", "dark": "bright in HiRISE colour", "hollow": "on a rise",
           "dark_local": "bright local patch", "steep": "too steep to hold sand"}


def robust_z(v: np.ndarray) -> np.ndarray:
    """(v - median) / spread, spread = (p90 - p10) / 2.563 (one standard deviation for a normal distribution)."""
    ok = np.isfinite(v)
    med = float(np.median(v[ok]))
    lo, hi = np.percentile(v[ok], [10, 90])
    out = (v - med) / max(1e-6, (hi - lo) / 2.563)
    return np.where(ok, out, 0.0).astype(np.float32)


def resize(a: np.ndarray, shape) -> np.ndarray:
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize((shape[1], shape[0]), Image.BILINEAR), np.float32)


def bedform_units(geology_meta: dict | None) -> list[int]:
    """1-based unit indices whose name says bedform or dune (not every unit whose story mentions wind)."""
    if not geology_meta:
        return []
    return [i + 1 for i, u in enumerate(geology_meta.get("units", []))
            if any(w in str(u.get("name", "")).lower() for w in ("bedform", "dune"))]


def clues(slope, tpi, night=None, brightness=None, geology=None, geology_meta=None) -> dict[str, np.ndarray]:
    """Logit contribution of every clue (same shape as slope). Missing inputs simply contribute nothing."""
    H, W = slope.shape
    out: dict[str, np.ndarray] = {}
    if night is not None:
        out["thermal"] = WEIGHTS["thermal"] * -robust_z(resize(night, (H, W)) if night.shape != (H, W) else night)
    if brightness is not None:
        b = resize(brightness, (H, W)) if brightness.shape != (H, W) else brightness.astype(np.float32)
        # no-data in the colour mosaic (missing tiles are pure black) must not read as "dark"
        hole = b < 4.0
        if hole.any():
            b = np.where(hole, float(np.median(b[~hole])) if (~hole).any() else 128.0, b)
            hole = ndimage.binary_dilation(hole, iterations=24)
        b2 = ndimage.gaussian_filter(b, 2.0)
        b25 = ndimage.gaussian_filter(b, 12.0)
        out["dark"] = np.where(hole, 0.0, WEIGHTS["dark"] * -robust_z(b25)).astype(np.float32)
        out["dark_local"] = np.where(hole, 0.0, WEIGHTS["dark_local"] * -robust_z(b2 - b25)).astype(np.float32)
    out["hollow"] = WEIGHTS["hollow"] * -robust_z(tpi)
    out["steep"] = -np.clip((slope - STEEP_DEG) / STEEP_PER, 0.0, None).astype(np.float32)
    units = bedform_units(geology_meta)
    if geology is not None and units:
        out["geology"] = np.where(np.isin(geology, units), WEIGHTS["geology"], 0.0).astype(np.float32)
    return out


REGIONAL = ("thermal", "dark", "geology")   # say how much of a ~100 m patch is loose sand
LOCAL = ("hollow", "dark_local", "steep")    # say where inside the patch it lies
FOOTPRINT_PX = 25                            # Gaussian sigma on the 2 m grid: about a THEMIS pixel


def combine(parts: dict[str, np.ndarray], footprint_px: float = FOOTPRINT_PX) -> tuple[np.ndarray, np.ndarray]:
    """(likelihood 0..1, confidence 0..1) from the clues' logit contributions.

    Two scales: the regional clues give the share f of the surrounding ~100 m patch that is loose sand (a logistic
    model); the local clues give each 2 m cell a propensity L, and the patch's sand goes to the cells with the most
    of it: p = f * L / mean(L over the patch). The patch average stays f, but a 15 m hollow in mostly-rock boxwork
    still gets its drift, which a 100 m thermal pixel cannot see.
    """
    shape = next(iter(parts.values())).shape
    reg = INTERCEPT + sum((parts[k] for k in REGIONAL if k in parts), np.zeros(shape, np.float32))
    f = 1.0 / (1.0 + np.exp(-np.clip(reg, -30, 30)))
    loc = np.exp(np.clip(sum((parts[k] for k in LOCAL if k in parts), np.zeros(shape, np.float32)), -20, 5))
    m = ndimage.gaussian_filter(loc, footprint_px, mode="nearest")
    p = np.clip(f * loc / np.maximum(m, 1e-6), 0.0, 1.0)
    # agreement: the share of clue evidence on the side the result came down on (p >= 0.5 = sand). The geology
    # prior only votes where it says "sand" (outside a mapped unit the map is silent, not a vote against).
    sign = np.where(p >= 0.5, 1.0, -1.0)
    total = np.zeros(shape, np.float32)
    agree = np.zeros(shape, np.float32)
    for k, v in parts.items():
        a = np.abs(v)
        if k == "geology":
            a = np.where(v > 0, a, 0.0)
        total += a
        agree += np.where(np.sign(v) == sign, a, 0.0)
    share = np.where(total > 1e-6, agree / np.maximum(total, 1e-6), 0.5)
    conf = np.clip(2.0 * share - 1.0, 0.0, 1.0)
    return p.astype(np.float32), conf.astype(np.float32)


def explain(parts_at: dict[str, float], top: int = 3) -> dict:
    """Which clues push a point towards sand and which away, strongest first (for Inspect)."""
    items = sorted(((k, float(v)) for k, v in parts_at.items() if abs(float(v)) >= 0.15), key=lambda kv: -abs(kv[1]))
    return {"for": [LABELS.get(k, k) for k, v in items if v > 0][:top],
            "against": [AGAINST.get(k, k) for k, v in items if v < 0][:top]}
