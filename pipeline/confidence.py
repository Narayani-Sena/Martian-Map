"""How far to trust the terrain under each 2 m cell: do two independent HiRISE terrain models agree?

Our USGS DTM and the rover team's DTM (pipeline/team_dem.py) come from different stereo pairs and different
processing. After lining them up (shift, height offset and tilt removed), what is left is the error of both
together: matching failures in smooth or shadowed ground, interpolated patches, seams between stereo models.

    height disagreement  |our z - team z|                 confidence factor exp(-(d / 2 m)^2)
    slope disagreement   |our slope - team slope| (deg)   confidence factor exp(-(d / 8 deg)^2)
    confidence           product of the two, smoothed over ~5 m

Gaussian, so the ordinary disagreement of two 1 m stereo models (median 0.4-0.6 m and 2-3 deg on 2 m slopes)
keeps a high confidence, and only real disagreements (seams, matching failures, steep walls) pull it down.

Cells the team model does not cover get NaN (no second opinion). The slope disagreement is also kept as a
rough +/- on the slope the planner uses.
"""

from __future__ import annotations

import logging
from pathlib import Path

import numpy as np
from scipy import ndimage

from . import derive

log = logging.getLogger("pipeline.confidence")

HEIGHT_SCALE_M = 2.0
SLOPE_SCALE_DEG = 8.0


def build(site_dir: Path, z2: np.ndarray, res: float) -> dict | None:
    tp, dp = site_dir / "team_dem_2m.npy", site_dir / "dem_diff_2m.npy"
    if not (tp.exists() and dp.exists()):
        return None
    team = np.load(tp).astype(np.float32)
    diff = np.load(dp).astype(np.float32)
    ok = np.isfinite(team) & np.isfinite(diff)
    team_f = np.where(ok, team, z2)
    s_ours = derive.slope_deg(z2, res)
    s_team = derive.slope_deg(team_f, res)
    ds = np.abs(s_ours - s_team)
    dh = np.abs(diff)
    conf = np.exp(-(np.where(ok, dh, 0.0) / HEIGHT_SCALE_M) ** 2 - (ds / SLOPE_SCALE_DEG) ** 2)
    conf = ndimage.gaussian_filter(conf.astype(np.float32), 1.25)
    # ignore a 2-cell rim where the slope stencil sees no-data
    bad = ndimage.binary_dilation(~ok, iterations=2)
    conf = np.where(bad, np.nan, conf).astype(np.float32)
    slope_unc = np.where(bad, np.nan, ndimage.gaussian_filter(ds, 1.0)).astype(np.float32)
    np.save(site_dir / "terrain_conf_2m.npy", conf.astype(np.float16))
    np.save(site_dir / "slope_unc_2m.npy", slope_unc.astype(np.float16))
    v = np.isfinite(conf)
    meta = {"covered": round(float(v.mean()), 4),
            "height_diff_p50_p95_m": [round(float(x), 2) for x in np.percentile(dh[ok], [50, 95])],
            "slope_diff_p50_p95_deg": [round(float(x), 2) for x in np.percentile(ds[~bad], [50, 95])],
            "share_low": round(float((conf[v] < 0.5).mean()), 4),
            "source": "agreement between our USGS DTM and the rover team's DTM after alignment"}
    log.info("terrain confidence: %s", meta)
    return meta
